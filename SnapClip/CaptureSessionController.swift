import AppKit
import Foundation
import SwiftUI

@MainActor
private final class CaptureOverlayPanel: NSPanel {
  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    isFloatingPanel = true
    becomesKeyOnlyIfNeeded = false
    hidesOnDeactivate = false
  }

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

enum CaptureFlowResult: Equatable {
  case editorOpened
  case cancelled
}

@MainActor
protocol InPlaceCapturePresenting: AnyObject {
  var isPresenting: Bool { get }
  var sessionDelegate: EditorSessionDelegate? { get set }
  func begin(mode: CaptureMode, soundEnabled: Bool) async throws -> CaptureFlowResult
  func discardActiveSession()
  func shutdown()
}

/// Owns one new-capture session from frozen snapshot through in-place editing.
@MainActor
final class CaptureSessionController: InPlaceCapturePresenting {
  private enum Phase {
    case idle
    case snapshotting
    case selecting
    case preparingImage
    case editing
    case cropping
    case finished
  }

  private struct EditorPresentation {
    let core: EditorSessionCore
    let hostView: InPlaceEditorOverlayView
    let displayID: CGDirectDisplayID
    var editorRect: CGRect
    let scale: CGFloat
    let capturedAt: Date
    let sourceImage: CaptureImage
    let sourceFrame: CGRect
  }

  private let snapshotter: any DisplaySnapshotting
  private var phase: Phase = .idle
  private var panels: [NSWindow] = []
  private var panelViews: [CaptureOverlayView] = []
  private var editorPresentation: EditorPresentation?
  private var selectionContinuation: CheckedContinuation<CaptureSelectionDecision, Never>?
  private var cropContinuation: CheckedContinuation<CropResizeDecision, Never>?
  private var cropView: CropResizeOverlayView?
  private var cropTask: Task<Void, Never>?
  private var inputMonitor: Any?
  private var frozenScreens: [FrozenDisplaySnapshot] = []
  private var sessionUUID = UUID()

  weak var sessionDelegate: EditorSessionDelegate?

  init(snapshotter: any DisplaySnapshotting = SCKDisplaySnapshotter()) {
    self.snapshotter = snapshotter
  }

  var isPresenting: Bool {
    switch phase {
    case .idle, .finished:
      return false
    case .snapshotting, .selecting, .preparingImage, .editing, .cropping:
      return true
    }
  }

  func begin(
    mode: CaptureMode,
    soundEnabled: Bool
  ) async throws -> CaptureFlowResult {
    guard phase == .idle || phase == .finished else {
      throw CaptureGeometryError.platformFailure(0)
    }
    phase = .snapshotting
    sessionUUID = UUID()

    let screens: [FrozenDisplaySnapshot]
    do {
      screens = try await snapshotter.captureFrozenScreens()
    } catch {
      teardownPanels()
      phase = .idle
      throw error
    }
    frozenScreens = screens
    guard !screens.isEmpty else {
      phase = .idle
      throw CaptureGeometryError.noDisplays
    }

    try Task.checkCancellation()
    presentSelectionPanels(screens: screens)
    phase = .selecting

    let decision: CaptureSelectionDecision
    if mode == .mainDisplay,
      let main = screens.first(where: {
        $0.displayID == CGMainDisplayID()
      })
    {
      decision = .region(
        displayID: main.displayID,
        rectInDisplayPoints: CGRect(
          origin: .zero,
          size: main.frameInAppKitPoints.size
        )
      )
    } else {
      decision = await withCheckedContinuation { continuation in
        selectionContinuation = continuation
      }
      selectionContinuation = nil
    }

    do {
      switch decision {
      case .cancelled:
        teardownPanels()
        phase = .idle
        return .cancelled

      case .region(let displayID, let rect):
        guard let display = screens.first(where: { $0.displayID == displayID }) else {
          throw CaptureGeometryError.displayUnavailable(displayID)
        }
        return try await enterEditing(
          display: display,
          displayRect: rect,
          soundEnabled: soundEnabled
        )

      case .window(let descriptor):
        let fallbackDisplay = screens.first(where: {
          $0.displayID == descriptor.primaryDisplayID
        })
        do {
          let image = try await snapshotter.captureWindow(descriptor: descriptor)
          return try await enterEditing(
            displayImage: image,
            display: fallbackDisplay,
            descriptor: descriptor,
            soundEnabled: soundEnabled
          )
        } catch {
          guard
            let display = fallbackDisplay,
            let rect = fallbackRect(for: descriptor, display: display)
          else {
            throw CaptureGeometryError.windowUnavailable(descriptor.windowID)
          }
          return try await enterEditing(
            display: display,
            displayRect: rect,
            soundEnabled: soundEnabled
          )
        }
      }
    } catch {
      teardownPanels()
      frozenScreens = []
      phase = .idle
      throw error
    }
  }

