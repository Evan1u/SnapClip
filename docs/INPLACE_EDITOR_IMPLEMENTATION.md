# SnapClip 截图“原地编辑”改造 AI 执行文档

> 状态：决策已锁定；实施已启动，正在按 Step 1–8 落地（当前完成几何/抓帧/共享编辑核心/overlay 接线与单元测试）
> 目标平台：Apple Silicon，macOS 14+
> 技术基线：Swift 6、SwiftUI + AppKit、ScreenCaptureKit、Vision、VisionKit、Core Graphics、Core Image
> 执行原则：原生、离线、零第三方运行时依赖；先做共享编辑核心抽取，再做 overlay，尽量不复制编辑逻辑

## 0. 本次决策（用户已确认，不再变更）

1. 历史卡片的“编辑”**不改成 overlay**，继续使用现有独立编辑窗口，只把新截图流程改为原地编辑。
2. **保留**空格切换窗口的截图模式（窗口模式仍是新截图的交互的一部分）。
3. **接受**把截图层从 `/usr/sbin/screencapture` 迁移到 ScreenCaptureKit。

因此本方案只改变“新截图（选区/窗口/主显示器）→ 编辑 → 确认/取消”这一条主链路；历史卡片编辑、三项历史、剪贴板事务、OCR、保存桌面等下游语义保持不变。

## 1. 目标行为（Feishu 式验收描述）

### 1.1 交互截图（`⇧⌘4` / 菜单“截取选区或窗口”）

1. 触发后，所有可见显示器瞬间冻结在当前画面，显示为半透明变暗背景；SnapClip 不激活系统截图界面，也不进入独立窗口。
2. 默认进入矩形选区模式，光标为十字；按住并拖动框选时，框内恢复冻结画面的原亮度，框外继续变暗，显示实时尺寸。
3. 按空格切换到窗口模式；再次按空格回到矩形选区模式。窗口模式下光标悬停的目标窗口显示高亮边框，单击即选窗口。
4. 松开鼠标完成矩形选区；单击（未达到拖拽阈值）且当前没有命中窗口时视为太小，取消本次截图；右键、Esc 取消。
5. 松手/选窗后**不关闭、不重建 overlay**：选区对应的截图内容保留在原屏幕坐标，立即出现工具栏并进入编辑模式；选区外仍为冻结变暗背景。
6. 编辑工具、撤销、二次裁剪、OCR、保存桌面、确认、取消的交互语义与现在独立编辑器一致。
7. 确认后写剪贴板 → 插入历史 → 关闭 overlay；取消则全部丢弃。

### 1.2 主显示器截图（`⇧⌘3` / 菜单“截取主显示器”）

触发后同样先冻结、变暗，不再显示独立窗口。主显示器整屏进入编辑模式，图片覆盖主屏原位置，工具栏吸附在不会挡住主要内容的位置；其余显示器保持冻结变暗。

### 1.3 保留的既有语义

- 一次只允许一个未提交编辑会话。
- 编辑中再次触发截图：先丢弃当前会话，再开始新的截图；新截图即使取消或失败，也不恢复旧会话。
- 历史项编辑仍是独立编辑窗口，与新截图 overlay 互斥；历史编辑不受本方案影响。
- 只有确认后才会写剪贴板和历史；写剪贴板失败保留编辑会话并可重试。
- 截图音效开关继续生效，由 SnapClip 在“画面冻结/进入编辑”的对应时机自行播放。
- 快捷键接管、辅助功能/屏幕录制权限检查逻辑不变。

## 2. 总体架构

新截图链路由一个新的主 Actor 会话控制器串联：

```text
触发 capture
  -> 主 Actor 预检权限并置 isCapturing
  -> DisplaySnapshotter（actor，SCK）逐显示器整屏抓帧
  -> 每个显示器一个无边框全屏 NSPanel（screenSaver 层级）
  -> 冻结图 + 变暗 + 选区/窗口高亮
  -> 用户完成选区或窗口选择
  -> 生成选区 PNG（后台裁剪/编码）或按需抓取独立窗口
  -> 仍在同一批 panel 上挂载 EditorSessionCore：画布放原坐标 + 工具栏 + 状态层
  -> 编辑完成后关闭全部 panel，交给既有剪贴板/历史事务
```

核心取舍：

