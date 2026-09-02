import CoreGraphics
import Foundation

// MARK: - Targets, tools, fonts

enum EditorTarget: Equatable, Sendable {
  case newCapture(capturedAt: Date)
  case historyItem(id: UUID, capturedAt: Date, sourceRevision: UInt64)
}

enum EditorTool: Equatable, Sendable {
  case selection
  case rectangle
  case ellipse
  case line
  case arrow
  case text
  case mosaic
  case crop
  case ocr
}

enum EditorFontDesign: String, CaseIterable, Equatable, Hashable, Sendable {
  case system
  case serif
  case rounded
  case monospaced
}

// MARK: - Colors and styles

struct RGBAColor: Equatable, Hashable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double

  init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }
}

extension RGBAColor {
  static let coral = RGBAColor(red: 0xE9 / 255.0, green: 0x65 / 255.0, blue: 0x48 / 255.0)
  static let red = RGBAColor(red: 0xE5 / 255.0, green: 0x39 / 255.0, blue: 0x35 / 255.0)
  static let green = RGBAColor(red: 0x34 / 255.0, green: 0xA8 / 255.0, blue: 0x53 / 255.0)
  static let blue = RGBAColor(red: 0x28 / 255.0, green: 0x78 / 255.0, blue: 0xD0 / 255.0)
  static let white = RGBAColor(red: 1, green: 1, blue: 1)
  static let graphite = RGBAColor(red: 0x36 / 255.0, green: 0x36 / 255.0, blue: 0x35 / 255.0)
}

struct EditorStrokeStyleDefaults: Equatable, Sendable {
  var nominalLineWidth: CGFloat
  var color: RGBAColor
}

struct EditorStrokeStyle: Equatable, Sendable {
  var nominalLineWidth: CGFloat
  var renderedLineWidthInPixels: CGFloat
  var color: RGBAColor
}

struct EditorTextStyleDefaults: Equatable, Sendable {
  var fontDesign: EditorFontDesign
  var nominalFontSize: CGFloat
  var rotationDegrees: Double
  var color: RGBAColor
}

struct EditorTextStyle: Equatable, Sendable {
  var fontDesign: EditorFontDesign
  var nominalFontSize: CGFloat
  var renderedFontSizeInPixels: CGFloat
  var rotationDegrees: Double
  var color: RGBAColor
}

struct MosaicStyleDefaults: Equatable, Sendable {
  var nominalBrushWidth: CGFloat
}

struct MosaicStyle: Equatable, Sendable {
  var nominalBrushWidth: CGFloat
  var renderedBrushWidthInPixels: CGFloat
  var renderedPixelScaleInPixels: CGFloat
}

/// A value snapshot of the app-run style defaults, usable by the pure reducer.
struct EditorStyleSnapshot: Equatable, Sendable {
  var stroke: EditorStrokeStyle
  var text: EditorTextStyle
  var mosaic: MosaicStyle
}

// MARK: - Session style store

/// App-run-scoped defaults. Main thread only; never persisted.
@MainActor
final class EditorToolStyleStore {
  private(set) var strokeDefaults: EditorStrokeStyleDefaults
  private(set) var textDefaults: EditorTextStyleDefaults
  private(set) var mosaicDefaults: MosaicStyleDefaults

  init() {
    strokeDefaults = EditorStrokeStyleDefaults(nominalLineWidth: 4, color: .coral)
    textDefaults = EditorTextStyleDefaults(
      fontDesign: .system,
      nominalFontSize: 18,
      rotationDegrees: 0,
      color: .coral
    )
    mosaicDefaults = MosaicStyleDefaults(nominalBrushWidth: 24)
  }

  func setStrokeNominalWidth(_ value: CGFloat) {
    strokeDefaults.nominalLineWidth = value
  }

  func setStrokeColor(_ color: RGBAColor) {
    strokeDefaults.color = color
  }

  func setTextFontDesign(_ design: EditorFontDesign) {
    textDefaults.fontDesign = design
  }

  func setTextNominalFontSize(_ size: CGFloat) {
    textDefaults.nominalFontSize = size
  }

  func setTextRotationDegrees(_ degrees: Double) {
    textDefaults.rotationDegrees = EditorGeometry.normalizedAngle(degrees)
  }

  func setTextColor(_ color: RGBAColor) {
    textDefaults.color = color
  }

