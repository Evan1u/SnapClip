import Foundation
import SwiftUI

enum SnapClipDesign {
  static let accent = Color(hex: "D56547")
  static let accentStrong = Color(hex: "B84F35")

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
    scheme == .dark ? Color(hex: "211F1D") : Color(hex: "F7F3EF")
  }

  static func surface(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(hex: "2D2A27") : Color(hex: "FFFDFB")
  }

  static func surfaceRaised(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(hex: "35302D") : Color(hex: "FFFFFF")
  }

  static func accentSoft(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(hex: "593326") : Color(hex: "F5DDD5")
  }

  static func textPrimary(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(hex: "F4EFEB") : Color(hex: "28231F")
  }

  static func textSecondary(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(hex: "B4AAA4") : Color(hex: "746B65")
  }

  static func divider(for scheme: ColorScheme) -> Color {
    scheme == .dark ? Color(hex: "443F3A") : Color(hex: "E3DAD3")
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
    Image(systemName: "camera.viewfinder")
      .font(.system(size: size * 0.45, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(SnapClipDesign.accent)
      .frame(width: size, height: size)
      .background(
        SnapClipDesign.accentSoft(for: colorScheme),
        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
      )
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
      .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
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
        isHovered ? Color.white : SnapClipDesign.textPrimary(for: colorScheme)
      )
      .background(
        backgroundColor(isPressed: configuration.isPressed),
        in: RoundedRectangle(cornerRadius: SnapClipDesign.radiusM, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: SnapClipDesign.radiusM, style: .continuous)
          .stroke(
            isHovered
              ? SnapClipDesign.accentStrong.opacity(0.55)
              : SnapClipDesign.divider(for: colorScheme),
            lineWidth: 1
          )
      }
      .shadow(
        color: isHovered
          ? SnapClipDesign.accent.opacity(configuration.isPressed ? 0.08 : 0.2)
          : Color.clear,
        radius: isHovered && !configuration.isPressed ? 7 : 2,
        y: isHovered && !configuration.isPressed ? 3 : 1
      )
      .scaleEffect(configuration.isPressed ? 0.99 : 1)
  }

  private func backgroundColor(isPressed: Bool) -> Color {
    if isHovered {
      return isPressed ? SnapClipDesign.accentStrong : SnapClipDesign.accent
    }
    return isPressed
      ? SnapClipDesign.accentSoft(for: colorScheme)
      : SnapClipDesign.surface(for: colorScheme)
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
          : SnapClipDesign.background(for: colorScheme),
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
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
              ? SnapClipDesign.accent.opacity(0.6)
              : SnapClipDesign.divider(for: colorScheme),
            lineWidth: isHovered ? 1.5 : 1
          )
      }
      .shadow(
        color: isHovered ? SnapClipDesign.accent.opacity(0.1) : Color.clear,
        radius: isHovered ? 5 : 0,
        y: isHovered ? 2 : 0
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
