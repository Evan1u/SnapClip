import AppKit
import ImageIO
import SwiftUI

struct MenuBarContentView: View {
  @ObservedObject var model: AppModel
  @ObservedObject private var history: HistoryStore
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.openSettings) private var openSettings

  init(model: AppModel) {
    self.model = model
    _history = ObservedObject(wrappedValue: model.history)
  }

  var body: some View {
    ZStack {
      SnapClipDesign.background(for: colorScheme)
        .ignoresSafeArea()

      VStack(alignment: .leading, spacing: SnapClipDesign.spaceM) {
        header
        captureSection
        historySection
        footer
      }
      .padding(SnapClipDesign.spaceM)
    }
    .frame(width: 376)
    .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))
    .tint(SnapClipDesign.accent)
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
    ) { _ in
      model.shutdown()
    }
  }

  private var header: some View {
    HStack(spacing: SnapClipDesign.spaceSM) {
      SnapClipMark(size: 38)

      VStack(alignment: .leading, spacing: SnapClipDesign.spaceXS) {
        Text("SnapClip")
          .font(SnapClipDesign.brandTitle)

        HStack(spacing: 6) {
          Circle()
            .fill(model.statusIsError ? SnapClipDesign.accentStrong : SnapClipDesign.accent)
            .frame(width: 6, height: 6)

          Text(model.statusMessage)
            .font(SnapClipDesign.caption)
            .foregroundStyle(
              model.statusIsError
                ? SnapClipDesign.accentStrong
                : SnapClipDesign.textSecondary(for: colorScheme)
            )
            .lineLimit(2)
        }
      }

      Spacer(minLength: SnapClipDesign.spaceS)

      if model.isCapturing || model.recognizingItemID != nil || model.savingItemID != nil {
        ProgressView()
          .controlSize(.small)
          .tint(SnapClipDesign.accent)
          .accessibilityLabel(
            model.isCapturing
              ? "正在截图"
              : model.recognizingItemID != nil ? "正在识别文字" : "正在保存图片"
          )
      }
    }
    .accessibilityElement(children: .combine)
  }

  private var captureSection: some View {
    VStack(spacing: SnapClipDesign.spaceS) {
      CaptureButton(
        title: "截取选区或窗口",
        subtitle: "按空格可切换窗口",
        systemImage: "rectangle.dashed",
        shortcut: model.interactiveShortcut.displayString,
        disabled: model.isCapturing
      ) {
        model.capture(.interactive)
      }

      CaptureButton(
        title: "截取主显示器",
        subtitle: "复制整个主屏幕",
        systemImage: "display",
        shortcut: model.mainDisplayShortcut.displayString,
        disabled: model.isCapturing
      ) {
        model.capture(.mainDisplay)
      }

      if model.canOpenPermissionSettings {
        PermissionBanner(
          message: "需要允许屏幕录制，截图内容才会进入剪贴板。",
          primaryTitle: "打开设置",
          primaryAction: model.openScreenCaptureSettings
        )
      }

      if model.hotKeyPermissionRequired {
        PermissionBanner(
          message: "允许辅助功能后，SnapClip 才能接管系统截图键。",
          primaryTitle: "授予权限",
          primaryAction: model.requestHotKeyPermission,
          secondaryTitle: "重新检测",
          secondaryAction: model.retryHotKeys
        )
      }
    }
  }

  private var historySection: some View {
    VStack(alignment: .leading, spacing: SnapClipDesign.spaceS) {
      HStack(spacing: SnapClipDesign.spaceS) {
        SnapClipSectionLabel(title: "最近截图", systemImage: "photo.stack")

        Spacer()

        Text(String(format: "%02d / 03", history.items.count))
          .font(SnapClipDesign.metadata)
          .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))

        if !history.items.isEmpty {
          Button {
            model.clearHistory()
          } label: {
            Label("清空", systemImage: "trash")
              .labelStyle(.titleAndIcon)
          }
          .buttonStyle(.plain)
          .font(SnapClipDesign.caption.weight(.semibold))
          .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
          .accessibilityLabel("清空截图历史")
        }
      }

      if history.items.isEmpty {
        EmptyHistoryView()
      } else {
        ForEach(Array(history.items.enumerated()), id: \.element.id) { index, item in
          HistoryItemView(item: item, position: index + 1, model: model)
        }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: SnapClipDesign.spaceS) {
      Button {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      } label: {
        Label("设置…", systemImage: "gearshape")
          .frame(minHeight: 32)
          .contentShape(Rectangle())
      }

      Spacer()

      Button {
        NSApp.terminate(nil)
      } label: {
        Label("退出", systemImage: "power")
          .frame(minHeight: 32)
          .contentShape(Rectangle())
      }
    }
    .buttonStyle(.plain)
    .font(SnapClipDesign.caption.weight(.semibold))
    .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
    .padding(.top, SnapClipDesign.spaceXS)
    .overlay(alignment: .top) {
      Rectangle()
        .fill(SnapClipDesign.divider(for: colorScheme))
        .frame(height: 1)
    }
  }
}