  func setMosaicNominalBrushWidth(_ value: CGFloat) {
    mosaicDefaults.nominalBrushWidth = value
  }

  func renderedStrokeStyle(scale: CGFloat) -> EditorStrokeStyle {
    EditorStrokeStyle(
      nominalLineWidth: strokeDefaults.nominalLineWidth,
      renderedLineWidthInPixels: strokeDefaults.nominalLineWidth * scale,
      color: strokeDefaults.color
    )
  }

  func renderedTextStyle(scale: CGFloat) -> EditorTextStyle {
    EditorTextStyle(
      fontDesign: textDefaults.fontDesign,
      nominalFontSize: textDefaults.nominalFontSize,
      renderedFontSizeInPixels: textDefaults.nominalFontSize * scale,
      rotationDegrees: EditorGeometry.normalizedAngle(textDefaults.rotationDegrees),
      color: textDefaults.color
    )
  }

  func renderedMosaicStyle(scale: CGFloat) -> MosaicStyle {
    MosaicStyle(
      nominalBrushWidth: mosaicDefaults.nominalBrushWidth,
      renderedBrushWidthInPixels: mosaicDefaults.nominalBrushWidth * scale,
      renderedPixelScaleInPixels: (mosaicDefaults.nominalBrushWidth / 2) * scale
    )
  }

  func styleSnapshot(scale: CGFloat) -> EditorStyleSnapshot {
    EditorStyleSnapshot(
      stroke: renderedStrokeStyle(scale: scale),
      text: renderedTextStyle(scale: scale),
      mosaic: renderedMosaicStyle(scale: scale)
    )
  }
}

// MARK: - Crop

enum EditorCropHandle: Equatable, Sendable, CaseIterable {
  case topLeft
  case top
  case topRight
  case right
  case bottomRight
  case bottom
  case bottomLeft
  case left
}

struct CropState: Equatable, Sendable {
  let originalPixelBounds: CGRect
  var appliedCropRect: CGRect
  var draftCropRect: CGRect?

  init(originalPixelBounds: CGRect, appliedCropRect: CGRect? = nil) {
    let bounds = originalPixelBounds.standardized
    self.originalPixelBounds = bounds
    let requested = appliedCropRect ?? bounds
    self.appliedCropRect = Self.sanitized(requested, within: bounds)
  }

  static func sanitized(_ rect: CGRect, within bounds: CGRect) -> CGRect {
    guard !rect.isNull, !rect.isEmpty, bounds.width > 0, bounds.height > 0 else {
      return bounds
    }
    let minX = max(bounds.minX, floor(rect.minX))
    let minY = max(bounds.minY, floor(rect.minY))
    let maxX = min(bounds.maxX, ceil(rect.maxX))
    let maxY = min(bounds.maxY, ceil(rect.maxY))
    guard maxX >= minX, maxY >= minY else {
      return bounds
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}

// MARK: - Annotations

struct ShapeAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var rect: CGRect
  var style: EditorStrokeStyle
  var rotationDegrees: Double = 0
}

struct LineAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var start: CGPoint
  var end: CGPoint
  var style: EditorStrokeStyle
  var rotationDegrees: Double = 0
}

struct TextAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var text: String
  var frame: CGRect
  var style: EditorTextStyle
}

struct MosaicAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var points: [CGPoint]
  var style: MosaicStyle
}

enum EditorAnnotation: Identifiable, Equatable, Sendable {
  case rectangle(ShapeAnnotation)
  case ellipse(ShapeAnnotation)
  case line(LineAnnotation)
  case arrow(LineAnnotation)
  case text(TextAnnotation)
  case mosaic(MosaicAnnotation)

  var id: UUID {
    switch self {
    case .rectangle(let value), .ellipse(let value):
      return value.id
    case .line(let value), .arrow(let value):
      return value.id
    case .text(let value):
      return value.id
    case .mosaic(let value):
      return value.id
    }
  }

  var isMosaic: Bool {
    if case .mosaic = self {
      return true
    }
    return false
  }
}

enum OCRCacheDisposition: Equatable, Sendable {
  case preserve
  case clear
  case replace(String)
}

struct EditorOutput: Equatable, Sendable {
  let target: EditorTarget
  let pngData: Data
  let contentChanged: Bool
  let ocrCache: OCRCacheDisposition
}

// MARK: - Geometry