1. **不沿用 `screencapture -i`**，因为它不返回选区屏幕坐标，无法做原地编辑；系统主显示器截图同样无法提供 overlay 所需的冻结底图。
2. **先在 overlay 显示前抓完整屏快照**，之后 overlay 覆盖屏幕时不会再把自己的窗口拍进最终结果。冻结内容以抓帧时刻为准。
3. 交互截图不使用跨显示器拼图：每个选择只属于**鼠标所在的那一块显示器**，选区矩形按该显示器的本地坐标裁剪；拖出屏幕时按当前显示器边界夹取。
4. 窗口模式“悬停识别”用 Quartz 窗口列表（只读取几何，不用于截图）；真正输出用 ScreenCaptureKit 对独立窗口按需抓取，保住圆角透明内容。找不到窗口时回退到该显示器冻结图按窗口框裁切，并提示用户。
5. 编辑内容模型继续使用“源像素坐标系 + 屏幕 pt 布局”：`EditorModels`、`EditorCanvasView`、`ScreenshotRenderer`、OCR overlay 的坐标规则不重写。
6. 先抽出共享 `EditorSessionCore`，历史窗口与 overlay 都只做“展示宿主”，避免在 overlay 里复制一份 669 行控制器逻辑。

## 3. 坐标空间与换算（全文档唯一约定）

### 3.1 坐标系清单

| 名称 | 原点/方向 | 使用方 |
|---|---|---|
| AppKit 全局屏幕坐标 | 主屏左下角为 (0,0)，y 向上 | `NSScreen.frame`、`NSPanel` 的 screen frame、窗口几何 |
| 显示器本地点坐标 | 每台显示器左下角为 (0,0)，y 向上 | overlay panel 内容视图、选区矩形、画布 frame |
| Quartz/SCK 全局坐标 | 主屏左上角为 (0,0)，y 向下 | `CGWindowList` bounds、SCK `SCWindow.frame`/`SCDisplay.frame` |
| 显示器本地像素坐标（裁剪用） | CGImage 的行 0 是画面顶部 | `CGImage.cropping`、ImageIO PNG 编码 |
| 编辑器模型坐标 | 源 PNG 左上角为 (0,0)，y 向下 | `EditorModels`、`EditorCanvasView`、`ScreenshotRenderer` |

本文档把“显示器本地点坐标”作为 overlay 与裁剪之间的主坐标，避免跨屏猜测。所有从 overlay 交出的 `CropRequest` 必须带 `displayID` 与 `rectInDisplayPoints`，不允许只交一个“全局矩形”让下游猜屏幕。

### 3.2 整屏抓帧

对每一台显示器：

1. 在 Main Actor 收集 `NSScreen` 拓扑：`displayID`（`NSDeviceDescriptionKey("NSScreenNumber")`）、`frame`（AppKit 全局点）、`backingScaleFactor`。
2. 获取一次 `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`，按 `displayID` 找到 `SCDisplay`。
3. 创建 `SCContentFilter(display: display, excludingWindows: [])`；显示器级 filter 默认包含桌面、Dock 与菜单栏。
4. 校验 `filter.contentRect.size` 与 `NSScreen.frame.size` 的差小于 0.5 pt，`filter.pointPixelScale` 与 `backingScaleFactor` 的差小于 0.01；不匹配视为“显示拓扑已变化”，本次失败并提示重试。
5. 输出像素尺寸：

```swift
let scale = CGFloat(filter.pointPixelScale)
let width = Int((screenFrame.width * scale).rounded())
let height = Int((screenFrame.height * scale).rounded())
```

`SCStreamConfiguration` 至少设置：

- `width = width`，`height = height`
- `captureResolution = .best`
- `showsCursor = false`
- `scalesToFit = false`
- `pixelFormat = kCVPixelFormatType_32BGRA`
- `shouldBeOpaque = true`

截图 API 使用 macOS 14+ 提供的：

```swift
SCScreenshotManager.captureImage(
  contentFilter: filter,
  configuration: configuration
) { image, error in ... }
```

用 completion-handler 包装成 `withCheckedThrowingContinuation`，避免依赖某个只在更新 SDK 才出现的 async 重载。

### 3.3 屏幕本地选区转 CGImage 裁剪

设 `display.sizeInPoints` 是抓帧图的点尺寸（像素宽高 ÷ scale），选区矩形 `rect` 是显示器本地左下角点坐标：

```swift
let pixelRect = CGRect(
  x: rect.minX * scale,
  y: (displayHeightPoints - rect.maxY) * scale,
  width: rect.width * scale,
  height: rect.height * scale
)
```

再做以下处理：

1. 对像素矩形取 `integral`（向外取整，保证不丢边缘）。
2. 与 `CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)` 求交集。
3. 若交集宽高小于 1 像素，视为 `cropOutsideSource`。
4. 用 `cgImage.cropping(to: intersection)` 得到选区 CGImage。

该公式由参考实现验证过：屏幕顶部的区域得到像素 y≈0，屏幕底部的区域得到像素 y 接近 `image.height`。任何新增裁剪函数都必须锁死这一公式，单元测试要分别覆盖屏幕顶部、底部、1x、2x 和非整数点边界。

