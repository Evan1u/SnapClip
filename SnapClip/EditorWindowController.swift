import AppKit
import Foundation
import SwiftUI

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

  func showStatus(_ message: String) {
    statusLabel.stringValue = message
    statusLabel.textColor = .white
    statusLabel.isHidden = message.isEmpty
  }

  func clearStatus() {
    statusLabel.isHidden = true
  }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, ScreenshotEditing {
  private let renderer: any ScreenshotRendering
  private let desktopExporter: any DesktopExportServing
  weak var sessionDelegate: EditorSessionDelegate?

  private var window: NSWindow?
  private var workspace: EditorWorkspaceView?
  private var core: EditorSessionCore?
  private var eventMonitor: Any?

  init(
    renderer: any ScreenshotRendering = ScreenshotRenderer(),
    desktopExporter: any DesktopExportServing = DesktopExportService()
  ) {
    self.renderer = renderer
    self.desktopExporter = desktopExporter
    super.init()
    eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard
        let self,
        let window = self.window,
        event.window === window,
        event.keyCode == 53
      else {
        return event
      }
      if let core = self.core, core.handleEscape() {
        return nil
      }
      return event
    }
  }

  var isPresenting: Bool {
    core?.isPresenting ?? false
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
    resetForReplacement()

    guard let bitmap = NSBitmapImageRep(data: pngData),
      bitmap.pixelsWide > 0,
      bitmap.pixelsHigh > 0
    else {
      throw EditorPresentationError.invalidImage
    }
    let pixelSize = CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
    let window = makeWindowIfNeeded()
    guard let workspace, let core else {
      throw EditorPresentationError.windowUnavailable
    }

    let expectedScale = expectedPointsToImageScale(for: pixelSize, window: window)
    try core.begin(
      pngData: pngData,
      pixelSize: pixelSize,
      capturedAt: capturedAt,
      target: target,
      sourceRevision: sourceRevision,
      pointsToImageScale: expectedScale
    )
    workspace.clearStatus()
    window.title = "SnapClip 截图编辑器"
    sizeWindow(for: pixelSize, window: window)

    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(workspace.canvas)
    core.updateToolbar()
  }

  func discardActiveSession() {
    core?.discard()
  }

  func focus() {
    window?.makeKeyAndOrderFront(nil)
    window?.makeFirstResponder(workspace?.canvas)
  }

  func shutdown() {
    core?.shutdown()
    core = nil
    window?.close()
    window = nil
    workspace = nil
  }

  // MARK: Window construction

  private func resetForReplacement() {
    core?.discard()
  }

  private func makeWindowIfNeeded() -> NSWindow {
    if let window { return window }

    let canvas = EditorCanvasView(
      frame: NSRect(x: 0, y: 0, width: 900, height: 600),
      sourcePixelSize: CGSize(width: 1, height: 1),
      styleStore: EditorToolStyleStore()
    )
    let core = EditorSessionCore(
      canvas: canvas,
      renderer: renderer,
      desktopExporter: desktopExporter
    )
    core.sessionDelegate = sessionDelegate
    core.onRequestClose = { [weak self] in
      self?.window?.close()
    }
    core.statusHandler = { [weak self] message, isError in
      guard let self else { return }
      if isError {
        self.workspace?.showError(message)
      } else {
        self.workspace?.showStatus(message)
      }
    }
    self.core = core

    let toolbarView = EditorToolbarView(
      viewModel: core.toolbarModel,
      onSelectTool: { [weak core] tool in
        core?.handleToolSelection(tool)
      },
      onUndo: { [weak core] in
        core?.canvas.undo()
      },
      onSaveToDesktop: { [weak core] in
        core?.saveToDesktop()
      },
      onCancel: { [weak core] in
        core?.cancelSession()
      },
      onConfirm: { [weak core] in
        core?.confirm()
      },
      onStyleAction: { [weak core] action in
        core?.handleStyleAction(action)
      },
      onPresentColorPanel: { [weak core] initialColor, preview, completion, cancel in
        core?.presentColorPanel(
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

  func windowWillClose(_ notification: Notification) {
    if core?.isPresenting == true {
      core?.discard()
    }
  }
}
