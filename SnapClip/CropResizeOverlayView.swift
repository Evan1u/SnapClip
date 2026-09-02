import AppKit

/// Full-screen-looking crop adjuster used by the in-place editor. It reuses
/// the initial source bitmap, lets the user drag/move/resize the selection,
/// and reports the chosen display-local rectangle.
@MainActor
final class CropResizeOverlayView: NSView {
  enum CropHandle {
    case move
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
  }

  var onDecision: ((CropResizeDecision) -> Void)?

  private let sourceImage: CaptureImage
  private let sourceFrame: CGRect
  private var currentRect: CGRect
  private var activeHandle: CropHandle?
  private var startPoint: CGPoint?
  private var dragStartRect: CGRect?

  init(
    sourceImage: CaptureImage,
    sourceFrame: CGRect,
    currentRect: CGRect,
    frame frameRect: CGRect
  ) {
    self.sourceImage = sourceImage
    self.sourceFrame = sourceFrame
    self.currentRect = currentRect
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func keyDown(with event: NSEvent) {
    switch event.keyCode {
    case 36, 76: // Return / keypad enter
      onDecision?(.applied(currentRect))
    case 53: // Escape
      onDecision?(.cancelled)
    default:
      super.keyDown(with: event)
    }
  }

  override func mouseDown(with event: NSEvent) {
    if event.clickCount >= 2, currentRect.contains(convert(event.locationInWindow, from: nil)) {
      onDecision?(.applied(currentRect))
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    startPoint = point
    dragStartRect = currentRect
    activeHandle = hitHandle(at: point)
    NSCursor.closedHand.set()
  }

  override func mouseDragged(with event: NSEvent) {
    guard let startPoint, let startRect = dragStartRect, let handle = activeHandle else {
      return
    }
    let point = convert(event.locationInWindow, from: nil)
    let deltaX = point.x - startPoint.x
    let deltaY = point.y - startPoint.y
    currentRect = Self.updatedRect(
      startRect,
      handle: handle,
      deltaX: deltaX,
      deltaY: deltaY,
      bounds: sourceFrame
    )
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    activeHandle = nil
    startPoint = nil
    dragStartRect = nil
    NSCursor.arrow.set()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    context.draw(sourceImage.cgImage, in: sourceFrame)
    NSColor.black.withAlphaComponent(0.5).setFill()
    bounds.fill()

    if currentRect.width > 0, currentRect.height > 0 {
      context.saveGState()
      context.clip(to: currentRect)
      context.draw(sourceImage.cgImage, in: sourceFrame)
      context.restoreGState()
    }

    let border = NSColor(
      srgbRed: 0xE9 / 255,
      green: 0x65 / 255,
      blue: 0x48 / 255,
      alpha: 0.72
    )
    border.setStroke()
    let path = NSBezierPath(rect: currentRect)
    path.lineWidth = 1.5
    path.setLineDash([6, 4], count: 2, phase: 0)
    path.stroke()

    NSColor.white.withAlphaComponent(0.8).setStroke()
    let sourceBorder = NSBezierPath(rect: sourceFrame)
    sourceBorder.lineWidth = 1
    sourceBorder.stroke()

    drawHandles()
  }

  private func drawHandles() {
    let color = NSColor.white
    color.setFill()
    for rect in handleRects() {
      let square = NSBezierPath(rect: rect)
      square.fill()
    }
  }

  private func handleRects() -> [CGRect] {
    let size: CGFloat = 10
    let inset = size / 2
    let x1 = currentRect.minX - inset
    let x2 = currentRect.midX - inset
    let x3 = currentRect.maxX - inset
    let y1 = currentRect.minY - inset
    let y2 = currentRect.midY - inset
    let y3 = currentRect.maxY - inset
    return [
      CGRect(x: x1, y: y1, width: size, height: size),
      CGRect(x: x2, y: y1, width: size, height: size),
      CGRect(x: x3, y: y1, width: size, height: size),
      CGRect(x: x3, y: y2, width: size, height: size),
      CGRect(x: x3, y: y3, width: size, height: size),
      CGRect(x: x2, y: y3, width: size, height: size),
      CGRect(x: x1, y: y3, width: size, height: size),
      CGRect(x: x1, y: y2, width: size, height: size),
    ]
  }

  private func hitHandle(at point: CGPoint) -> CropHandle? {
    let tolerance: CGFloat = 12
    let nearMinX = abs(point.x - currentRect.minX) <= tolerance
    let nearMaxX = abs(point.x - currentRect.maxX) <= tolerance
    let nearMinY = abs(point.y - currentRect.minY) <= tolerance
    let nearMaxY = abs(point.y - currentRect.maxY) <= tolerance
    if nearMinX, nearMinY { return .topLeft }
    if nearMaxX, nearMinY { return .topRight }
    if nearMinX, nearMaxY { return .bottomLeft }
    if nearMaxX, nearMaxY { return .bottomRight }
    if nearMinX { return .left }
    if nearMaxX { return .right }
    if nearMinY { return .top }
    if nearMaxY { return .bottom }
    if currentRect.contains(point) { return .move }
    return nil
  }

  static func updatedRect(
    _ original: CGRect,
    handle: CropHandle,
    deltaX: CGFloat,
    deltaY: CGFloat,
    bounds: CGRect
  ) -> CGRect {
    var rect = original
    switch handle {
    case .move:
      rect.origin.x += deltaX
      rect.origin.y += deltaY
    case .topLeft:
      rect.origin.x += deltaX
      rect.origin.y += deltaY
      rect.size.width -= deltaX
      rect.size.height -= deltaY
    case .top:
      rect.origin.y += deltaY
      rect.size.height -= deltaY
    case .topRight:
      rect.origin.y += deltaY
      rect.size.width += deltaX
      rect.size.height -= deltaY
    case .right:
      rect.size.width += deltaX
    case .bottomRight:
      rect.size.width += deltaX
      rect.size.height += deltaY
    case .bottom:
      rect.size.height += deltaY
    case .bottomLeft:
      rect.origin.x += deltaX
      rect.size.width -= deltaX
      rect.size.height += deltaY
    case .left:
      rect.origin.x += deltaX
      rect.size.width -= deltaX
    }
    rect = rect.standardized
    let minimum: CGFloat = CaptureSelectionMetrics.minSelectionSize
    if rect.width < minimum {
      rect.origin.x -= (minimum - rect.width) / 2
      rect.size.width = minimum
    }
    if rect.height < minimum {
      rect.origin.y -= (minimum - rect.height) / 2
      rect.size.height = minimum
    }
    return rect.intersection(bounds)
  }
}

enum CropResizeDecision: Equatable {
  case applied(CGRect)
  case cancelled
}

enum CropAnnotationMath {
  static func offsetAnnotations(
    _ annotations: [EditorAnnotation],
    offset: CGSize
  ) -> [EditorAnnotation] {
    annotations.map { annotation in
      switch annotation {
      case .rectangle(var value):
        value.rect = value.rect.offsetBy(dx: offset.width, dy: offset.height)
        return .rectangle(value)
      case .ellipse(var value):
        value.rect = value.rect.offsetBy(dx: offset.width, dy: offset.height)
        return .ellipse(value)
      case .line(var value):
        value.start = CGPoint(
          x: value.start.x + offset.width,
          y: value.start.y + offset.height
        )
        value.end = CGPoint(
          x: value.end.x + offset.width,
          y: value.end.y + offset.height
        )
        return .line(value)
      case .arrow(var value):
        value.start = CGPoint(
          x: value.start.x + offset.width,
          y: value.start.y + offset.height
        )
        value.end = CGPoint(
          x: value.end.x + offset.width,
          y: value.end.y + offset.height
        )
        return .arrow(value)
      case .text(var value):
        value.frame = value.frame.offsetBy(dx: offset.width, dy: offset.height)
        return .text(value)
      case .mosaic(var value):
        value.points = value.points.map {
          CGPoint(x: $0.x + offset.width, y: $0.y + offset.height)
        }
        return .mosaic(value)
      }
    }
  }
}
