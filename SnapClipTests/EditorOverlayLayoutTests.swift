import CoreGraphics
import XCTest

@testable import SnapClip

final class EditorOverlayLayoutTests: XCTestCase {
  func testToolbarPrefersBelowSelection() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let selection = CGRect(x: 100, y: 400, width: 300, height: 200)
    let toolbar = EditorOverlayLayout.toolbarFrame(
      relativeTo: selection,
      screenBounds: screen,
      toolbarSize: CGSize(width: 600, height: 56)
    )
    XCTAssertEqual(toolbar.maxY, selection.minY - 12)
  }

  func testToolbarMovesAboveWhenSelectionIsNearBottom() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let selection = CGRect(x: 100, y: 30, width: 300, height: 200)
    let toolbar = EditorOverlayLayout.toolbarFrame(
      relativeTo: selection,
      screenBounds: screen,
      toolbarSize: CGSize(width: 600, height: 56)
    )
    XCTAssertEqual(toolbar.minY, selection.maxY + 12)
  }

  func testToolbarStaysInsideScreenForSmallScreens() {
    let screen = CGRect(x: 0, y: 0, width: 300, height: 300)
    let selection = screen.insetBy(dx: 20, dy: 20)
    let toolbar = EditorOverlayLayout.toolbarFrame(
      relativeTo: selection,
      screenBounds: screen,
      toolbarSize: CGSize(width: 700, height: 56)
    )
    XCTAssertTrue(screen.contains(toolbar))
    XCTAssertLessThanOrEqual(toolbar.width, screen.width - 24)
  }

  func testStatusStaysVisible() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let toolbar = CGRect(x: 200, y: 100, width: 600, height: 56)
    let status = EditorOverlayLayout.statusFrame(
      relativeTo: toolbar,
      screenBounds: screen,
      statusSize: CGSize(width: 200, height: 20)
    )
    XCTAssertTrue(screen.contains(status))
  }
}
