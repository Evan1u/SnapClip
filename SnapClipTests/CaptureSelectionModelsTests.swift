import CoreGraphics
import XCTest

@testable import SnapClip

final class CaptureSelectionModelsTests: XCTestCase {
  func testNormalizedRectFlipsDragDirection() {
    let rect = CaptureSelectionMath.normalizedRect(
      start: CGPoint(x: 40, y: 60),
      end: CGPoint(x: 10, y: 20)
    )
    XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 30, height: 40))
  }

  func testValidSelectionRejectsTooSmall() {
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
    let rect = CaptureSelectionMath.validSelectionRect(
      start: .zero,
      end: CGPoint(x: 5, y: 5),
      bounds: bounds
    )
    XCTAssertNil(rect)
  }

  func testValidSelectionClampsToBounds() {
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let rect = CaptureSelectionMath.validSelectionRect(
      start: CGPoint(x: -20, y: -20),
      end: CGPoint(x: 30, y: 30),
      bounds: bounds
    )
    XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 30, height: 30))
  }

  func testClickThreshold() {
    let click = CaptureDragState(
      startPoint: .zero,
      currentPoint: CGPoint(x: 4, y: 4)
    )
    XCTAssertTrue(click.isClick)

    let drag = CaptureDragState(
      startPoint: .zero,
      currentPoint: CGPoint(x: 7, y: 7)
    )
    XCTAssertFalse(drag.isClick)
  }
}
