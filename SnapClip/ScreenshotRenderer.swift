import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotRendererError: LocalizedError, Equatable {
  case invalidImage

  var errorDescription: String? {
    "无法读取或生成截图 PNG。"
  }
}

protocol ScreenshotRendering: Sendable {
  func render(
    sourcePNG: Data,
    cropRect: CGRect,
    annotations: [EditorAnnotation]
  ) async throws -> Data
}

struct ScreenshotRenderer: ScreenshotRendering {
  func render(
    sourcePNG: Data,
    cropRect: CGRect,
    annotations: [EditorAnnotation]
  ) async throws -> Data {
    try await Task.detached(priority: .userInitiated) {
      try Self.renderSync(
        sourcePNG: sourcePNG,
        cropRect: cropRect,
        annotations: annotations
      )
    }.value
  }

  static func renderSync(
    sourcePNG: Data,
    cropRect: CGRect,
    annotations: [EditorAnnotation]
  ) throws -> Data {
    guard let sourceImage = Self.decodeSourceImage(sourcePNG) else {
      throw ScreenshotRendererError.invalidImage
    }
    guard cropRect.width > 0, cropRect.height > 0 else {
      throw ScreenshotRendererError.invalidImage
    }

    let outputWidth = Int(cropRect.width.rounded())
    let outputHeight = Int(cropRect.height.rounded())
    guard outputWidth > 0, outputHeight > 0 else {
      throw ScreenshotRendererError.invalidImage
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
      ?? CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
      data: nil,
      width: outputWidth,
      height: outputHeight,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      throw ScreenshotRendererError.invalidImage
    }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let previousGraphicsContext = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    defer {
      NSGraphicsContext.current = previousGraphicsContext
    }

    let sourceSize = CGSize(width: sourceImage.width, height: sourceImage.height)
    let sourceRect = CGRect(origin: .zero, size: sourceSize)
    let cropImageRect = CGRect(
      x: cropRect.minX,
      y: cropRect.minY,
      width: cropRect.width,
      height: cropRect.height
    )
    guard let croppedSource = sourceImage.cropping(to: cropImageRect) else {
      throw ScreenshotRendererError.invalidImage
    }
    context.draw(
      croppedSource,
      in: CGRect(x: 0, y: 0, width: CGFloat(outputWidth), height: CGFloat(outputHeight))
    )
    let outputRect = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(outputWidth),
      height: CGFloat(outputHeight)
    )

    // Quartz context origin is bottom-left. Map top-left model coordinates to CG
    // coordinates by y' = cropHeight - y - cropRect.minY.
    func modelPoint(_ point: CGPoint) -> CGPoint {
      CGPoint(
        x: point.x - cropRect.minX,
        y: CGFloat(outputHeight) - (point.y - cropRect.minY)
      )
    }
    func modelRect(_ rect: CGRect) -> CGRect {
      CGRect(
        x: rect.minX - cropRect.minX,
        y: CGFloat(outputHeight) - (rect.maxY - cropRect.minY),
        width: rect.width,
        height: rect.height
      )
    }

    var pixelatedCache: [CGFloat: CGImage] = [:]
    for case .mosaic(let annotation) in annotations {
      let pixelScale = max(1, annotation.style.renderedPixelScaleInPixels)
      let pixelated: CGImage
      if let cached = pixelatedCache[pixelScale] {
        pixelated = cached
      } else {
        guard let created = Self.pixelated(sourceImage, scale: pixelScale) else {
          continue
        }
        pixelated = created
        pixelatedCache[pixelScale] = created
      }

      context.saveGState()
      let path = CGMutablePath()
      guard let first = annotation.points.first else {
        context.restoreGState()
        continue
      }
      path.move(to: modelPoint(first))
      for point in annotation.points.dropFirst() {
        path.addLine(to: modelPoint(point))
      }
      context.addPath(path)
      context.setLineWidth(annotation.style.renderedBrushWidthInPixels)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.replacePathWithStrokedPath()
      context.clip()
      let croppedPixelated = pixelated.cropping(to: cropImageRect) ?? pixelated
      context.draw(croppedPixelated, in: outputRect)
      context.restoreGState()
    }

    for annotation in annotations {
      switch annotation {
      case .rectangle(let value):
        drawShapeRect(
          modelRect(value.rect),
          style: value.style,
          context: context,
          kind: .rectangle,
          rotationDegrees: value.rotationDegrees
        )
      case .ellipse(let value):
        drawShapeRect(
          modelRect(value.rect),
          style: value.style,
          context: context,
          kind: .ellipse,
          rotationDegrees: value.rotationDegrees
        )
      case .line(let value):
        drawLine(
          start: modelPoint(value.start),
          end: modelPoint(value.end),
          style: value.style,
          context: context,
          arrow: false
        )
      case .arrow(let value):
        drawLine(
          start: modelPoint(value.start),
          end: modelPoint(value.end),
          style: value.style,
          context: context,
          arrow: true
        )
      case .text(let value):
        drawText(
          annotation: value,
          context: context,
          mappedFrame: modelRect(value.frame)
        )
      case .mosaic:
        break
      }
    }

