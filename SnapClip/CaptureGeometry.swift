import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Immutable image values

/// A single full-resolution bitmap plus the point-per-pixel scale that maps it
/// back to screen points. No AppKit object is stored here.
struct CaptureImage: Sendable {
  let cgImage: CGImage
  let pointScale: CGFloat

  var sizeInPoints: CGSize {
    CGSize(
      width: CGFloat(cgImage.width) / pointScale,
      height: CGFloat(cgImage.height) / pointScale
    )
  }

  init(cgImage: CGImage, pointScale: CGFloat) throws {
    guard pointScale.isFinite, pointScale > 0 else {
      throw CaptureGeometryError.invalidPointScale
    }
    self.cgImage = cgImage
    self.pointScale = pointScale
  }

  /// Encodes the current bitmap as a PNG payload using ImageIO. Pure and safe
  /// to call off the main actor.
  func pngData() throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else {
      throw CaptureGeometryError.pngEncodingFailed
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CaptureGeometryError.pngEncodingFailed
    }
    return data as Data
  }
}

/// One frozen display: topology captured on the main actor plus its full
/// resolution snapshot from ScreenCaptureKit.
struct FrozenDisplaySnapshot: Sendable {
  let displayID: CGDirectDisplayID
  /// AppKit global screen points, origin at bottom-left of the primary screen.
  let frameInAppKitPoints: CGRect
  let image: CaptureImage
}

struct CaptureWindowDescriptor: Sendable, Equatable {
  let windowID: CGWindowID
  /// AppKit global screen points, origin at bottom-left of the primary screen.
  let frameInAppKitPoints: CGRect
  let primaryDisplayID: CGDirectDisplayID
  let ownerPID: pid_t
}

// MARK: - Typed errors

enum CaptureGeometryError: LocalizedError, Equatable, Sendable {
  case invalidPointScale
  case invalidGeometry
  case invalidPixelDimensions
  case cropOutsideSource
  case pngEncodingFailed
  case topologyChanged
  case noDisplays
  case permissionDenied
  case contentEnumerationFailed
  case displayUnavailable(CGDirectDisplayID)
  case windowUnavailable(CGWindowID)
  case platformFailure(Int)

  var errorDescription: String? {
    switch self {
    case .invalidPointScale:
      return "无法读取有效的屏幕缩放比例。"
    case .invalidGeometry:
      return "显示器几何信息无效。"
    case .invalidPixelDimensions:
      return "无法计算有效像素尺寸。"
    case .cropOutsideSource:
      return "选区超出了可用截图范围。"
    case .pngEncodingFailed:
      return "无法生成截图 PNG。"
    case .topologyChanged:
      return "显示器设置已变化，请重试。"
    case .noDisplays:
      return "没有可用的显示器。"
    case .permissionDenied:
      return "需要屏幕录制权限才能截图。"
    case .contentEnumerationFailed:
      return "无法读取当前屏幕内容。"
    case .displayUnavailable:
      return "显示器当前不可用，请重试。"
    case .windowUnavailable:
      return "该窗口当前不可用，请重新选择。"
    case .platformFailure(let code):
      return "系统截图失败（状态码：\(code)）。"
    }
  }
}

// MARK: - Coordinate helpers

enum CaptureGeometry {
  static func validatedPixelSize(
    sizeInPoints: CGSize,
    pointScale: CGFloat
  ) throws -> (width: Int, height: Int) {
    guard
      sizeInPoints.width.isFinite,
      sizeInPoints.height.isFinite,
      pointScale.isFinite,
      sizeInPoints.width > 0,
      sizeInPoints.height > 0,
      pointScale > 0
    else {
      throw CaptureGeometryError.invalidGeometry
    }

    let width = (sizeInPoints.width * pointScale).rounded()
    let height = (sizeInPoints.height * pointScale).rounded()
    guard
      width.isFinite,
      height.isFinite,
      width >= 1,
      height >= 1,
      width <= CGFloat(Int.max),
      height <= CGFloat(Int.max)
    else {
      throw CaptureGeometryError.invalidPixelDimensions
    }
    return (Int(width), Int(height))
  }

