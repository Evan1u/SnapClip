import CoreGraphics
import XCTest

@testable import SnapClip

@MainActor
final class EditorModelsTests: XCTestCase {
  private let styleStore = EditorToolStyleStore()

  private func makeState(
    size: CGSize = CGSize(width: 200, height: 200),
    scale: CGFloat = 2,
    tool: EditorTool = .selection
  ) -> EditorInteractionState {
    EditorInteractionState(
      sourcePixelSize: size,
      pointsToImageScale: scale,
      activeTool: tool
    )
  }

  private func metrics(_ scale: CGFloat = 2) -> EditorPointerMetrics {
    EditorPointerMetrics(modelPixelsPerPoint: scale)
  }

  private func snapshot(_ scale: CGFloat = 2) -> EditorStyleSnapshot {
    styleStore.styleSnapshot(scale: scale)
  }

  // MARK: Angles

  func testAngleNormalizationUsesHalfOpenRangeAndNormalizesNegative180() {
    XCTAssertEqual(EditorGeometry.normalizedAngle(180), 180)
    XCTAssertEqual(EditorGeometry.normalizedAngle(-180), 180)
    XCTAssertEqual(EditorGeometry.normalizedAngle(540), 180)
    XCTAssertEqual(EditorGeometry.normalizedAngle(-181), 179)
    XCTAssertEqual(EditorGeometry.normalizedAngle(181), -179)
  }

  func testRotationStepperCyclesAtBothBounds() {
    XCTAssertEqual(EditorGeometry.incrementStepperAngle(180, by: 1), -179)
    XCTAssertEqual(EditorGeometry.incrementStepperAngle(-179, by: -1), 180)
    XCTAssertEqual(EditorGeometry.incrementStepperAngle(0, by: 1), 1)
  }

  func testShiftSnapUsesFifteenDegreeIncrements() {
    XCTAssertEqual(EditorGeometry.snappedAngle(7), 0)
    XCTAssertEqual(EditorGeometry.snappedAngle(8), 15)
    XCTAssertEqual(EditorGeometry.snappedAngle(373), 15)
  }

  // MARK: Geometry and crop state