    guard let outputImage = context.makeImage() else {
      throw ScreenshotRendererError.invalidImage
    }
    return try Self.encodePNG(outputImage)
  }

  // MARK: Decoding and encoding

  private static func decodeSourceImage(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
      as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else {
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(width, height),
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func pixelated(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let input = CIImage(cgImage: image)
    guard let filter = CIFilter(name: "CIPixellate") else {
      return nil
    }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(Double(scale), forKey: kCIInputScaleKey)
    guard let output = filter.outputImage else { return nil }
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    return context.createCGImage(output, from: output.extent)
  }

  private static func encodePNG(_ image: CGImage) throws -> Data {
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

  // MARK: Shapes and lines

  private enum ShapeKind {
    case rectangle
    case ellipse
  }

  private static func drawShapeRect(
    _ rect: CGRect,
    style: EditorStrokeStyle,
    context: CGContext,
    kind: ShapeKind,
    rotationDegrees: Double
  ) {
    context.saveGState()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: CGFloat(-rotationDegrees * Double.pi / 180))
    context.translateBy(x: -center.x, y: -center.y)
    context.setStrokeColor(cgColor(style.color))
    context.setLineWidth(style.renderedLineWidthInPixels)
    switch kind {
    case .rectangle:
      context.stroke(rect)
    case .ellipse:
      context.strokeEllipse(in: rect)
    }
    context.restoreGState()
  }

  private static func drawLine(
    start: CGPoint,
    end: CGPoint,
    style: EditorStrokeStyle,
    context: CGContext,
    arrow: Bool
  ) {
    context.saveGState()
    context.setStrokeColor(cgColor(style.color))
    context.setLineWidth(style.renderedLineWidthInPixels)
    context.setLineCap(arrow ? .butt : .round)
    context.beginPath()
    context.move(to: start)
    context.addLine(to: end)
    context.strokePath()

    if arrow {
      let length = hypot(end.x - start.x, end.y - start.y)
      if length > 0 {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(style.renderedLineWidthInPixels * 7, 20)
        let base = CGPoint(
          x: end.x - headLength * cos(angle),
          y: end.y - headLength * sin(angle)
        )
        let perpendicular = CGPoint(x: -sin(angle), y: cos(angle))
        let halfBase = max(
          style.renderedLineWidthInPixels * 1.1,
          headLength * 0.22
        )
        let leftBase = CGPoint(
          x: base.x + perpendicular.x * halfBase,
          y: base.y + perpendicular.y * halfBase
        )
        let rightBase = CGPoint(
          x: base.x - perpendicular.x * halfBase,
          y: base.y - perpendicular.y * halfBase
        )

        context.beginPath()
        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()

        context.beginPath()
        context.move(to: end)
        context.addLine(to: leftBase)
        context.addLine(to: rightBase)
        context.closePath()
        context.setFillColor(cgColor(style.color))
        context.fillPath()
      }
    }
    context.restoreGState()
  }

  // MARK: Text

  private static func drawText(
    annotation: TextAnnotation,
    context: CGContext,
    mappedFrame: CGRect
  ) {
    let attributes = EditorTextLayout.attributes(for: annotation.style)
    let attributed = NSAttributedString(string: annotation.text, attributes: attributes)

    context.saveGState()
    let center = CGPoint(x: mappedFrame.midX, y: mappedFrame.midY)
    let radians = annotation.style.rotationDegrees * Double.pi / 180
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: CGFloat(-radians))
    context.translateBy(x: -center.x, y: -center.y)

    attributed.draw(
      with: mappedFrame,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    context.restoreGState()
  }

  static func cgColor(_ color: RGBAColor) -> CGColor {
    CGColor(
      srgbRed: color.red,
      green: color.green,
      blue: color.blue,
      alpha: color.alpha
    )
  }
}

enum EditorTextLayout {
  static func font(for design: EditorFontDesign, size: CGFloat) -> NSFont {
    switch design {
    case .system:
      return .systemFont(ofSize: size)
    case .serif:
      return NSFont(name: "NewYork-Regular", size: size)
        ?? NSFont(name: "Times-Roman", size: size)
        ?? .systemFont(ofSize: size)
    case .rounded:
      return .systemFont(ofSize: size)
    case .monospaced:
      return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
  }

  static func attributes(for style: EditorTextStyle) -> [NSAttributedString.Key: Any] {
    let font = font(for: style.fontDesign, size: style.renderedFontSizeInPixels)
    let color = NSColor(
      srgbRed: style.color.red,
      green: style.color.green,
      blue: style.color.blue,
      alpha: style.color.alpha
    )
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    return [
      .font: font,
      .foregroundColor: color,
      .paragraphStyle: paragraph,
    ]
  }

  static func measuredSize(
    text: String,
    style: EditorTextStyle,
    width: CGFloat
  ) -> CGSize {
    let attributed = NSAttributedString(
      string: text,
      attributes: attributes(for: style)
    )
    let bounds = attributed.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
  }
}