private struct CaptureButton: View {
  @State private var isHovered = false

  let title: String
  let subtitle: String
  let systemImage: String
  let shortcut: String
  let disabled: Bool
  let action: () -> Void

  private var showsHoverState: Bool {
    isHovered && !disabled
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: SnapClipDesign.spaceSM) {
        Image(systemName: systemImage)
          .font(.system(size: 17, weight: .semibold))
          .symbolRenderingMode(.hierarchical)
          .frame(width: 22)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(SnapClipDesign.heading)
          Text(subtitle)
            .font(SnapClipDesign.caption)
            .opacity(0.7)
        }

        Spacer(minLength: SnapClipDesign.spaceS)

        Text(shortcut)
          .font(SnapClipDesign.metadata)
          .padding(.horizontal, SnapClipDesign.spaceS)
          .padding(.vertical, 6)
          .background(
            showsHoverState
              ? SnapClipDesign.porcelain.opacity(0.2)
              : SnapClipDesign.graphite.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
          )
      }
      .padding(.horizontal, SnapClipDesign.spaceSM)
      .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(SnapClipCaptureButtonStyle(isHovered: showsHoverState))
    .disabled(disabled)
    .opacity(disabled ? 0.55 : 1)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
    .accessibilityLabel("\(title)，快捷键 \(shortcut)")
  }
}

private struct PermissionBanner: View {
  @Environment(\.colorScheme) private var colorScheme

  let message: String
  let primaryTitle: String
  let primaryAction: () -> Void
  var secondaryTitle: String?
  var secondaryAction: (() -> Void)?

  var body: some View {
    HStack(alignment: .top, spacing: SnapClipDesign.spaceS) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(SnapClipDesign.accent)
        .symbolRenderingMode(.hierarchical)

      VStack(alignment: .leading, spacing: 6) {
        Text(message)
          .font(SnapClipDesign.caption)
          .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))

        HStack(spacing: SnapClipDesign.spaceSM) {
          Button(primaryTitle, action: primaryAction)
          if let secondaryTitle, let secondaryAction {
            Button(secondaryTitle, action: secondaryAction)
          }
        }
        .buttonStyle(.link)
        .font(SnapClipDesign.caption.weight(.semibold))
      }

      Spacer(minLength: 0)
    }
    .padding(SnapClipDesign.spaceSM)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      SnapClipDesign.accentSoft(for: colorScheme),
      in: RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
        .stroke(SnapClipDesign.accent.opacity(0.36), lineWidth: 1)
    }
  }
}

private struct EmptyHistoryView: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(spacing: SnapClipDesign.spaceS) {
      ZStack {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .strokeBorder(
            SnapClipDesign.divider(for: colorScheme),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
          )
          .frame(width: 48, height: 34)
          .rotationEffect(.degrees(-5))

        Image(systemName: "viewfinder")
          .font(.system(size: 22, weight: .medium))
          .foregroundStyle(SnapClipDesign.accent)
      }