  func testAspectFitRectKeepsAspectAndCenters() {
    let rect = EditorGeometry.aspectFitRect(
      for: CGSize(width: 200, height: 100),
      in: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
    XCTAssertEqual(rect.width, 100, accuracy: 0.001)
    XCTAssertEqual(rect.height, 50, accuracy: 0.001)
    XCTAssertEqual(rect.midX, 50, accuracy: 0.001)
    XCTAssertEqual(rect.midY, 50, accuracy: 0.001)
  }

  func testCropSanitizationFloorsMinAndCeilsMaxWithinSource() {
    let crop = CropState(
      originalPixelBounds: CGRect(x: 0, y: 0, width: 100, height: 80),
      appliedCropRect: CGRect(x: 1.2, y: 2.7, width: 40.4, height: 30.1)
    )
    XCTAssertEqual(crop.appliedCropRect.minX, 1)
    XCTAssertEqual(crop.appliedCropRect.minY, 2)
    XCTAssertEqual(crop.appliedCropRect.maxX, 42, accuracy: 0.001)
    XCTAssertEqual(crop.appliedCropRect.maxY, 33, accuracy: 0.001)
  }

  // MARK: Style rendering

  func testStyleStoreRendersNominalValuesWithSessionScale() {
    let snapshot = styleStore.styleSnapshot(scale: 4)
    XCTAssertEqual(snapshot.stroke.nominalLineWidth, 4)
    XCTAssertEqual(snapshot.stroke.renderedLineWidthInPixels, 16)
    XCTAssertEqual(snapshot.text.nominalFontSize, 18)
    XCTAssertEqual(snapshot.text.renderedFontSizeInPixels, 72)
    XCTAssertEqual(snapshot.mosaic.nominalBrushWidth, 24)
    XCTAssertEqual(snapshot.mosaic.renderedBrushWidthInPixels, 96)
    XCTAssertEqual(snapshot.mosaic.renderedPixelScaleInPixels, 48)
  }

  func testStyleStoreKeepsOnlyNominalValuesAcrossSessions() {
    let snapshotLarge = styleStore.styleSnapshot(scale: 4)
    XCTAssertEqual(snapshotLarge.stroke.renderedLineWidthInPixels, 16)
    XCTAssertEqual(snapshotLarge.text.renderedFontSizeInPixels, 72)

    let snapshotSmall = styleStore.styleSnapshot(scale: 0.5)
    XCTAssertEqual(snapshotSmall.stroke.nominalLineWidth, 4)
    XCTAssertEqual(snapshotSmall.stroke.renderedLineWidthInPixels, 2)
    XCTAssertEqual(snapshotSmall.text.nominalFontSize, 18)
    XCTAssertEqual(snapshotSmall.text.renderedFontSizeInPixels, 9)
  }

  // MARK: Shape creation

  func testRectangleCommitExpandsToMinimumDisplayExtent() {
    var state = makeState(tool: .rectangle)
    state.pointerDown(at: CGPoint(x: 100, y: 100), metrics: metrics(), styleSnapshot: snapshot())
    state.pointerDragged(to: CGPoint(x: 105, y: 105))
    state.pointerUp(at: CGPoint(x: 105, y: 105))

    XCTAssertEqual(state.annotations.count, 1)
    guard case .rectangle(let annotation)? = state.annotations.first else {
      return XCTFail("Expected rectangle")
    }
    XCTAssertEqual(annotation.rect.width, 12, accuracy: 0.001)
    XCTAssertEqual(annotation.rect.height, 12, accuracy: 0.001)
    XCTAssertEqual(state.contentRevision, 1)
    XCTAssertEqual(state.undoStack.count, 1)
  }

  func testDrawingOutsideAppliedCropCreatesNothing() {
    var state = makeState(tool: .rectangle)
    state.pointerDown(at: CGPoint(x: -10, y: 10), metrics: metrics(), styleSnapshot: snapshot())
    state.pointerDragged(to: CGPoint(x: 20, y: 20))
    state.pointerUp(at: CGPoint(x: 20, y: 20))
    XCTAssertTrue(state.annotations.isEmpty)
  }

  func testHorizontalAndVerticalLinesCanBeCommitted() {
    var state = makeState(tool: .line)
    state.pointerDown(at: CGPoint(x: 100, y: 100), metrics: metrics(), styleSnapshot: snapshot())
    state.pointerDragged(to: CGPoint(x: 100, y: 112))
    state.pointerUp(at: CGPoint(x: 100, y: 112))
    XCTAssertEqual(state.annotations.count, 1)
  }

  func testLineShorterThanMinimumIsDiscarded() {
    var state = makeState(tool: .line)
    state.pointerDown(at: CGPoint(x: 100, y: 100), metrics: metrics(), styleSnapshot: snapshot())
    state.pointerDragged(to: CGPoint(x: 100, y: 105))
    state.pointerUp(at: CGPoint(x: 100, y: 105))
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertEqual(state.contentRevision, 0)
  }

  func testMosaicStrokeCreatesOneUndoRecord() {
    var state = makeState(tool: .mosaic)
    state.pointerDown(at: CGPoint(x: 10, y: 10), metrics: metrics(), styleSnapshot: snapshot())
    state.pointerDragged(to: CGPoint(x: 20, y: 20))
    state.pointerDragged(to: CGPoint(x: 30, y: 10))
    state.pointerUp(at: CGPoint(x: 30, y: 10))

    XCTAssertEqual(state.annotations.count, 1)
    guard case .mosaic(let annotation)? = state.annotations.first else {
      return XCTFail("Expected mosaic")
    }
    XCTAssertEqual(annotation.points.count, 3)
    XCTAssertEqual(state.contentRevision, 1)
    XCTAssertEqual(state.undoStack.count, 1)
  }

  // MARK: Selection and undo

  func testDeleteSelectionAndUndoRestoreAnnotation() {
    var state = makeState()
    let style = snapshot().stroke
    let id = UUID()
    let annotation = ShapeAnnotation(
      id: id,
      rect: CGRect(x: 10, y: 10, width: 50, height: 50),
      style: style
    )
    state.annotations = [.rectangle(annotation)]
    state.selectedObjectID = id

    state.deleteSelection()
    XCTAssertTrue(state.annotations.isEmpty)
    XCTAssertEqual(state.contentRevision, 1)

    state.undo()
    XCTAssertEqual(state.annotations.count, 1)
    XCTAssertEqual(state.annotations.first?.id, id)
    XCTAssertEqual(state.contentRevision, 2)
  }

  func testSelectedShapeStyleChangeProducesOneUndoPerAction() {
    var state = makeState()
    let id = UUID()
    let annotation = ShapeAnnotation(
      id: id,
      rect: CGRect(x: 10, y: 10, width: 50, height: 50),
      style: snapshot().stroke
    )
    state.annotations = [.rectangle(annotation)]
    state.selectedObjectID = id

    XCTAssertTrue(
      state.updateSelectedShapeStroke(
        nominalLineWidth: 8,
        color: .blue
      )
    )
    XCTAssertEqual(state.contentRevision, 1)
    XCTAssertEqual(state.undoStack.count, 1)

    XCTAssertTrue(state.updateSelectedShapeStroke(nominalLineWidth: 2))
    XCTAssertEqual(state.contentRevision, 2)
    XCTAssertEqual(state.undoStack.count, 2)

    guard case .rectangle(let updated)? = state.annotations.first else {
      return XCTFail("Expected rectangle")
    }
    XCTAssertEqual(updated.style.nominalLineWidth, 2)
    XCTAssertEqual(updated.style.renderedLineWidthInPixels, 4)
  }

  func testTextRotationGestureMergesIntoOneUndoRecord() {
    var state = makeState()
    let id = UUID()
    let annotation = TextAnnotation(
      id: id,
      text: "hello",
      frame: CGRect(x: 10, y: 10, width: 80, height: 24),
      style: EditorTextStyle(
        fontDesign: .system,
        nominalFontSize: 18,
        renderedFontSizeInPixels: 36,
        rotationDegrees: 0,
        color: .coral
      )
    )
    state.annotations = [.text(annotation)]
    state.selectedObjectID = id

    XCTAssertTrue(state.beginSelectedTextRotation())
    XCTAssertTrue(state.setSelectedTextRotation(22))
    XCTAssertTrue(state.setSelectedTextRotation(30, snapping: true))
    state.endSelectedTextRotation()

    XCTAssertEqual(state.contentRevision, 1)
    XCTAssertEqual(state.undoStack.count, 1)

    state.undo()
    guard case .text(let restored)? = state.annotations.first else {
      return XCTFail("Expected text")
    }
    XCTAssertEqual(restored.style.rotationDegrees, 0)
  }

  func testTextRotationCancellationRestoresOriginalAngleWithoutUndo() {
    var state = makeState()
    let id = UUID()
    let annotation = TextAnnotation(
      id: id,
      text: "hello",
      frame: CGRect(x: 10, y: 10, width: 80, height: 24),
      style: EditorTextStyle(
        fontDesign: .system,
        nominalFontSize: 18,
        renderedFontSizeInPixels: 36,
        rotationDegrees: 45,
        color: .coral
      )
    )
    state.annotations = [.text(annotation)]
    state.selectedObjectID = id

    state.beginSelectedTextRotation()
    state.setSelectedTextRotation(120)
    state.cancelSelectedTextRotation()
    guard case .text(let restored)? = state.annotations.first else {
      return XCTFail("Expected text")
    }
    XCTAssertEqual(restored.style.rotationDegrees, 45)
    XCTAssertTrue(state.undoStack.isEmpty)
    XCTAssertEqual(state.contentRevision, 0)
  }

  func testHitTestFindsRotatedTextInRotatedFrame() {
    let style = EditorTextStyle(
      fontDesign: .system,
      nominalFontSize: 18,
      renderedFontSizeInPixels: 36,
      rotationDegrees: 90,
      color: .coral
    )
    let annotation = TextAnnotation(
      id: UUID(),
      text: "hello",
      frame: CGRect(x: 100, y: 100, width: 100, height: 50),
      style: style
    )
    var state = makeState()
    state.annotations = [.text(annotation)]

    XCTAssertNotNil(state.hitTest(at: CGPoint(x: 150, y: 85), metrics: metrics()))
    XCTAssertNil(state.hitTest(at: CGPoint(x: 200, y: 100), metrics: metrics()))
  }

  // MARK: Crop reducer

  func testCropApplyChangesRevisionAndUndoRestoresAppliedRect() {
    var state = makeState()
    state.enterCropMode()
    state.resizeCropDraft(.bottomRight, to: CGPoint(x: 150, y: 150))
    state.applyCropDraft()

    XCTAssertEqual(state.crop.appliedCropRect.width, 150)
    XCTAssertEqual(state.contentRevision, 1)
    XCTAssertEqual(state.undoStack.count, 1)

    state.undo()
    XCTAssertEqual(state.crop.appliedCropRect.width, 200)
    XCTAssertEqual(state.crop.appliedCropRect.height, 200)
    XCTAssertEqual(state.contentRevision, 2)
  }

  func testCropNoChangeApplyDoesNotCreateUndoOrRevision() {
    var state = makeState()
    state.enterCropMode()
    state.applyCropDraft()
    XCTAssertNil(state.crop.draftCropRect)
    XCTAssertEqual(state.contentRevision, 0)
    XCTAssertTrue(state.undoStack.isEmpty)
  }

  func testFirstUndoWhileCropDraftActiveDiscardsDraftOnly() {
    var state = makeState()
    state.enterCropMode()
    state.resizeCropDraft(.bottomRight, to: CGPoint(x: 80, y: 80))
    XCTAssertNotNil(state.crop.draftCropRect)

    state.undo()
    XCTAssertNil(state.crop.draftCropRect)
    XCTAssertEqual(state.crop.appliedCropRect.width, 200)
    XCTAssertEqual(state.contentRevision, 0)
    XCTAssertTrue(state.undoStack.isEmpty)
  }

  func testCropDraftStaysWithinSourceAndMinimumSize() {
    var state = makeState(size: CGSize(width: 100, height: 100))
    state.enterCropMode()
    state.resizeCropDraft(.bottomRight, to: CGPoint(x: 10, y: 10))
    guard let draft = state.crop.draftCropRect else {
      return XCTFail("Expected crop draft")
    }
    XCTAssertGreaterThanOrEqual(draft.width, 32)
    XCTAssertGreaterThanOrEqual(draft.height, 32)

    state.resizeCropDraft(.bottomRight, to: CGPoint(x: 500, y: 500))
    XCTAssertEqual(state.crop.draftCropRect?.maxX, 100)
    XCTAssertEqual(state.crop.draftCropRect?.maxY, 100)
  }
}
