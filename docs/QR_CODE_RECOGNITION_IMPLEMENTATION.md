# SnapClip 二维码识别功能实施计划

> 状态：已实现并验收
> 计划日期：2026-09-06
> 实施日期：2026-09-06
> 目标平台：Apple Silicon，macOS 14+
> 范围原则：只增加二维码识别，不扩展为扫码器或链接管理器；识别过程完全离线

## 1. 目标行为

在截图后的二级编辑工具栏中，紧挨现有 **OCR** 按钮增加独立的 **二维码识别** 按钮。用户可以对当前正在编辑的截图执行识别：

1. 用户点击工具栏中 OCR 旁边的“二维码识别”，图标使用 `qrcode.viewfinder`。
2. SnapClip 先合成当前可见结果，包括已应用的裁剪和现有标注。
3. 使用 Apple Vision 在本机只识别 QR Code。
4. 识别到二维码后，在当前编辑画面的对应位置显示珊瑚色可点击边框；多个二维码可分别点击。
5. 用户点击其中一个二维码，只选中该二维码并在附近显示预览操作卡片，不立即打开或执行内容。
6. 操作卡片根据内容显示：
   - 合法的 `http` 或 `https` 链接：显示内容类型、醒目的目标域名、截断后的完整链接，以及“复制链接”“打开链接”两个按钮；
   - 其他内容：显示内容类型、文本预览和“复制内容”按钮，不提供执行按钮。
7. 用户明确点击“打开链接”后，SnapClip 才结束当前编辑会话，并使用系统默认浏览器打开链接。
8. 用户点击“复制链接”或“复制内容”后写入系统剪贴板，保留编辑会话和全部二维码识别框。
9. 未识别到可解码二维码时，提示“未识别到二维码”，不修改剪贴板。
10. 用户点击其他二维码时切换卡片内容；卡片打开时，点击框外、按 Esc 或右键只关闭卡片并消费本次事件。卡片关闭后再次按 Esc 或右键，才退出二维码工具。
11. 用户切换其他工具或取消编辑时，立即移除卡片与识别框，并取消尚未完成的识别任务。
12. 识别无结果或失败时，显示对应状态并自动回到“选择”工具；用户再次点击“二维码识别”即可重试。

该入口同时适用于：

- 新截图的原地编辑 overlay；
- 从历史卡片进入的独立编辑窗口。

这里的“当前屏幕”定义为**当前编辑画面**，即用户截图选区或历史图片当前裁剪后、包含现有标注的合成内容，不扫描选区之外的整个桌面。这样二维码框与用户看到的图片一一对应，也不会额外读取其他屏幕内容。

历史卡片本身不新增第四个按钮。用户需要先点“编辑”，再使用工具栏中的“二维码识别”，避免挤压现有 376 pt 菜单栏布局。

## 2. 明确不做

- 点击二维码识别框本身不打开链接；只有用户在预览卡片中明确点击“打开链接”才执行跳转。
- 不执行自定义 URL Scheme，也不根据内容类型执行 Wi-Fi、联系人、支付或登录操作。
- SnapClip 的识别过程不上传图片、不发起网络请求；只有用户确认“打开链接”后，才把 URL 交给系统默认浏览器，后续网络访问由浏览器完成。
- 不持续扫描摄像头或屏幕。
- 不识别条形码、Data Matrix、Aztec、PDF417 或 Micro QR；Vision 请求只启用 `.qr`。
- 不把二维码内容写入截图历史，不增加缓存或持久化字段。
- 不改变截图、编辑确认、图片剪贴板和现有 OCR 的事务语义。
- 不新增设置项、快捷键、独立窗口或菜单栏顶级入口。
- 不扫描当前截图选区之外的其他屏幕区域。

## 3. 技术方案

### 3.1 识别服务

在 `SnapClip/SystemServices.swift` 增加一个小型可注入服务：

```swift
struct QRCodeResult: Identifiable, Equatable, Sendable {
  let id: UUID
  let rawPayload: String
  let boundingBox: CGRect
}

protocol QRCodeRecognizing: Sendable {
  func recognizeQRCodes(in pngData: Data) async throws -> [QRCodeResult]
}

struct VisionQRCodeService: QRCodeRecognizing {
  func recognizeQRCodes(in pngData: Data) async throws -> [QRCodeResult]
}
```

实现约束：