  func discardActiveSession() {
    if let continuation = selectionContinuation {
      self.selectionContinuation = nil
      continuation.resume(returning: .cancelled(.escape))
      return
    }
    if let continuation = cropContinuation {
      self.cropContinuation = nil
      continuation.resume(returning: .cancelled)
      finishEditing()
      return
    }
    editorPresentation?.core.discard()
    finishEditing()
  }

  func shutdown() {
    discardActiveSession()
  }

  // MARK: Selection panels

  private func presentSelectionPanels(screens: [FrozenDisplaySnapshot]) {
    teardownPanels()
    panelViews.removeAll(keepingCapacity: true)

    for screen in screens {
      let frame = screen.frameInAppKitPoints
      let panel = CaptureOverlayPanel(contentRect: frame)
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.level = .screenSaver
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      panel.isReleasedWhenClosed = false
      panel.acceptsMouseMovedEvents = true

      let view = CaptureOverlayView(
        frame: NSRect(origin: .zero, size: frame.size),
        displaySnapshot: screen
      )
      view.onDecision = { [weak self] decision in
        self?.finishSelection(decision)
      }
      view.onRequestToggleMode = { [weak view, weak self] in
        guard let self, let view else { return }
        let next: CaptureSelectionMode = view.currentMode() == .region ? .window : .region
        for panelView in self.panelViews {
          panelView.setMode(next)
        }
      }
      view.onRequestCancel = { [weak self] reason in
        self?.finishSelection(.cancelled(reason))
      }

      panel.contentView = view
      panel.setFrame(frame, display: false)
      panelViews.append(view)
      panels.append(panel)
    }

    for panel in panels {
      panel.orderFrontRegardless()
    }
    NSApp.activate(ignoringOtherApps: true)
    installInputMonitor()
    let mouse = NSEvent.mouseLocation
    let anchorIndex = panels.firstIndex { $0.frame.contains(mouse) } ?? panels.indices.first
    if let anchorIndex {
      let panel = panels[anchorIndex]
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(panel.contentView)
    }
  }

  private func finishSelection(_ decision: CaptureSelectionDecision) {
    guard let selectionContinuation else { return }
    self.selectionContinuation = nil
    selectionContinuation.resume(returning: decision)
  }

