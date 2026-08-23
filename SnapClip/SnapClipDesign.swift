import AppKit
import Foundation
import SwiftUI

enum SnapClipDesign {
  // The complete UI palette comes from the scissors mark: coral pivot,
  // graphite blades, porcelain handles, and warm studio paper.
  static let accent = Color(hex: "E96548")
  static let accentStrong = Color(hex: "C84D36")
  static let graphite = Color(hex: "555452")
  static let graphiteStrong = Color(hex: "363635")
  static let graphiteHighlight = Color(hex: "6B6A67")
  static let porcelain = Color(hex: "E9E6DF")
  static let porcelainShadow = Color(hex: "C8C4BC")
  static let studioPaper = Color(hex: "F3F1ED")
  static let studioPaperRaised = Color(hex: "FCFBF8")

  static let appKitAccent = NSColor(srgbRed: 233 / 255, green: 101 / 255, blue: 72 / 255, alpha: 1)
  static let appKitGraphite = NSColor(srgbRed: 85 / 255, green: 84 / 255, blue: 82 / 255, alpha: 1)
  static let appKitGraphiteStrong = NSColor(
    srgbRed: 54 / 255, green: 54 / 255, blue: 53 / 255, alpha: 1)
  static let appKitGraphiteHighlight = NSColor(
    srgbRed: 107 / 255, green: 106 / 255, blue: 103 / 255, alpha: 1)
  static let appKitPorcelain = NSColor(
    srgbRed: 233 / 255, green: 230 / 255, blue: 223 / 255, alpha: 1)
  static let appKitPorcelainShadow = NSColor(
    srgbRed: 200 / 255, green: 196 / 255, blue: 188 / 255, alpha: 1)
  static let appKitStudioPaper = NSColor(
    srgbRed: 243 / 255, green: 241 / 255, blue: 237 / 255, alpha: 1)

  static let spaceXS: CGFloat = 4
  static let spaceS: CGFloat = 8
  static let spaceSM: CGFloat = 12
  static let spaceM: CGFloat = 16
  static let spaceL: CGFloat = 24
  static let spaceXL: CGFloat = 32

  static let radiusS: CGFloat = 8
  static let radiusM: CGFloat = 12
  static let radiusL: CGFloat = 16

  static let brandTitle = Font.system(size: 19, weight: .bold, design: .serif)
  static let screenTitle = Font.system(size: 22, weight: .bold, design: .serif)
  static let heading = Font.system(size: 13, weight: .semibold)
  static let body = Font.system(size: 12.5)
  static let caption = Font.system(size: 10.5)
  static let metadata = Font.system(size: 10, weight: .semibold, design: .monospaced)

  static func background(for scheme: ColorScheme) -> Color {
    scheme == .dark ? graphiteStrong : studioPaper
  }

  static func surface(for scheme: ColorScheme) -> Color {
    scheme == .dark ? graphite : studioPaperRaised
  }

  static func surfaceRaised(for scheme: ColorScheme) -> Color {
    scheme == .dark ? graphiteHighlight : studioPaperRaised
  }

  static func porcelain(for scheme: ColorScheme) -> Color {
    scheme == .dark ? graphite : porcelain
  }

  static func graphiteSurface(for scheme: ColorScheme) -> Color {
    scheme == .dark ? graphiteStrong : graphite
  }

  static func accentSoft(for scheme: ColorScheme) -> Color {
    scheme == .dark ? accent.opacity(0.22) : accent.opacity(0.16)
  }

  static func textPrimary(for scheme: ColorScheme) -> Color {
    scheme == .dark ? porcelain : graphiteStrong
  }

  static func textSecondary(for scheme: ColorScheme) -> Color {
    scheme == .dark ? porcelainShadow : graphite
  }

  static func divider(for scheme: ColorScheme) -> Color {
    scheme == .dark ? graphiteHighlight : porcelainShadow
  }

  static func materialEdge(for scheme: ColorScheme) -> Color {
    scheme == .dark ? porcelain.opacity(0.14) : porcelainShadow
  }
}

extension Color {
  init(hex: String) {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)

    let alpha: UInt64
    let red: UInt64
    let green: UInt64
    let blue: UInt64

    switch cleaned.count {
    case 3:
      (alpha, red, green, blue) = (
        255,
        (value >> 8) * 17,
        (value >> 4 & 0xF) * 17,
        (value & 0xF) * 17
      )
    case 8:
      (alpha, red, green, blue) = (
        value >> 24,
        value >> 16 & 0xFF,
        value >> 8 & 0xFF,
        value & 0xFF
      )
    default:
      (alpha, red, green, blue) = (
        255,
        value >> 16,
        value >> 8 & 0xFF,
        value & 0xFF
      )
    }

