import AppKit
import Foundation

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
private struct EditorActiveSession {
  let pngData: Data
  let pixelSize: CGSize
  let capturedAt: Date
  let target: EditorTarget
  let sourceRevision: UInt64
}

/// Shared editing session engine used by both the history editor window and
/// the new in-place overlay. It owns all model/undo/OCR/render state and never
/// creates windows itself.
@MainActor
final class EditorSessionCore {
  typealias StatusHandler = @MainActor (_ message: String, _ isError: Bool) -> Void

  private let renderer: any ScreenshotRendering
  private let desktopExporter: any DesktopExportServing
  private let styleStore = EditorToolStyleStore()
  private let colorPanelCoordinator = ColorPanelCoordinator()
  private let ocrGate = OCRExecutionGate(ocrService: VisionOCRService())
  private var isOCRWorking = false
  private var session: EditorActiveSession?
  private var renderTask: Task<Void, Never>?
  private var ocrTask: Task<Void, Never>?

  let canvas: EditorCanvasView
  let toolbarModel = EditorToolbarViewModel(
    model: EditorToolbarModel(
      tool: .selection,
      canUndo: false,
      isFrozen: false,
      isSaving: false,
      hasCropDraft: false
    )
  )

  weak var sessionDelegate: EditorSessionDelegate?
  var onRequestClose: (() -> Void)?
  var statusHandler: StatusHandler?
  /// Overlay hosts set this so NSColorPanel stays above `.screenSaver`.
  var forcesPanelOnTop = false
  /// When set and non-nil, the overlay host takes over crop interactions.
  var onCropStart: (() -> Bool)?

  init(
    canvas: EditorCanvasView,
    renderer: any ScreenshotRendering = ScreenshotRenderer(),
    desktopExporter: any DesktopExportServing = DesktopExportService()
  ) {
    self.canvas = canvas
    self.renderer = renderer
    self.desktopExporter = desktopExporter
    canvas.onStateChanged = { [weak self] in
      self?.updateToolbar()
    }
    canvas.onCanvasInteraction = { [weak self] in
      guard let self else { return }
      toolbarModel.styleMenuPresentedTool = nil
      updateToolbar()
    }
    canvas.onCanvasDoubleClick = { [weak self] in
      self?.handleCanvasDoubleClick()
    }
  }

  var isPresenting: Bool {
    session != nil
  }

  var isColorPanelPresenting: Bool {
    colorPanelCoordinator.isPresenting
  }

  // MARK: Session lifecycle

  func begin(
    pngData: Data,
    pixelSize: CGSize,
    capturedAt: Date,
    target: EditorTarget,
    sourceRevision: UInt64,
    pointsToImageScale: CGFloat
  ) throws {
    discard()

    guard
      pixelSize.width > 0,
      pixelSize.height > 0,
      pixelSize.width.isFinite,
      pixelSize.height.isFinite
    else {
      throw EditorPresentationError.invalidImage
    }
    guard let image = pixelSizedImage(from: pngData) else {
      throw EditorPresentationError.invalidImage
    }

    session = EditorActiveSession(
      pngData: pngData,
      pixelSize: pixelSize,
      capturedAt: capturedAt,
      target: target,
      sourceRevision: sourceRevision
    )
    canvas.setImage(image)
    canvas.setInteractionState(
      EditorInteractionState(
        sourcePixelSize: pixelSize,
        pointsToImageScale: pointsToImageScale
      )
    )
    clearStatus()
    sessionDelegate?.editorDidBeginSession()
    updateToolbar()
  }

  func discard() {
    renderTask?.cancel()
    renderTask = nil
    ocrTask?.cancel()
    ocrTask = nil
    canvas.discardCropIfNeeded()
    session = nil
    sessionDelegate?.editorDidCancelSession()
    updateToolbar()
  }

  func shutdown() {
    colorPanelCoordinator.closeIfNeeded()
    renderTask?.cancel()
    renderTask = nil
    ocrTask?.cancel()
    ocrTask = nil
    session = nil
  }

  @discardableResult
  func handleEscape() -> Bool {
    guard session != nil else { return false }
    if colorPanelCoordinator.isPresenting {
      colorPanelCoordinator.cancelColorTransaction()
      return true
    }
    if canvas.isInlineTextEditing {
      canvas.cancelInlineText()
      return true
    }
    if canvas.snapshotInteractionState().isCropModeActive {
      canvas.undo()
      return true
    }
    cancelSession()
    return true
  }

  // MARK: Toolbar state

  func handleRightClick() {
    guard session != nil else { return }
    let state = canvas.snapshotInteractionState()
    if state.activeTool != .selection || canvas.isInlineTextEditing
      || state.isCropModeActive || colorPanelCoordinator.isPresenting
      || state.selectedObjectID != nil || state.creationDraft != nil
    {
      exitCurrentTool()
    } else {
      cancelSession()
    }
  }