enum EditorGeometry {
  static func aspectFitRect(for pixelSize: CGSize, in bounds: CGRect) -> CGRect {
    guard pixelSize.width > 0, pixelSize.height > 0, bounds.width > 0, bounds.height > 0 else {
      return .zero
    }
    let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
    let size = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    return CGRect(
      x: bounds.midX - size.width / 2,
      y: bounds.midY - size.height / 2,
      width: size.width,
      height: size.height
    )
  }

  /// Normalizes to `(-180, 180]`; `-180` is stored as `180`.
  static func normalizedAngle(_ degrees: Double) -> Double {
    guard degrees.isFinite else { return 0 }
    var value = degrees.truncatingRemainder(dividingBy: 360)
    if value <= -180 {
      value += 360
    } else if value > 180 {
      value -= 360
    }
    return value == -180 ? 180 : value
  }

  /// Steppers wrap instead of clamping at both ends.
  static func incrementStepperAngle(_ degrees: Double, by delta: Double) -> Double {
    normalizedAngle(normalizedAngle(degrees) + delta)
  }

  static func snappedAngle(_ degrees: Double, increment: Double = 15) -> Double {
    normalizedAngle((degrees / increment).rounded() * increment)
  }

  static func rotatedPoint(_ point: CGPoint, around center: CGPoint, by degrees: Double) -> CGPoint {
    let radians = degrees * Double.pi / 180
    let dx = point.x - center.x
    let dy = point.y - center.y
    let cosValue = CGFloat(cos(radians))
    let sinValue = CGFloat(sin(radians))
    return CGPoint(
      x: center.x + dx * cosValue - dy * sinValue,
      y: center.y + dx * sinValue + dy * cosValue
    )
  }

  static func inverseRotatedPoint(_ point: CGPoint, around center: CGPoint, by degrees: Double) -> CGPoint {
    rotatedPoint(point, around: center, by: -degrees)
  }

  static func containsRotatedFrame(_ rect: CGRect, point: CGPoint, degrees: Double) -> Bool {
    let local = inverseRotatedPoint(
      point,
      around: CGPoint(x: rect.midX, y: rect.midY),
      by: degrees
    )
    return rect.contains(local)
  }

  static func distance(from point: CGPoint, toSegment start: CGPoint, end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else {
      return hypot(point.x - start.x, point.y - start.y)
    }
    let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
    let projection = CGPoint(x: start.x + t * dx, y: start.y + t * dy)
    return hypot(point.x - projection.x, point.y - projection.y)
  }

  static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
  }

  static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
    CGPoint(
      x: min(max(point.x, rect.minX), rect.maxX),
      y: min(max(point.y, rect.minY), rect.maxY)
    )
  }
}

// MARK: - Pointer metrics

struct EditorPointerMetrics: Equatable, Sendable {
  var modelPixelsPerPoint: CGFloat

  init(modelPixelsPerPoint: CGFloat) {
    self.modelPixelsPerPoint = modelPixelsPerPoint
  }

  var minimumShapeExtent: CGFloat {
    6 * modelPixelsPerPoint
  }

  var minimumLineLength: CGFloat {
    3 * modelPixelsPerPoint
  }

  var hitTolerance: CGFloat {
    6 * modelPixelsPerPoint
  }

  func mosaicHitTolerance(brushWidthPixels: CGFloat) -> CGFloat {
    brushWidthPixels / 2 + 4 * modelPixelsPerPoint
  }
}

// MARK: - Reducer drafts

enum EditorShapeKind: Equatable, Sendable {
  case rectangle
  case ellipse
  case line
  case arrow
}

enum EditorCreationDraft: Equatable, Sendable {
  case shape(kind: EditorShapeKind, start: CGPoint, current: CGPoint, style: EditorStrokeStyle)
  case mosaic(points: [CGPoint], style: MosaicStyle)
  case selectionMove(original: EditorAnnotation, startPoint: CGPoint, hasChanged: Bool)
}

struct EditorUndoRecord: Equatable, Sendable {
  var appliedCropRect: CGRect
  var annotations: [EditorAnnotation]
  var selectedObjectID: UUID?
}

// MARK: - Pure interaction state

struct EditorInteractionState: Equatable, Sendable {
  let originalPixelBounds: CGRect
  let pointsToImageScale: CGFloat
  var crop: CropState
  var annotations: [EditorAnnotation]
  var selectedObjectID: UUID?
  var activeTool: EditorTool
  var creationDraft: EditorCreationDraft?
  var activePointerMetrics: EditorPointerMetrics?
  var pendingTextRotationUndo: EditorUndoRecord?
  var pendingTextRotationOriginalDegrees: Double?
  var pendingResizeUndo: EditorUndoRecord?
  private(set) var undoStack: [EditorUndoRecord]
  private(set) var contentRevision: UInt64

