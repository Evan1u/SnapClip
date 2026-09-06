import AppKit
import SwiftUI

private struct QRCodeActionCard: View {
  @Environment(\.colorScheme) private var colorScheme

  let payloadKind: QRCodePayloadKind
  let onCopy: () -> Void
  let onOpen: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: SnapClipDesign.spaceSM) {
      HStack(spacing: SnapClipDesign.spaceS) {
        Image(systemName: iconName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(SnapClipDesign.accent)
          .frame(width: 24, height: 24)
          .background(
            SnapClipDesign.accentSoft(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(kindTitle)
            .font(SnapClipDesign.caption.weight(.semibold))
            .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
          if let displayHost {
            Text(displayHost)
              .font(.system(size: 14, weight: .semibold, design: .monospaced))
              .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))
              .lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }

      Text(previewText)
        .font(SnapClipDesign.body)
        .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))
        .lineLimit(isLink ? 2 : 4)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: SnapClipDesign.spaceS) {
        Spacer(minLength: 0)
        Button(action: onCopy) {
          Label(copyTitle, systemImage: "doc.on.doc")
            .frame(minWidth: 92, minHeight: 32)
        }
        .buttonStyle(QRCodeSecondaryButtonStyle())
        .keyboardShortcut("c", modifiers: .command)

        if let onOpen {
          Button(action: onOpen) {
            Label("打开链接", systemImage: "arrow.up.right.square")
              .frame(minWidth: 100, minHeight: 32)
          }
          .buttonStyle(QRCodePrimaryButtonStyle())
          .keyboardShortcut(.return, modifiers: [])
        }
      }
    }
    .padding(SnapClipDesign.spaceM)
    .frame(width: 320)
    .background(SnapClipDesign.surface(for: colorScheme))
    .tint(SnapClipDesign.accent)
    .accessibilityElement(children: .contain)
  }

  private var isLink: Bool {
    if case .link = payloadKind { return true }
    return false
  }

  private var kindTitle: String { isLink ? "二维码链接" : "二维码文本" }
  private var iconName: String { isLink ? "link" : "text.alignleft" }
  private var copyTitle: String { isLink ? "复制链接" : "复制内容" }

  private var displayHost: String? {
    guard case .link(_, let host, _) = payloadKind else { return nil }
    return host
  }

  private var previewText: String {
    switch payloadKind {
    case .link(_, _, let copyValue):
      return copyValue
    case .text(let rawPayload):
      return rawPayload
    }
  }
}

private struct QRCodePrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SnapClipDesign.caption.weight(.semibold))
      .foregroundStyle(SnapClipDesign.porcelain)
      .padding(.horizontal, SnapClipDesign.spaceS)
      .padding(.vertical, 6)
      .background(
        configuration.isPressed ? SnapClipDesign.accentStrong : SnapClipDesign.accent,
        in: RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
      )
  }
}

private struct QRCodeSecondaryButtonStyle: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(SnapClipDesign.caption.weight(.semibold))
      .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))
      .padding(.horizontal, SnapClipDesign.spaceS)
      .padding(.vertical, 6)
      .background(
        configuration.isPressed
          ? SnapClipDesign.accentSoft(for: colorScheme)
          : SnapClipDesign.porcelain(for: colorScheme),
        in: RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
          .stroke(SnapClipDesign.materialEdge(for: colorScheme), lineWidth: 1)
      }
  }
}

@MainActor
final class QRCodeActionPopoverController: NSObject, NSPopoverDelegate {
  var onCopy: ((QRCodePayloadKind) -> Void)?
  var onOpen: ((QRCodePayloadKind) -> Void)?
  var onDismiss: (() -> Void)?

  private let popover = NSPopover()
  private var isReplacingContent = false

  override init() {
    super.init()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
  }

  var isShown: Bool { popover.isShown }

  func present(
    result: QRCodeResult,
    relativeTo anchorRect: CGRect,
    of positioningView: NSView
  ) {
    let kind = QRCodePayloadClassifier.classify(result.rawPayload)
    isReplacingContent = popover.isShown
    if popover.isShown {
      popover.close()
    }
    let card = QRCodeActionCard(
      payloadKind: kind,
      onCopy: { [weak self] in self?.onCopy?(kind) },
      onOpen: {
        guard case .link = kind else { return nil }
        return { [weak self] in self?.onOpen?(kind) }
      }()
    )
    let hosting = NSHostingController(rootView: card)
    popover.contentViewController = hosting
    popover.contentSize = NSSize(width: 320, height: 188)
    popover.show(relativeTo: anchorRect, of: positioningView, preferredEdge: .maxY)
    isReplacingContent = false
  }

  func dismiss() {
    guard popover.isShown else { return }
    popover.close()
  }

  func popoverDidClose(_ notification: Notification) {
    guard !isReplacingContent else { return }
    onDismiss?()
  }
}