### 3.4 编辑器画布放在原位置

把“选区像素 PNG”交给编辑器时：

- 画布 frame = 同一显示器 panel 内容视图里的选区点矩形（显示器本地左下角坐标）。
- `EditorInteractionState(sourcePixelSize: pixelSize, pointsToImageScale: scale)`，其中 `scale` 为该显示器的抓帧/输出 scale。
- `EditorCanvasView` 本身保持 flipped（内部模型坐标 y 向下），但 frame 放在未翻转的父视图坐标系中即可，不改画布内部转换。
- 对主显示器全屏：选区矩形就是主屏 `(0, 0, width, height)`，scale 为主屏 scale。

这样一“屏上 pt”≈ 原画面视觉尺寸，Retina 下也按 2x 像素密度显示；编辑模型里 4 pt 线宽等名义值与 renderer 的像素换算沿用现有 `pointsToImageScale` 机制。

### 3.5 窗口模式几何

悬停命中使用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly | .excludeDesktopElements, kCGNullWindowID)`：

- 跳过 SnapClip 自身 PID、系统黑名单进程（Window Server、Dock、SystemUIServer）、alpha ≤ 0、不可见窗口、全屏覆盖层窗口。
- 层级只接受普通窗口到弹出菜单层之间。
- 同一 PID 下父窗口完整包含子窗口时，选父窗口（解决 Electron/Chromium 子窗口误选）。
- 列表本身是前到后顺序，选第一个合法的悬停候选。

Quartz bounds（左上原点）转 AppKit 屏幕坐标：

```swift
let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
let appKitRect = CGRect(
  x: quartzBounds.minX,
  y: mainHeight - quartzBounds.maxY,
  width: quartzBounds.width,
  height: quartzBounds.height
)
```

选中窗口后：

1. 用 `windowID + ownerPID` 在最新一次 `SCShareableContent` 中匹配 `SCWindow`。
2. 创建 `SCContentFilter(desktopIndependentWindow: window)`。
3. 输出像素尺寸 = `filter.contentRect.size × filter.pointPixelScale`。
4. `SCStreamConfiguration`：`backgroundColor = .clear`、`shouldBeOpaque = false`、`ignoreShadowsSingleWindow = true`，其余同 3.2；这样输出保留窗口圆角透明、不含窗外阴影。
5. 编辑器画布 frame 使用 3.5 得到的 AppKit 窗口矩形与本显示器 frame 相交后的本地矩形。
6. 若 `contentRect.size` 与悬停 bounds 尺寸相差超过 2 pt，说明窗口状态已变化，放弃这次抓取并回到选区模式提示“窗口已变化，请重试”。

## 4. 建议的新文件与职责

所有新 Swift 文件加入 `SnapClip.xcodeproj` 的 `SnapClip` target（PBXFileReference + Sources build phase），测试加入 `SnapClipTests` target。

后续每个 Step 新创建的文件都要在提交前同步 pbxproj；漏接线的常见表现是“目标中找不到类型”或测试目标编译错误。先接线再编译，避免把接线错误误判成 Swift 错误。

| 文件 | 职责 |
|---|---|
| `SnapClip/CaptureGeometry.swift` | 纯值类型与纯函数：`CaptureImage`、`FrozenDisplaySnapshot`、显示器本地点坐标、抓帧图数据、点→像素裁剪、Quartz→AppKit 坐标换算。不含 AppKit/SCK 对象 |
| `SnapClip/DisplaySnapshotService.swift` | `DisplaySnapshotting` 协议 + `SCKDisplaySnapshotter` actor：整屏抓帧与独立窗口抓取 |
| `SnapClip/CaptureSelectionModels.swift` | 纯状态机：拖拽开始/移动/结束、矩形归一化、最小尺寸、点击 vs 拖拽阈值、区域/窗口/取消三种决策 |
| `SnapClip/WindowHitTester.swift` | 用 Quartz 窗口列表做悬停命中与黑名单过滤；结果只含几何与窗口标识 |
| `SnapClip/CaptureOverlayView.swift` | 单个显示器 overlay 视图：冻结图绘制、变暗、选区/窗口高亮、鼠标与键盘事件转发 |
| `SnapClip/CaptureSessionController.swift` | 整个新截图会话的 Main Actor 协调者：建/关 panel、选择阶段、图片生成、切换编辑阶段、会话终态 |
| `SnapClip/InPlaceEditorOverlayView.swift` | 编辑阶段单显示器宿主：冻结背景 + 画布 + 工具栏 + 状态标签；只做布局与展示 |
| `SnapClip/EditorOverlayLayout.swift` | 纯布局函数：给定选区点矩形与显示器边界，返回画布、工具栏、状态标签 frame |
| `SnapClip/EditorSessionCore.swift` | 从 `EditorWindowController` 抽出的共享编辑逻辑（见 §6） |
| `SnapClip/CaptureSoundPlayer.swift` | 可注入截图音效协议与实现，替代 `screencapture` 自带音效 |
| 测试：`CaptureGeometryTests.swift`、`CaptureSelectionModelsTests.swift`、`EditorOverlayLayoutTests.swift`、`DisplaySnapshotServiceTests.swift`、`CaptureSessionControllerTests.swift` | 对应纯逻辑与流程测试 |

## 5. 显示器 overlay panel 规则

统一创建一个共享的 `CaptureOverlayPanel` 工厂：

- `styleMask = [.borderless]`；`isOpaque = false`；`backgroundColor = .clear`；`hasShadow = false`。
- `level = .screenSaver`。
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`。
- `acceptsMouseMovedEvents = true`；`isReleasedWhenClosed = false`。
- `contentRect = 该 NSScreen.frame`；panel 的 contentView 为未翻转视图（显示器本地左下角点坐标）。
- 显示前调用 `NSApp.activate(ignoringOtherApps: true)` 并让鼠标所在显示器 panel 成为 key，以便 Space/Esc/文字输入有键盘 responder；关闭全部 panel 后不再额外抢焦点（沿用现有编辑器行为即可）。
- 全屏抓帧完成后才 order front，确保最终帧不会包含这些 panel。