  var isCropModeActive: Bool {
    crop.draftCropRect != nil
  }

  var canUndo: Bool {
    isCropModeActive || !undoStack.isEmpty
  }

  init(
    sourcePixelSize: CGSize,
    pointsToImageScale: CGFloat = 1,
    activeTool: EditorTool = .selection,
    annotations: [EditorAnnotation] = []
  ) {
    let bounds = CGRect(origin: .zero, size: sourcePixelSize)
    self.originalPixelBounds = bounds
    self.pointsToImageScale = pointsToImageScale
    self.crop = CropState(originalPixelBounds: bounds)
    self.annotations = annotations
    self.selectedObjectID = nil
    self.activeTool = activeTool
    self.creationDraft = nil
    self.activePointerMetrics = nil
    self.pendingTextRotationUndo = nil
    self.pendingTextRotationOriginalDegrees = nil
    self.pendingResizeUndo = nil
    self.undoStack = []
    self.contentRevision = 0
  }

  // MARK: Undo

  private mutating func pushUndoSnapshot() {
    undoStack.append(
      EditorUndoRecord(
        appliedCropRect: crop.appliedCropRect,
        annotations: annotations,
        selectedObjectID: selectedObjectID
      )
    )
  }

  mutating func undo() {
    if isCropModeActive {
      crop.draftCropRect = nil
      return
    }
    guard let record = undoStack.popLast() else { return }
    crop.appliedCropRect = record.appliedCropRect
    annotations = record.annotations
    selectedObjectID = record.selectedObjectID
    creationDraft = nil
    activePointerMetrics = nil
    pendingTextRotationUndo = nil
    pendingTextRotationOriginalDegrees = nil
    pendingResizeUndo = nil
    contentRevision &+= 1
  }

  @discardableResult
  mutating func beginResize(original: EditorAnnotation) -> Bool {
    guard annotations.contains(where: { $0.id == original.id }) else {
      return false
    }
    guard pendingResizeUndo == nil else { return false }
    pendingResizeUndo = EditorUndoRecord(
      appliedCropRect: crop.appliedCropRect,
      annotations: annotations,
      selectedObjectID: selectedObjectID
    )
    return true
  }

  mutating func replaceDuringResize(_ annotation: EditorAnnotation) {
    guard pendingResizeUndo != nil,
      let index = annotations.firstIndex(where: { $0.id == annotation.id })
    else {
      return
    }
    annotations[index] = annotation
  }

  mutating func endResize() {
    guard let pending = pendingResizeUndo else { return }
    pendingResizeUndo = nil
    undoStack.append(pending)
    contentRevision &+= 1
  }

  mutating func cancelResize() {
    pendingResizeUndo = nil
  }

  func annotation(withID id: UUID) -> EditorAnnotation? {
    annotations.last { $0.id == id }
  }

  // MARK: Tool and selection

  mutating func setActiveTool(_ tool: EditorTool) {
    if isCropModeActive, tool != .crop {
      applyCropDraft()
    }
    activeTool = tool
    creationDraft = nil
    activePointerMetrics = nil
    if tool != .selection {
      selectedObjectID = nil
    }
  }

  mutating func deleteSelection() {
    guard let id = selectedObjectID else { return }
    pushUndoSnapshot()
    annotations.removeAll { $0.id == id }
    selectedObjectID = nil
    contentRevision &+= 1
  }

  @discardableResult
  mutating func updateSelectedShapeStroke(
    nominalLineWidth: CGFloat? = nil,
    color: RGBAColor? = nil
  ) -> Bool {
    guard let id = selectedObjectID,
      let index = annotations.firstIndex(where: { $0.id == id })
    else {
      return false
    }
    let changed: Bool
    switch annotations[index] {
    case .rectangle(var value):
      changed = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      if changed {
        annotations[index] = .rectangle(value)
      }
    case .ellipse(var value):
      changed = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      if changed {
        annotations[index] = .ellipse(value)
      }
    case .line(var value):
      changed = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      if changed {
        annotations[index] = .line(value)
      }
    case .arrow(var value):
      changed = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      if changed {
        annotations[index] = .arrow(value)
      }
    case .text, .mosaic:
      return false
    }
    guard changed else { return false }
    pushUndoSnapshot()
    contentRevision &+= 1
    return true
  }

