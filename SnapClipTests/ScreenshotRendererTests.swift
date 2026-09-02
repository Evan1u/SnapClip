import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import SnapClip

final class ScreenshotRendererTests: XCTestCase {
  func testFullImageRenderKeepsPixelDimensionsAndSolidColor() async throws {
    let source = try makePNG(width: 3, height: 3, color: .init(red: 0.2, green: 0.6, blue: 0.8))

    let output = try await ScreenshotRenderer().render(
      sourcePNG: source,
      cropRect: CGRect(x: 0, y: 0, width: 3, height: 3),
      annotations: []
    )

    let bitmap = try makeBitmap(output)
    XCTAssertEqual(bitmap.pixelsWide, 3)
    XCTAssertEqual(bitmap.pixelsHigh, 3)
    let color = bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)
    XCTAssertEqual(color?.redComponent ?? 0, 0.2, accuracy: 0.1)
    XCTAssertEqual(color?.greenComponent ?? 0, 0.6, accuracy: 0.1)
    XCTAssertEqual(color?.blueComponent ?? 0, 0.8, accuracy: 0.1)
  }

  func testCroppedRenderUsesCropPixelDimensions() async throws {
    let source = try makePNG(width: 4, height: 4, color: .init(red: 1, green: 1, blue: 1))

    let output = try await ScreenshotRenderer().render(
      sourcePNG: source,
      cropRect: CGRect(x: 1, y: 1, width: 2, height: 2),
      annotations: []
    )

    let bitmap = try makeBitmap(output)
    XCTAssertEqual(bitmap.pixelsWide, 2)
    XCTAssertEqual(bitmap.pixelsHigh, 2)
  }

  func testRenderDrawsShapeLineArrowAndTextWithoutCrashing() async throws {
    let source = try makePNG(width: 40, height: 30, color: .init(red: 0.9, green: 0.9, blue: 0.9))
    let stroke = EditorStrokeStyle(
      nominalLineWidth: 2,
      renderedLineWidthInPixels: 2,
      color: .red
    )
    let textStyle = EditorTextStyle(
      fontDesign: .system,
      nominalFontSize: 12,
      renderedFontSizeInPixels: 12,
      rotationDegrees: 30,
      color: .graphite
    )
    let annotations: [EditorAnnotation] = [
      .rectangle(
        ShapeAnnotation(
          id: UUID(),
          rect: CGRect(x: 2, y: 2, width: 12, height: 12),
          style: stroke
        )
      ),
      .ellipse(
        ShapeAnnotation(
          id: UUID(),
          rect: CGRect(x: 18, y: 2, width: 10, height: 12),
          style: stroke
        )
      ),
      .line(
        LineAnnotation(
          id: UUID(),
          start: CGPoint(x: 2, y: 20),
          end: CGPoint(x: 15, y: 25),
          style: stroke
        )
      ),
      .arrow(
        LineAnnotation(
          id: UUID(),
          start: CGPoint(x: 20, y: 22),
          end: CGPoint(x: 36, y: 8),
          style: stroke
        )
      ),
      .text(
        TextAnnotation(
          id: UUID(),
          text: "中文 OCR",
          frame: CGRect(x: 2, y: 2, width: 24, height: 20),
          style: textStyle
        )
      ),
    ]

    let output = try await ScreenshotRenderer().render(
      sourcePNG: source,
      cropRect: CGRect(x: 0, y: 0, width: 40, height: 30),
      annotations: annotations
    )

    _ = try makeBitmap(output)
  }

  // MARK: Helpers

  private struct PixelColor {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
  }

  private func makePNG(width: Int, height: Int, color: PixelColor) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw ScreenshotRendererError.invalidImage
    }
    context.setFillColor(
      CGColor(
        srgbRed: color.red,
        green: color.green,
        blue: color.blue,
        alpha: 1
      )
    )
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
      throw ScreenshotRendererError.invalidImage
    }

    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw ScreenshotRendererError.invalidImage
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ScreenshotRendererError.invalidImage
    }
    return data as Data
  }

  private func makeBitmap(_ data: Data) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(data: data) else {
      throw ScreenshotRendererError.invalidImage
    }
    return bitmap
  }
}
