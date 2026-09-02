import AppKit
import CoreGraphics
import CoreImage
import Foundation

/// Converts between source-pixel model coordinates and canvas display points.
struct EditorCanvasViewport: Equatable {
  let modelRect: CGRect
  let displayRect: CGRect

  /// View points per model pixel. Aspect-fit guarantees equal x/y scales.
  var viewPointsPerModelPixel: CGFloat {
    guard modelRect.width > 0 else { return 1 }
    return displayRect.width / modelRect.width
  }

  func viewPoint(fromModel point: CGPoint) -> CGPoint {
    CGPoint(
      x: displayRect.minX + (point.x - modelRect.minX) * viewPointsPerModelPixel,
      y: displayRect.minY + (point.y - modelRect.minY) * viewPointsPerModelPixel
    )
  }

  func modelPoint(fromView point: CGPoint) -> CGPoint {
    CGPoint(
      x: modelRect.minX + (point.x - displayRect.minX) / viewPointsPerModelPixel,
      y: modelRect.minY + (point.y - displayRect.minY) / viewPointsPerModelPixel
    )
  }

  func viewRect(fromModel rect: CGRect) -> CGRect {
    CGRect(
      x: displayRect.minX + (rect.minX - modelRect.minX) * viewPointsPerModelPixel,
      y: displayRect.minY + (rect.minY - modelRect.minY) * viewPointsPerModelPixel,
      width: rect.width * viewPointsPerModelPixel,
      height: rect.height * viewPointsPerModelPixel
    )
  }

  func lineWidth(fromModel width: CGFloat) -> CGFloat {
    max(width * viewPointsPerModelPixel, 0.5)
  }

  func displayLineWidth(fromModelWidth width: CGFloat) -> CGFloat {
    width * viewPointsPerModelPixel
  }
}

enum CanvasResizeHandle: Equatable {
  case shape(EditorCropHandle)
  case shapeRotation
  case lineStart
  case lineEnd
  case textCorner(Int)
  case textLeft
  case textRight
}

@MainActor
final class EditorCanvasView: NSView {
  private(set) var interactionState: EditorInteractionState
  private let styleStore: EditorToolStyleStore
  private var image: NSImage?
  private var sourceCGImage: CGImage?
  private var mosaicPreviewCache: [CGFloat: NSImage] = [:]
  private var lastViewport = EditorCanvasViewport(
    modelRect: .zero,
    displayRect: .zero
  )
  private var inlineEditor: NSTextView?
  private var inlineTextAnnotationID: UUID?
  private var pendingTextOrigin: CGPoint?
  private var pendingTextWidthInPixels: CGFloat?
  private let ocrSelectionView: EditorOCRSelectionView
  private var isRotatingText = false
  private var activeResize: (annotation: EditorAnnotation, kind: CanvasResizeHandle)?
  private var resizeDidChange = false

