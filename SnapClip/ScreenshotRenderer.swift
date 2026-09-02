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

    // Flip the bitmap context so model coordinates are top-left / y-down,
    // matching the original source pixel coordinate system.
    context.translateBy(x: 0, y: CGFloat(outputHeight))
    context.scaleBy(x: 1, y: -1)
    context.translateBy(x: -cropRect.minX, y: -cropRect.minY)

    let previousGraphicsContext = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    defer {
      NSGraphicsContext.current = previousGraphicsContext
    }

    let sourceRect = CGRect(
      x: 0,
      y: 0,
      width: CGFloat(sourceImage.width),
      height: CGFloat(sourceImage.height)
    )
    context.draw(sourceImage, in: sourceRect)

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
      path.move(to: first)
      for point in annotation.points.dropFirst() {
        path.addLine(to: point)
      }
      context.addPath(path)
      context.setLineWidth(annotation.style.renderedBrushWidthInPixels)
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.replacePathWithStrokedPath()
      context.clip()
      context.draw(pixelated, in: sourceRect)
      context.restoreGState()
    }

    for annotation in annotations {
      switch annotation {
      case .rectangle(let value):
        drawShapeRect(value.rect, style: value.style, context: context, kind: .rectangle)
      case .ellipse(let value):
        drawShapeRect(value.rect, style: value.style, context: context, kind: .ellipse)
      case .line(let value):
        drawLine(value, context: context, arrow: false)
      case .arrow(let value):
        drawLine(value, context: context, arrow: true)
      case .text(let value):
        drawText(value, context: context)
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
    kind: ShapeKind
  ) {
    context.saveGState()
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
    _ annotation: LineAnnotation,
    context: CGContext,
    arrow: Bool
  ) {
    context.saveGState()
    context.setStrokeColor(cgColor(annotation.style.color))
    context.setLineWidth(annotation.style.renderedLineWidthInPixels)
    context.setLineCap(.round)
    context.beginPath()
    context.move(to: annotation.start)
    context.addLine(to: annotation.end)
    context.strokePath()

    if arrow {
      let length = EditorGeometry.distance(annotation.start, annotation.end)
      if length > 0 {
        let angle = atan2(
          annotation.end.y - annotation.start.y,
          annotation.end.x - annotation.start.x
        )
        let headLength = max(annotation.style.renderedLineWidthInPixels * 3.2, 10)
        let wing = CGFloat.pi * 0.22
        let base = CGPoint(
          x: annotation.end.x - headLength * cos(angle),
          y: annotation.end.y - headLength * sin(angle)
        )
        context.beginPath()
        context.move(to: annotation.end)
        context.addLine(
          to: CGPoint(
            x: base.x + headLength * cos(angle + .pi - wing),
            y: base.y + headLength * sin(angle + .pi - wing)
          )
        )
        context.addLine(
          to: CGPoint(
            x: base.x + headLength * cos(angle + .pi + wing),
            y: base.y + headLength * sin(angle + .pi + wing)
          )
        )
        context.closePath()
        context.setFillColor(cgColor(annotation.style.color))
        context.fillPath()
      }
    }
    context.restoreGState()
  }

  // MARK: Text

  private static func drawText(_ annotation: TextAnnotation, context: CGContext) {
    let attributes = EditorTextLayout.attributes(for: annotation.style)
    let attributed = NSAttributedString(string: annotation.text, attributes: attributes)

    context.saveGState()
    let center = CGPoint(x: annotation.frame.midX, y: annotation.frame.midY)
    let radians = annotation.style.rotationDegrees * Double.pi / 180
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: CGFloat(radians))
    context.translateBy(x: -center.x, y: -center.y)

    attributed.draw(
      with: annotation.frame,
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
