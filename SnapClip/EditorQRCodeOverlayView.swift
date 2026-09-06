import AppKit
import CoreGraphics

struct QRCodeOverlayItem: Equatable {
  let result: QRCodeResult
  let modelRect: CGRect
}

enum QRCodeOverlayLayout {
  static func modelRect(
    for result: QRCodeResult,
    renderedPixelSize: CGSize,
    effectiveCropRect: CGRect
  ) -> CGRect {
    let box = result.boundingBox
    let renderedRect = CGRect(
      x: box.minX * renderedPixelSize.width,
      y: (1 - box.maxY) * renderedPixelSize.height,
      width: box.width * renderedPixelSize.width,
      height: box.height * renderedPixelSize.height
    )
    return renderedRect.offsetBy(
      dx: effectiveCropRect.minX,
      dy: effectiveCropRect.minY
    )
  }

  static func hitRect(for visualRect: CGRect, minimumSize: CGFloat = 44) -> CGRect {
    CGRect(
      x: visualRect.midX - max(visualRect.width, minimumSize) / 2,
      y: visualRect.midY - max(visualRect.height, minimumSize) / 2,
      width: max(visualRect.width, minimumSize),
      height: max(visualRect.height, minimumSize)
    )
  }

  static func hitItem(
    at point: CGPoint,
    items: [QRCodeOverlayItem],
    viewport: EditorCanvasViewport
  ) -> QRCodeOverlayItem? {
    items
      .filter {
        hitRect(for: viewport.viewRect(fromModel: $0.modelRect)).contains(point)
      }
      .min {
        let left = viewport.viewRect(fromModel: $0.modelRect)
        let right = viewport.viewRect(fromModel: $1.modelRect)
        return left.width * left.height < right.width * right.height
      }
  }
}

@MainActor
final class EditorQRCodeOverlayView: NSView {
  var onSelect: ((QRCodeResult, CGRect) -> Void)?
  var onBackgroundClick: (() -> Void)?
  var onExitRequest: (() -> Void)?

  private var items: [QRCodeOverlayItem] = []
  private var viewport = EditorCanvasViewport(modelRect: .zero, displayRect: .zero)
  private var selectedID: QRCodeResult.ID?
  private var hoveredID: QRCodeResult.ID?
  private var trackingArea: NSTrackingArea?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  func show(
    results: [QRCodeResult],
    renderedPixelSize: CGSize,
    effectiveCropRect: CGRect,
    viewport: EditorCanvasViewport
  ) {
    self.viewport = viewport
    items = results.map {
      QRCodeOverlayItem(
        result: $0,
        modelRect: QRCodeOverlayLayout.modelRect(
          for: $0,
          renderedPixelSize: renderedPixelSize,
          effectiveCropRect: effectiveCropRect
        )
      )
    }
    selectedID = nil
    hoveredID = nil
    isHidden = false
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  func updateViewport(_ viewport: EditorCanvasViewport) {
    self.viewport = viewport
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
  }

  func clear() {
    items = []
    selectedID = nil
    hoveredID = nil
    isHidden = true
    NSCursor.arrow.set()
    needsDisplay = true
  }

  func clearSelection() {
    selectedID = nil
    needsDisplay = true
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    for item in items {
      let rect = viewport.viewRect(fromModel: item.modelRect)
      let selected = item.result.id == selectedID
      let hovered = item.result.id == hoveredID
      let fillAlpha: CGFloat = selected ? 0.28 : hovered ? 0.20 : 0.13
      SnapClipDesign.appKitAccent.withAlphaComponent(fillAlpha).setFill()
      let fill = NSBezierPath(
        roundedRect: rect,
        xRadius: SnapClipDesign.radiusS,
        yRadius: SnapClipDesign.radiusS
      )
      fill.fill()

      // A warm-white contrast rail keeps the coral frame legible over both
      // dark and highly saturated screenshot content.
      SnapClipDesign.appKitPorcelain.withAlphaComponent(selected ? 0.94 : 0.82).setStroke()
      fill.lineWidth = selected ? 5.5 : hovered ? 5 : 4.5
      fill.stroke()

      SnapClipDesign.appKitAccent.withAlphaComponent(selected ? 1 : 0.96).setStroke()
      fill.lineWidth = selected ? 3 : hovered ? 2.75 : 2.25
      fill.stroke()

      drawCornerMarks(around: rect, emphasized: selected || hovered)
    }
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let next = QRCodeOverlayLayout.hitItem(
      at: point,
      items: items,
      viewport: viewport
    )?.result.id
    if next != hoveredID {
      hoveredID = next
      needsDisplay = true
    }
    (next == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
  }

  override func mouseExited(with event: NSEvent) {
    hoveredID = nil
    NSCursor.arrow.set()
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let point = convert(event.locationInWindow, from: nil)
    guard
      let item = QRCodeOverlayLayout.hitItem(
        at: point,
        items: items,
        viewport: viewport
      )
    else {
      selectedID = nil
      needsDisplay = true
      onBackgroundClick?()
      return
    }
    selectedID = item.result.id
    needsDisplay = true
    onSelect?(item.result, viewport.viewRect(fromModel: item.modelRect))
  }

  override func rightMouseDown(with event: NSEvent) {
    onExitRequest?()
  }

  private func drawCornerMarks(around rect: CGRect, emphasized: Bool) {
    let length = min(12, max(5, min(rect.width, rect.height) * 0.28))
    let path = NSBezierPath()
    for (corner, horizontal, vertical) in [
      (CGPoint(x: rect.minX, y: rect.minY), CGFloat(1), CGFloat(1)),
      (CGPoint(x: rect.maxX, y: rect.minY), CGFloat(-1), CGFloat(1)),
      (CGPoint(x: rect.minX, y: rect.maxY), CGFloat(1), CGFloat(-1)),
      (CGPoint(x: rect.maxX, y: rect.maxY), CGFloat(-1), CGFloat(-1)),
    ] {
      path.move(to: CGPoint(x: corner.x + horizontal * length, y: corner.y))
      path.line(to: corner)
      path.line(to: CGPoint(x: corner.x, y: corner.y + vertical * length))
    }
    path.lineCapStyle = .round

    SnapClipDesign.appKitPorcelain.withAlphaComponent(0.94).setStroke()
    path.lineWidth = emphasized ? 5.5 : 4.5
    path.stroke()

    SnapClipDesign.appKitAccent.setStroke()
    path.lineWidth = emphasized ? 3.5 : 2.75
    path.stroke()
  }
}
