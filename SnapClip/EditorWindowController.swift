import AppKit
import Foundation
import SwiftUI

enum EditorPresentationError: LocalizedError, Equatable {
  case invalidImage
  case windowUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidImage:
      return "无法读取这张截图。"
    case .windowUnavailable:
      return "无法创建编辑窗口。"
    }
  }
}

enum EditorCommitResult: Equatable {
  case accepted
  case rejected(message: String)
}

@MainActor
protocol EditorSessionDelegate: AnyObject {
  func editorDidBeginSession()
  func editorDidCancelSession()
  func editorDidRequestCommit(_ output: EditorOutput) -> EditorCommitResult
}

@MainActor
protocol ScreenshotEditing: AnyObject {
  var isPresenting: Bool { get }
  var sessionDelegate: EditorSessionDelegate? { get set }
  func presentNewCapture(pngData: Data, capturedAt: Date) throws
  func presentHistoryItem(_ item: ScreenshotItem) throws
  func discardActiveSession()
  func focus()
  func shutdown()
}

@MainActor
private struct EditorActiveSession {
  let pngData: Data
  let pixelSize: CGSize
  let capturedAt: Date
  let target: EditorTarget
  let sourceRevision: UInt64
}

@MainActor
private final class EditorWorkspaceView: NSView {
  let canvas: EditorCanvasView
  let toolbarHost: NSHostingView<EditorToolbarView>
  let statusLabel = NSTextField(labelWithString: "")