- 在 `Task.detached(priority: .userInitiated)` 中运行 Vision，避免阻塞 Main Actor。
- 使用 `VNDetectBarcodesRequest`，并设置 `symbologies = [.qr]`。
- 通过 `VNImageRequestHandler(data:options:)` 读取 PNG，让 Vision 处理图片方向。
- 保留 `payloadStringValue` 原文为 `rawPayload`；只用其去除首尾空白后的值判断是否为空。
- 使用 `VNBarcodeObservation.boundingBox` 排序：`midY` 降序，再按 `minX` 升序。
- 每次识别完成排序后为结果生成 UUID；同一次结果集展示期间 ID 和顺序保持不变，重新识别时全部重建。
- 错误类型固定为 `QRCodeRecognitionError.invalidImage`、`.noQRCode` 和 `.visionFailed`，对应文案分别为“无法读取当前画面”“未识别到二维码”和“二维码识别失败，请重试”。

二维码内容只分为“链接”和“文本”两类，不识别更细的业务类型。保留的 `rawPayload` 用于普通文本复制；另取去除首尾空白的 `classificationValue` 做链接分类。内容只有在同时满足以下条件时才被归类为可打开链接：

- `URLComponents` 可解析；
- scheme 忽略大小写后为 `http` 或 `https`；
- host 非空。
- 不含控制字符，也不包含 URL user/password 凭据。

链接卡片显示系统解析后的 `host`，有端口时显示 `host:port`；“复制链接”和“打开链接”都使用同一个 `classificationValue`。其他所有内容（包括 `file:`、`javascript:`、应用自定义 scheme、Wi-Fi 配置、邮箱与纯文本）归类为“文本”，“复制内容”使用完整 `rawPayload`，不执行。

### 3.2 编辑会话接线

在 `EditorSessionCore` 中增加：

- `qrCodeService: any QRCodeRecognizing`，默认使用 `VisionQRCodeService()`；
- `qrTask: Task<Void, Never>?`；
- `isQRCodeWorking` 状态；
- `qrRequestGeneration: UInt64`；
- 当前识别结果 `[QRCodeResult]`；
- 当前选中的 `QRCodeResult.ID`；
- `recognizeQRCodes()`、`selectQRCode(at:)`、`copySelectedQRCode()` 与 `openSelectedQRCodeURL()` 动作。

动作流程固定为：

```text
提交未完成文字输入
  -> 应用当前裁剪草稿
  -> snapshot 当前编辑状态
  -> ScreenshotRenderer 合成当前画面
  -> VisionQRCodeService 识别 QR
  -> 将 Vision boundingBox 映射回当前画布
  -> 显示每个二维码的可点击边框
  -> 用户点击某个边框
  -> 显示内容预览与操作卡片
  -> 用户明确选择复制，或打开 http/https 链接
```

这与现有“复制全部文字”的输入保持一致，因此二维码识别看到的是用户此刻将要确认的画面，而不是最初截图。

会话生命周期要求：

- 每个 `EditorActiveSession` 增加内部 `sessionID: UUID`；每次开始二维码识别时递增 `qrRequestGeneration`，并捕获 `(sessionID, generation)` 作为请求 token。
- 开始识别时立即关闭旧卡片并清空旧识别框，再显示忙碌状态。
- 统一实现 `invalidateQRCodeRequest()`：递增 generation、取消并清空 `qrTask`、关闭卡片、清空识别框，并立即把 `isQRCodeWorking` 复位为 `false`。
- `begin()`、`replaceSource()`、切换工具、`discard()` 与 `shutdown()` 都必须调用 `invalidateQRCodeRequest()`，不能只让 token 失效而遗留后台任务或忙碌态。
- 识别期间按钮禁用，防止同一动作重复提交。
- `Task.detached` 的 Vision 工作可能在外层任务取消后继续运行，因此所有成功和失败回写前必须同时检查：外层任务未取消、当前 `sessionID` 一致、generation 一致且当前工具仍为 `.qrCode`。不满足时静默丢弃。
- 二维码识别不占用现有 OCR 缓存，也不改变 `ScreenshotItem.ocrState`。
- OCR 与二维码识别共用一个“图像分析忙碌”状态；任一正在执行时，两个动作都禁用，避免并发渲染和互相覆盖状态。
- 切换到任何其他工具时清空二维码结果；再次进入二维码模式重新识别当前合成画面。
- 点击识别框只更新选中状态，不触碰剪贴板、不调用外部应用。
- 点击卡片中的“打开链接”是用户明确触发的终态动作：先调用可注入的 `ExternalURLOpening.open(_:)`。调用成功后立即关闭当前编辑会话，使原地编辑的 `.screenSaver` panel 不再遮住浏览器；调用失败则保留编辑会话和卡片并显示“无法打开链接”。
- 点击卡片中的复制动作不关闭编辑会话，用户可以继续点击其他二维码或继续编辑。
- 默认 `SystemExternalURLOpener` 内部使用 `NSWorkspace.shared.open`；测试使用 stub，不真正启动浏览器。

