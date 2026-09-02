import AppKit

/// Full-screen frozen capture surface for one display. Draws selection in
/// display-local AppKit point coordinates (bottom-left origin) and forwards
/// decisions to the owning capture session.
@MainActor
final class CaptureOverlayView: NSView {
  let displaySnapshot: FrozenDisplaySnapshot

  var onDecision: ((CaptureSelectionDecision) -> Void)?
  var onRequestToggleMode: (() -> Void)?
  var onRequestCancel: ((UserCancelReason) -> Void)?

  private var mode: CaptureSelectionMode = .region {
    didSet {
      window?.invalidateCursorRects(for: self)
      needsDisplay = true
    }
  }

  private var drag: CaptureDragState?
  private var hoverWindow: WindowHitTestResult?
  private var highlightRect: CGRect?
  private var lastMousePoint: CGPoint = .zero
  private var trackingAreaReference: NSTrackingArea?
  private var isInteractionPaused = false

  init(frame frameRect: NSRect, displaySnapshot: FrozenDisplaySnapshot) {
    self.displaySnapshot = displaySnapshot
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func setMode(_ newMode: CaptureSelectionMode) {
    guard mode != newMode else { return }
    mode = newMode
    if newMode == .region {
      hoverWindow = nil
      highlightRect = nil
    }
    needsDisplay = true
  }

  func currentMode() -> CaptureSelectionMode {
    mode
  }

  func pauseInteraction() {
    isInteractionPaused = true
    drag = nil
    hoverWindow = nil
    highlightRect = nil
    needsDisplay = true
  }

  override var acceptsFirstResponder: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let scale = window?.backingScaleFactor {
      layer?.contentsScale = scale
    }
    hoverWindow = nil
    highlightRect = nil
    needsDisplay = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingAreaReference {
      removeTrackingArea(trackingAreaReference)
    }
    let options: NSTrackingArea.Options = [.mouseMoved, .activeAlways, .inVisibleRect]
    let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingAreaReference = area
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: mode == .region ? .crosshair : .arrow)
  }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 49: // Space
      onRequestToggleMode?()
    case 53: // Escape
      onRequestCancel?(.escape)
    default:
      super.keyDown(with: event)
    }
  }

  // MARK: Mouse

  override func mouseMoved(with event: NSEvent) {
    lastMousePoint = localPoint(from: event)
    guard drag == nil, mode == .window else {
      if mode != .window { clearHighlight() }
      return
    }
    refreshWindowHover()
  }

  override func mouseDown(with event: NSEvent) {
    guard !isInteractionPaused else { return }
    lastMousePoint = localPoint(from: event)
    drag = CaptureDragState(startPoint: lastMousePoint)
    if mode == .window {
      refreshWindowHover()
    }
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard !isInteractionPaused else { return }
    guard var drag else { return }
    drag.currentPoint = localPoint(from: event)
    self.drag = drag
    if !drag.isClick {
      hoverWindow = nil
      highlightRect = nil
    }
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    guard !isInteractionPaused else { return }
    guard let drag else {
      onDecision?(.cancelled(.tooSmall))
      return
    }
    self.drag = nil

    if drag.isClick {
      if mode == .window, let hoverWindow {
        onDecision?(
          .window(
            CaptureWindowDescriptor(
              windowID: hoverWindow.windowID,
              frameInAppKitPoints: hoverWindow.frameInAppKitPoints,
              primaryDisplayID: displaySnapshot.displayID,
              ownerPID: hoverWindow.ownerPID
            )
          )
        )
        return
      }
      resetInteraction()
      onDecision?(.cancelled(.tooSmall))
      return
    }

    if let rect = CaptureSelectionMath.validSelectionRect(
      start: drag.startPoint,
      end: drag.currentPoint,
      bounds: bounds
    ) {
      onDecision?(
        .region(displayID: displaySnapshot.displayID, rectInDisplayPoints: rect)
      )
    } else {
      resetInteraction()
      onDecision?(.cancelled(.tooSmall))
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    guard !isInteractionPaused else { return }
    resetInteraction()
    onRequestCancel?(.rightClick)
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    context.draw(displaySnapshot.image.cgImage, in: bounds)

    NSColor.black.withAlphaComponent(0.28).setFill()
    bounds.fill()

    var revealRect: CGRect?
    if let drag, drag.startPoint != drag.currentPoint {
      revealRect = CaptureSelectionMath.normalizedRect(
        start: drag.startPoint,
        end: drag.currentPoint
      )
    } else if let highlightRect {
      revealRect = highlightRect
    }

    guard let revealRect else { return }
    if revealRect.width > 0, revealRect.height > 0 {
      context.saveGState()
      context.clip(to: revealRect)
      context.draw(displaySnapshot.image.cgImage, in: bounds)
      context.restoreGState()
    }

    let borderColor = NSColor(
      srgbRed: 0xE9 / 255,
      green: 0x65 / 255,
      blue: 0x48 / 255,
      alpha: 0.72
    )
    borderColor.setStroke()
    let path = NSBezierPath(rect: revealRect)
    path.lineWidth = 1.5
    path.setLineDash([6, 4], count: 2, phase: 0)
    path.stroke()

    if let drag, drag.startPoint != drag.currentPoint {
      drawSizeLabel(
        width: revealRect.width,
        height: revealRect.height,
        near: revealRect
      )
    }
  }

  private func drawSizeLabel(
    width: CGFloat,
    height: CGFloat,
    near rect: CGRect
  ) {
    let text = "\(Int(width.rounded())) × \(Int(height.rounded()))"
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
      .backgroundColor: NSColor.black.withAlphaComponent(0.55),
    ]
    let size = (text as NSString).size(withAttributes: attributes)
    var labelRect = CGRect(
      x: rect.minX,
      y: min(rect.maxY + 6, bounds.maxY - size.height - 4),
      width: size.width + 12,
      height: size.height + 4
    )
    labelRect.origin.x = max(
      bounds.minX + 2,
      min(labelRect.minX, bounds.maxX - labelRect.width - 2)
    )
    (text as NSString).draw(in: labelRect, withAttributes: attributes)
  }

  // MARK: Helpers

  private func localPoint(from event: NSEvent) -> CGPoint {
    convert(event.locationInWindow, from: nil)
  }

  private func appKitPoint(for localPoint: CGPoint) -> CGPoint {
    let screen = displaySnapshot.frameInAppKitPoints
    return CGPoint(
      x: screen.minX + localPoint.x,
      y: screen.minY + localPoint.y
    )
  }

  private func refreshWindowHover() {
    let appKitPoint = appKitPoint(for: lastMousePoint)
    guard
      let hit = WindowHitTester.hitTest(
        appKitPoint: appKitPoint,
        skipSelfWindows: true
      )
    else {
      hoverWindow = nil
      highlightRect = nil
      needsDisplay = true
      return
    }
    let local = CaptureGeometry.localRect(
      fromGlobalRect: hit.frameInAppKitPoints,
      screenFrame: displaySnapshot.frameInAppKitPoints
    )
    hoverWindow = hit
    highlightRect = local.intersection(bounds)
    needsDisplay = true
  }

  private func clearHighlight() {
    hoverWindow = nil
    highlightRect = nil
    needsDisplay = true
  }

  private func resetInteraction() {
    drag = nil
    hoverWindow = nil
    highlightRect = nil
    needsDisplay = true
  }
}
