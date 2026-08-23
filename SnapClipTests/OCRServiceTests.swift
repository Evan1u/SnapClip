import CoreGraphics
import XCTest

@testable import SnapClip

final class OCRServiceTests: XCTestCase {
  func testJoinLinesUsesTopToBottomThenLeftToRightOrder() throws {
    let lines = [
      OCRLine(text: "right", boundingBox: CGRect(x: 0.6, y: 0.8, width: 0.2, height: 0.1)),
      OCRLine(text: "bottom", boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)),
      OCRLine(text: "left", boundingBox: CGRect(x: 0.1, y: 0.79, width: 0.2, height: 0.1)),
    ]

    let result = try VisionOCRService.joinLines(lines)

    XCTAssertEqual(result, "left\nright\nbottom")
  }

  func testJoinLinesRejectsEmptyText() {
    XCTAssertThrowsError(try VisionOCRService.joinLines([])) { error in
      XCTAssertEqual(error as? OCRError, .noText)
    }
  }

  func testJoinLinesFormsRowsBeforeSortingHorizontally() throws {
    let lines = [
      OCRLine(text: "C", boundingBox: CGRect(x: 0.1, y: 0.80, width: 0.1, height: 0.10)),
      OCRLine(text: "B", boundingBox: CGRect(x: 0.6, y: 0.84, width: 0.1, height: 0.10)),
      OCRLine(text: "A", boundingBox: CGRect(x: 0.3, y: 0.89, width: 0.1, height: 0.10)),
    ]

    let result = try VisionOCRService.joinLines(lines)

    XCTAssertEqual(result, "A\nB\nC")
  }
}