为便于测试，`EditorSessionCore` 增加可注入的 `ClipboardServing`，默认仍为 `SystemClipboardService()`；现有“复制全部文字”同步改用该依赖，用户可见行为不变。

### 3.3 二维码点击覆盖层与操作卡片

新增 `EditorQRCodeOverlayView`，作为 `EditorCanvasView` 的子视图，层级位于图片/标注之上，只负责识别框、选择状态与点击命中：

- 输入为当前合成图像的像素尺寸和 `[QRCodeResult]`。
- Vision 的 `boundingBox` 是归一化、左下原点；先转换为当前合成图的左上原点像素矩形，再通过 `EditorCanvasViewport.viewRect(fromModel:)` 映射到画布。
- 每个识别框使用半透明珊瑚填充、1.5 pt 实线边框和至少 44×44 pt 的点击热区；小二维码扩大热区但不扩大视觉框。
- 鼠标悬停时加深填充并切换为 pointing-hand 光标。
- 点击识别框后只选中该二维码并把“结果 + 画布内锚点矩形”回调给会话核心，不直接执行内容。
- 边框仅为交互提示，不写入 `EditorAnnotation`，也不会出现在保存或确认后的图片中。
- 多个框重叠时，选择面积最小且包含点击点的结果，避免大框遮住小框。

预览操作卡片由独立的 `QRCodeActionPopoverController` 承载，通过 `NSPopover` 锚定到被点击的二维码框。原地 overlay 与历史编辑窗口复用同一个 controller 和 SwiftUI 卡片视图：

- `NSPopover` 优先显示在二维码下方；空间不足时由 AppKit 自动换边并保持在当前可见屏幕内。
- 链接卡片突出显示经过 URL 解析得到的 host，完整链接最多显示两行并支持截断；“复制链接”和“打开链接”必须是两个独立按钮。
- 非链接 payload 最多预览四行，只提供“复制内容”；完整原文只在用户点击后写入剪贴板。
- 点击另一个识别框先更新选中项，再复用当前 popover 更新内容与锚点。
- 点击框外关闭 popover，但保留二维码模式与其他识别框。
- 卡片和按钮提供 VoiceOver 标签；打开卡片时键盘焦点进入卡片，Tab 可依次到达操作按钮，Esc 先关闭卡片。
- 必须在真实 `.screenSaver` overlay 上验证 popover 窗口层级；若系统 popover 无法稳定置顶，实施时改用相同卡片视图的 overlay-host 子视图，不改变交互语义。

二维码坐标映射必须抽成纯函数并独立测试，避免 Vision 左下原点与编辑模型左上原点造成上下颠倒。

坐标契约固定如下：

1. 二维码动作在进入 renderer 前定义一次 `effectiveCropRect = appliedCropRect.integral`，并把该矩形传给 renderer。`ScreenshotRenderer` 输出 PNG 的像素尺寸必须等于 `effectiveCropRect.size`，否则本次结果按 `.invalidImage` 拒绝。
2. Vision `boundingBox = (x, y, width, height)` 使用归一化左下原点；若合成 PNG 尺寸为 `(W, H)`，先转成左上原点的渲染像素矩形：

```swift
let renderedRect = CGRect(
  x: x * W,
  y: (1 - y - height) * H,
  width: width * W,
  height: height * H
)
```

3. 当前编辑模型仍使用原始源图像像素坐标，因此再平移裁剪原点：

```swift
let modelRect = renderedRect.offsetBy(
  dx: effectiveCropRect.minX,
  dy: effectiveCropRect.minY
)
```

4. 最后通过当前 `EditorCanvasViewport.viewRect(fromModel:)` 得到点击框。Retina scale 不直接参与该公式，因为 renderer 输出、crop 和编辑模型均以源像素为单位。
5. `EditorCanvasView.layout()` 每次执行时都用保存的 `modelRect` 和最新 viewport 重算框位置；窗口缩放、画布 aspect-fit 变化后不得沿用旧 view rect。

必须覆盖非零裁剪原点、顶部/底部、1x/2x 源图、窗口缩放后二次布局与 renderer 尺寸不匹配测试。

### 3.4 退出状态机

