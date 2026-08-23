# SnapClip

SnapClip 是一款面向 Apple Silicon、macOS 14+ 的原生菜单栏截图工具。它会把截图直接写入系统剪贴板，并在当前运行周期内保留最近三张截图；OCR 使用 Apple Vision 在本地执行。

本项目以 MIT License 开源。

## 首版功能

- `⇧⌘4`：由 SnapClip 接管，启动选区截图；按空格切换窗口模式。
- `⇧⌘3`：由 SnapClip 接管，截取主显示器。
- 最近三张内存历史，退出即清空。
- 单击历史缩略图重新复制图片。
- 应用内预览支持直接拖选图片文字，并通过右键或 `⌘C` 复制所选片段。
- 历史卡片提供本地中英文 OCR，可一键复制整张图片的文字。
- 每张历史截图可直接保存到桌面，采用 `SnapClip yyyy-MM-dd HH.mm.ss.png` 命名，重名时自动追加序号且不覆盖文件。
- 可自定义全局快捷键、截图音效和登录启动。
- 菜单与设置采用暖色“暗房工作台”视觉，支持浅色/深色模式；视觉规范见 [docs/brand-spec.md](docs/brand-spec.md)。
- 零第三方依赖、无网络请求。

完整需求见 [docs/PRD.md](docs/PRD.md)。

## 开发环境

1. 安装与当前 macOS 兼容的完整 Xcode。
2. 在终端确认：

   ```sh
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   ```

3. 用 Xcode 打开 `SnapClip.xcodeproj`。
4. 在 SnapClip Target 的 Signing & Capabilities 中选择你自己的 Personal Team。仓库保留维护者本机的 Team 配置以维持稳定权限身份，其他开发者必须替换为自己的 Team；Bundle ID 默认为 `com.local.SnapClip`。不要改回 Sign to Run Locally/ad-hoc：macOS 的屏幕录制授权会校验代码签名身份，ad-hoc 构建在重编译或切换 Debug/Release 后可能被当作另一个应用；`SMAppService` 同样需要有效签名。
5. 选择 `My Mac`，运行 SnapClip。
6. 首次启动时授予“辅助功能”权限，以便 SnapClip 在运行期间接管并阻止系统的 `⇧⌘3/4` 动作；首次截图时再授予“屏幕与系统音频录制”权限。拒绝后可从菜单或设置中的入口打开系统设置。若此前运行过 ad-hoc 版本，请先执行 `tccutil reset ScreenCapture com.local.SnapClip`，再启动当前稳定签名版本并重新授权一次。
7. 自用安装时执行 Product > Archive，或完成 Release 构建后把 `SnapClip.app` 复制到 `/Applications`；首版不制作安装器。

## 命令行验证

`Package.swift` 只用于无完整 Xcode 时验证应用源码能够编译，不会生成可正式使用的 `.app`，也不运行 Xcode 的 XCTest：

```sh
swift build
```

安装完整 Xcode 后执行正式验证：

```sh
xcodebuild -project SnapClip.xcodeproj \
  -scheme SnapClip \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 1 \
  test
```

首次使用新开发证书时建议保留 `-jobs 1`，避免多个 XCTest 组件同时请求钥匙串私钥访问；后续可按需移除。

## 架构说明

- 正式构建入口：Xcode 工程。
- UI：SwiftUI + AppKit。
- 截图：系统 `/usr/sbin/screencapture`。
- 图片内文字选择：VisionKit。
- 整图 OCR：Vision。
- 快捷键：Core Graphics 事件拦截接管 `⇧⌘3/4`；Carbon `RegisterEventHotKey` 处理用户自定义组合。
- 登录启动：`SMAppService.mainApp`。

首版调用系统截图进程，因此不启用 App Sandbox，也不面向 Mac App Store。如果未来上架商店，需要将截图层迁移到 ScreenCaptureKit 和自定义选区界面。

## License

[MIT](LICENSE) © 2026 Evan Lu
