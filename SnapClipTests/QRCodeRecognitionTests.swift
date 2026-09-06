import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import SnapClip

final class QRCodeRecognitionTests: XCTestCase {
  func testVisionRecognizesQRCodePayload() async throws {
    let payload = "https://example.com/路径?q=SnapClip"
    let pngData = try makeQRCodePNG(payload: payload)

    let results = try await VisionQRCodeService().recognizeQRCodes(in: pngData)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results[0].rawPayload, payload)
    XCTAssertGreaterThan(results[0].boundingBox.width, 0)
    XCTAssertGreaterThan(results[0].boundingBox.height, 0)
  }

  func testVisionRejectsImageWithoutQRCode() async throws {
    let pngData = try makeSolidPNG(width: 128, height: 128)

    do {
      _ = try await VisionQRCodeService().recognizeQRCodes(in: pngData)
      XCTFail("Expected noQRCode")
    } catch {
      XCTAssertEqual(error as? QRCodeRecognitionError, .noQRCode)
    }
  }

  func testVisionRejectsInvalidImage() async {
    do {
      _ = try await VisionQRCodeService().recognizeQRCodes(in: Data())
      XCTFail("Expected invalidImage")
    } catch {
      XCTAssertEqual(error as? QRCodeRecognitionError, .invalidImage)
    }
  }

  func testClassifierAllowsOnlySafeWebLinks() {
    guard case .link(let url, let host, let copyValue) =
      QRCodePayloadClassifier.classify("  HTTPS://example.com:8443/a?q=1  ")
    else {
      return XCTFail("Expected web link")
    }
    XCTAssertEqual(url.scheme, "https")
    XCTAssertEqual(host, "example.com:8443")
    XCTAssertEqual(copyValue, "HTTPS://example.com:8443/a?q=1")

    for payload in [
      "javascript:alert(1)",
      "file:///tmp/private",
      "snapclip://open/item",
      "WIFI:T:WPA;S:Office;P:secret;;",
      "https://user:password@example.com/private",
      "plain text",
    ] {
      guard case .text(let copied) = QRCodePayloadClassifier.classify(payload) else {
        return XCTFail("Expected text for \(payload)")
      }
      XCTAssertEqual(copied, payload)
    }
  }

  private func makeQRCodePNG(payload: String) throws -> Data {
    guard
      let filter = CIFilter(name: "CIQRCodeGenerator"),
      let input = payload.data(using: .utf8)
    else {
      throw QRCodeRecognitionError.invalidImage
    }
    filter.setValue(input, forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage?.transformed(
      by: CGAffineTransform(scaleX: 12, y: 12)
    ) else {
      throw QRCodeRecognitionError.invalidImage
    }
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    guard let image = context.createCGImage(output, from: output.extent) else {
      throw QRCodeRecognitionError.invalidImage
    }
    return try encodePNG(image)
  }

  private func makeSolidPNG(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw QRCodeRecognitionError.invalidImage
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else {
      throw QRCodeRecognitionError.invalidImage
    }
    return try encodePNG(image)
  }

  private func encodePNG(_ image: CGImage) throws -> Data {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      data,
      UTType.png.identifier as CFString,
      1,
      nil
    ) else {
      throw QRCodeRecognitionError.invalidImage
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw QRCodeRecognitionError.invalidImage
    }
    return data as Data
  }
}