编辑器需要的 `NSColorPanel` 若仍比 `.screenSaver` 低而看不见，就在 overlay 编辑阶段临时把 `NSColorPanel.shared.level` 提到 `.screenSaver` 之上，事务结束后恢复原 level；SwiftUI Popover 跟随宿主窗口层级，无需额外处理。

## 6. 共享编辑核心抽取

### 6.1 动机

`EditorWindowController.swift`（669 行）同时混合“编辑会话逻辑”和“独立窗口展示”。若直接复制一份到 overlay，撤销、保存、OCR、颜色事务、Esc 层级就会出现两份实现，后续维护必然漂移。因此先抽取，后做 overlay。

### 6.2 `EditorSessionCore` 接口建议

新建 `SnapClip/EditorSessionCore.swift`，把下列私有内容从 `EditorWindowController` 迁过去并改为 internal：

- `EditorActiveSession`（session 数据：pngData、pixelSize、capturedAt、target、sourceRevision）
- `renderTask`、`ocrTask`、`isOCRWorking`、`session`
- `styleStore`、`colorPanelCoordinator`、`ocrGate`
- `toolbarModel`、`updateToolbar()`
- `handleToolSelect`、`handleStyleAction`、`copyAllOCRText`、`prepareOCRSelection`
- `saveToDesktop`、`confirmSession`、`discardActiveSession`、`shutdown`
- 颜色/OCR/渲染相关的异步生命周期与“会话 UUID 拒绝晚到结果”规则

它只依赖一个已存在的 `EditorCanvasView` 和少量宿主回调，核心方法大致为：

```swift
@MainActor
final class EditorSessionCore {
  let canvas: EditorCanvasView
  let toolbarModel = EditorToolbarViewModel(...)
  weak var sessionDelegate: EditorSessionDelegate?

  /// 宿主在关闭或用户确认后回调；核心不在核心层直接操作任何 NSWindow/NSPanel。
  var onRequestClose: (() -> Void)?
  /// 宿主把错误/状态显示接到自己的 statusLabel。
  var statusHandler: (@MainActor (String, Bool) -> Void)?

  init(canvas: EditorCanvasView,
       renderer: any ScreenshotRendering = ScreenshotRenderer(),
       desktopExporter: any DesktopExportServing = DesktopExportService())

  func begin(pngData: Data,
             pixelSize: CGSize,
             capturedAt: Date,
             target: EditorTarget,
             sourceRevision: UInt64,
             pointsToImageScale: CGFloat) throws
  func discard()
  func shutdown()

  func updateToolbar()
  func handleToolSelection(_ tool: EditorTool)
  func handleStyleAction(_ action: EditorStyleMenuAction)
  func handleEscape() -> Bool   // 颜色事务→inline text→裁剪草稿→取消整个会话
  func saveToDesktop()
  func confirm()
  func cancel()
}
```

关键规则：

- 核心只在成功 `begin` 后持有 session；失败不得留下半成品。
- `discard()`/`shutdown()` 取消并清空渲染、OCR 任务，先通知 sessionDelegate。
- `confirm()` 成功后调用 `onRequestClose`；失败只显示状态，不关闭。
- `cancel()` 按现状顺序关闭颜色事务 → `discard()` → `onRequestClose`。
- 颜色面板、OCR 的打开/关闭状态仍由核心内的 coordinator/gate 负责；宿主只转发 Esc。