  init(
    canvas: EditorCanvasView,
    toolbar: EditorToolbarView
  ) {
    self.canvas = canvas
    self.toolbarHost = NSHostingView(rootView: toolbar)
    super.init(frame: .zero)

    canvas.translatesAutoresizingMaskIntoConstraints = false
    toolbarHost.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.textColor = .white
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.isHidden = true

    addSubview(canvas)
    addSubview(toolbarHost)
    addSubview(statusLabel)

    NSLayoutConstraint.activate([
      canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
      canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
      canvas.topAnchor.constraint(equalTo: topAnchor),
      canvas.bottomAnchor.constraint(equalTo: bottomAnchor),

      toolbarHost.centerXAnchor.constraint(equalTo: centerXAnchor),
      toolbarHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),

      statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusLabel.bottomAnchor.constraint(equalTo: toolbarHost.topAnchor, constant: -8),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func showError(_ message: String) {
    statusLabel.stringValue = message
    statusLabel.textColor = NSColor(
      srgbRed: 0xFF / 255,
      green: 0x6B / 255,
      blue: 0x5B / 255,
      alpha: 1
    )
    statusLabel.isHidden = false
  }

  func clearStatus() {
    statusLabel.isHidden = true
  }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, ScreenshotEditing {
  private let renderer: any ScreenshotRendering
  private let desktopExporter: any DesktopExportServing
  private let styleStore = EditorToolStyleStore()
  private let colorPanelCoordinator = ColorPanelCoordinator()
  private let ocrGate = OCRExecutionGate(ocrService: VisionOCRService())
  private var isOCRWorking = false
  weak var sessionDelegate: EditorSessionDelegate?

  private var window: NSWindow?
  private var workspace: EditorWorkspaceView?
  private let toolbarModel = EditorToolbarViewModel(
    model: EditorToolbarModel(
      tool: .selection,
      canUndo: false,
      isFrozen: false,
      isSaving: false,
      hasCropDraft: false
    )
  )
  private var session: EditorActiveSession?
  private var renderTask: Task<Void, Never>?
  private var ocrTask: Task<Void, Never>?
  private var eventMonitor: Any?

  init(
    renderer: any ScreenshotRendering = ScreenshotRenderer(),
    desktopExporter: any DesktopExportServing = DesktopExportService()
  ) {
    self.renderer = renderer
    self.desktopExporter = desktopExporter
    super.init()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let window = self.window, event.window === window,
        event.keyCode == 53
      else {
        return event
      }
      if self.colorPanelCoordinator.isPresenting {
        self.colorPanelCoordinator.cancelColorTransaction()
        return nil
      }
      guard let canvas = self.workspace?.canvas else {
        return event
      }
      if canvas.isInlineTextEditing {
        canvas.cancelInlineText()
      } else if canvas.snapshotInteractionState().isCropModeActive {
        canvas.undo()
      } else {
        self.cancelSession()
      }
      return nil
    }
  }

  var isPresenting: Bool {
    session != nil
  }

  // MARK: Presentation

  func presentNewCapture(pngData: Data, capturedAt: Date) throws {
    try present(
      pngData: pngData,
      capturedAt: capturedAt,
      target: .newCapture(capturedAt: capturedAt),
      sourceRevision: 0
    )
  }

  func presentHistoryItem(_ item: ScreenshotItem) throws {
    try present(
      pngData: item.pngData,
      capturedAt: item.capturedAt,
      target: .historyItem(
        id: item.id,
        capturedAt: item.capturedAt,
        sourceRevision: item.imageRevision
      ),
      sourceRevision: item.imageRevision
    )
  }

  private func present(
    pngData: Data,
    capturedAt: Date,
    target: EditorTarget,
    sourceRevision: UInt64
  ) throws {
    discardActiveSession()

    guard let bitmap = NSBitmapImageRep(data: pngData),
      bitmap.pixelsWide > 0,
      bitmap.pixelsHigh > 0
    else {
      throw EditorPresentationError.invalidImage
    }
    guard let image = pixelSizedImage(from: pngData) else {
      throw EditorPresentationError.invalidImage
    }

    let pixelSize = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    session = EditorActiveSession(
      pngData: pngData,
      pixelSize: pixelSize,
      capturedAt: capturedAt,
      target: target,
      sourceRevision: sourceRevision
    )

    let window = makeWindowIfNeeded()
    guard let workspace else {
      session = nil
      throw EditorPresentationError.windowUnavailable
    }

    let expectedScale = expectedPointsToImageScale(for: pixelSize, window: window)
    let canvas = workspace.canvas
    canvas.setImage(image)
    canvas.setInteractionState(
      EditorInteractionState(
        sourcePixelSize: pixelSize,
        pointsToImageScale: expectedScale
      )
    )
    workspace.clearStatus()
    window.title = "SnapClip 截图编辑器"
    sizeWindow(for: pixelSize, window: window)

    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(canvas)
    sessionDelegate?.editorDidBeginSession()
    updateToolbar()
  }

  func discardActiveSession() {
    renderTask?.cancel()
    renderTask = nil
    workspace?.canvas.discardCropIfNeeded()
    session = nil
    sessionDelegate?.editorDidCancelSession()
    updateToolbar()
  }

  func focus() {
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(workspace?.canvas)
  }

  func shutdown() {
    colorPanelCoordinator.closeIfNeeded()
    renderTask?.cancel()
    renderTask = nil
    ocrTask?.cancel()
    ocrTask = nil
    session = nil
    window?.close()
    window = nil
    workspace = nil
  }

  // MARK: Window construction

  private func makeWindowIfNeeded() -> NSWindow {
    if let window { return window }

    let canvas = EditorCanvasView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 600),
      sourcePixelSize: CGSize(width: 1, height: 1),
      styleStore: styleStore
    )
    canvas.onStateChanged = { [weak self] in
      self?.updateToolbar()
    }
    canvas.onCanvasInteraction = { [weak self] in
      self?.toolbarModel.styleMenuPresentedTool = nil
      self?.updateToolbar()
    }

    let toolbarView = EditorToolbarView(
      viewModel: toolbarModel,
      onSelectTool: { [weak self] tool in
        self?.handleToolSelect(tool)
      },
      onUndo: { [weak self] in
        self?.workspace?.canvas.undo()
      },
      onSaveToDesktop: { [weak self] in
        self?.saveToDesktop()
      },
      onCancel: { [weak self] in
        self?.cancelSession()
      },
      onConfirm: { [weak self] in
        self?.confirmSession()
      },
      onStyleAction: { [weak self] action in
        self?.handleStyleAction(action)
      },
      onPresentColorPanel: { [weak self] initialColor, preview, completion, cancel in
        self?.colorPanelCoordinator.present(
          initialColor: initialColor,
          onColor: completion,
          onPreview: preview,
          onCancel: cancel
        )
      }
    )

    let workspace = EditorWorkspaceView(canvas: canvas, toolbar: toolbarView)
    self.workspace = workspace

    let createdWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    createdWindow.titlebarAppearsTransparent = true
    createdWindow.titleVisibility = .hidden
    createdWindow.isReleasedWhenClosed = false
    createdWindow.delegate = self
    createdWindow.contentView = workspace
    createdWindow.center()
    createdWindow.setFrameAutosaveName("SnapClipEditorWindow")
    window = createdWindow
    return createdWindow
  }

  private func expectedPointsToImageScale(
    for pixelSize: CGSize,
    window: NSWindow
  ) -> CGFloat {
    let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let maxWidth = min(visible.width * 0.8, 1200)
    let maxHeight = visible.height * 0.8
    let scale = min(maxWidth / pixelSize.width, maxHeight / pixelSize.height, 1)
    let displayWidth = max(pixelSize.width * scale, 1)
    return pixelSize.width / displayWidth
  }

  private func pixelSizedImage(from data: Data) -> NSImage? {
    guard let representation = NSBitmapImageRep(data: data) else { return nil }
    let image = NSImage(
      size: NSSize(
        width: representation.pixelsWide,
        height: representation.pixelsHigh
      )
    )
    image.addRepresentation(representation)
    return image
  }