| 当前状态 | 点击其他二维码 | 点击框外 | Esc / 右键 | 切换其他工具 |
|---|---|---|---|---|
| 正在识别 | 无操作 | 无操作 | 取消请求并退出二维码工具 | 取消请求并进入所选工具 |
| 已显示识别框、卡片关闭 | 选中并打开卡片 | 无操作 | 清空识别框并回到选择工具 | 清空识别框并进入所选工具 |
| 卡片打开 | 切换选中码并更新卡片 | 只关闭卡片 | 只关闭卡片 | 关闭卡片、清空识别框并进入所选工具 |
| 无结果或识别失败 | 不适用 | 按选择工具处理 | 按选择工具既有语义处理 | 进入所选工具 |

无结果或失败完成时已经自动回到选择工具；再次点击二维码按钮会发起全新的识别请求。上述鼠标/键盘事件在二维码层处理后必须被消费，不能继续传给画布创建、移动或确认标注。回到选择工具后，再次右键才沿用编辑器既有语义取消整个编辑会话。

### 3.5 工具栏接线

在 `EditorToolbarView.swift` 做最小改动：

- `EditorTool` 增加 `.qrCode`。
- 工具栏在 `.ocr` 右侧增加 `toolButton(.qrCode, title: "二维码识别", symbol: "qrcode.viewfinder")`。
- 选择该工具后立即开始识别，不再打开属性弹层。
- 识别期间二维码按钮显示忙碌态并禁用重复触发；OCR 与二维码识别互斥。
- 工具栏增加一个按钮后，重新验证窄选区、主显示器边缘和小屏幕上的吸附布局；必要时只压缩按钮间距，不改工具顺序或另增折叠菜单。

## 4. 文件改动范围

| 文件 | 改动 |
|---|---|
| `SnapClip/QRCodeRecognition.swift` | 二维码结果、错误、Vision 识别协议、链接分类与可注入的外部链接打开协议 |
| `SnapClip/EditorSessionCore.swift` | 增加识别动作、异步生命周期、剪贴板写入与状态提示 |
| `SnapClip/EditorModels.swift` | 增加 `.qrCode` 工具枚举并保持 reducer 对该工具不创建标注 |
| `SnapClip/EditorCanvasView.swift` | 承载二维码覆盖层、坐标映射与点击回调 |
| `SnapClip/EditorQRCodeOverlayView.swift` | 绘制识别框、选择状态、悬停反馈和点击命中 |
| `SnapClip/QRCodeActionPopover.swift` | 二维码内容预览、复制/打开按钮和 `NSPopover` 生命周期 |
| `SnapClip/EditorToolbarView.swift` | 在 OCR 旁增加独立二维码按钮与忙碌态 |
| `SnapClipTests/QRCodeRecognitionTests.swift` | Vision 二维码识别、失败处理与安全链接分类测试 |
| `SnapClipTests/QRCodeOverlayTests.swift` | Vision → 编辑坐标转换、点击热区和重叠命中测试 |
| `SnapClipTests/EditorSessionCoreQRCodeTests.swift` | 会话取消、链接打开、文本复制、失败反馈与晚到结果拒绝测试 |
| `SnapClip.xcodeproj/project.pbxproj` | 把新增测试文件加入 `SnapClipTests` target；如拆出新源文件，也加入 `SnapClip` target |
| `README.md`、`docs/PRD.md` | 功能完成并通过验收后，仅补充二维码能力与本地隐私说明 |

不修改 `ScreenshotItem`、`HistoryStore`、截图控制器、渲染坐标模型或用户偏好。

## 5. 测试计划

### 5.1 单元测试

使用 Core Image 的 `CIQRCodeGenerator` 在测试内生成确定性二维码，不提交外部图片 fixture。

必须覆盖：

1. 单个二维码可还原中英文、URL 和常见符号组成的 payload。
2. 普通无二维码图片返回 `.noQRCode`。
3. 无效图片数据返回 `.invalidImage`。
4. 请求只接受 QR，不把其他条形码当成结果。
5. Vision 左下原点矩形能正确映射到编辑画布顶部/底部，没有上下翻转。
6. 多个二维码分别显示、分别可点击；重叠区域命中面积最小的码。
7. 非零裁剪原点、1x/2x 源图和窗口缩放后，识别框仍映射正确；renderer 输出尺寸不匹配时拒绝结果。
8. 点击识别框只显示卡片，不调用外部打开或 `copyText`。
9. 链接卡片展示解析后的正确域名，靠近四侧边缘时 popover 仍保持在可见屏幕内。
10. 只有点击“打开链接”才调用一次外部打开动作；成功后关闭编辑会话，失败时保留会话和卡片。
11. 点击“复制链接”只复制 trim 后的链接并保留编辑会话；文本复制保留原始 payload。
12. 控制字符、URL 凭据、`file:`、`javascript:`、自定义 scheme、Wi-Fi 配置和纯文本不会出现“打开链接”，只能复制。
13. 卡片打开时，点击框外、Esc 或右键只关闭卡片；卡片关闭后 Esc/右键才退出二维码工具。
14. 无结果或识别失败会清空旧结果，不调用外部打开或 `copyText`，不破坏原剪贴板。
15. 剪贴板写入失败显示错误。
16. 会话取消、关闭、切换图片、重新识别或切换工具后，晚到的成功和失败都不再改变 UI 或执行动作。
17. OCR 或二维码识别运行中，另一动作不可并发启动。