### 6.3 `EditorWindowController` 瘦身

`EditorWindowController` 保留：

- 历史项 `ScreenshotEditing` 实现（`presentHistoryItem`、`isPresenting`、`focus`、`shutdown`）。
- 独立 NSWindow、`EditorWorkspaceView`、工具栏 `NSHostingView` 的创建与布局。
- 窗口级 Esc local monitor（只做 `sessionCore.handleEscape()` 转发）、`windowWillClose`。
- `sessionDelegate` 转交给核心。

对外协议方法可暂时保留 `presentNewCapture(pngData:capturedAt:)` 以便旧测试过渡，但 AppModel 新截图不再调用它；清理阶段确认无引用后删除。

### 6.4 抽取的验收门槛

抽取必须是一个纯重构里程碑：先抽取并通过既有全部单元测试与历史编辑人工回归，再进入 overlay。禁止一边抽取一边改截图流程。

## 7. Overlay 编辑阶段布局

### 7.1 `InPlaceEditorOverlayView`

编辑阶段的每块显示器宿主只放在“来源显示器”的 panel 上，其他显示器 panel 继续画冻结暗背景且不接收编辑事件：

1. 绘制冻结抓帧图；除画布区域外统一变暗。
2. 把 `EditorSessionCore.canvas` 作为子视图放在选区点矩形上。
3. 加 1 pt 左右的浅色选中描边（不计入截图、不进入渲染器）。
4. 底部/顶部放置工具栏 `NSHostingView<EditorToolbarView>`。
5. 工具栏上方（或下方）放状态标签，复用现有错误/提示颜色。
6. 画布默认关闭暖石墨背景（见 §7.3），让透明窗口截图与暗背景自然衔接。

### 7.2 `EditorOverlayLayout` 纯布局规则

```
toolbarSize ≈ 宽 700pt、高 56pt（以实际 fitting 尺寸为准）
margin = 12pt
```

- 优先放选区下缘下方：`toolbar.minY = selection.minY - toolbarHeight - margin`，水平以选区中心对齐。
- 若该位置越出显示器边界，改放选区上缘上方。
- 若上下都没有足够空间，放显示器底部/顶部可用边缘并保持 margin。
- 状态标签放在工具栏外侧；无内容时隐藏。
- 任何情况下 canvas frame 始终等于选区点矩形，不因工具栏空间而缩放。

写为纯函数并测试：选区贴底、贴顶、极小选区、异形多显示器等边界。

### 7.3 `EditorCanvasView` 必要的小改动

给 `EditorCanvasView` 增加“是否绘制编辑器底色”的开关，默认保持现状（历史窗口为暖石墨底），overlay 宿主创建时设为 `false`：

- `draw(_:)` 中只有开启时才 fill 暖石墨；关闭时画布透明，让父视图冻结/暗背景透出。
- 不影响 `drawSourceImage`、标注、裁剪遮罩、OCR overlay、命中测试。
- 不改模型、渲染器与撤销栈。

若发现子视图透明区域仍被 AppKit 清除成黑/灰，则把 canvas 放入 layer-backed 容器并设置 `wantsLayer` + 透明 layer；以真机视觉验收为准，不要改动最终渲染器。

## 8. CaptureSessionController 状态机

### 8.1 会话阶段

```swift
enum CaptureSessionPhase: Equatable {
  case idle
  case snapshotting
  case selecting          // overlay 选区/窗口
  case preparingImage     // 裁剪/独立窗口抓取/编码
  case editing            // EditorSessionCore 已挂载
  case committing         // 确认渲染中
  case finished
}
```

所有“结束”都走同一条终态清理：取消任务、移除事件、关闭全部 panel、清空冻结图、恢复 phase = idle。

### 8.2 会话方法

对外暴露给 AppModel：

```swift
@MainActor
protocol InPlaceCapturePresenting: AnyObject {
  var isPresenting: Bool { get }
  var sessionDelegate: EditorSessionDelegate? { get set }
  func begin(mode: CaptureMode,
             soundEnabled: Bool) async throws -> CaptureFlowResult
  func discardActiveSession()
  func shutdown()
}

enum CaptureFlowResult: Equatable {
  case editorOpened     // overlay 已进入编辑，AppModel 可结束 isCapturing
  case cancelled        // 用户取消或太小
}
```

`begin` 内部：