  /// When false the canvas does not paint its warm graphite workspace, letting
  /// transparent pixels reveal the frozen overlay background behind it.
  var drawsEditorBackground = true
  /// Layout inset applied around the model image. The floating window keeps
  /// 1pt breathing room; the in-place overlay sets zero for exact mapping.
  var viewportEdgeInsets = NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)

  var onStateChanged: (() -> Void)?
  var onCanvasInteraction: (() -> Void)?
  var onRequestFirstResponder: ((NSTextView) -> Void)?
  var onCanvasDoubleClick: (() -> Void)?

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func resetCursorRects() {
    super.resetCursorRects()
    guard interactionState.activeTool == .mosaic,
      let cursor = mosaicCursor()
    else {
      return
    }
    addCursorRect(bounds, cursor: cursor)
  }

  func refreshMosaicCursor() {
    window?.invalidateCursorRects(for: self)
  }

  private func mosaicCursor() -> NSCursor? {
    let nominalWidth = styleStore.mosaicDefaults.nominalBrushWidth
    let pixelWidth = nominalWidth * interactionState.pointsToImageScale
    let diameter = max(pixelWidth * viewport.viewPointsPerModelPixel, 8)
    let size = NSSize(width: diameter + 4, height: diameter + 4)
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    let image = NSImage(size: size, flipped: false) { _ in
      let circle = NSBezierPath(
        ovalIn: NSRect(
          x: center.x - diameter / 2,
          y: center.y - diameter / 2,
          width: diameter,
          height: diameter
        )
      )
      circle.lineWidth = 1.5
      NSColor.black.withAlphaComponent(0.75).setStroke()
      NSColor.white.withAlphaComponent(0.35).setFill()
      circle.fill()
      circle.stroke()
      return true
    }
    return NSCursor(image: image, hotSpot: center)
  }

  init(
    frame frameRect: NSRect,
    sourcePixelSize: CGSize,
    styleStore: EditorToolStyleStore,
    pointsToImageScale: CGFloat = 1,
    annotations: [EditorAnnotation] = []
  ) {
    self.styleStore = styleStore
    self.interactionState = EditorInteractionState(
      sourcePixelSize: sourcePixelSize,
      pointsToImageScale: pointsToImageScale,
      annotations: annotations
    )
    self.ocrSelectionView = EditorOCRSelectionView()
    super.init(frame: frameRect)
    ocrSelectionView.isHidden = true
    addSubview(ocrSelectionView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  func setImage(_ image: NSImage?) {
    self.image = image
    self.sourceCGImage = image?.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    )
    mosaicPreviewCache.removeAll()
    needsDisplay = true
  }

  func setInteractionState(_ state: EditorInteractionState) {
    interactionState = state
    needsDisplay = true
    onStateChanged?()
  }

  func setActiveTool(_ tool: EditorTool) {
    let wasMosaic = interactionState.activeTool == .mosaic
    interactionState.setActiveTool(tool)
    if tool != .ocr {
      hideOCRSelection()
    }
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
    if wasMosaic && tool != .mosaic {
      NSCursor.arrow.set()
    }
    onStateChanged?()
  }

  func activateTool(_ tool: EditorTool) {
    if tool == .crop {
      interactionState.enterCropMode()
    } else {
      interactionState.setActiveTool(tool)
    }
    if tool != .ocr {
      hideOCRSelection()
    }
    needsDisplay = true
    window?.invalidateCursorRects(for: self)
    onStateChanged?()
  }

  func undo() {
    if inlineEditor != nil {
      cancelInlineText()
      return
    }
    interactionState.undo()
    needsDisplay = true
    onStateChanged?()
  }

  func commitPendingInlineText() {
    if inlineEditor != nil {
      commitInlineText()
    }
  }

  func snapshotInteractionState() -> EditorInteractionState {
    interactionState
  }

  var isInlineTextEditing: Bool {
    inlineEditor != nil
  }

  func showOCRSelection(image: NSImage?) {
    guard interactionState.activeTool == .ocr else {
      ocrSelectionView.isHidden = true
      return
    }
    ocrSelectionView.frame = viewport.displayRect
    ocrSelectionView.isHidden = image == nil
    if let image {
      ocrSelectionView.beginAnalysis(for: image)
    }
  }

  func hideOCRSelection() {
    ocrSelectionView.reset()
    ocrSelectionView.isHidden = true
  }

  func updateSelectedShapeStroke(
    nominalLineWidth: CGFloat? = nil,
    color: RGBAColor? = nil
  ) {
    let changed = interactionState.updateSelectedShapeStroke(
      nominalLineWidth: nominalLineWidth,
      color: color
    )
    if changed {
      needsDisplay = true
      onStateChanged?()
    }
  }

  func previewSelectedShapeColor(_ color: RGBAColor) {
    if interactionState.previewSelectedShapeStroke(color: color) {
      needsDisplay = true
    }
  }

  func updateSelectedTextStyle(
    fontDesign: EditorFontDesign,
    fontSize: CGFloat,
    rotationDegrees: Double,
    color: RGBAColor
  ) {
    guard let id = interactionState.selectedObjectID,
      case .text(let annotation)? = interactionState.annotation(withID: id)
    else {
      return
    }
    let width = annotation.frame.width
    var style = EditorTextStyle(
      fontDesign: fontDesign,
      nominalFontSize: fontSize,
      renderedFontSizeInPixels: fontSize * interactionState.pointsToImageScale,
      rotationDegrees: EditorGeometry.normalizedAngle(rotationDegrees),
      color: color
    )
    let measured = EditorTextLayout.measuredSize(
      text: annotation.text,
      style: style,
      width: width
    )
    var frame = annotation.frame
    frame.size.height = max(measured.height, 1)
    interactionState.replaceTextAnnotation(
      id: id,
      text: annotation.text,
      frame: frame,
      style: style
    )
    needsDisplay = true
    onStateChanged?()
  }

  func previewSelectedTextColor(_ color: RGBAColor) {
    guard let id = interactionState.selectedObjectID,
      case .text(let annotation)? = interactionState.annotation(withID: id)
    else {
      return
    }
    var style = annotation.style
    style.color = color
    interactionState.previewReplaceTextAnnotation(
      id: id,
      text: annotation.text,
      frame: annotation.frame,
      style: style
    )
    needsDisplay = true
  }

  // MARK: Layout

  override func layout() {
    super.layout()
    recomputeViewport()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    recomputeViewport()

    if drawsEditorBackground {
      let backgroundColor = NSColor(
        calibratedRed: 0.24,
        green: 0.23,
        blue: 0.22,
        alpha: 1
      )
      backgroundColor.setFill()
      bounds.fill()
    }

    drawSourceImage()
    drawAnnotations()
    drawCropOverlayIfNeeded()
  }

  private func recomputeViewport() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let modelRect: CGRect
    let modelPixelSize: CGSize
    if interactionState.isCropModeActive {
      modelRect = interactionState.originalPixelBounds
      modelPixelSize = interactionState.originalPixelBounds.size
    } else {
      modelRect = interactionState.crop.appliedCropRect
      modelPixelSize = modelRect.size
    }
    let insetBounds = CGRect(
      x: bounds.minX + viewportEdgeInsets.left,
      y: bounds.minY + viewportEdgeInsets.top,
      width: max(bounds.width - viewportEdgeInsets.left - viewportEdgeInsets.right, 1),
      height: max(bounds.height - viewportEdgeInsets.top - viewportEdgeInsets.bottom, 1)
    )
    let displayRect = EditorGeometry.aspectFitRect(
      for: modelPixelSize,
      in: insetBounds
    )
    lastViewport = EditorCanvasViewport(modelRect: modelRect, displayRect: displayRect)
  }

  private var viewport: EditorCanvasViewport {
    lastViewport
  }

  // MARK: Source drawing

  private func drawSourceImage() {
    guard let cgImage = sourceCGImage else { return }
    let sourceRect: CGRect
    if interactionState.isCropModeActive {
      sourceRect = interactionState.originalPixelBounds
    } else {
      sourceRect = interactionState.crop.appliedCropRect
    }
    guard let displayImage = croppedDisplayImage(cgImage, sourceRect: sourceRect) else {
      return
    }
    displayImage.draw(
      in: viewport.displayRect,
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )
  }

  private func croppedDisplayImage(
    _ cgImage: CGImage,
    sourceRect: CGRect
  ) -> NSImage? {
    let cropRect = CGRect(
      x: sourceRect.minX,
      y: sourceRect.minY,
      width: max(sourceRect.width, 0),
      height: max(sourceRect.height, 0)
    )
    guard let cropped = cgImage.cropping(to: cropRect) else { return nil }
    let representation = NSBitmapImageRep(cgImage: cropped)
    let result = NSImage(
      size: NSSize(
        width: representation.pixelsWide,
        height: representation.pixelsHigh
      )
    )
    result.addRepresentation(representation)
    return result
  }

  // MARK: Crop overlay

  private func drawCropOverlayIfNeeded() {
    guard interactionState.isCropModeActive,
      let draft = interactionState.crop.draftCropRect
    else {
      return
    }

    let box = viewport.viewRect(fromModel: draft)
    let path = NSBezierPath(rect: bounds)
    path.appendRect(box)
    path.windingRule = .evenOdd
    NSColor(
      calibratedRed: 0.17,
      green: 0.17,
      blue: 0.16,
      alpha: 0.55
    ).setFill()
    path.fill()

    NSColor.white.setStroke()
    let outline = NSBezierPath(rect: box)
    outline.lineWidth = 1
    outline.stroke()
    drawCropHandles(box)
    drawRuleOfThirds(box)
  }

  private func drawRuleOfThirds(_ box: NSRect) {
    NSColor.white.withAlphaComponent(0.35).setStroke()
    for value in [1.0 / 3, 2.0 / 3] {
      let vertical = NSBezierPath()
      vertical.move(to: NSPoint(x: box.minX + box.width * value, y: box.minY))
      vertical.line(to: NSPoint(x: box.minX + box.width * value, y: box.maxY))
      vertical.lineWidth = 0.5
      vertical.stroke()

      let horizontal = NSBezierPath()
      horizontal.move(to: NSPoint(x: box.minX, y: box.minY + box.height * value))
      horizontal.line(to: NSPoint(x: box.maxX, y: box.minY + box.height * value))
      horizontal.lineWidth = 0.5
      horizontal.stroke()
    }
  }

  private func drawCropHandles(_ box: NSRect) {
    let size: CGFloat = 7
    let positions: [NSPoint] = [
      NSPoint(x: box.minX, y: box.minY),
      NSPoint(x: box.midX, y: box.minY),
      NSPoint(x: box.maxX, y: box.minY),
      NSPoint(x: box.maxX, y: box.midY),
      NSPoint(x: box.maxX, y: box.maxY),
      NSPoint(x: box.midX, y: box.maxY),
      NSPoint(x: box.minX, y: box.maxY),
      NSPoint(x: box.minX, y: box.midY),
    ]
    NSColor.white.setFill()
    for center in positions {
      NSRect(
        x: center.x - size / 2,
        y: center.y - size / 2,
        width: size,
        height: size
      ).fill()
    }
  }

  // MARK: Annotation drawing

  private func drawAnnotations() {
    for annotation in interactionState.annotations {
      drawAnnotation(annotation, selected: annotation.id == interactionState.selectedObjectID)
    }
    if case .mosaic(let points, let style)? = interactionState.creationDraft {
      drawMosaicPreview(
        MosaicAnnotation(id: UUID(), points: points, style: style)
      )
    }
  }

  private func drawAnnotation(_ annotation: EditorAnnotation, selected: Bool) {
    switch annotation {
    case .rectangle(let value):
      strokeShapeRect(
        value.rect,
        style: value.style,
        ellipse: false,
        rotationDegrees: value.rotationDegrees
      )
      if selected { drawShapeSelection(value.rect, rotationDegrees: value.rotationDegrees) }
    case .ellipse(let value):
      strokeShapeRect(
        value.rect,
        style: value.style,
        ellipse: true,
        rotationDegrees: value.rotationDegrees
      )
      if selected { drawShapeSelection(value.rect, rotationDegrees: value.rotationDegrees) }
    case .line(let value):
      drawLine(value, arrow: false)
      if selected { drawLineSelection(value) }
    case .arrow(let value):
      drawLine(value, arrow: true)
      if selected { drawLineSelection(value) }
    case .text(let value):
      drawText(value, selected: selected)
    case .mosaic(let value):
      drawMosaicPreview(value)
    }
  }

  private func strokeShapeRect(
    _ rect: CGRect,
    style: EditorStrokeStyle,
    ellipse: Bool,
    rotationDegrees: Double
  ) {
    let viewRect = viewport.viewRect(fromModel: rect)
    NSGraphicsContext.saveGraphicsState()
    let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: CGFloat(rotationDegrees))
    transform.translateX(by: -center.x, yBy: -center.y)
    transform.concat()
    let path = ellipse ? NSBezierPath(ovalIn: viewRect) : NSBezierPath(rect: viewRect)
    path.lineWidth = viewport.lineWidth(fromModel: style.renderedLineWidthInPixels)
    style.color.nsColor.setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()
  }

  private func drawLine(_ line: LineAnnotation, arrow: Bool) {
    let start = viewport.viewPoint(fromModel: line.start)
    let end = viewport.viewPoint(fromModel: line.end)
    let lineWidth = viewport.lineWidth(fromModel: line.style.renderedLineWidthInPixels)
    line.style.color.nsColor.setStroke()

    guard arrow else {
      let path = NSBezierPath()
      path.move(to: start)
      path.line(to: end)
      path.lineWidth = lineWidth
      path.lineCapStyle = .round
      path.stroke()
      return
    }

    let length = hypot(end.x - start.x, end.y - start.y)
    guard length > 0 else { return }
    let angle = atan2(end.y - start.y, end.x - start.x)
    let headLength = max(lineWidth * 7, 20)
    let base = CGPoint(
      x: end.x - headLength * cos(angle),
      y: end.y - headLength * sin(angle)
    )
    let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
    let halfBase = max(lineWidth * 1.1, headLength * 0.22)
    let leftBase = CGPoint(
      x: base.x + perpendicular.x * halfBase,
      y: base.y + perpendicular.y * halfBase
    )
    let rightBase = CGPoint(
      x: base.x - perpendicular.x * halfBase,
      y: base.y - perpendicular.y * halfBase
    )

    func strokeLine(_ from: CGPoint, to: CGPoint) {
      let path = NSBezierPath()
      path.move(to: from)
      path.line(to: to)
      path.lineWidth = lineWidth
      path.lineCapStyle = .round
      path.stroke()
    }

    strokeLine(start, to: base)
    let triangle = NSBezierPath()
    triangle.move(to: end)
    triangle.line(to: leftBase)
    triangle.line(to: rightBase)
    triangle.close()
    line.style.color.nsColor.setFill()
    triangle.fill()
  }

  private func drawMosaicPreview(_ mosaic: MosaicAnnotation) {
    guard let first = mosaic.points.first else { return }
    guard let cgContext = NSGraphicsContext.current?.cgContext else { return }
    let path = CGMutablePath()
    path.move(to: viewport.viewPoint(fromModel: first))
    for point in mosaic.points.dropFirst() {
      path.addLine(to: viewport.viewPoint(fromModel: point))
    }
    if let pixellated = pixellatedPreview(scale: mosaic.style.renderedPixelScaleInPixels) {
      NSGraphicsContext.saveGraphicsState()
      cgContext.addPath(path)
      cgContext.setLineWidth(
        viewport.lineWidth(fromModel: mosaic.style.renderedBrushWidthInPixels)
      )
      cgContext.setLineCap(.round)
      cgContext.setLineJoin(.round)
      cgContext.replacePathWithStrokedPath()
      cgContext.clip()
      let sourceRect = interactionState.isCropModeActive
        ? interactionState.originalPixelBounds
        : interactionState.crop.appliedCropRect
      if let pixellatedCG = pixellated.cgImage(
        forProposedRect: nil,
        context: nil,
        hints: nil
      ), let displayImage = croppedDisplayImage(
        pixellatedCG,
        sourceRect: sourceRect
      ) {
        displayImage.draw(
          in: viewport.displayRect,
          from: .zero,
          operation: .sourceOver,
          fraction: 1,
          respectFlipped: true,
          hints: [.interpolation: NSImageInterpolation.high]
        )
      }
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  private func pixellatedPreview(scale: CGFloat) -> NSImage? {
    let key = max(scale, 1)
    if let cached = mosaicPreviewCache[key] {
      return cached
    }
    guard let cgImage = image?.cgImage(
      forProposedRect: nil,
      context: nil,
      hints: nil
    ), let filter = CIFilter(name: "CIPixellate") else {
      return nil
    }
    let input = CIImage(cgImage: cgImage)
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(Double(key), forKey: kCIInputScaleKey)
    guard let output = filter.outputImage else { return nil }
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    guard let result = context.createCGImage(output, from: output.extent) else {
      return nil
    }
    let representation = NSBitmapImageRep(cgImage: result)
    let resultImage = NSImage(
      size: NSSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    )
    resultImage.addRepresentation(representation)
    mosaicPreviewCache[key] = resultImage
    return resultImage
  }

  private func drawText(_ annotation: TextAnnotation, selected: Bool) {
    let viewRect = viewport.viewRect(fromModel: annotation.frame)
    let style = annotation.style
    let displayFontSize = style.renderedFontSizeInPixels
      * viewport.viewPointsPerModelPixel
    var styleCopy = style
    styleCopy.renderedFontSizeInPixels = displayFontSize
    let attributed = NSAttributedString(
      string: annotation.text,
      attributes: EditorTextLayout.attributes(for: styleCopy)
    )

    NSGraphicsContext.saveGraphicsState()
    let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: CGFloat(style.rotationDegrees))
    transform.translateX(by: -center.x, yBy: -center.y)
    transform.concat()
    attributed.draw(
      with: viewRect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    NSGraphicsContext.restoreGraphicsState()

    if selected {
      let path = NSBezierPath(rect: viewRect)
      NSColor.white.withAlphaComponent(0.7).setStroke()
      path.lineWidth = 1
      path.stroke()
      drawTextHandles(viewRect)
    }
  }

  private func drawShapeSelection(_ rect: CGRect, rotationDegrees: Double) {
    let viewRect = viewport.viewRect(fromModel: rect)
    let path = NSBezierPath(rect: viewRect.insetBy(dx: -2, dy: -2))
    NSColor.white.withAlphaComponent(0.8).setStroke()
    path.lineWidth = 1
    path.stroke()
    drawCornerHandles(viewRect)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let handleModel = EditorGeometry.rotatedPoint(
      CGPoint(x: rect.midX, y: rect.minY - 24),
      around: center,
      by: rotationDegrees
    )
    let handle = viewport.viewPoint(fromModel: handleModel)
    NSColor.white.setFill()
    NSRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8).fill()
  }

  private func drawLineSelection(_ line: LineAnnotation) {
    for point in [line.start, line.end] {
      let view = viewport.viewPoint(fromModel: point)
      NSColor.white.setFill()
      NSRect(x: view.x - 3, y: view.y - 3, width: 6, height: 6).fill()
    }
    let centerModel = CGPoint(
      x: (line.start.x + line.end.x) / 2,
      y: (line.start.y + line.end.y) / 2
    )
    let handleModel = CGPoint(
      x: centerModel.x,
      y: min(line.start.y, line.end.y) - 24
    )
    let handle = viewport.viewPoint(fromModel: handleModel)
    NSColor.white.setFill()
    NSRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8).fill()
  }

  private func drawCornerHandles(_ rect: NSRect) {
    let size: CGFloat = 6
    for x in [rect.minX, rect.midX, rect.maxX] {
      for y in [rect.minY, rect.midY, rect.maxY] {
        NSColor.white.setFill()
        NSRect(x: x - size / 2, y: y - size / 2, width: size, height: size).fill()
      }
    }
  }

  private func drawTextHandles(_ rect: NSRect) {
    drawCornerHandles(rect)
    let rotation = NSRect(
      x: rect.midX - 3,
      y: rect.minY - 26,
      width: 6,
      height: 6
    )
    NSColor.white.setFill()
    rotation.fill()
  }

  // MARK: Mouse

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    onCanvasInteraction?()
    let viewPoint = convert(event.locationInWindow, from: nil)
    guard viewport.displayRect.contains(viewPoint) else { return }

    if interactionState.isCropModeActive {
      handleCropMouseDown(viewPoint)
      return
    }
    if interactionState.activeTool == .ocr {
      return
    }
    if inlineEditor != nil, interactionState.activeTool != .text {
      commitInlineText()
    }

    let modelPoint = viewport.modelPoint(fromView: viewPoint)
    let metrics = EditorPointerMetrics(
      modelPixelsPerPoint: 1 / viewport.viewPointsPerModelPixel
    )
    let snapshot = styleStore.styleSnapshot(scale: interactionState.pointsToImageScale)

    if event.clickCount == 1, interactionState.activeTool == .selection,
      let hit = resizeHandle(at: viewPoint)
    {
      interactionState.selectedObjectID = hit.annotation.id
      guard interactionState.beginResize(original: hit.annotation) else { return }
      activeResize = (hit.annotation, hit.kind)
      resizeDidChange = false
      return
    }

    if event.clickCount == 1, interactionState.activeTool == .selection,
      let rotationID = selectedTextRotationHandle(at: viewPoint)
    {
      interactionState.selectedObjectID = rotationID
      if interactionState.beginSelectedTextRotation() {
        isRotatingText = true
      }
      return
    }

    if event.clickCount == 2, interactionState.activeTool == .selection,
      let hit = interactionState.hitTest(at: modelPoint, metrics: metrics)
    {
      if case .text(let value) = hit {
        beginInlineTextEditing(value)
      } else {
        onCanvasDoubleClick?()
      }
      return
    }

    if event.clickCount == 2, interactionState.activeTool == .selection {
      onCanvasDoubleClick?()
      return
    }

    if interactionState.activeTool == .text {
      if inlineEditor == nil {
        beginInlineText(at: modelPoint)
      } else if event.clickCount == 1 {
        commitInlineText()
        beginInlineText(at: modelPoint)
      } else {
        window?.makeFirstResponder(inlineEditor)
      }
    } else {
      interactionState.pointerDown(at: modelPoint, metrics: metrics, styleSnapshot: snapshot)
      needsDisplay = true
    }
  }

  override func mouseDragged(with event: NSEvent) {
    let viewPoint = convert(event.locationInWindow, from: nil)
    if let activeResize {
      applyResizeDrag(to: viewPoint, original: activeResize.annotation, kind: activeResize.kind)
      return
    }
    if isRotatingText {
      updateTextRotation(viewPoint)
      return
    }
    if interactionState.isCropModeActive {
      handleCropMouseDragged(viewPoint)
      return
    }
    guard interactionState.creationDraft != nil else { return }
    interactionState.pointerDragged(
      to: viewport.modelPoint(fromView: viewPoint)
    )
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    let viewPoint = convert(event.locationInWindow, from: nil)
    if activeResize != nil {
      if resizeDidChange {
        interactionState.endResize()
      } else {
        interactionState.cancelResize()
      }
      activeResize = nil
      resizeDidChange = false
      needsDisplay = true
      onStateChanged?()
      onCanvasInteraction?()
      return
    }
    if isRotatingText {
      isRotatingText = false
      interactionState.endSelectedTextRotation()
      needsDisplay = true
      onStateChanged?()
      onCanvasInteraction?()
      return
    }
    if interactionState.isCropModeActive {
      handleCropMouseUp(viewPoint)
      return
    }
    if interactionState.creationDraft != nil {
      interactionState.pointerUp(
        at: viewport.modelPoint(fromView: viewPoint)
      )
      switch interactionState.activeTool {
      case .rectangle, .ellipse, .line, .arrow:
        interactionState.setActiveTool(.selection)
      case .mosaic, .selection, .text, .crop, .ocr:
        break
      }
    }
    needsDisplay = true
    onStateChanged?()
    onCanvasInteraction?()
  }

  override func rightMouseDown(with event: NSEvent) {
    if interactionState.activeTool == .mosaic {
      interactionState.setActiveTool(.selection)
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
      NSCursor.arrow.set()
      onStateChanged?()
      onCanvasInteraction?()
      return
    }
    super.rightMouseDown(with: event)
  }

  private func resizeHandle(at point: NSPoint) -> (annotation: EditorAnnotation, kind: CanvasResizeHandle)? {
    guard let id = interactionState.selectedObjectID,
      let annotation = interactionState.annotation(withID: id)
    else {
      return nil
    }
    let tolerance: CGFloat = 12
    switch annotation {
    case .rectangle(let value), .ellipse(let value):
      let viewRect = viewport.viewRect(fromModel: value.rect)
      let candidates: [(EditorCropHandle, NSPoint)] = [
        (.topLeft, NSPoint(x: viewRect.minX, y: viewRect.minY)),
        (.top, NSPoint(x: viewRect.midX, y: viewRect.minY)),
        (.topRight, NSPoint(x: viewRect.maxX, y: viewRect.minY)),
        (.right, NSPoint(x: viewRect.maxX, y: viewRect.midY)),
        (.bottomRight, NSPoint(x: viewRect.maxX, y: viewRect.maxY)),
        (.bottom, NSPoint(x: viewRect.midX, y: viewRect.maxY)),
        (.bottomLeft, NSPoint(x: viewRect.minX, y: viewRect.maxY)),
        (.left, NSPoint(x: viewRect.minX, y: viewRect.midY)),
      ]
      if let handle = candidates.first(where: {
        hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance
      })?.0 {
        return (annotation, .shape(handle))
      }
      if let rotationHandle = rotationHandlePoint(
        center: CGPoint(x: value.rect.midX, y: value.rect.midY),
        topY: value.rect.minY,
        rotationDegrees: value.rotationDegrees
      ) {
        let view = viewport.viewPoint(fromModel: rotationHandle)
        if hypot(view.x - point.x, view.y - point.y) <= tolerance {
          return (annotation, .shapeRotation)
        }
      }
    case .line(let value):
      let start = viewport.viewPoint(fromModel: value.start)
      let end = viewport.viewPoint(fromModel: value.end)
      if hypot(start.x - point.x, start.y - point.y) <= tolerance {
        return (annotation, .lineStart)
      }
      if hypot(end.x - point.x, end.y - point.y) <= tolerance {
        return (annotation, .lineEnd)
      }
      if let rotationHandle = rotationHandlePoint(
        center: CGPoint(
          x: (value.start.x + value.end.x) / 2,
          y: (value.start.y + value.end.y) / 2
        ),
        topY: min(value.start.y, value.end.y),
        rotationDegrees: 0
      ) {
        let view = viewport.viewPoint(fromModel: rotationHandle)
        if hypot(view.x - point.x, view.y - point.y) <= tolerance {
          return (annotation, .shapeRotation)
        }
      }
    case .arrow(let value):
      let start = viewport.viewPoint(fromModel: value.start)
      let end = viewport.viewPoint(fromModel: value.end)
      if hypot(start.x - point.x, start.y - point.y) <= tolerance {
        return (annotation, .lineStart)
      }
      if hypot(end.x - point.x, end.y - point.y) <= tolerance {
        return (annotation, .lineEnd)
      }
      if let rotationHandle = rotationHandlePoint(
        center: CGPoint(
          x: (value.start.x + value.end.x) / 2,
          y: (value.start.y + value.end.y) / 2
        ),
        topY: min(value.start.y, value.end.y),
        rotationDegrees: 0
      ) {
        let view = viewport.viewPoint(fromModel: rotationHandle)
        if hypot(view.x - point.x, view.y - point.y) <= tolerance {
          return (annotation, .shapeRotation)
        }
      }
    case .text(let value):
      let center = CGPoint(x: value.frame.midX, y: value.frame.midY)
      let cornerPoints = [
        CGPoint(x: value.frame.minX, y: value.frame.minY),
        CGPoint(x: value.frame.maxX, y: value.frame.minY),
        CGPoint(x: value.frame.maxX, y: value.frame.maxY),
        CGPoint(x: value.frame.minX, y: value.frame.maxY),
      ]
      for (index, corner) in cornerPoints.enumerated() {
        let rotated = EditorGeometry.rotatedPoint(
          corner,
          around: center,
          by: value.style.rotationDegrees
        )
        let view = viewport.viewPoint(fromModel: rotated)
        if hypot(view.x - point.x, view.y - point.y) <= tolerance {
          return (annotation, .textCorner(index))
        }
      }
      let leftMid = EditorGeometry.rotatedPoint(
        CGPoint(x: value.frame.minX, y: value.frame.midY),
        around: center,
        by: value.style.rotationDegrees
      )
      let rightMid = EditorGeometry.rotatedPoint(
        CGPoint(x: value.frame.maxX, y: value.frame.midY),
        around: center,
        by: value.style.rotationDegrees
      )
      let leftView = viewport.viewPoint(fromModel: leftMid)
      let rightView = viewport.viewPoint(fromModel: rightMid)
      if hypot(leftView.x - point.x, leftView.y - point.y) <= tolerance {
        return (annotation, .textLeft)
      }
      if hypot(rightView.x - point.x, rightView.y - point.y) <= tolerance {
        return (annotation, .textRight)
      }
    case .mosaic:
      break
    }
    return nil
  }

  private func rotationHandlePoint(
    center: CGPoint,
    topY: CGFloat,
    rotationDegrees: Double
  ) -> CGPoint? {
    let raw = CGPoint(x: center.x, y: topY - 26)
    return EditorGeometry.rotatedPoint(
      raw,
      around: center,
      by: rotationDegrees
    )
  }

  private func applyResizeDrag(
    to viewPoint: NSPoint,
    original: EditorAnnotation,
    kind: CanvasResizeHandle
  ) {
    let point = viewport.modelPoint(fromView: viewPoint)
    let bounds = interactionState.crop.appliedCropRect
    var updated: EditorAnnotation?

    switch (original, kind) {
    case (.rectangle(let value), .shapeRotation),
      (.ellipse(let value), .shapeRotation):
      var newValue = value
      let center = CGPoint(x: value.rect.midX, y: value.rect.midY)
      let handle = CGPoint(x: center.x, y: value.rect.minY - 26)
      let handleAngle = atan2(
        handle.y - center.y,
        handle.x - center.x
      ) * 180 / .pi
      let targetAngle = atan2(
        point.y - center.y,
        point.x - center.x
      ) * 180 / .pi
      let delta = EditorGeometry.normalizedAngle(targetAngle - handleAngle)
      let next = EditorGeometry.normalizedAngle(value.rotationDegrees + delta)
      guard next != value.rotationDegrees else { break }
      newValue.rotationDegrees = next
      if case .rectangle = original {
        updated = .rectangle(newValue)
      } else {
        updated = .ellipse(newValue)
      }
    case (.line(let value), .shapeRotation), (.arrow(let value), .shapeRotation):
      let center = CGPoint(
        x: (value.start.x + value.end.x) / 2,
        y: (value.start.y + value.end.y) / 2
      )
      let handle = CGPoint(x: center.x, y: min(value.start.y, value.end.y) - 26)
      let handleAngle = atan2(handle.y - center.y, handle.x - center.x) * 180 / .pi
      let targetAngle = atan2(point.y - center.y, point.x - center.x) * 180 / .pi
      let delta = EditorGeometry.normalizedAngle(targetAngle - handleAngle)
      guard abs(delta) > 0.01 else { break }
      var newValue = value
      newValue.start = EditorGeometry.rotatedPoint(value.start, around: center, by: delta)
      newValue.end = EditorGeometry.rotatedPoint(value.end, around: center, by: delta)
      if case .line = original {
        updated = .line(newValue)
      } else {
        updated = .arrow(newValue)
      }
    case (.rectangle(let value), .shape(let handle)),
      (.ellipse(let value), .shape(let handle)):
      let rect = resizedRect(
        original: value.rect,
        handle: handle,
        to: point,
        bounds: bounds
      )
      if rect != value.rect {
        var newValue = value
        newValue.rect = rect
        if case .rectangle = original {
          updated = .rectangle(newValue)
        } else {
          updated = .ellipse(newValue)
        }
      }
    case (.line(let value), .lineStart):
      let newStart = EditorGeometry.clamp(point, to: bounds)
      if newStart != value.start {
        var newValue = value
        newValue.start = newStart
        updated = .line(newValue)
      }
    case (.line(let value), .lineEnd):
      let newEnd = EditorGeometry.clamp(point, to: bounds)
      if newEnd != value.end {
        var newValue = value
        newValue.end = newEnd
        updated = .line(newValue)
      }
    case (.arrow(let value), .lineStart):
      let newStart = EditorGeometry.clamp(point, to: bounds)
      if newStart != value.start {
        var newValue = value
        newValue.start = newStart
        updated = .arrow(newValue)
      }
    case (.arrow(let value), .lineEnd):
      let newEnd = EditorGeometry.clamp(point, to: bounds)
      if newEnd != value.end {
        var newValue = value
        newValue.end = newEnd
        updated = .arrow(newValue)
      }
    case (.text(let value), .textCorner(let index)):
      updated = resizedText(
        value,
        cornerIndex: index,
        to: point,
        bounds: bounds
      )
    case (.text(let value), .textLeft):
      updated = resizedTextWidth(value, left: true, to: point, bounds: bounds)
    case (.text(let value), .textRight):
      updated = resizedTextWidth(value, left: false, to: point, bounds: bounds)
    default:
      break
    }

    if let updated {
      interactionState.replaceDuringResize(updated)
      resizeDidChange = true
      needsDisplay = true
    }
  }

  private func resizedText(
    _ value: TextAnnotation,
    cornerIndex: Int,
    to point: CGPoint,
    bounds: CGRect
  ) -> EditorAnnotation? {
    let center = CGPoint(x: value.frame.midX, y: value.frame.midY)
    let local = EditorGeometry.inverseRotatedPoint(
      point,
      around: center,
      by: value.style.rotationDegrees
    )
    let oppositeIndex = (cornerIndex + 2) % 4
    let corners = [
      CGPoint(x: value.frame.minX, y: value.frame.minY),
      CGPoint(x: value.frame.maxX, y: value.frame.minY),
      CGPoint(x: value.frame.maxX, y: value.frame.maxY),
      CGPoint(x: value.frame.minX, y: value.frame.maxY),
    ]
    let opposite = corners[oppositeIndex]
    let oldCorner = corners[cornerIndex]
    let oldDX = abs(oldCorner.x - opposite.x)
    let oldDY = abs(oldCorner.y - opposite.y)
    guard oldDX > 0, oldDY > 0 else { return nil }
    let ratio = max(
      max(abs(local.x - opposite.x) / oldDX, 0.1),
      max(abs(local.y - opposite.y) / oldDY, 0.1)
    )
    let newWidth = max(value.frame.width * ratio, 8)
    let newHeight = max(value.frame.height * ratio, 8)
    let oppositeWidth = opposite.x == value.frame.minX
    let oppositeTop = opposite.y == value.frame.minY
    var newFrame = value.frame
    newFrame.size = CGSize(width: newWidth, height: newHeight)
    if oppositeWidth {
      newFrame.origin.x = opposite.x
    } else {
      newFrame.origin.x = opposite.x - newWidth
    }
    if oppositeTop {
      newFrame.origin.y = opposite.y
    } else {
      newFrame.origin.y = opposite.y - newHeight
    }
    guard bounds.contains(newFrame) else { return nil }

    let nominal = min(96, max(10, value.style.nominalFontSize * ratio))
    let style = EditorTextStyle(
      fontDesign: value.style.fontDesign,
      nominalFontSize: nominal,
      renderedFontSizeInPixels: nominal * interactionState.pointsToImageScale,
      rotationDegrees: value.style.rotationDegrees,
      color: value.style.color
    )
    let measured = EditorTextLayout.measuredSize(
      text: value.text,
      style: style,
      width: newWidth
    )
    newFrame.size.height = measured.height
    return .text(
      TextAnnotation(
        id: value.id,
        text: value.text,
        frame: newFrame,
        style: style
      )
    )
  }

  private func resizedTextWidth(
    _ value: TextAnnotation,
    left: Bool,
    to point: CGPoint,
    bounds: CGRect
  ) -> EditorAnnotation? {
    let center = CGPoint(x: value.frame.midX, y: value.frame.midY)
    let local = EditorGeometry.inverseRotatedPoint(
      point,
      around: center,
      by: value.style.rotationDegrees
    )
    var newFrame = value.frame
    if left {
      let minX = min(max(local.x, bounds.minX), newFrame.maxX - 8)
      newFrame.origin.x = minX
      newFrame.size.width = newFrame.maxX - minX
    } else {
      let maxX = max(local.x, newFrame.minX + 8)
      newFrame.size.width = maxX - newFrame.minX
    }
    let style = value.style
    let measured = EditorTextLayout.measuredSize(
      text: value.text,
      style: style,
      width: newFrame.width
    )
    newFrame.size.height = measured.height
    guard newFrame.minX >= bounds.minX, newFrame.maxX <= bounds.maxX else {
      return nil
    }
    return .text(
      TextAnnotation(
        id: value.id,
        text: value.text,
        frame: newFrame,
        style: value.style
      )
    )
  }

  private func resizedRect(
    original: CGRect,
    handle: EditorCropHandle,
    to point: CGPoint,
    bounds: CGRect
  ) -> CGRect {
    var minX = original.minX
    var minY = original.minY
    var maxX = original.maxX
    var maxY = original.maxY
    let minimum: CGFloat = 6
    let minimumHeight: CGFloat = 6

    switch handle {
    case .topLeft:
      minX = min(point.x, maxX - minimum)
      minY = min(point.y, maxY - minimumHeight)
    case .top:
      minY = min(point.y, maxY - minimumHeight)
    case .topRight:
      maxX = max(point.x, minX + minimum)
      minY = min(point.y, maxY - minimumHeight)
    case .right:
      maxX = max(point.x, minX + minimum)
    case .bottomRight:
      maxX = max(point.x, minX + minimum)
      maxY = max(point.y, minY + minimumHeight)
    case .bottom:
      maxY = max(point.y, minY + minimumHeight)
    case .bottomLeft:
      minX = min(point.x, maxX - minimum)
      maxY = max(point.y, minY + minimumHeight)
    case .left:
      minX = min(point.x, maxX - minimum)
    }
    return CGRect(
      x: max(bounds.minX, minX),
      y: max(bounds.minY, minY),
      width: min(maxX, bounds.maxX) - max(bounds.minX, minX),
      height: min(maxY, bounds.maxY) - max(bounds.minY, minY)
    )
  }

  private func selectedTextRotationHandle(at viewPoint: NSPoint) -> UUID? {
    guard let id = interactionState.selectedObjectID,
      case .text(let annotation)? = interactionState.annotation(withID: id)
    else {
      return nil
    }
    let viewRect = viewport.viewRect(fromModel: annotation.frame)
    let center = CGPoint(x: viewRect.midX, y: viewRect.midY)
    let handleModel = CGPoint(x: annotation.frame.midX, y: annotation.frame.minY - 24)
    let handleModelRotated = EditorGeometry.rotatedPoint(
      handleModel,
      around: CGPoint(x: annotation.frame.midX, y: annotation.frame.midY),
      by: annotation.style.rotationDegrees
    )
    let handle = viewport.viewPoint(fromModel: handleModelRotated)
    _ = center
    if hypot(handle.x - viewPoint.x, handle.y - viewPoint.y) <= 12 {
      return id
    }
    return nil
  }

  private func updateTextRotation(_ viewPoint: NSPoint) {
    guard let id = interactionState.selectedObjectID,
      case .text(let annotation)? = interactionState.annotation(withID: id)
    else {
      return
    }
    let modelPoint = viewport.modelPoint(fromView: viewPoint)
    let center = CGPoint(x: annotation.frame.midX, y: annotation.frame.midY)
    let degrees = atan2(
      modelPoint.y - center.y,
      modelPoint.x - center.x
    ) * 180 / .pi
    let shiftDown = NSEvent.modifierFlags.contains(.shift)
    interactionState.setSelectedTextRotation(degrees, snapping: shiftDown)
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 || event.keyCode == 117 {
      if interactionState.selectedObjectID != nil {
        interactionState.deleteSelection()
        needsDisplay = true
        onStateChanged?()
      }
      return
    }
    super.keyDown(with: event)
  }

  // MARK: Crop mouse handling

  private var cropDragHandle: EditorCropHandle?
  private var cropDragStart: NSPoint?
  private var cropWasMoving = false
  private var cropSelectionStart: CGPoint?

  private func handleCropMouseDown(_ point: NSPoint) {
    guard let draft = interactionState.crop.draftCropRect else { return }
    let box = viewport.viewRect(fromModel: draft)
    if let event = NSApp.currentEvent, event.clickCount == 2, box.contains(point) {
      interactionState.applyCropDraft()
      interactionState.setActiveTool(.selection)
      cropDragHandle = nil
      cropDragStart = nil
      cropWasMoving = false
      needsDisplay = true
      onStateChanged?()
      onCanvasInteraction?()
      return
    }
    if let handle = cropHandle(at: point, box: box) {
      cropDragHandle = handle
      cropDragStart = point
      cropWasMoving = false
      cropSelectionStart = nil
    } else if box.contains(point) {
      let isFullCrop = draft.width >= interactionState.originalPixelBounds.width - 0.5
        && draft.height >= interactionState.originalPixelBounds.height - 0.5
      cropDragHandle = nil
      cropSelectionStart = isFullCrop ? viewport.modelPoint(fromView: point) : nil
      cropDragStart = point
      cropWasMoving = !isFullCrop
    } else {
      cropDragHandle = nil
      cropDragStart = nil
      cropSelectionStart = nil
    }
  }

  private func handleCropMouseDragged(_ point: NSPoint) {
    if let start = cropSelectionStart {
      let current = viewport.modelPoint(fromView: point)
      let bounds = interactionState.originalPixelBounds
      let clamped = CGPoint(
        x: min(max(current.x, bounds.minX), bounds.maxX),
        y: min(max(current.y, bounds.minY), bounds.maxY)
      )
      interactionState.crop.draftCropRect = CGRect(
        x: min(start.x, clamped.x),
        y: min(start.y, clamped.y),
        width: abs(clamped.x - start.x),
        height: abs(clamped.y - start.y)
      )
      needsDisplay = true
      return
    }
    guard let start = cropDragStart else { return }
    let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
    let modelDelta = CGPoint(
      x: delta.x / viewport.viewPointsPerModelPixel,
      y: delta.y / viewport.viewPointsPerModelPixel
    )
    if let handle = cropDragHandle {
      interactionState.resizeCropDraft(
        handle,
        to: viewport.modelPoint(fromView: point)
      )
    } else if cropWasMoving {
      interactionState.moveCropDraft(by: modelDelta)
      cropDragStart = point
    }
    needsDisplay = true
  }

  private func handleCropMouseUp(_ point: NSPoint) {
    cropDragHandle = nil
    cropDragStart = nil
    cropWasMoving = false
    cropSelectionStart = nil
    onStateChanged?()
    onCanvasInteraction?()
  }

  private func cropHandle(at point: NSPoint, box: NSRect) -> EditorCropHandle? {
    let tolerance: CGFloat = 10
    let candidates: [(EditorCropHandle, NSPoint)] = [
      (.topLeft, NSPoint(x: box.minX, y: box.minY)),
      (.top, NSPoint(x: box.midX, y: box.minY)),
      (.topRight, NSPoint(x: box.maxX, y: box.minY)),
      (.right, NSPoint(x: box.maxX, y: box.midY)),
      (.bottomRight, NSPoint(x: box.maxX, y: box.maxY)),
      (.bottom, NSPoint(x: box.midX, y: box.maxY)),
      (.bottomLeft, NSPoint(x: box.minX, y: box.maxY)),
      (.left, NSPoint(x: box.minX, y: box.midY)),
    ]
    let nearest = candidates
      .filter { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance }
      .min { hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y) }
    return nearest?.0
  }

  // MARK: Inline text

  private func inlineTextUsedSize() -> CGSize {
    guard
      let textView = inlineEditor,
      let layoutManager = textView.layoutManager,
      let container = textView.textContainer
    else {
      return .zero
    }
    layoutManager.ensureLayout(for: container)
    let used = layoutManager.usedRect(for: container)
    return used.size
  }

  private func beginInlineText(at modelPoint: CGPoint) {
    endInlineText(commit: false)
    let style = styleStore.renderedTextStyle(scale: interactionState.pointsToImageScale)
    let viewPoint = viewport.viewPoint(fromModel: modelPoint)
    let availableWidth = max(viewport.displayRect.maxX - viewPoint.x, 80)
    let width = min(240, max(80, availableWidth))
    pendingTextOrigin = modelPoint
    pendingTextWidthInPixels = width / viewport.viewPointsPerModelPixel
    let frame = NSRect(x: viewPoint.x, y: viewPoint.y, width: width, height: 32)
    let textView = NSTextView(frame: frame)
    textView.isRichText = false
    textView.allowsUndo = false
    textView.font = EditorTextLayout.font(
      for: style.fontDesign,
      size: style.renderedFontSizeInPixels * viewport.viewPointsPerModelPixel
    )
    textView.textColor = style.color.nsColor
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: 10_000,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.autoresizingMask = []
    textView.delegate = self
    addSubview(textView)
    inlineEditor = textView
    onRequestFirstResponder?(textView)
  }

  private func beginInlineTextEditing(_ annotation: TextAnnotation) {
    endInlineText(commit: false)
    let viewRect = viewport.viewRect(fromModel: annotation.frame)
    pendingTextOrigin = annotation.frame.origin
    pendingTextWidthInPixels = annotation.frame.width
    let textView = NSTextView(frame: viewRect)
    textView.isRichText = false
    textView.allowsUndo = false
    textView.string = annotation.text
    textView.font = EditorTextLayout.font(
      for: annotation.style.fontDesign,
      size: annotation.style.renderedFontSizeInPixels * viewport.viewPointsPerModelPixel
    )
    textView.textColor = annotation.style.color.nsColor
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.textContainer?.lineFragmentPadding = 0
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    textView.autoresizingMask = []
    textView.delegate = self
    addSubview(textView)
    inlineEditor = textView
    inlineTextAnnotationID = annotation.id
    interactionState.selectedObjectID = annotation.id
    onRequestFirstResponder?(textView)
    needsDisplay = true
  }

  private func commitInlineText() {
    guard let textView = inlineEditor else { return }
    let text = textView.string
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      textView.removeFromSuperview()
      inlineEditor = nil
      return
    }

    let style = styleStore.renderedTextStyle(scale: interactionState.pointsToImageScale)
    let viewRect = textView.frame
    let origin = pendingTextOrigin ?? viewport.modelPoint(fromView: viewRect.origin)
    let currentWidth = max(
      pendingTextWidthInPixels ?? viewRect.width / viewport.viewPointsPerModelPixel,
      1
    )
    let usedSize = inlineTextUsedSize()
    let viewToModel = 1 / max(viewport.viewPointsPerModelPixel, 0.01)
    let horizontalPadding = max(
      4,
      6 * viewToModel
    )
    let modelRect = CGRect(
      x: origin.x,
      y: origin.y,
      width: max(usedSize.width * viewToModel, currentWidth) + horizontalPadding,
      height: max(usedSize.height * viewToModel, 1)
    )
    let boundedRect = clampedTextRect(
      modelRect,
      in: interactionState.crop.appliedCropRect
    )
    if let id = inlineTextAnnotationID {
      interactionState.replaceTextAnnotation(
        id: id,
        text: text,
        frame: boundedRect,
        style: style
      )
    } else {
      interactionState.commitNewText(
        text: text,
        frame: boundedRect,
        style: style
      )
    }
    textView.removeFromSuperview()
    inlineEditor = nil
    inlineTextAnnotationID = nil
    pendingTextOrigin = nil
    pendingTextWidthInPixels = nil
    interactionState.setActiveTool(.selection)
    needsDisplay = true
    onStateChanged?()
  }

  private func clampedTextRect(_ rect: CGRect, in bounds: CGRect) -> CGRect {
    var result = rect
    if result.maxX > bounds.maxX {
      result.origin.x = max(bounds.minX, bounds.maxX - result.width)
    }
    if result.minX < bounds.minX {
      result.origin.x = bounds.minX
    }
    if result.maxY > bounds.maxY {
      result.origin.y = max(bounds.minY, bounds.maxY - result.height)
    }
    if result.minY < bounds.minY {
      result.origin.y = bounds.minY
    }
    return result
  }

  private func endInlineText(commit: Bool) {
    guard inlineEditor != nil else { return }
    if commit {
      commitInlineText()
    } else {
      inlineEditor?.removeFromSuperview()
      inlineEditor = nil
      inlineTextAnnotationID = nil
      pendingTextOrigin = nil
      pendingTextWidthInPixels = nil
    }
  }

  func cancelInlineText() {
    endInlineText(commit: false)
  }

  func applyCropIfNeeded() {
    interactionState.applyCropDraft()
    needsDisplay = true
  }

  func discardCropIfNeeded() {
    interactionState.discardCropDraft()
    needsDisplay = true
  }
}

extension EditorCanvasView: NSTextViewDelegate {
  func textDidChange(_ notification: Notification) {
    guard
      inlineEditor != nil,
      let textView = notification.object as? NSTextView,
      textView === inlineEditor
    else {
      return
    }
    let used = inlineTextUsedSize()
    var frame = textView.frame
    let desiredWidth = min(max(used.width, frame.width) + 8, 10_000)
    frame.size.width = desiredWidth
    let targetHeight = max(used.height, 32)
    frame.size.height = targetHeight
    textView.frame = frame
    if let container = textView.textContainer {
      container.containerSize = NSSize(
        width: desiredWidth,
        height: max(targetHeight, 1_000)
      )
    }
    textView.needsLayout = true
    textView.needsDisplay = true
  }

  func textDidEndEditing(_ notification: Notification) {
    guard inlineEditor != nil else { return }
    commitInlineText()
  }
}

private extension RGBAColor {
  var nsColor: NSColor {
    NSColor(
      srgbRed: red,
      green: green,
      blue: blue,
      alpha: alpha
    )
  }
}
