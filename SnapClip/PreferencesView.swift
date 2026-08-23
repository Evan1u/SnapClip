import SwiftUI

struct PreferencesView: View {
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    ZStack {
      SnapClipDesign.background(for: colorScheme)
        .ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: SnapClipDesign.spaceM) {
          settingsHeader
          shortcutSettings
          behaviorSettings
          defaultsSettings
          privacySettings
        }
        .padding(SnapClipDesign.spaceL)
      }
    }
    .frame(width: 600, height: 680)
    .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))
    .tint(SnapClipDesign.accent)
    .onAppear {
      model.refreshLoginItemStatus()
    }
  }

  private var settingsHeader: some View {
    HStack(spacing: SnapClipDesign.spaceM) {
      SnapClipMark(size: 48)

      VStack(alignment: .leading, spacing: SnapClipDesign.spaceXS) {
        Text("SnapClip")
          .font(SnapClipDesign.screenTitle)
        Text("快捷、安静，只保留需要的内容。")
          .font(SnapClipDesign.body)
          .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
      }

      Spacer()

      HStack(spacing: 6) {
        Circle()
          .fill(model.statusIsError ? Color.red : SnapClipDesign.accent)
          .frame(width: 6, height: 6)
        Text(model.statusIsError ? "需要处理" : "运行正常")
          .font(SnapClipDesign.metadata)
      }
      .foregroundStyle(
        model.statusIsError ? Color.red : SnapClipDesign.textSecondary(for: colorScheme)
      )
      .padding(.horizontal, SnapClipDesign.spaceSM)
      .frame(minHeight: 30)
      .background(
        SnapClipDesign.surface(for: colorScheme),
        in: Capsule()
      )
      .overlay {
        Capsule()
          .stroke(SnapClipDesign.divider(for: colorScheme), lineWidth: 1)
      }
    }
  }

  private var shortcutSettings: some View {
    SettingsGroup(title: "快捷键", systemImage: "keyboard") {
      SettingsRow(
        title: "选区或窗口",
        subtitle: "进入系统选区模式，按空格可切换窗口截图。"
      ) {
        HotKeyRecorder(
          shortcut: model.interactiveShortcut,
          onChange: { shortcut in
            model.updateShortcut(shortcut, for: .interactiveCapture)
          },
          onRecordingChanged: model.setHotKeyRecording
        )
        .frame(width: 150, height: 28)
      }

      settingsDivider

      SettingsRow(
        title: "主显示器全屏",
        subtitle: "截取当前主显示器并直接复制。"
      ) {
        HotKeyRecorder(
          shortcut: model.mainDisplayShortcut,
          onChange: { shortcut in
            model.updateShortcut(shortcut, for: .mainDisplayCapture)
          },
          onRecordingChanged: model.setHotKeyRecording
        )
        .frame(width: 150, height: 28)
      }

      settingsDivider

      Label(
        "单击快捷键框后按下新组合；按 Esc 取消。组合中必须包含修饰键。",
        systemImage: "info.circle"
      )
      .font(SnapClipDesign.caption)
      .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
      .padding(.horizontal, SnapClipDesign.spaceM)
      .padding(.vertical, SnapClipDesign.spaceSM)

      if model.hotKeyPermissionRequired {
        settingsDivider

        SettingsNotice(
          message: "使用 ⇧⌘3/4 需要辅助功能权限，SnapClip 才能接管按键并阻止系统重复截图。",
          actions: [
            ("请求权限", model.requestHotKeyPermission),
            ("打开系统设置", model.openAccessibilitySettings),
            ("重新检测", model.retryHotKeys),
          ]
        )
      }
    }
  }

  private var behaviorSettings: some View {
    SettingsGroup(title: "行为", systemImage: "switch.2") {
      ToggleRow(
        title: "播放截图音效",
        subtitle: "每次成功截图后播放系统截图音效。",
        isOn: Binding(
          get: { model.soundEnabled },
          set: { model.setSoundEnabled($0) }
        )
      )

      settingsDivider

      ToggleRow(
        title: "登录时启动",
        subtitle: "登录这台 Mac 后自动在菜单栏运行 SnapClip。",
        isOn: Binding(
          get: { model.launchAtLoginEnabled },
          set: { model.setLaunchAtLogin($0) }
        )
      )

      if model.loginItemRequiresApproval {
        settingsDivider

        SettingsNotice(
          message: "系统需要你批准 SnapClip 登录项，启用后才能自动启动。",
          actions: [("打开登录项设置", model.openLoginItemSettings)]
        )
      }
    }
  }

  private var defaultsSettings: some View {
    SettingsGroup(title: "默认设置", systemImage: "arrow.counterclockwise") {
      HStack(spacing: SnapClipDesign.spaceM) {
        VStack(alignment: .leading, spacing: SnapClipDesign.spaceXS) {
          Text("恢复快捷键与音效")
            .font(SnapClipDesign.heading)
          Text("不会修改登录启动状态或清空截图历史。")
            .font(SnapClipDesign.caption)
            .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
        }

        Spacer()

        Button {
          model.restoreDefaults()
        } label: {
          Label("恢复默认", systemImage: "arrow.counterclockwise")
            .font(SnapClipDesign.caption.weight(.semibold))
            .padding(.horizontal, SnapClipDesign.spaceSM)
            .frame(minHeight: 32)
        }
        .buttonStyle(SnapClipSecondaryButtonStyleForSettings())
      }
      .padding(SnapClipDesign.spaceM)

      settingsDivider

      HStack(alignment: .top, spacing: SnapClipDesign.spaceS) {
        Image(
          systemName: model.statusIsError
            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        )
        .foregroundStyle(model.statusIsError ? Color.red : SnapClipDesign.accent)
        .symbolRenderingMode(.hierarchical)

        Text(model.statusMessage)
          .font(SnapClipDesign.caption)
          .foregroundStyle(
            model.statusIsError
              ? Color.red : SnapClipDesign.textSecondary(for: colorScheme)
          )
          .textSelection(.enabled)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, SnapClipDesign.spaceM)
      .padding(.vertical, SnapClipDesign.spaceSM)
    }
  }

  private var privacySettings: some View {
    HStack(alignment: .top, spacing: SnapClipDesign.spaceSM) {
      Image(systemName: "checkmark.shield.fill")
        .font(.system(size: 19, weight: .semibold))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(SnapClipDesign.accent)
        .frame(width: 28)

      VStack(alignment: .leading, spacing: SnapClipDesign.spaceXS) {
        Text("仅在本机，且仅限当前会话")
          .font(SnapClipDesign.heading)
        Text("截图历史和 OCR 不离开这台 Mac；SnapClip 不访问网络，退出后自动清空历史。")
          .font(SnapClipDesign.caption)
          .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .padding(SnapClipDesign.spaceM)
    .background(
      SnapClipDesign.accentSoft(for: colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.72),
      in: RoundedRectangle(cornerRadius: SnapClipDesign.radiusM, style: .continuous)
    )
    .accessibilityElement(children: .combine)
  }

  private var settingsDivider: some View {
    Rectangle()
      .fill(SnapClipDesign.divider(for: colorScheme))
      .frame(height: 1)
      .padding(.leading, SnapClipDesign.spaceM)
  }
}

private struct SettingsGroup<Content: View>: View {
  let title: String
  let systemImage: String
  let content: Content

  init(
    title: String,
    systemImage: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: SnapClipDesign.spaceS) {
      SnapClipSectionLabel(title: title, systemImage: systemImage)
        .padding(.horizontal, SnapClipDesign.spaceXS)

      VStack(spacing: 0) {
        content
      }
      .snapClipSurface()
    }
  }
}