1. 拒绝并发：已有会话直接抛 busy。
2. 置 `snapshotting`，调 `DisplaySnapshotting.captureFrozenScreens()`。
3. 建 panel 并进入 `selecting`；用一个 `CheckedContinuation` 等待用户决策。
4. `.mainDisplay` 可跳过选择：主屏全屏作为选区决策。
5. 得到区域决策：后台按 §3.3 裁剪并编码 PNG。
6. 得到窗口决策：调 snapshotter 的独立窗口抓取；失败则回退并提示。
7. 图片就绪后进入 `editing`：在该显示器 panel 上创建 `InPlaceEditorOverlayView`、`EditorSessionCore`，调用 `core.begin(...)`，随后调用 `sessionDelegate?.editorDidBeginSession()`。
8. 返回 `.editorOpened`。

取消路径返回 `.cancelled`，不调 `editorDidCancelSession`（AppModel 自己显示“已取消截图”）。

### 8.3 编辑后的回调

`EditorSessionCore.sessionDelegate` 指向 AppModel 的既有 `EditorSessionDelegate`：

- `editorDidBeginSession` → AppModel `isEditing = true`、状态“正在编辑截图”。
- `editorDidCancelSession` → 只覆盖“编辑”取消（选择阶段取消由 `CaptureFlowResult.cancelled` 处理）。
- `editorDidRequestCommit` → AppModel 现有实现（新截图 = 复制 → insert → accepted）不变。
- `.accepted` 后 `CaptureSessionController` 关闭 panel；`.rejected` 留在编辑状态显示错误。

## 9. AppModel 与旧 CaptureService 改造

### 9.1 AppModel

1. 注入两个呈现对象：
   - `captureSession: any InPlaceCapturePresenting`（新截图）
   - `historyEditor: any ScreenshotEditing`（历史项编辑）
2. 保留 `editorController.sessionDelegate = self` 语义，但分别对两者设置 `sessionDelegate = self`。
3. `capture(_:)` 改为在 `captureTask` 里 `await captureSession.begin(mode:soundEnabled:)`：

```swift
switch result {
case .editorOpened:
  // 不写剪贴板/历史；由 editorDidRequestCommit 完成
  break
case .cancelled:
  showFeedback("已取消截图")
}
```

4. 新截图触发前，若 `captureSession.isPresenting || historyEditor.isPresenting`，先调用对应 `discardActiveSession()`。
5. 权限预检/`isCapturing`/`statusMessage` 的时间轴保持不变：截图和选区期间 `isCapturing=true`，进入编辑后 `isCapturing=false`。
6. `openPreview(_:)` 只调用 `historyEditor`。
7. `shutdown()` 同时取消 `captureSession` 与 `historyEditor`。

### 9.2 CaptureService 去留

- 新截图不再创建 `screencapture` 子进程、不再依赖临时 PNG 文件桥。
- `CaptureServing`/`SystemCaptureService`/`FoundationProcessRunner` 以及临时文件清理逻辑只服务旧链路；等 AppModel 测试切换到新的注入对象后整组删除。
- 旧 `CaptureServiceTests` 删除，替换为：
  - 纯几何/裁剪测试；
  - mock `DisplaySnapshotting` + mock capture session 的 AppModel 时序测试；
  - mock `InPlaceCapturePresenting` 的取消/失败/重复触发测试。
- 删除前用 `rg` 确认没有任何生产路径引用；`Package.swift` 若仍有 SwiftPM 构建，同步清理无关代码但保留 AppKit/Vision 等系统框架。

### 9.3 截图音效

实现 `CaptureSoundPlayer`，只做两件事：

```swift
@MainActor
protocol CaptureSoundPlaying {
  func playCaptureSoundIfEnabled(_ enabled: Bool)
}
```

实现尝试系统快门音效名称，找不到时 `NSSound.beep()`。播放时机：

- 交互截图：选区/窗口确定且编辑器即将显示时。
- 主显示器截图：抓帧完成、进入编辑时。

## 10. 文件级实施步骤（严格顺序）

每一步完成后先编译，再进入下一步；步骤 6 之前不改变 AppModel 的新截图入口。

### Step 1：纯几何与抓帧底座

1. 新建 `SnapClip/CaptureGeometry.swift`：
   - `CaptureImage`（CGImage + pointScale + `sizeInPoints`）
   - `FrozenDisplaySnapshot`（displayID、frameInAppKitPoints、image）
   - `DisplayTopologySnapshot`（NSScreen 拓扑）
   - §3.3 的裁剪纯函数、像素矩形校验与交并夹取。
2. 新建 `SnapClip/DisplaySnapshotService.swift`：
   - `DisplaySnapshotting` 协议（Sendable）
   - `SCKDisplaySnapshotter` actor：抓全屏、校验 scale/size、按需求抓独立窗口。
