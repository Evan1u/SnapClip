import AppKit
import SwiftUI

@MainActor
private final class CropBorderView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let color = NSColor(
      srgbRed: 0xE9 / 255,
      green: 0x65 / 255,
      blue: 0x48 / 255,
      alpha: 0.72
    )
    color.setStroke()
    let path = NSBezierPath(rect: bounds.insetBy(dx: 0.75, dy: 0.75))
    path.lineWidth = 1.5
    path.setLineDash([6, 4], count: 2, phase: 0)
    path.stroke()
  }
}

/// Editor-phase host for one display. Draws the frozen/dim background and
/// places an `EditorSessionCore` canvas at the original selection rectangle,
/// with the toolbar and status label attached nearby.
@MainActor
final class InPlaceEditorOverlayView: NSView {
  let displaySnapshot: FrozenDisplaySnapshot
  let canvas: EditorCanvasView
  let toolbarHost: NSHostingView<EditorToolbarView>
  let statusLabel = NSTextField(labelWithString: "")
  private let cropBorderView = CropBorderView()

  private var selectionRectInDisplayPoints: CGRect

  init(
    displaySnapshot: FrozenDisplaySnapshot,
    selectionRectInDisplayPoints: CGRect,
    canvas: EditorCanvasView,
    toolbarHost: NSHostingView<EditorToolbarView>
  ) {
    self.displaySnapshot = displaySnapshot
    self.selectionRectInDisplayPoints = selectionRectInDisplayPoints
    self.canvas = canvas
    self.toolbarHost = toolbarHost
    super.init(frame: .zero)

    canvas.drawsEditorBackground = false
    canvas.viewportEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    canvas.frame = selectionRectInDisplayPoints
    canvas.autoresizingMask = []

    statusLabel.textColor = .white
    statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
    statusLabel.isHidden = true

    addSubview(canvas)
    addSubview(cropBorderView)
    addSubview(toolbarHost)
    addSubview(statusLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func layout() {
    super.layout()
    canvas.frame = selectionRectInDisplayPoints
    cropBorderView.frame = selectionRectInDisplayPoints

    let toolbarSize = toolbarHost.fittingSize
    let toolbarRect = EditorOverlayLayout.toolbarFrame(
      relativeTo: selectionRectInDisplayPoints,
      screenBounds: bounds,
      toolbarSize: toolbarSize
    )
    toolbarHost.frame = toolbarRect

    let statusSize = statusLabel.fittingSize
    statusLabel.frame = EditorOverlayLayout.statusFrame(
      relativeTo: toolbarRect,
      screenBounds: bounds,
      statusSize: statusSize
    )
  }

  func updateSelectionRect(_ rect: CGRect) {
    selectionRectInDisplayPoints = rect
    needsLayout = true
    layoutSubtreeIfNeeded()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.draw(displaySnapshot.image.cgImage, in: bounds)
    NSColor.black.withAlphaComponent(0.45).setFill()
    bounds.fill()
  }

  func showStatus(_ message: String, isError: Bool) {
    statusLabel.stringValue = message
    statusLabel.textColor = isError
      ? NSColor(srgbRed: 0xFF / 255, green: 0x6B / 255, blue: 0x5B / 255, alpha: 1)
      : .white
    statusLabel.isHidden = message.isEmpty
    needsLayout = true
  }
}