  private func sizeWindow(for pixelSize: CGSize, window: NSWindow) {
    let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let maximum = NSSize(
      width: visible.width * 0.8,
      height: visible.height * 0.8
    )
    let scale = min(
      maximum.width / max(pixelSize.width, 1),
      maximum.height / max(pixelSize.height, 1),
      1
    )
    let target = NSSize(
      width: max(640, min(maximum.width, pixelSize.width * scale)),
      height: max(420, min(maximum.height, pixelSize.height * scale))
    )
    window.setContentSize(target)
    window.center()
  }

  // MARK: Toolbar state

  private func updateToolbar() {
    guard let canvas = workspace?.canvas else { return }
    let state = canvas.snapshotInteractionState()
    let selectedIsText: Bool
    if let id = state.selectedObjectID,
      case .text? = state.annotation(withID: id)
    {
      selectedIsText = true
    } else {
      selectedIsText = false
    }
    toolbarModel.model = EditorToolbarModel(
      tool: state.activeTool,
      canUndo: state.canUndo,
      isFrozen: renderTask != nil,
      isSaving: false,
      hasCropDraft: state.isCropModeActive,
      strokeWidth: styleStore.strokeDefaults.nominalLineWidth,
      strokeColor: styleStore.strokeDefaults.color,
      mosaicWidth: styleStore.mosaicDefaults.nominalBrushWidth,
      textFontDesign: styleStore.textDefaults.fontDesign,
      textFontSize: styleStore.textDefaults.nominalFontSize,
      textRotation: styleStore.textDefaults.rotationDegrees,
      textColor: styleStore.textDefaults.color,
      isOCRWorking: isOCRWorking,
      selectionIsText: selectedIsText
    )
  }

  private func handleStyleAction(_ action: EditorStyleMenuAction) {
    guard let canvas = workspace?.canvas else { return }
    switch action {
    case .strokeWidth(let width):
      styleStore.setStrokeNominalWidth(width)
      canvas.updateSelectedShapeStroke(nominalLineWidth: width)
    case .strokeColor(let color):
      styleStore.setStrokeColor(color)
      canvas.updateSelectedShapeStroke(color: color)
    case .mosaicWidth(let width):
      styleStore.setMosaicNominalBrushWidth(width)
      canvas.refreshMosaicCursor()
    case .textFont(let design):
      styleStore.setTextFontDesign(design)
      canvas.updateSelectedTextStyle(
        fontDesign: design,
        fontSize: styleStore.textDefaults.nominalFontSize,
        rotationDegrees: styleStore.textDefaults.rotationDegrees,
        color: styleStore.textDefaults.color
      )
    case .textFontSize(let size):
      styleStore.setTextNominalFontSize(size)
      canvas.updateSelectedTextStyle(
        fontDesign: styleStore.textDefaults.fontDesign,
        fontSize: size,
        rotationDegrees: styleStore.textDefaults.rotationDegrees,
        color: styleStore.textDefaults.color
      )
    case .textRotation(let degrees):
      let normalized = EditorGeometry.normalizedAngle(degrees)
      styleStore.setTextRotationDegrees(normalized)
      canvas.updateSelectedTextStyle(
        fontDesign: styleStore.textDefaults.fontDesign,
        fontSize: styleStore.textDefaults.nominalFontSize,
        rotationDegrees: normalized,
        color: styleStore.textDefaults.color
      )
    case .textColor(let color):
      styleStore.setTextColor(color)
      canvas.updateSelectedTextStyle(
        fontDesign: styleStore.textDefaults.fontDesign,
        fontSize: styleStore.textDefaults.nominalFontSize,
        rotationDegrees: styleStore.textDefaults.rotationDegrees,
        color: color
      )
    case .copyAllOCRText:
      copyAllOCRText()
    case .previewStrokeColor(let color):
      canvas.previewSelectedShapeColor(color)
    case .previewTextColor(let color):
      canvas.previewSelectedTextColor(color)
    case .cancelColorTransaction(let color, let isText):
      if isText {
        canvas.previewSelectedTextColor(color)
      } else {
        canvas.previewSelectedShapeColor(color)
      }
    }
    updateToolbar()
  }