3. 新建 `SnapClipTests/CaptureGeometryTests.swift`，覆盖 1x/2x、顶部/底部、非整数边界、跨界夹取、窗口 frame 尺寸校验。
4. 把新文件加进 pbxproj 的两个 target；`Package.swift` 增加 `.linkedFramework("ScreenCaptureKit")`。
5. 用无签名 xcodebuild 编译并跑新测试。

### Step 2：选择状态机与纯布局（可无 UI 编译）

1. 新建 `SnapClip/CaptureSelectionModels.swift`：矩形拖拽状态、阈值、最小尺寸、区域/窗口/取消决策。
2. 新建 `SnapClip/EditorOverlayLayout.swift`：画布/工具栏/状态标签布局纯函数。
3. 新建对应测试（贴边、极小选区、Retina 尺寸差异）。
4. 编译并跑测试。

### Step 3：抽取共享编辑核心（纯重构里程碑）

1. 新建 `SnapClip/EditorSessionCore.swift`，按 §6.2 迁移逻辑。
2. 把 `EditorWindowController` 改成瘦宿主，历史编辑行为完全不变。
3. 运行既有全部单元测试 + 历史项手工回归（打开、编辑、确认、取消、OCR、颜色、保存桌面）。
4. 只有通过才进入 Step 4。

### Step 4：Overlay 选区视图与窗口命中

1. 新建 `SnapClip/WindowHitTester.swift`，实现 §3.5 的 Quartz 命中与 AppKit 坐标换算。
2. 新建 `SnapClip/CaptureOverlayView.swift`：
   - 画冻结图、暗遮罩、选区/窗口高亮；
   - 未命中窗口且单击/过小 → 取消；
   - 空格由 controller 切换“区域/窗口”模式，Esc 取消，右键取消；
   - 事件只响应鼠标所在显示器。
3. 用 `CaptureSessionController` 的临时“只选择、不编辑”分支联调：面板能在所有显示器出现，能框选/选窗口并打印决策。
4. 该分支不得进入生产 AppModel；可在测试目标中写 `CaptureSessionControllerTests` 用 mock panel/视图验证阶段转换。

### Step 5：图片生成与独立窗口抓取

1. 在 `CaptureSessionController` 中接上选区裁剪（后台）与编码。
2. 在 `SCKDisplaySnapshotter` 中实现 `captureWindow(descriptor:)`，按 §3.5 匹配 SCWindow 并返回 `CaptureImage`。
3. 无法匹配或尺寸变化时返回 typed error，controller 回退到冻结图裁窗口。
4. 测试 mock 的服务 + 真实纯裁剪；真机只验证窗口圆角与透明背景方向。

### Step 6：Overlay 编辑挂载与接线 AppModel

1. 新建 `SnapClip/InPlaceEditorOverlayView.swift`，用 `EditorSessionCore` 挂画布与工具栏。
2. `EditorCanvasView` 增加透明底色开关（§7.3）。
3. `ColorPanelCoordinator` 支持 overlay 层级的颜色面板。
4. 完成 `CaptureSessionController` 的 `.editing` 阶段与终态清理。
5. 按 §9.1 改造 AppModel，删除旧 `SystemCaptureService` 调用，更新/重写相关单元测试。
6. 手工跑通：选区 → 原地编辑 → 确认/取消/重截；主屏截图 → 原地编辑。

### Step 7：视觉与交互打磨（Feishu 对照）

1. 对照飞书检查：冻结暗度、选区亮度、确认/取消反馈、工具栏吸附位置、窄选区/贴底选区、深色壁纸可读性。
2. 检查空格窗口模式：悬停高亮、选中窗口、再次空格回区域、Esc、圆角透明。
3. 检查编辑器内原有能力在 overlay 下不回归：工具二级菜单、颜色面板、inline 文字、裁剪、OCR、保存、状态提示。
4. 补齐 accessibility：选区尺寸播报、窗口模式说明、按钮标签与禁用状态。

### Step 8：文档与收尾

1. 更新 `README.md`、`docs/PRD.md`、`docs/SCREENSHOT_EDITOR_IMPLEMENTATION.md`：
   - 删除“截图完成后停留在原屏幕坐标的全屏覆盖编辑”属于“明确不做”的表述；
   - PRD 删除 `/usr/sbin/screencapture` 实现细节与“未来迁移 SCK”的路线表述；
   - 把 CAP-01/02 验收条件改为自定义 overlay 的行为。
2. 更新 `docs/brand-spec.md`：增加 overlay 选区/编辑器层规范。
3. 按全局 `AGENTS.md` 对本次 Markdown 检查 Obsidian 绝对符号链接；不得 `ln -sf`，目标冲突时停下报告。
4. `git status` 无 DerivedData、临时文件、构建产物。

