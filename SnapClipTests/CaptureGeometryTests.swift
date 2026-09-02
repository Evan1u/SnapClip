import CoreGraphics
import XCTest

@testable import SnapClip

final class CaptureGeometryTests: XCTestCase {
  private func makeImage(width: Int, height: Int, scale: CGFloat) throws -> CaptureImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw CaptureGeometryError.invalidPixelDimensions
    }
    guard let cgImage = context.makeImage() else {
      throw CaptureGeometryError.invalidPixelDimensions
    }
    return try CaptureImage(cgImage: cgImage, pointScale: scale)
  }

  func testTopRegionMapsToTopPixelRowsAtTwoX() throws {
    let image = try makeImage(width: 400, height: 200, scale: 2)
    // Display local points: 200x100. Top half has minY = 50.
    let rect = CGRect(x: 10, y: 50, width: 100, height: 50)
    let pixels = try CaptureGeometry.pixelCropRect(
      forDisplayRect: rect,
      in: image
    )
    XCTAssertEqual(pixels, CGRect(x: 20, y: 0, width: 200, height: 100))
  }

  func testBottomRegionMapsToBottomPixelRows() throws {
    let image = try makeImage(width: 400, height: 200, scale: 2)
    let rect = CGRect(x: 0, y: 0, width: 200, height: 50)
    let pixels = try CaptureGeometry.pixelCropRect(
      forDisplayRect: rect,
      in: image
    )
    XCTAssertEqual(pixels, CGRect(x: 0, y: 100, width: 400, height: 100))
  }

  func testNonIntegralRectIsExpandedAndClampedToImage() throws {
    let image = try makeImage(width: 90, height: 90, scale: 3)
    let rect = CGRect(x: 28.3, y: 1.2, width: 2.4, height: 10.2)
    let pixels = try CaptureGeometry.pixelCropRect(
      forDisplayRect: rect,
      in: image
    )
    // Image point size is 30x30.
    XCTAssertEqual(pixels, CGRect(x: 84, y: 55, width: 6, height: 32))
  }

  func testOutOfBoundsRectThrows() throws {
    let image = try makeImage(width: 100, height: 100, scale: 1)
    XCTAssertThrowsError(
      try CaptureGeometry.pixelCropRect(
        forDisplayRect: CGRect(x: 200, y: 0, width: 20, height: 20),
        in: image
      )
    )
  }

  func testQuartzToAppKitConversion() {
    let quartz = CGRect(x: 10, y: 100, width: 300, height: 200)
    let appKit = CaptureGeometry.appKitRect(
      fromQuartzRect: quartz,
      mainDisplayHeight: 900
    )
    XCTAssertEqual(appKit, CGRect(x: 10, y: 600, width: 300, height: 200))

    let point = CaptureGeometry.quartzPoint(
      fromAppKitPoint: CGPoint(x: 10, y: 600),
      mainDisplayHeight: 900
    )
    XCTAssertEqual(point, CGPoint(x: 10, y: 300))
  }

  func testLocalRectIntersectsScreen() {
    let screen = CGRect(x: 100, y: 200, width: 500, height: 400)
    let global = CGRect(x: 300, y: 100, width: 400, height: 300)
    let local = CaptureGeometry.localRect(
      fromGlobalRect: global,
      screenFrame: screen
    )
    XCTAssertEqual(local, CGRect(x: 200, y: 0, width: 300, height: 200))
  }
}
