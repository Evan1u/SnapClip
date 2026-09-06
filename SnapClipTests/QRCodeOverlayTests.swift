import CoreGraphics
import XCTest

@testable import SnapClip

final class QRCodeOverlayTests: XCTestCase {
  func testVisionTopLeftCoordinatesMapIntoNonZeroCropOrigin() {
    let result = QRCodeResult(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      rawPayload: "top",
      boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.2)
    )

    let rect = QRCodeOverlayLayout.modelRect(
      for: result,
      renderedPixelSize: CGSize(width: 400, height: 200),
      effectiveCropRect: CGRect(x: 50, y: 80, width: 400, height: 200)
    )

    XCTAssertEqual(rect.origin.x, 90, accuracy: 0.000_001)
    XCTAssertEqual(rect.origin.y, 100, accuracy: 0.000_001)
    XCTAssertEqual(rect.width, 80, accuracy: 0.000_001)
    XCTAssertEqual(rect.height, 40, accuracy: 0.000_001)
  }

  func testHitRectExpandsSmallCodeToMinimumTarget() {
    let visual = CGRect(x: 20, y: 30, width: 12, height: 10)

    let hit = QRCodeOverlayLayout.hitRect(for: visual)

    XCTAssertEqual(hit.size, CGSize(width: 44, height: 44))
    XCTAssertEqual(hit.midX, visual.midX)
    XCTAssertEqual(hit.midY, visual.midY)
  }

  func testOverlappingHitChoosesSmallestQRCode() {
    let large = QRCodeOverlayItem(
      result: QRCodeResult(rawPayload: "large", boundingBox: .zero),
      modelRect: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
    let small = QRCodeOverlayItem(
      result: QRCodeResult(rawPayload: "small", boundingBox: .zero),
      modelRect: CGRect(x: 40, y: 40, width: 20, height: 20)
    )
    let viewport = EditorCanvasViewport(
      modelRect: CGRect(x: 0, y: 0, width: 100, height: 100),
      displayRect: CGRect(x: 0, y: 0, width: 100, height: 100)
    )

    let hit = QRCodeOverlayLayout.hitItem(
      at: CGPoint(x: 50, y: 50),
      items: [large, small],
      viewport: viewport
    )

    XCTAssertEqual(hit?.result.rawPayload, "small")
  }

  func testViewportRecomputesQRCodeFrameAfterResize() {
    let result = QRCodeResult(
      rawPayload: "resize",
      boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    )
    let model = QRCodeOverlayLayout.modelRect(
      for: result,
      renderedPixelSize: CGSize(width: 200, height: 100),
      effectiveCropRect: CGRect(x: 20, y: 40, width: 200, height: 100)
    )
    let first = EditorCanvasViewport(
      modelRect: CGRect(x: 20, y: 40, width: 200, height: 100),
      displayRect: CGRect(x: 0, y: 0, width: 200, height: 100)
    )
    let resized = EditorCanvasViewport(
      modelRect: CGRect(x: 20, y: 40, width: 200, height: 100),
      displayRect: CGRect(x: 0, y: 0, width: 400, height: 200)
    )

    XCTAssertEqual(first.viewRect(fromModel: model), CGRect(x: 50, y: 25, width: 100, height: 50))
    XCTAssertEqual(resized.viewRect(fromModel: model), CGRect(x: 100, y: 50, width: 200, height: 100))
  }
}