private struct SettingsRow<Trailing: View>: View {
  let title: String
  let subtitle: String
  let trailing: Trailing
  @Environment(\.colorScheme) private var colorScheme

  init(
    title: String,
    subtitle: String,
    @ViewBuilder trailing: () -> Trailing
  ) {
    self.title = title
    self.subtitle = subtitle
    self.trailing = trailing()
  }

  var body: some View {
    HStack(spacing: SnapClipDesign.spaceM) {
      VStack(alignment: .leading, spacing: SnapClipDesign.spaceXS) {
        Text(title)
          .font(SnapClipDesign.heading)
        Text(subtitle)
          .font(SnapClipDesign.caption)
          .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
      }

      Spacer(minLength: SnapClipDesign.spaceM)
      trailing
    }
    .padding(.horizontal, SnapClipDesign.spaceM)
    .frame(minHeight: 58)
  }
}

private struct ToggleRow: View {
  let title: String
  let subtitle: String
  @Binding var isOn: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: SnapClipDesign.spaceM) {
      VStack(alignment: .leading, spacing: SnapClipDesign.spaceXS) {
        Text(title)
          .font(SnapClipDesign.heading)
        Text(subtitle)
          .font(SnapClipDesign.caption)
          .foregroundStyle(SnapClipDesign.textSecondary(for: colorScheme))
      }

      Spacer(minLength: SnapClipDesign.spaceM)

      Toggle("", isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
    }
    .padding(.horizontal, SnapClipDesign.spaceM)
    .frame(minHeight: 58)
  }
}

private struct SettingsNotice: View {
  @Environment(\.colorScheme) private var colorScheme

  let message: String
  let actions: [(String, () -> Void)]

  var body: some View {
    HStack(alignment: .top, spacing: SnapClipDesign.spaceS) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .symbolRenderingMode(.hierarchical)

      VStack(alignment: .leading, spacing: SnapClipDesign.spaceS) {
        Text(message)
          .font(SnapClipDesign.caption)
          .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))

        HStack(spacing: SnapClipDesign.spaceM) {
          ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            Button(action.0, action: action.1)
          }
        }
        .buttonStyle(.link)
        .font(SnapClipDesign.caption.weight(.semibold))
      }

      Spacer(minLength: 0)
    }
    .padding(SnapClipDesign.spaceM)
    .background(Color.orange.opacity(colorScheme == .dark ? 0.1 : 0.06))
  }
}

private struct SnapClipSecondaryButtonStyleForSettings: ButtonStyle {
  @Environment(\.colorScheme) private var colorScheme

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(SnapClipDesign.textPrimary(for: colorScheme))
      .background(
        configuration.isPressed
          ? SnapClipDesign.accentSoft(for: colorScheme)
          : SnapClipDesign.background(for: colorScheme),
        in: RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: SnapClipDesign.radiusS, style: .continuous)
          .stroke(SnapClipDesign.divider(for: colorScheme), lineWidth: 1)
      }
  }
}