  @discardableResult
  mutating func previewSelectedShapeStroke(
    nominalLineWidth: CGFloat? = nil,
    color: RGBAColor? = nil
  ) -> Bool {
    guard let id = selectedObjectID,
      let index = annotations.firstIndex(where: { $0.id == id })
    else {
      return false
    }
    switch annotations[index] {
    case .rectangle(var value):
      _ = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      annotations[index] = .rectangle(value)
    case .ellipse(var value):
      _ = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      annotations[index] = .ellipse(value)
    case .line(var value):
      _ = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      annotations[index] = .line(value)
    case .arrow(var value):
      _ = mutateStroke(&value.style, nominalLineWidth: nominalLineWidth, color: color)
      annotations[index] = .arrow(value)
    case .text, .mosaic:
      return false
    }
    return true
  }

  private func mutateStroke(
    _ style: inout EditorStrokeStyle,
    nominalLineWidth: CGFloat?,
    color: RGBAColor?
  ) -> Bool {
    var changed = false
    if let nominalLineWidth, nominalLineWidth != style.nominalLineWidth {
      style.nominalLineWidth = nominalLineWidth
      style.renderedLineWidthInPixels = nominalLineWidth * pointsToImageScale
      changed = true
    }
    if let color, color != style.color {
      style.color = color
      changed = true
    }
    return changed
  }

  // MARK: Text rotation transactions

  mutating func beginSelectedTextRotation() -> Bool {
    guard let id = selectedObjectID,
      case .text(let value)? = annotation(withID: id)
    else {
      return false
    }
    pendingTextRotationUndo = EditorUndoRecord(
      appliedCropRect: crop.appliedCropRect,
      annotations: annotations,
      selectedObjectID: selectedObjectID
    )
    pendingTextRotationOriginalDegrees = value.style.rotationDegrees
    return true
  }

  mutating func setSelectedTextRotation(
    _ degrees: Double,
    snapping: Bool = false
  ) -> Bool {
    guard let id = selectedObjectID,
      let index = annotations.firstIndex(where: { $0.id == id })
    else {
      return false
    }
    guard case .text(var value) = annotations[index] else {
      return false
    }
    let target = snapping
      ? EditorGeometry.snappedAngle(degrees)
      : EditorGeometry.normalizedAngle(degrees)
    guard target != value.style.rotationDegrees else { return false }
    value.style.rotationDegrees = target
    annotations[index] = .text(value)
    return true
  }

  mutating func endSelectedTextRotation() {
    guard let pending = pendingTextRotationUndo,
      let originalDegrees = pendingTextRotationOriginalDegrees
    else {
      return
    }
    defer {
      pendingTextRotationUndo = nil
      pendingTextRotationOriginalDegrees = nil
    }
    guard let id = selectedObjectID,
      case .text(let value)? = annotation(withID: id),
      value.style.rotationDegrees != originalDegrees
    else {
      return
    }
    undoStack.append(pending)
    contentRevision &+= 1
  }

  mutating func cancelSelectedTextRotation() {
    guard let originalDegrees = pendingTextRotationOriginalDegrees,
      let id = selectedObjectID,
      let index = annotations.firstIndex(where: { $0.id == id })
    else {
      pendingTextRotationUndo = nil
      pendingTextRotationOriginalDegrees = nil
      return
    }
    if case .text(var value) = annotations[index] {
      value.style.rotationDegrees = originalDegrees
      annotations[index] = .text(value)
    }
    pendingTextRotationUndo = nil
    pendingTextRotationOriginalDegrees = nil
  }