  private func copyAllOCRText() {
    guard let session, !isOCRWorking else { return }
    isOCRWorking = true
    workspace?.canvas.commitPendingInlineText()
    workspace?.canvas.applyCropIfNeeded()
    let state = workspace?.canvas.snapshotInteractionState()
    guard let state else { return }

    ocrTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.isOCRWorking = false
        self.ocrTask = nil
        self.updateToolbar()
      }
      do {
        let rendered = try await self.renderer.render(
          sourcePNG: session.pngData,
          cropRect: state.crop.appliedCropRect,
          annotations: state.annotations
        )
        guard !Task.isCancelled else { return }
        let text = try await self.ocrGate.recognize(
          requestID: UUID(),
          pngData: rendered
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        self.workspace?.showError("已复制 \(text.count) 个字符")
      } catch is CancellationError {
        return
      } catch {
        self.workspace?.showError("识别失败：\(error.localizedDescription)")
      }
    }
  }

  private func handleToolSelect(_ tool: EditorTool) {
    guard let canvas = workspace?.canvas else { return }
    canvas.activateTool(tool)
    switch tool {
    case .selection:
      toolbarModel.styleMenuPresentedTool =
        canvas.snapshotInteractionState().selectedObjectID != nil ? .selection : nil
    case .rectangle, .ellipse, .line, .arrow, .text, .mosaic, .ocr:
      toolbarModel.styleMenuPresentedTool = tool
    default:
      toolbarModel.styleMenuPresentedTool = nil
    }
    if tool == .mosaic {
      canvas.refreshMosaicCursor()
    }
    if tool == .ocr {
      prepareOCRSelection()
    }
  }

  private func prepareOCRSelection() {
    guard let session else { return }
    ocrTask?.cancel()
    workspace?.canvas.commitPendingInlineText()
    workspace?.canvas.applyCropIfNeeded()
    let state = workspace?.canvas.snapshotInteractionState()
    guard let state else { return }

    ocrTask = Task { [weak self] in
      guard let self else { return }
      defer { self.ocrTask = nil }
      do {
        let data = try await self.renderer.render(
          sourcePNG: session.pngData,
          cropRect: state.crop.appliedCropRect,
          annotations: state.annotations
        )
        guard !Task.isCancelled else { return }
        let image = self.pixelSizedImage(from: data)
        self.workspace?.canvas.showOCRSelection(image: image)
      } catch {
        self.workspace?.showError("OCR 合成失败：\(error.localizedDescription)")
      }
    }
  }

  // MARK: Actions

  private func cancelSession() {
    colorPanelCoordinator.closeIfNeeded()
    discardActiveSession()
    window?.close()
  }

  private func saveToDesktop() {
    guard let session else { return }
    workspace?.canvas.commitPendingInlineText()
    workspace?.canvas.applyCropIfNeeded()
    let state = workspace?.canvas.snapshotInteractionState()
    toolbarModel.model.isSaving = true

    renderTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.renderTask = nil
        self.toolbarModel.model.isSaving = false
        self.updateToolbar()
      }
      do {
        guard let state else { return }
        let data = try await self.renderer.render(
          sourcePNG: session.pngData,
          cropRect: state.crop.appliedCropRect,
          annotations: state.annotations
        )
        guard !Task.isCancelled else { return }
        _ = try await self.desktopExporter.savePNG(
          data,
          capturedAt: session.capturedAt
        )
        self.workspace?.showError("已保存到桌面")
      } catch is CancellationError {
        return
      } catch {
        self.workspace?.showError("保存失败：\(error.localizedDescription)")
      }
    }
  }

  private func confirmSession() {
    guard let session else { return }
    workspace?.canvas.commitPendingInlineText()
    workspace?.canvas.applyCropIfNeeded()
    let state = workspace?.canvas.snapshotInteractionState()
    guard let state else { return }

    let contentChanged: Bool
    let ocrCache: OCRCacheDisposition
    switch session.target {
    case .newCapture:
      contentChanged = true
      ocrCache = .clear
    case .historyItem:
      contentChanged = state.contentRevision > 0
      ocrCache = contentChanged ? .clear : .preserve
    }

    toolbarModel.model.isFrozen = true
    renderTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.renderTask = nil
        self.toolbarModel.model.isFrozen = false
        self.updateToolbar()
      }
      do {
        let data = try await self.renderer.render(
          sourcePNG: session.pngData,
          cropRect: state.crop.appliedCropRect,
          annotations: state.annotations
        )
        guard !Task.isCancelled else { return }
        let output = EditorOutput(
          target: session.target,
          pngData: data,
          contentChanged: contentChanged,
          ocrCache: ocrCache
        )
        guard let result = self.sessionDelegate?.editorDidRequestCommit(output) else {
          self.workspace?.showError("无法提交截图。")
          return
        }
        if result == .accepted {
          self.discardActiveSession()
          self.window?.close()
        } else if case .rejected(let message) = result {
          self.workspace?.showError(message)
        }
      } catch is CancellationError {
        return
      } catch {
        self.workspace?.showError("渲染失败：\(error.localizedDescription)")
      }
    }
  }

  func windowWillClose(_ notification: Notification) {
    if session != nil {
      discardActiveSession()
    }
  }
}