## 11. 构建与测试门槛

编译与单元测试使用 Xcode 工程，不以 SwiftPM 二进制为验收：

```sh
xcodebuild \
  -project SnapClip.xcodeproj \
  -scheme SnapClip \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 1 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

签名/真机阶段：

```sh
xcodebuild \
  -project SnapClip.xcodeproj \
  -scheme SnapClip \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 1 \
  test
```

完成标准：

- 全部既有与新增单元测试通过，无 Swift 6 并发错误。
- Step 3 纯重构里程碑、Step 6 接线里程碑、Step 8 文档里程碑各自有干净 commit。
- §12 人工验收全部通过。
- 截图、编辑器、历史、OCR、保存桌面与实际文档一致。

## 12. 人工验收清单

### 12.1 交互截图

1. `⇧⌘4` 后所有显示器冻结变暗，菜单栏/Dock 被遮住；画面不出现 SnapClip 自身 panel。
2. 拖动框选：框内原亮度、框外变暗、尺寸实时显示；松手后截图内容停在原屏幕坐标，无窗口弹出/闪烁。
3. 空格 → 窗口模式：窗口高亮跟随鼠标；单击选窗；空格回区域；Esc 取消。
4. 单击空白、拖拽过小：按取消处理，不写剪贴板/历史。
5. 编辑模式可继续用全部工具；选区内图片显示比例与原始屏幕一致（Retina 下不模糊、不失真）。
6. 工具栏不遮挡正文；选区贴底/贴顶时能自动换边。
7. 确认：写入剪贴板并出现在历史；取消：全部丢弃。
8. 编辑中再次 `⇧⌘4`：丢弃当前会话并开始新截图；随后 Esc 取消也不恢复旧会话。

### 12.2 窗口模式

1. 对普通 App 窗口、Electron/Chromium 窗口、带圆角透明窗口分别验证悬停高亮与输出。
2. 输出窗口内容带圆角透明，不含桌面背景；画布放在原窗口位置。
3. 窗口在等待期间移动/关闭：显示明确提示并回到选区模式，不崩溃、不提交错误图片。

### 12.3 主显示器

1. `⇧⌘3` 主屏整屏直接进入原地编辑，图片在主屏原位置、其余屏冻结变暗。
2. 保存/复制/OCR/裁剪与交互截图一致。

### 12.4 多显示器与 Retina

1. 鼠标在哪块屏就在哪块屏框选；跨屏拖拽按起始屏边界夹取，不产生错位图。
2. 不同分辨率/缩放（1x、2x、外接 4K）下像素尺寸与屏幕视觉一致。
3. 显示器拓扑变化（拔插、改排列）后重试能重新抓帧，旧会话安全结束。

### 12.5 历史与权限

1. 历史“编辑”仍弹独立窗口，确认/取消语义不变。
2. 新截图所需权限仍是屏幕录制；未授权时错误与设置入口正常。
3. 截图音效开关关闭后不播放；开启后播放一次。

## 13. 主要风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| SCK 抓帧尺寸/坐标系在 Retina 或多屏有偏差 | 选区与原画面错位 | §3 锁死公式并真机多屏验收；抓帧时校验 `contentRect`/`pointPixelScale` |
| overlay 挡住所有屏导致 Esc/取消路径失效 | 用户被困住 | 面板必须成为 key、单一 Esc 路由、焦点丢失也终态清理 |
| 抽取 EditorSessionCore 回归历史编辑 | 现有稳定功能被破坏 | Step 3 独立里程碑 + 既有测试 + 手工回归后冻结 |
| 编辑逻辑被复制到 overlay | 双份代码漂移 | 只允许 overlay 使用共享 `EditorSessionCore`；代码评审禁止复制粘贴 |
| SCK 对窗口的“阴影/圆角/边框”与系统截图不同 | 窗口截图观感变化 | 明确选择“圆角透明、无阴影”策略并在 README/PRD 说明 |
| 全分辨率抓帧内存大 | 卡顿/内存上涨 | 后台 actor 串行/限流抓帧，冻结图用后及时释放；编辑源只保留选区 PNG |
| `NSColorPanel`/Popover 层级低于 `.screenSaver` | 编辑器里打不开颜色 | 临时提升面板层级；真机验收 |

## 14. 不做（本期边界）

- 不支持一次拖拽跨显示器生成一张拼图截图；跨屏拖拽夹取到起始屏。
- 窗口截图不包含窗口阴影，也不承诺逐像素等同 `screencapture -i -w`。
- 不在本期新增图层、贴纸、录屏、窗口列表 UI、剪贴板历史等。
- 历史项编辑不迁移到 overlay。