    self.init(
      .sRGB,
      red: Double(red) / 255,
      green: Double(green) / 255,
      blue: Double(blue) / 255,
      opacity: Double(alpha) / 255
    )
  }
}

struct SnapClipMark: View {
  @Environment(\.colorScheme) private var colorScheme

  var size: CGFloat = 36

  var body: some View {
    Image("BrandScissors")
      .resizable()
      .scaledToFill()
      .frame(width: size, height: size)
      .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
          .stroke(SnapClipDesign.materialEdge(for: colorScheme), lineWidth: 1)
      }
      .shadow(color: SnapClipDesign.graphiteStrong.opacity(0.16), radius: 4, y: 2)
      .accessibilityHidden(true)
  }
}

struct SnapClipSectionLabel: View {
  @Environment(\.colorScheme) private var colorScheme

  let title: String
  let systemImage: String

  var body: some View {
    Label(title.uppercased(), systemImage: systemImage)
      .font(SnapClipDesign.metadata)
      .tracking(0.7)
      .foregroundStyle(
        colorScheme == .dark
          ? SnapClipDesign.textSecondary(for: colorScheme)
          : SnapClipDesign.graphite
      )
  }
}

struct SnapClipKeycap: View {
  @Environment(\.colorScheme) private var colorScheme

  let text: String

  var body: some View {
    Text(text)
      .font(SnapClipDesign.metadata)
      .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))
      .padding(.horizontal, SnapClipDesign.spaceS)
      .padding(.vertical, 6)
      .background(
        SnapClipDesign.background(for: colorScheme),
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(SnapClipDesign.divider(for: colorScheme), lineWidth: 1)
      }
  }
}

struct SnapClipCaptureButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  let isHovered: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(
        isHovered ? SnapClipDesign.porcelain : SnapClipDesign.textPrimary(for: colorScheme)
      )
      .background(
        backgroundColor(isPressed: configuration.isPressed),
        in: RoundedRectangle(cornerRadius: SnapClipDesign.radiusM, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: SnapClipDesign.radiusM, style: .continuous)
          .stroke(
            isHovered
              ? SnapClipDesign.accent.opacity(0.82)
              : SnapClipDesign.materialEdge(for: colorScheme),
            lineWidth: 1
          )
      }
      .shadow(
        color: isHovered
          ? SnapClipDesign.graphiteStrong.opacity(configuration.isPressed ? 0.16 : 0.26)
          : SnapClipDesign.graphiteStrong.opacity(colorScheme == .dark ? 0.12 : 0.05),
        radius: isHovered && !configuration.isPressed ? 8 : 3,
        y: isHovered && !configuration.isPressed ? 4 : 1
      )
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isHovered {
      return isPressed
        ? SnapClipDesign.graphiteStrong
        : SnapClipDesign.graphiteSurface(for: colorScheme)
    }
    return isPressed
      ? SnapClipDesign.accentSoft(for: colorScheme)
      : SnapClipDesign.porcelain(for: colorScheme)
  }
}

struct SnapClipCompactButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SnapClipDesign.caption.weight(.semibold))
      .foregroundStyle(SnapClipDesign.accent)
      .padding(.horizontal, SnapClipDesign.spaceS)
      .frame(minHeight: 28)
      .background(
        configuration.isPressed
          ? SnapClipDesign.accentSoft(for: colorScheme)
          : SnapClipDesign.porcelain(for: colorScheme),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .stroke(SnapClipDesign.materialEdge(for: colorScheme), lineWidth: 0.75)
      }
  }
}

struct SnapClipSurfaceModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme

  let radius: CGFloat
  let isHovered: Bool

  func body(content: Content) -> some View {
    content
      .background(
        isHovered
          ? SnapClipDesign.surfaceRaised(for: colorScheme)
          : SnapClipDesign.surface(for: colorScheme),
        in: RoundedRectangle(cornerRadius: radius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(
            isHovered
              ? SnapClipDesign.graphite.opacity(colorScheme == .dark ? 0.95 : 0.68)
              : SnapClipDesign.materialEdge(for: colorScheme),
            lineWidth: isHovered ? 1.5 : 1
          )
      }
      .shadow(
        color: isHovered
          ? SnapClipDesign.graphiteStrong.opacity(0.16)
          : SnapClipDesign.graphiteStrong.opacity(0.035),
        radius: isHovered ? 6 : 2,
        y: isHovered ? 3 : 1
      )
  }
}

extension View {
  func snapClipSurface(
    radius: CGFloat = SnapClipDesign.radiusM,
    isHovered: Bool = false
  ) -> some View {
    modifier(SnapClipSurfaceModifier(radius: radius, isHovered: isHovered))
  }
}