  /// Converts a display-local rectangle (bottom-left origin, points) into the
  /// pixel rectangle accepted by `CGImage.cropping`. Pixel row 0 is the top of
  /// the captured screen.
  static func pixelCropRect(
    forDisplayRect rect: CGRect,
    in image: CaptureImage
  ) throws -> CGRect {
    guard
      rect.minX.isFinite,
      rect.minY.isFinite,
      rect.width.isFinite,
      rect.height.isFinite,
      rect.width > 0,
      rect.height > 0
    else {
      throw CaptureGeometryError.invalidGeometry
    }

    let scale = image.pointScale
    let heightInPoints = image.sizeInPoints.height
    let fractional = CGRect(
      x: rect.minX * scale,
      y: (heightInPoints - rect.maxY) * scale,
      width: rect.width * scale,
      height: rect.height * scale
    )
    guard fractional.minX.isFinite, fractional.minY.isFinite else {
      throw CaptureGeometryError.invalidGeometry
    }

    let pixelBounds = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(image.cgImage.width),
      height: CGFloat(image.cgImage.height)
    )
    let integral = fractional.integral
    let cropped = integral.intersection(pixelBounds)
    guard
      !cropped.isNull,
      !cropped.isEmpty,
      cropped.width >= 1,
      cropped.height >= 1
    else {
      throw CaptureGeometryError.cropOutsideSource
    }
    return cropped
  }

  static func croppedCGImage(
    _ image: CaptureImage,
    displayRect: CGRect
  ) throws -> CGImage {
    let pixelRect = try pixelCropRect(forDisplayRect: displayRect, in: image)
    guard let cropped = image.cgImage.cropping(to: pixelRect) else {
      throw CaptureGeometryError.cropOutsideSource
    }
    return cropped
  }

  // MARK: Quartz / AppKit conversion

  /// Quartz window bounds use the primary screen's top-left as the origin.
  /// AppKit screen coordinates use the primary screen's bottom-left.
  static func appKitRect(
    fromQuartzRect quartzRect: CGRect,
    mainDisplayHeight: CGFloat
  ) -> CGRect {
    CGRect(
      x: quartzRect.minX,
      y: mainDisplayHeight - quartzRect.maxY,
      width: quartzRect.width,
      height: quartzRect.height
    )
  }

  static func quartzPoint(
    fromAppKitPoint point: CGPoint,
    mainDisplayHeight: CGFloat
  ) -> CGPoint {
    CGPoint(x: point.x, y: mainDisplayHeight - point.y)
  }

  /// Returns the portion of `globalRect` that lies inside `screenFrame`,
  /// expressed in that screen's local bottom-left coordinates.
  static func localRect(
    fromGlobalRect globalRect: CGRect,
    screenFrame: CGRect
  ) -> CGRect {
    let intersection = globalRect.intersection(screenFrame)
    guard !intersection.isNull else { return .zero }
    return CGRect(
      x: intersection.minX - screenFrame.minX,
      y: intersection.minY - screenFrame.minY,
      width: intersection.width,
      height: intersection.height
    )
  }

  /// Aligns a display-point rectangle to the captured image's pixel grid so
  /// the crop dimensions are exactly representable at the display's scale.
  static func displayRectAlignedToPixels(
    _ rect: CGRect,
    pointScale: CGFloat
  ) -> CGRect {
    guard pointScale.isFinite, pointScale > 0 else { return rect }
    let scaled = CGRect(
      x: rect.minX * pointScale,
      y: rect.minY * pointScale,
      width: rect.width * pointScale,
      height: rect.height * pointScale
    )
    let integral = scaled.integral
    return CGRect(
      x: integral.minX / pointScale,
      y: integral.minY / pointScale,
      width: integral.width / pointScale,
      height: integral.height / pointScale
    )
  }
}