  func exitCurrentTool() {
    colorPanelCoordinator.cancelColorTransaction()
    canvas.cancelInlineText()
    canvas.discardCropIfNeeded()
    canvas.exitToolInteraction()
    toolbarModel.styleMenuPresentedTool = nil
    NSCursor.arrow.set()
    updateToolbar()
  }

  func updateToolbar() {
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

  func handleStyleAction(_ action: EditorStyleMenuAction) {
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

  func handleToolSelection(_ tool: EditorTool) {
    if tool == .crop, let onCropStart, onCropStart() {
      return
    }
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

  func presentColorPanel(
    initialColor: RGBAColor,
    onColor: @escaping (RGBAColor) -> Void,
    onPreview: @escaping (RGBAColor) -> Void,
    onCancel: @escaping () -> Void
  ) {
    colorPanelCoordinator.present(
      initialColor: initialColor,
      onColor: onColor,
      onPreview: onPreview,
      onCancel: onCancel,
      panelLevel: forcesPanelOnTop ? .screenSaver : nil
    )
  }

  // MARK: OCR

  private func copyAllOCRText() {
    guard session != nil, !isOCRWorking else { return }
    isOCRWorking = true
    canvas.commitPendingInlineText()
    canvas.applyCropIfNeeded()
    let state = canvas.snapshotInteractionState()
    guard let session else {
      isOCRWorking = false
      updateToolbar()
      return
    }

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
        self.showStatus("已复制 \(text.count) 个字符", isError: false)
      } catch is CancellationError {
        return
      } catch {
        self.showStatus("识别失败：\(error.localizedDescription)", isError: true)
      }
    }
  }

  private func prepareOCRSelection() {
    guard let session else { return }
    ocrTask?.cancel()
    canvas.commitPendingInlineText()
    canvas.applyCropIfNeeded()
    let state = canvas.snapshotInteractionState()

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
        self.canvas.showOCRSelection(image: image)
      } catch {
        self.showStatus("OCR 合成失败：\(error.localizedDescription)", isError: true)
      }
    }
  }

  // MARK: Actions

  func saveToDesktop() {
    guard let session else { return }
    canvas.commitPendingInlineText()
    canvas.applyCropIfNeeded()
    let state = canvas.snapshotInteractionState()
    toolbarModel.model.isSaving = true

    renderTask = Task { [weak self] in
      guard let self else { return }
      defer {
        self.renderTask = nil
        self.toolbarModel.model.isSaving = false
        self.updateToolbar()
      }
      do {
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
        self.showStatus("已保存到桌面", isError: false)
      } catch is CancellationError {
        return
      } catch {
        self.showStatus("保存失败：\(error.localizedDescription)", isError: true)
      }
    }
  }

  func confirm() {
    guard let session else { return }
    canvas.commitPendingInlineText()
    canvas.applyCropIfNeeded()
    let state = canvas.snapshotInteractionState()

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
          self.showStatus("无法提交截图。", isError: true)
          return
        }
        if result == .accepted {
          self.discard()
          self.onRequestClose?()
        } else if case .rejected(let message) = result {
          self.showStatus(message, isError: true)
        }
      } catch is CancellationError {
        return
      } catch {
        self.showStatus("渲染失败：\(error.localizedDescription)", isError: true)
      }
    }
  }

  func cancelSession() {
    colorPanelCoordinator.closeIfNeeded()
    discard()
    onRequestClose?()
  }

  private func handleCanvasDoubleClick() {
    guard
      session != nil,
      renderTask == nil,
      !toolbarModel.model.isFrozen,
      canvas.snapshotInteractionState().activeTool == .selection
    else {
      return
    }
    confirm()
  }

  /// Replaces the source bitmap and re-bases annotations after an in-place
  /// crop adjustment. Keeps the same commit target and capturedAt.
  func replaceSource(
    pngData: Data,
    pixelSize: CGSize,
    pointsToImageScale: CGFloat,
    annotations: [EditorAnnotation]
  ) throws {
    guard let current = session else {
      throw EditorPresentationError.invalidImage
    }
    guard let image = pixelSizedImage(from: pngData) else {
      throw EditorPresentationError.invalidImage
    }
    session = EditorActiveSession(
      pngData: pngData,
      pixelSize: pixelSize,
      capturedAt: current.capturedAt,
      target: current.target,
      sourceRevision: current.sourceRevision
    )
    canvas.setImage(image)
    canvas.setInteractionState(
      EditorInteractionState(
        sourcePixelSize: pixelSize,
        pointsToImageScale: pointsToImageScale,
        annotations: annotations
      )
    )
    updateToolbar()
  }

  // MARK: Helpers

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

  private func showStatus(_ message: String, isError: Bool) {
    statusHandler?(message, isError)
  }

  private func clearStatus() {
    statusHandler?("", false)
  }
}