  mutating func commitNewText(text: String, frame: CGRect, style: EditorTextStyle) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var style = style
    style.rotationDegrees = EditorGeometry.normalizedAngle(style.rotationDegrees)
    pushUndoSnapshot()
    let annotation = TextAnnotation(id: UUID(), text: text, frame: frame, style: style)
    annotations.append(.text(annotation))
    selectedObjectID = annotation.id
    contentRevision &+= 1
  }

  mutating func replaceTextAnnotation(
    id: UUID,
    text: String,
    frame: CGRect,
    style: EditorTextStyle
  ) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    var style = style
    style.rotationDegrees = EditorGeometry.normalizedAngle(style.rotationDegrees)
    pushUndoSnapshot()
    annotations[index] = .text(
      TextAnnotation(id: id, text: text, frame: frame, style: style)
    )
    contentRevision &+= 1
  }

  mutating func previewReplaceTextAnnotation(
    id: UUID,
    text: String,
    frame: CGRect,
    style: EditorTextStyle
  ) {
    guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
    var style = style
    style.rotationDegrees = EditorGeometry.normalizedAngle(style.rotationDegrees)
    annotations[index] = .text(
      TextAnnotation(id: id, text: text, frame: frame, style: style)
    )
  }

  // MARK: Hit testing

  func hitTest(at point: CGPoint, metrics: EditorPointerMetrics) -> EditorAnnotation? {
    for annotation in annotations.reversed() {
      if annotationHit(annotation, at: point, metrics: metrics) {
        return annotation
      }
    }
    return nil
  }

  private func annotationHit(
    _ annotation: EditorAnnotation,
    at point: CGPoint,
    metrics: EditorPointerMetrics
  ) -> Bool {
    let tolerance = metrics.hitTolerance
    switch annotation {
    case .rectangle(let value):
      return EditorGeometry.containsRotatedFrame(
        value.rect,
        point: point,
        degrees: value.rotationDegrees
      ) || value.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    case .ellipse(let value):
      return EditorGeometry.containsRotatedFrame(
        value.rect,
        point: point,
        degrees: value.rotationDegrees
      ) || value.rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    case .line(let value), .arrow(let value):
      return EditorGeometry.distance(from: point, toSegment: value.start, end: value.end)
        <= tolerance
    case .text(let value):
      return EditorGeometry.containsRotatedFrame(
        value.frame,
        point: point,
        degrees: value.style.rotationDegrees
      )
    case .mosaic(let value):
      guard !value.points.isEmpty else { return false }
      let tolerance = metrics.mosaicHitTolerance(
        brushWidthPixels: value.style.renderedBrushWidthInPixels
      )
      if value.points.count == 1 {
        return EditorGeometry.distance(point, value.points[0]) <= tolerance
      }
      for index in value.points.indices.dropLast() {
        if EditorGeometry.distance(
          from: point,
          toSegment: value.points[index],
          end: value.points[index + 1]
        ) <= tolerance {
          return true
        }
      }
      return false
    }
  }

  // MARK: Pointer gestures

  mutating func pointerDown(
    at point: CGPoint,
    metrics: EditorPointerMetrics,
    styleSnapshot: EditorStyleSnapshot
  ) {
    activePointerMetrics = metrics
    creationDraft = nil

    switch activeTool {
    case .selection:
      if let hit = hitTest(at: point, metrics: metrics) {
        selectedObjectID = hit.id
        if !hit.isMosaic {
          creationDraft = .selectionMove(
            original: hit,
            startPoint: point,
            hasChanged: false
          )
        }
      } else {
        selectedObjectID = nil
      }
    case .rectangle:
      guard crop.appliedCropRect.contains(point) else { return }
      creationDraft = .shape(
        kind: .rectangle,
        start: point,
        current: point,
        style: styleSnapshot.stroke
      )
    case .ellipse:
      guard crop.appliedCropRect.contains(point) else { return }
      creationDraft = .shape(
        kind: .ellipse,
        start: point,
        current: point,
        style: styleSnapshot.stroke
      )
    case .line:
      guard crop.appliedCropRect.contains(point) else { return }
      creationDraft = .shape(
        kind: .line,
        start: point,
        current: point,
        style: styleSnapshot.stroke
      )
    case .arrow:
      guard crop.appliedCropRect.contains(point) else { return }
      creationDraft = .shape(
        kind: .arrow,
        start: point,
        current: point,
        style: styleSnapshot.stroke
      )
    case .mosaic:
      guard crop.appliedCropRect.contains(point) else { return }
      creationDraft = .mosaic(
        points: [point],
        style: styleSnapshot.mosaic
      )
    case .text, .crop, .ocr:
      break
    }
  }

  mutating func pointerDragged(to point: CGPoint) {
    guard let draft = creationDraft else { return }
    let bounds = crop.appliedCropRect

    switch draft {
    case .shape(let kind, let start, _, let style):
      let current = EditorGeometry.clamp(point, to: bounds)
      creationDraft = .shape(kind: kind, start: start, current: current, style: style)
    case .mosaic(var points, let style):
      let current = EditorGeometry.clamp(point, to: bounds)
      if points.last != current {
        let step = max(style.renderedBrushWidthInPixels / 2, 1)
        var last = points.last ?? current
        while EditorGeometry.distance(last, current) >= step {
          let fraction = step / max(EditorGeometry.distance(last, current), 0.0001)
          last = CGPoint(
            x: last.x + (current.x - last.x) * fraction,
            y: last.y + (current.y - last.y) * fraction
          )
          points.append(last)
        }
        if points.last != current {
          points.append(current)
        }
        creationDraft = .mosaic(points: points, style: style)
      }
    case .selectionMove(let original, let startPoint, let hasChanged):
      let delta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y)
      let didChange = hasChanged || abs(delta.x) > 0 || abs(delta.y) > 0
      if didChange, !hasChanged {
        pushUndoSnapshot()
      }
      creationDraft = .selectionMove(
        original: original,
        startPoint: startPoint,
        hasChanged: didChange
      )
      if didChange {
        moveSelection(original, by: delta)
      }
    }
  }

  mutating func pointerUp(at point: CGPoint) {
    guard let draft = creationDraft else {
      activePointerMetrics = nil
      return
    }
    defer {
      creationDraft = nil
      activePointerMetrics = nil
    }

    switch draft {
    case .selectionMove(_, _, let hasChanged):
      if hasChanged {
        contentRevision &+= 1
      }
    case .shape(let kind, _, let current, let style):
      commitShape(kind: kind, current: point == current ? current : point, style: style)
    case .mosaic(let points, let style):
      commitMosaic(points: points, style: style)
    }
  }

  private mutating func commitShape(kind: EditorShapeKind, current: CGPoint, style: EditorStrokeStyle) {
    guard case .some(.shape(_, let start, _, _)) = creationDraft else { return }
    let bounds = crop.appliedCropRect
    let end = EditorGeometry.clamp(current, to: bounds)

    switch kind {
    case .rectangle, .ellipse:
      let rect = constrainedRect(
        from: start,
        to: end,
        minimumWidth: activePointerMetrics?.minimumShapeExtent ?? 0,
        minimumHeight: activePointerMetrics?.minimumShapeExtent ?? 0,
        bounds: bounds
      )
      guard let rect else { return }
      pushUndoSnapshot()
      let annotation = ShapeAnnotation(id: UUID(), rect: rect, style: style)
      switch kind {
      case .rectangle:
        annotations.append(.rectangle(annotation))
      case .ellipse:
        annotations.append(.ellipse(annotation))
      case .line, .arrow:
        break
      }
      selectedObjectID = annotation.id
      contentRevision &+= 1
    case .line, .arrow:
      let length = EditorGeometry.distance(start, end)
      guard length >= (activePointerMetrics?.minimumLineLength ?? 0) else { return }
      pushUndoSnapshot()
      let annotation = LineAnnotation(id: UUID(), start: start, end: end, style: style)
      switch kind {
      case .line:
        annotations.append(.line(annotation))
      case .arrow:
        annotations.append(.arrow(annotation))
      case .rectangle, .ellipse:
        break
      }
      selectedObjectID = annotation.id
      contentRevision &+= 1
    }
  }

  private mutating func commitMosaic(points: [CGPoint], style: MosaicStyle) {
    let clamped = points.map { EditorGeometry.clamp($0, to: crop.appliedCropRect) }
    guard !clamped.isEmpty else { return }
    pushUndoSnapshot()
    let annotation = MosaicAnnotation(id: UUID(), points: clamped, style: style)
    annotations.append(.mosaic(annotation))
    selectedObjectID = annotation.id
    contentRevision &+= 1
  }

  private func constrainedRect(
    from start: CGPoint,
    to end: CGPoint,
    minimumWidth: CGFloat,
    minimumHeight: CGFloat,
    bounds: CGRect
  ) -> CGRect? {
    var rect = CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    )
    guard rect.width > 0 || rect.height > 0 else { return nil }
    rect.size.width = min(bounds.width, max(rect.width, minimumWidth))
    rect.size.height = min(bounds.height, max(rect.height, minimumHeight))
    guard rect.width >= minimumWidth, rect.height >= minimumHeight else { return nil }
    rect.origin.x = min(max(rect.minX, bounds.minX), bounds.maxX - rect.width)
    rect.origin.y = min(max(rect.minY, bounds.minY), bounds.maxY - rect.height)
    return rect.intersection(bounds)
  }

  private mutating func moveSelection(_ original: EditorAnnotation, by delta: CGPoint) {
    guard let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
    let bounds = crop.appliedCropRect

    switch original {
    case .rectangle(var value), .ellipse(var value):
      let candidate = value.rect.offsetBy(dx: delta.x, dy: delta.y)
      guard bounds.contains(candidate) else { return }
      value.rect = candidate
      if case .rectangle = original {
        annotations[index] = .rectangle(value)
      } else {
        annotations[index] = .ellipse(value)
      }
    case .line(var value), .arrow(var value):
      let start = CGPoint(x: value.start.x + delta.x, y: value.start.y + delta.y)
      let end = CGPoint(x: value.end.x + delta.x, y: value.end.y + delta.y)
      guard bounds.contains(start), bounds.contains(end) else { return }
      value.start = start
      value.end = end
      if case .line = original {
        annotations[index] = .line(value)
      } else {
        annotations[index] = .arrow(value)
      }
    case .text(var value):
      let frame = value.frame.offsetBy(dx: delta.x, dy: delta.y)
      let center = CGPoint(x: frame.midX, y: frame.midY)
      guard bounds.contains(center) else { return }
      value.frame = frame
      annotations[index] = .text(value)
    case .mosaic:
      break
    }
  }

  // MARK: Crop reducer

  mutating func enterCropMode() {
    activeTool = .crop
    creationDraft = nil
    selectedObjectID = nil
    activePointerMetrics = nil
    if crop.draftCropRect == nil {
      crop.draftCropRect = crop.appliedCropRect
    }
  }

  mutating func moveCropDraft(by delta: CGPoint) {
    guard let draft = crop.draftCropRect else { return }
    let bounds = crop.originalPixelBounds
    let moved = draft.offsetBy(dx: delta.x, dy: delta.y)
    crop.draftCropRect = CGRect(
      x: min(max(moved.minX, bounds.minX), bounds.maxX - draft.width),
      y: min(max(moved.minY, bounds.minY), bounds.maxY - draft.height),
      width: draft.width,
      height: draft.height
    )
  }

  mutating func resizeCropDraft(_ handle: EditorCropHandle, to point: CGPoint) {
    guard let draft = crop.draftCropRect else { return }
    let bounds = crop.originalPixelBounds
    let minimum = min(32, bounds.width)
    let minimumHeight = min(32, bounds.height)
    let target = EditorGeometry.clamp(point, to: bounds)

    var minX = draft.minX
    var minY = draft.minY
    var maxX = draft.maxX
    var maxY = draft.maxY

    switch handle {
    case .topLeft:
      minX = min(target.x, maxX - minimum)
      minY = min(target.y, maxY - minimumHeight)
    case .top:
      minY = min(target.y, maxY - minimumHeight)
    case .topRight:
      maxX = max(target.x, minX + minimum)
      minY = min(target.y, maxY - minimumHeight)
    case .right:
      maxX = max(target.x, minX + minimum)
    case .bottomRight:
      maxX = max(target.x, minX + minimum)
      maxY = max(target.y, minY + minimumHeight)
    case .bottom:
      maxY = max(target.y, minY + minimumHeight)
    case .bottomLeft:
      minX = min(target.x, maxX - minimum)
      maxY = max(target.y, minY + minimumHeight)
    case .left:
      minX = min(target.x, maxX - minimum)
    }

    maxX = max(minX + minimum, min(maxX, bounds.maxX))
    maxY = max(minY + minimumHeight, min(maxY, bounds.maxY))
    minX = min(max(minX, bounds.minX), maxX - minimum)
    minY = min(max(minY, bounds.minY), maxY - minimumHeight)

    crop.draftCropRect = CGRect(
      x: minX,
      y: minY,
      width: maxX - minX,
      height: maxY - minY
    )
  }

  mutating func applyCropDraft() {
    guard let draft = crop.draftCropRect else { return }
    let sanitized = CropState.sanitized(draft, within: crop.originalPixelBounds)
    crop.draftCropRect = nil
    guard sanitized != crop.appliedCropRect else { return }
    pushUndoSnapshot()
    crop.appliedCropRect = sanitized
    contentRevision &+= 1
  }

  mutating func discardCropDraft() {
    crop.draftCropRect = nil
  }
}