### 5.2 自动化回归

实现完成后运行：

```sh
xcodebuild -project SnapClip.xcodeproj \
  -scheme SnapClip \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SnapClip-qr-derived \
  -jobs 1 \
  CODE_SIGNING_ALLOWED=NO \
  test
```

除新增测试外，必须保持现有截图方向、裁剪、OCR、编辑器和历史测试全部通过。

### 5.3 真实 UI 验收

自动化通过后，用真实运行中的 SnapClip 验证：

1. 新截一张包含网址二维码的图片，点击“二维码识别”后出现位置准确的边框；点击边框只出现卡片，不立即跳转。
2. 卡片突出显示正确域名；点击“复制链接”保留 overlay，点击“打开链接”才关闭 overlay 并由默认浏览器打开正确链接。
3. 新截一张同时包含链接和纯文本二维码的图片，确认两个框可以分别选择，卡片内容和可用动作随之切换。
4. 截图中先裁剪掉一个二维码，再识别，只显示保留区域内的码。
5. 在二维码上添加标注后识别，确认使用当前合成画面且应用不崩溃。
6. 对普通截图识别，显示“未识别到二维码”，原剪贴板内容保持不变。
7. 从历史卡片进入“编辑”后执行同一动作；点击链接只弹卡片，确认打开后编辑窗口关闭并打开浏览器。
8. 识别过程中按 Esc、右键或切换工具，晚到结果不再显示或污染菜单状态。
9. 浅色、深色模式下二维码按钮、识别框、选中态、卡片、悬停态和忙碌态清晰。
10. 在二维码非常小、靠近图片四侧边缘、画布缩放以及 Retina 2x 场景下，识别框、点击热区和卡片位置仍准确。

## 6. 实施顺序

1. 增加二维码服务、错误类型和纯排序逻辑，并先完成服务单元测试。
2. 增加二维码覆盖层、预览操作 popover 及 Vision → 画布坐标转换，锁定上下方向、卡片内容和点击命中测试。
3. 给 `EditorSessionCore` 注入二维码、剪贴板和外部链接打开依赖，接入两步确认、取消与会话代次保护。
4. 在 OCR 旁增加独立二维码工具按钮并接入自动识别。
5. 补齐链接 allowlist、核心协调测试并接入 Xcode 工程。
6. 运行完整 XCTest。
7. 进行原地 overlay 与历史编辑窗口的真实 UI 验收。
8. 验收通过后更新 README/PRD；不在实现前把未完成能力写成已发布功能。

## 6.1 实施记录

- 已完成二维码工具按钮、Vision 本地识别、识别框、操作卡片、安全链接分类、复制/打开动作和异步会话保护。
- 2026-09-06 使用正式 Xcode 工程运行完整 XCTest：86 项测试全部通过，0 失败。
- 调试版 `.app` 已成功签名、安装并启动；当前自动化服务无法枚举 `LSUIElement` 菜单栏应用的编辑 overlay，因此最终视觉由用户在真实界面完成验收。
- 2026-09-06 用户确认二维码识别与增强后的识别框效果可接受，同意进入提交和发布流程。

## 7. 完成定义

同时满足以下条件才算完成：

- OCR 按钮旁可发现并进入独立的“二维码识别”工具。
- 每个二维码都在正确位置显示独立点击框。
- 点击识别框只显示内容预览卡片；不会立即打开或复制。
- 用户在卡片中确认后，`http/https` 链接可由默认浏览器打开；其他内容只复制、不执行。
- 单码、多码、无结果、无效图片、坐标映射、卡片布局、链接限制、剪贴板失败与取消竞态均有测试。
- 所有识别完全本地，且不会在用户确认前执行二维码内容。
- 现有完整测试套件通过。
- 新截图 overlay 和历史编辑窗口均完成真实交互验证。
- 文档只宣称已经验证的行为。