      Text("等待第一张截图")
        .font(SnapClipDesign.heading)

      Text("截图会自动复制，并在当前会话保留最近三张。")
        .font(SnapClipDesign.caption)
        .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: 116)
    .snapClipSurface()
    .accessibilityElement(children: .combine)
  }
}

private struct HistoryItemView: View {
  @State private var isHovered = false

  let item: ScreenshotItem
  let position: Int
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: SnapClipDesign.spaceSM) {
      Button {
        model.copyImage(item)
      } label: {
        HistoryThumbnail(item: item)
          .overlay(alignment: .bottomTrailing) {
            Image(systemName: "doc.on.doc")
              .font(.system(size: 9, weight: .bold))
              .foregroundStyle(SnapClipDesign.porcelain)
              .padding(5)
              .background(SnapClipDesign.graphiteStrong.opacity(0.78), in: Circle())
              .padding(5)
          }
      }
      .buttonStyle(.plain)
      .accessibilityLabel("复制 \(timeText) 的截图")

      VStack(alignment: .center, spacing: 6) {
        HStack(spacing: SnapClipDesign.spaceS) {
          Text(String(format: "截图 %02d", position))
            .font(SnapClipDesign.metadata)
            .foregroundStyle(SnapClipDesign.accent)

          Text(timeText)
            .font(SnapClipDesign.caption)
            .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
        }

        HStack(spacing: SnapClipDesign.spaceXS) {
          Button {
            model.openPreview(item)
          } label: {
            Label("打开", systemImage: "arrow.up.forward.app")
          }
          .buttonStyle(SnapClipCompactButtonStyle())

          Button {
            model.copyRecognizedText(item)
          } label: {
            Label(ocrButtonTitle, systemImage: "text.viewfinder")
          }
          .buttonStyle(SnapClipCompactButtonStyle())
          .disabled(
            item.ocrState == .recognizing
              || (model.recognizingItemID != nil && item.recognizedText == nil)
          )

          Button {
            model.saveToDesktop(item)
          } label: {
            Label("保存", systemImage: "square.and.arrow.down")
          }
          .buttonStyle(SnapClipCompactButtonStyle())
          .disabled(model.savingItemID != nil)
          .help("保存到桌面")
          .accessibilityLabel("保存截图到桌面")
        }

        if case .failed(let message) = item.ocrState {
          Text(message)
            .font(SnapClipDesign.caption)
            .foregroundStyle(SnapClipDesign.accentStrong)
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
    }
    .padding(SnapClipDesign.spaceS)
    .snapClipSurface(isHovered: isHovered)
    .onHover { hovering in
      withAnimation(.easeOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
  }

  private var timeText: String {
    item.capturedAt.formatted(date: .omitted, time: .standard)
  }

  private var ocrButtonTitle: String {
    switch item.ocrState {
    case .recognizing:
      return "识别中…"
    case .completed:
      return "再次复制"
    case .idle, .failed:
      return "复制文字"
    }
  }
}

private struct HistoryThumbnail: View {
  let item: ScreenshotItem
  @State private var image: NSImage?
  @State private var didDecode = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image)
          .resizable()
          .scaledToFill()
      } else if didDecode {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(SnapClipDesign.accentStrong)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .frame(width: 112, height: 70)
    .background(SnapClipDesign.background(for: colorScheme))
    .clipShape(RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
        .stroke(SnapClipDesign.materialEdge(for: colorScheme), lineWidth: 1)
    }
    .task(id: item.id) {
      image = ThumbnailDecoder.image(from: item.pngData, maximumPixelSize: 224)
      didDecode = true
    }
  }
}

private enum ThumbnailDecoder {
  static func image(from pngData: Data, maximumPixelSize: Int) -> NSImage? {
    guard
      let source = CGImageSourceCreateWithData(pngData as CFData, nil),
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
      )
    else {
      return nil
    }

    return NSImage(cgImage: thumbnail, size: .zero)
  }
}