  private func installInputMonitor() {
    removeInputMonitor()
    inputMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .rightMouseDown]
    ) {
      [weak self] event in
      guard
        let self,
        self.panels.contains(where: { $0 === event.window })
      else {
        return event
      }

      if event.type == .rightMouseDown {
        switch self.phase {
        case .selecting:
          self.finishSelection(.cancelled(.rightClick))
        case .editing:
          self.editorPresentation?.core.handleRightClick()
        case .cropping:
          if let continuation = self.cropContinuation {
            self.cropContinuation = nil
            continuation.resume(returning: .cancelled)
          }
          self.editorPresentation?.core.exitCurrentTool()
        default:
          return event
        }
        return nil
      }

      switch self.phase {
      case .selecting:
        switch event.keyCode {
        case 49:
          let next: CaptureSelectionMode =
            self.panelViews.first?.currentMode() == .window ? .region : .window
          for view in self.panelViews {
            view.setMode(next)
          }
          return nil
        case 53:
          self.finishSelection(.cancelled(.escape))
          return nil
        default:
          return event
        }
      case .editing:
        guard event.keyCode == 53 else { return event }
        if self.editorPresentation?.core.handleEscape() == true {
          return nil
        }
        return event
      default:
        return event
      }
    }
  }

  private func removeInputMonitor() {
    if let inputMonitor {
      NSEvent.removeMonitor(inputMonitor)
    }
    inputMonitor = nil
  }

  // MARK: Enter editing

  private func enterEditing(
    display: FrozenDisplaySnapshot,
    displayRect: CGRect,
    soundEnabled: Bool
  ) async throws -> CaptureFlowResult {
    phase = .preparingImage
    let alignedRect = CaptureGeometry.displayRectAlignedToPixels(
      displayRect,
      pointScale: display.image.pointScale
    )
    let image = try await Task.detached(priority: .userInitiated) {
      let cropped = try CaptureGeometry.croppedCGImage(
        display.image,
        displayRect: alignedRect
      )
      return try CaptureImage(
        cgImage: cropped,
        pointScale: display.image.pointScale
      )
    }.value
    return try await mountEditor(
      display: display,
      image: image,
      editorRect: alignedRect,
      cropSourceImage: display.image,
      cropSourceFrame: CGRect(
        origin: .zero,
        size: display.image.sizeInPoints
      ),
      soundEnabled: soundEnabled
    )
  }

  private func enterEditing(
    displayImage: CaptureImage,
    display: FrozenDisplaySnapshot?,
    descriptor: CaptureWindowDescriptor,
    soundEnabled: Bool
  ) async throws -> CaptureFlowResult {
    phase = .preparingImage
    guard let display else {
      teardownPanels()
      phase = .idle
      throw CaptureGeometryError.displayUnavailable(descriptor.primaryDisplayID)
    }
    let editorRect = CaptureGeometry.localRect(
      fromGlobalRect: descriptor.frameInAppKitPoints,
      screenFrame: display.frameInAppKitPoints
    )
    guard editorRect.width > 0, editorRect.height > 0 else {
      teardownPanels()
      phase = .idle
      throw CaptureGeometryError.invalidGeometry
    }
    let imagePointSize = displayImage.sizeInPoints
    guard
      abs(editorRect.width - imagePointSize.width) <= 2,
      abs(editorRect.height - imagePointSize.height) <= 2
    else {
      throw CaptureGeometryError.invalidGeometry
    }
    return try await mountEditor(
      display: display,
      image: displayImage,
      editorRect: editorRect,
      cropSourceImage: displayImage,
      cropSourceFrame: editorRect,
      soundEnabled: soundEnabled
    )
  }

  private func mountEditor(
    display: FrozenDisplaySnapshot,
    image: CaptureImage,
    editorRect: CGRect,
    cropSourceImage: CaptureImage,
    cropSourceFrame: CGRect,
    soundEnabled: Bool
  ) async throws -> CaptureFlowResult {
    let capturedAt = Date()
    let data: Data
    do {
      data = try await Task.detached(priority: .userInitiated) {
        try image.pngData()
      }.value
    } catch {
      teardownPanels()
      phase = .idle
      throw error
    }

    guard let panel = panels.first(where: {
      ($0.contentView as? CaptureOverlayView)?.displaySnapshot.displayID
        == display.displayID
    }) else {
      teardownPanels()
      phase = .idle
      throw CaptureGeometryError.displayUnavailable(display.displayID)
    }
    for view in panelViews {
      view.pauseInteraction()
    }

    let canvas = EditorCanvasView(
      frame: editorRect,
      sourcePixelSize: CGSize(
        width: image.cgImage.width,
        height: image.cgImage.height
      ),
      styleStore: EditorToolStyleStore()
    )
    let core = EditorSessionCore(canvas: canvas)
    core.sessionDelegate = sessionDelegate
    core.forcesPanelOnTop = true
    core.onCropStart = { [weak self] in
      self?.startCropResize() ?? false
    }

    let host: InPlaceEditorOverlayView
    do {
      let toolbar = EditorToolbarView(
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
      let toolbarHost = NSHostingView(rootView: toolbar)
      host = InPlaceEditorOverlayView(
        displaySnapshot: display,
        selectionRectInDisplayPoints: editorRect,
        canvas: canvas,
        toolbarHost: toolbarHost
      )
    }

    core.onRequestClose = { [weak self] in
      self?.finishEditing()
    }
    core.statusHandler = { [weak host] message, isError in
      host?.showStatus(message, isError: isError)
    }
    editorPresentation = EditorPresentation(
      core: core,
      hostView: host,
      displayID: display.displayID,
      editorRect: editorRect,
      scale: image.pointScale,
      capturedAt: capturedAt,
      sourceImage: cropSourceImage,
      sourceFrame: cropSourceFrame
    )

    panel.contentView = host
    panel.setFrame(display.frameInAppKitPoints, display: false)
    panel.orderFrontRegardless()
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(canvas)

    do {
      try core.begin(
        pngData: data,
        pixelSize: CGSize(
          width: image.cgImage.width,
          height: image.cgImage.height
        ),
        capturedAt: capturedAt,
        target: .newCapture(capturedAt: capturedAt),
        sourceRevision: 0,
        pointsToImageScale: image.pointScale
      )
    } catch {
      finishEditing()
      throw error
    }
    phase = .editing
    if soundEnabled {
      playCaptureSound()
    }
    return .editorOpened
  }

  private func playCaptureSound() {
    if let sound = NSSound(named: NSSound.Name("Pop")) {
      sound.play()
    } else {
      NSSound.beep()
    }
  }

  private func fallbackRect(
    for descriptor: CaptureWindowDescriptor,
    display: FrozenDisplaySnapshot
  ) -> CGRect? {
    let rect = CaptureGeometry.localRect(
      fromGlobalRect: descriptor.frameInAppKitPoints,
      screenFrame: display.frameInAppKitPoints
    )
    return CaptureSelectionMath.validSelectionRect(
      start: CGPoint(x: rect.minX, y: rect.minY),
      end: CGPoint(x: rect.maxX, y: rect.maxY),
      bounds: CGRect(origin: .zero, size: display.frameInAppKitPoints.size)
    )
  }

  // MARK: In-place crop adjustment

  @discardableResult
  private func startCropResize() -> Bool {
    guard cropTask == nil, let editorPresentation else { return false }
    guard
      let panel = panels.first(where: { $0.contentView === editorPresentation.hostView })
    else {
      return false
    }

    let view = CropResizeOverlayView(
      sourceImage: editorPresentation.sourceImage,
      sourceFrame: editorPresentation.sourceFrame,
      currentRect: editorPresentation.editorRect,
      frame: NSRect(origin: .zero, size: panel.frame.size)
    )
    view.onDecision = { [weak self] decision in
      guard let self, let continuation = self.cropContinuation else { return }
      self.cropContinuation = nil
      continuation.resume(returning: decision)
    }

    phase = .cropping
    cropView = view
    panel.contentView = view
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(view)

    cropTask = Task { @MainActor [weak self] in
      let decision = await withCheckedContinuation { continuation in
        self?.cropContinuation = continuation
      }
      guard let self, cropTask != nil else { return }
      cropTask = nil
      handleCropDecision(decision)
    }
    return true
  }

  private func handleCropDecision(_ decision: CropResizeDecision) {
    guard let editorPresentation else {
      cropView = nil
      phase = .idle
      return
    }
    guard
      let panel = panels.first(where: { $0.contentView === cropView })
    else {
      cropView = nil
      return
    }

    cropView = nil
    panel.contentView = editorPresentation.hostView
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(editorPresentation.core.canvas)
    phase = .editing

    if case .applied(let rect) = decision {
      applyCropResult(rect)
    }
  }

  private func applyCropResult(_ rect: CGRect) {
    guard let editorPresentation else { return }
    let alignedRect = CaptureGeometry.displayRectAlignedToPixels(
      rect,
      pointScale: editorPresentation.scale
    )
    let sourceFrame = editorPresentation.sourceFrame
    let oldLocalRect = editorPresentation.editorRect.offsetBy(
      dx: -sourceFrame.minX,
      dy: -sourceFrame.minY
    )
    let newLocalRect = alignedRect.offsetBy(
      dx: -sourceFrame.minX,
      dy: -sourceFrame.minY
    )
    guard
      let oldPixel = try? CaptureGeometry.pixelCropRect(
        forDisplayRect: oldLocalRect,
        in: editorPresentation.sourceImage
      ),
      let newPixel = try? CaptureGeometry.pixelCropRect(
        forDisplayRect: newLocalRect,
        in: editorPresentation.sourceImage
      )
    else {
      editorPresentation.core.statusHandler?("裁剪区域无效，请重试", true)
      return
    }

    let offset = CGSize(
      width: oldPixel.minX - newPixel.minX,
      height: oldPixel.minY - newPixel.minY
    )
    let annotations = editorPresentation.core.canvas
      .snapshotInteractionState().annotations
    let transformed = CropAnnotationMath.offsetAnnotations(annotations, offset: offset)

    do {
      let cropped = try CaptureGeometry.croppedCGImage(
        editorPresentation.sourceImage,
        displayRect: newLocalRect
      )
      let image = try CaptureImage(
        cgImage: cropped,
        pointScale: editorPresentation.scale
      )
      let data = try image.pngData()
      try editorPresentation.core.replaceSource(
        pngData: data,
        pixelSize: CGSize(width: cropped.width, height: cropped.height),
        pointsToImageScale: editorPresentation.scale,
        annotations: transformed
      )
      editorPresentation.hostView.updateSelectionRect(alignedRect)
      self.editorPresentation?.editorRect = alignedRect
    } catch {
      editorPresentation.core.statusHandler?(
        "裁剪失败：\(error.localizedDescription)",
        true
      )
    }
  }

  // MARK: Teardown

  private func finishEditing() {
    cropTask?.cancel()
    cropTask = nil
    cropContinuation = nil
    cropView = nil
    editorPresentation = nil
    teardownPanels()
    frozenScreens = []
    phase = .idle
  }

  private func teardownPanels() {
    removeInputMonitor()
    for panel in panels {
      panel.delegate = nil
      panel.orderOut(nil)
      panel.close()
    }
    panels.removeAll()
    panelViews.removeAll()
    NSCursor.arrow.set()
  }
}
