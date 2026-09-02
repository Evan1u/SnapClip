# SnapClip 截图编辑器 AI 执行文档

> 状态：已确认，可直接实施  
> 目标平台：Apple Silicon，macOS 14+  
> 技术基线：Swift 6、SwiftUI + AppKit、Vision、VisionKit、Core Graphics、Core Image  
> 执行原则：原生、离线、零第三方运行时依赖；不得使用 `planning-with-files`。

## 1. 目标

把 SnapClip 当前的“截图成功后立即复制并写入历史”流程改为：

1. 用户完成系统选区、窗口或主显示器截图。
2. SnapClip 打开一个居中的独立编辑窗口，原图此时只保存在内存中。
3. 用户可二次裁剪图片，添加矩形、椭圆、直线、箭头、可旋转文字和马赛克，也可使用 OCR。
4. 用户点击“确认”后，应用才把最终合成 PNG 写入剪贴板和最近三张历史。
5. 用户点击“取消”、在颜色/文字/裁剪等内层交互均不活动时按 Esc，或关闭窗口时，完全丢弃本次编辑结果。

历史图片的“打开”也进入同一编辑器；确认后原位替换该历史项，不新增历史项、不改变排序。

## 2. 已锁定的产品决策

### 2.1 编辑窗口

- 使用单一、可复用的独立窗口，不重写系统截图选区层。
- 使用标准 `NSWindow` 加透明标题栏和全尺寸内容区，视觉上无边框，但保留窗口拖动、缩放、键盘事件和辅助功能语义。
- 初始内容尺寸不超过当前屏幕可见区域的 85%，常规最小内容尺寸为 640×420 pt。若可见区域扣除 16 pt 安全边距后小于该值，以安全边距内的可用尺寸为准；“不超出屏幕”的优先级高于最小尺寸。
- 图片在工作区中保持比例居中显示；图片外区域使用 SnapClip 暖石墨背景。
- 底部工具栏悬浮在图片工作区上方，不占用图片输出内容。
- 全应用只允许一个未提交编辑会话。
- 编辑中再次触发截图：在启动系统截图前就不弹确认地丢弃当前会话；之后即使系统截图被取消或失败，旧会话也不恢复。
- 编辑中打开另一张历史图片：不弹确认，丢弃当前会话并打开目标历史图片。

### 2.2 工具栏顺序

工具栏从左到右固定为：

1. 选择
2. 矩形
3. 椭圆
4. 直线
5. 箭头
6. 插入文字
7. 马赛克
8. 二次裁剪
9. OCR
10. 分隔线
11. 撤销
12. 保存到桌面
13. 取消
14. 确认

二次裁剪使用 SF Symbol `crop`。其余按钮继续使用合适的 SF Symbols，不使用 emoji 或外部图标包。所有主要点击目标不得小于 44×44 pt。选中工具使用 Pivot Coral，工具栏表面使用 Studio Paper Raised/Blade Graphite，保持现有浅色和深色语义，不使用渐变。

### 2.3 标注颜色

矩形、椭圆、直线、箭头和文字都必须支持创建前选色，以及创建后选中对象改色。马赛克没有颜色属性。

预设颜色固定为：

| 名称 | 色值 |
|---|---|
| 珊瑚 | `#E96548` |
| 红色 | `#E53935` |
| 绿色 | `#34A853` |
| 蓝色 | `#2878D0` |
| 白色 | `#FFFFFF` |
| 石墨 | `#363635` |

六个预设色之后固定放置第七个“调色板色块”。它使用带边框的调色板图标；点击后打开系统 `NSColorPanel`。用户选取颜色后，该色块显示最近一次自定义颜色并保持调色板小图标，再次点击仍然打开面板。自定义颜色保存为 sRGB RGBA，不持久化到下次启动。

`NSColorPanel` 通过一个主线程 `ColorPanelCoordinator` 管理，并把一次“打开面板直到结束”视为一个颜色事务：

- 打开时冻结目标为“当前默认图形样式”“当前默认文字样式”或一个明确的已选对象 UUID，并记录事务前颜色；后续连续颜色事件不得改绑到其他工具或对象。
- 面板连续发送的、可转换为 sRGB 的颜色用于实时预览对象和最后一个色块；这些事件合并为同一个撤销记录，不得每个事件各压入一次。
- 点击面板关闭按钮、点击编辑器其他位置、切换工具或切换选中对象时，以最后一个有效颜色提交事务。若目标是已有对象且颜色实际改变，只产生一个撤销步骤；若目标是默认样式，不产生撤销步骤。
- 面板打开时按 Esc 视为取消颜色事务：对象、当前默认颜色和最后一个色块全部恢复事务前值，不产生撤销步骤。颜色无法转换为 sRGB 时忽略该事件并保持最后一个有效预览值。
- 关闭、取消或替换整个编辑会话前先取消颜色事务；调色板事件必须同时校验编辑会话 UUID 和颜色事务 UUID，晚到事件直接丢弃。

图形描边和文字分别维护当前颜色，默认都为珊瑚色；修改其中一类不会覆盖另一类。它们在当前应用运行周期内保持，但不写入 `UserDefaults`。

这些颜色属于用户生成的图片内容，不是应用界面色。`docs/brand-spec.md` 中“界面九色限制”继续有效，但必须增加这一条标注色例外。

### 2.4 各工具二级菜单

矩形、椭圆、直线、箭头、插入文字和马赛克都必须有锚定在对应按钮正下方的二级 Popover。选择工具本身没有固定样式菜单，但选中已有可调样式对象时提供对应的上下文菜单；二次裁剪直接进入画布裁剪模式，不打开二级菜单；OCR、撤销、保存、取消和确认没有样式菜单。

统一打开规则：

- 第一次选择某个标注工具时立即打开它的二级菜单，提升功能可发现性。
- 点击画布后关闭菜单，但工具继续保持激活。
- 再次点击当前工具按钮可重新打开菜单；切换到其他工具时关闭旧菜单并打开新工具菜单。
- 修改粗细、字体、字号或预设颜色后菜单保持打开；点击菜单外部或开始绘制时关闭。
- 工具按钮使用主图标加小型向下指示，不额外增加独立的线宽或颜色按钮。
- Popover 使用水平紧凑布局、12 pt 内边距和 8 pt 项间距；粗细区与颜色区之间使用一条竖向分隔线。

#### 2.4.1 矩形、椭圆、直线和箭头

这四个工具共享同一套“当前描边样式”，二级菜单固定为左粗细、右颜色：

- 左侧用三条不同粗细的水平线展示三档描边：细 2 pt、中 4 pt、粗 8 pt；默认中档 4 pt。
- 右侧依次显示第 2.3 节的六个预设色，最后一个色块为调色板入口。
- 当前粗细用珊瑚色选中底和勾选标记表示；当前颜色用白色或石墨描边加勾选标记表示，确保浅色和深色背景都可辨识。
- 四个工具共享最后选择的粗细和颜色；切换工具时沿用该样式。
- 使用选择工具选中已有矩形、椭圆、直线或箭头时，选择按钮显示下拉指示，并复用同一菜单。菜单读取对象当前粗细和颜色；修改立即作用于该对象、更新当前描边样式，并登记一个撤销步骤。

#### 2.4.2 插入文字

文字工具二级菜单固定包含字体、字号、旋转、颜色四组，组间使用分隔线：

1. **字体**
   - 系统黑体：SF Pro，默认。
   - 系统衬线：New York/system serif。
   - 系统圆体：system rounded。
   - 系统等宽：SF Mono/system monospaced。
2. **字号**
   - 预设：14、18、24、32、48 pt。
   - 提供减号、当前数值和加号；范围 10–96 pt，每次调整 1 pt。
   - 默认 18 pt。
3. **旋转**
   - 预设：0°、45°、90°、180°。
   - 提供减号、当前角度和加号；范围为 -179° 至 180°，每次调整 1°，默认 0°。
   - 内部统一规范到 `(-180°, 180°]`；输入或拖动得到 -180° 时存为 180°。
   - 步进器循环而非钳制：180° 再加 1° 变为 -179°，-179° 再减 1° 变为 180°，保证物理旋转方向连续。
4. **颜色**
   - 依次显示第 2.3 节的六个预设色。
   - 最后一个色块为调色板入口。

没有选中文字对象时，菜单修改下一次插入使用的当前文字样式。选择工具选中已有文字时，选择按钮显示下拉指示并复用文字菜单；修改立即作用于对象、更新当前文字样式，并按字体、字号、旋转或颜色分别登记一个撤销步骤。选中多个对象不在本期范围内。

#### 2.4.3 马赛克

马赛克二级菜单只显示笔刷粗细，不显示颜色：

- 用三个实心圆展示细 12 pt、中 24 pt、粗 40 pt；默认中档 24 pt。
- 当前档位使用珊瑚色选中底和勾选标记。
- 像素块视觉尺寸固定为当前笔刷宽度的一半，即 6、12、20 pt。
- 修改只影响后续新画的马赛克笔画；已经完成的笔画保持原粗细，只能整体删除或撤销。
- 最后使用的马赛克粗细在当前应用运行周期内保持，不写入 `UserDefaults`。

### 2.5 图形与对象编辑

- 矩形和椭圆只绘制轮廓，不填充。
- 直线为无箭头直线；箭头为单箭头，箭头位于拖动终点。
- 图形描边提供细 2 pt、中 4 pt、粗 8 pt 三档，默认中档 4 pt；矩形、椭圆、直线和箭头共享当前描边粗细与颜色。
- 选择工具可选中一个矩形、椭圆、直线、箭头、文字对象或一整笔马赛克；重叠时从绘制顺序末尾向前命中最上层对象。旋转文字按其旋转后的四边形命中，不能只用未旋转的轴对齐 frame。
- 选中后支持拖动、缩放、Delete/Backspace 删除和改色。
- 上一条的拖动、缩放和改色只适用于矩形、椭圆、直线、箭头和文字；马赛克选中后只允许 Delete/Backspace 删除整笔。
- 矩形和椭圆显示边框及八个缩放控制点；边中点只调整单轴，角点可自由调整宽高。
- 直线和箭头显示起点、终点两个控制点。
- 文字显示随对象角度旋转的边框、左右两个宽度控制点、四个角点，以及距局部上边中点 24 pt 的旋转手柄。左右控制点沿文字局部 x 轴改变排版宽度并触发换行；角点在文字局部坐标内保持比例缩放边框并同步改变字号，不得拉伸字形位图；拖动旋转手柄围绕文字框中心旋转，按住 Shift 时吸附到 15° 增量。
- 创建、移动或缩放矩形、椭圆、直线、箭头和未旋转文字时，把操作结果限制在当前已应用裁剪矩形内且不允许翻转；之后应用更小的裁剪不得移动或删除既有对象，因此它们可以被新裁剪框部分或完全遮住。矩形和椭圆的最小显示宽高各为 6 pt；直线和箭头不使用宽高阈值，只要求两端欧氏距离至少 3 pt，因此允许完全水平或垂直。文字角点缩放仍受 10–96 pt 字号范围限制。旋转文字要求中心点留在当前裁剪矩形内，但旋转后的角点可以越界，越界内容在预览和输出中按裁剪矩形裁切；控制点仍可绘制在图片外的工作区并接受鼠标事件。
- 命中容差为当前窗口坐标中的 6 pt；马赛克按鼠标到折线路径的距离命中，阈值为半个画笔宽度再加 4 pt。
- 单击空白处取消选择。选择边框、控制点和辅助线不得进入导出图片。
- 鼠标按下到抬起视为一次操作；连续拖动只生成一个撤销记录。

交互阈值的单位换算锁定：模型与 reducer 只在源像素坐标系中比较，所有以“窗口 pt / 显示 pt”表达的交互阈值必须在视图适配层按事件发生时的当前显示变换换算为源像素后再进入 reducer；换算随窗口缩放或应用/扩大裁剪实时变化，不沿用冻结的 `initialPointsToImageScale`，也不使用 backing scale。记 `r` 为当前显示变换下“源像素 / 显示 pt”比例，换算如下：

- 命中容差：`6 pt → 6 × r`。
- 矩形/椭圆最小显示宽高：`6 pt → 6 × r`；直线/箭头最小长度：`3 pt → 3 × r`。
- 马赛克命中阈值：`0.5 × renderedBrushWidthInPixels + 4 × r`（即把显示中的笔刷半宽与 4 pt 容差一起换算回模型单位）。

普通编辑视图取 `appliedCropRect.width / 图片显示矩形宽度`，裁剪模式取 `originalPixelBounds.width / 完整源图显示矩形宽度`；二者长宽同比例，用宽度即可。鼠标按下到抬起使用手势开始时捕获的同一个 `r`，保证一次拖动内约束稳定。

### 2.6 文字输入

- 使用文字工具单击图片，在对应位置创建原位 `NSTextView` 编辑器。
- 初始文字框显示宽度为 `min(240 pt, 图片显示宽度)`，但图片显示宽度至少 80 pt 时不得小于 80 pt；点击位置右侧空间不足时把文字框向左移动，最终完整夹在图片内。初始高度为当前字体的一行 line height 加上下各 4 pt 内边距。
- 输入和左右控制点改变宽度后，使用与最终 renderer 相同的 TextKit 排版规则重新计算 intrinsic height。0° 文字保持局部上边不动并优先向下增长，触底时整体上移；非 0° 文字保持未旋转 frame 的中心和宽度不变，在局部 y 轴两侧均分高度变化，只把中心夹在裁剪矩形内，旋转后的越界部分允许裁切。若全部文本高度仍超过裁剪矩形可容纳的未旋转高度，则 frame 高度限制为该高度，编辑时允许内部滚动，导出时按裁剪矩形裁切超出内容。
- 排版规则落地为单一共享 helper：原位 `NSTextView` 的“宽度 → intrinsic height / 换行”估算与最终 renderer 必须调用同一个纯函数排版 helper（输入文字、字体设计、字号与局部 frame 宽度，输出排版高度与换行结果），不允许 `NSTextView` 与渲染器各维护一套规则；该 helper 不依赖窗口、显示变换或 backing scale。
- Return 插入换行；`Command+Return` 完成输入；Esc 取消本次新建或恢复编辑前文本。
- 文字编辑会话独立于 `NSTextView` 是否暂时为 first responder。打开文字样式 Popover 或其 `NSColorPanel` 属于焦点例外：控制器设置 `isHandlingTextStyleUI`，暂时抑制 `resignFirstResponder` 的自动提交，保留草稿、选区和插入点；菜单/面板结束后把 first responder 与选区还给原 `NSTextView`。只有点击画布或其他非文字样式控件、切换工具、保存、确认等真正离开文字编辑上下文的动作才按规则提交。
- Esc 严格按最内层界面逐级处理：若 `NSColorPanel` 打开，第一次 Esc 只回滚并关闭颜色事务，然后恢复文字样式 Popover 或原 `NSTextView`；否则若文字样式 Popover 打开，Esc 只关闭 Popover 并恢复原 `NSTextView`；否则若文字编辑器活动，Esc 取消本次新建或恢复编辑前文字；否则若裁剪草稿活动，Esc 丢弃草稿并退出裁剪模式；只有上述状态都不活动时，Esc 才取消整个截图会话。任一层处理后必须停止事件传播。
- 键盘事件路由锁定：Esc 的分层消费由 `EditorWindowController` 为当前编辑会话安装的单一 local event monitor 负责（仅监听 keyDown，Esc 使用系统虚拟键码 53），不交给 `NSView`、`NSTextView`、SwiftUI Popover 或 `NSColorPanel` 各自竞争；路由按上一条顺序逐层检查，只让最内层处理并直接消费事件，处理后不再进入普通 responder chain 或 SwiftUI 键盘动作。事件携带会话 UUID 与颜色事务 UUID；会话已替换或颜色事务已结束时，晚到 Esc 事件直接丢弃。文字样式 Popover / `NSColorPanel` 结束后的 first responder 与选区恢复由对应 Coordinator 在主线程回调完成，回到触发菜单或面板前的原 `NSTextView`。
- 失去焦点时提交非空文本；纯空白文本不创建对象。
- 双击已有文字重新进入内容编辑。
- 从文字二级菜单修改已有文字的字体或字号时，保持文字框当前宽度，立即使用最终 renderer 相同的 TextKit 规则重算 intrinsic height，并按上一条的 0°/非 0° 锚定规则调整 frame。一次菜单动作把旧 `TextStyle` 与旧 `frame` 作为同一份撤销快照，撤销时两者一起恢复；命中区域与最终渲染立即使用新 frame。
- 文字以未旋转的局部 `frame` 完成 TextKit 排版，再围绕 frame 中心旋转整个排版结果；旋转不得改变字号、换行、intrinsic height 或 frame。创建非 0° 文字时，用户点击位置仍是未旋转 frame 的左上角，完成初始布局后只把 frame 中心夹在裁剪矩形内，旋转角点允许被裁切。二级菜单预设/步进每次产生一个撤销步骤；旋转手柄一次按下至抬起合并为一个撤销步骤，并把最终角度同步为后续新文字的默认角度。
- 若原位 `NSTextView` 正在编辑，字体、字号、旋转或颜色菜单动作直接更新该编辑器和草稿对象；编辑器使用与对象相同的旋转变换，并保持插入点可见。每次预设选择、字号步进或角度步进各形成一个撤销步骤，系统调色板的连续事件仍按第 2.3 节合并为一次。空白新建文字最终取消时，一并丢弃其期间的样式/几何撤销记录，但保留已选样式作为后续文字的当前默认值。
- 提交文字前，保存、确认、切换工具等动作必须先结束当前输入；空白输入按取消处理。

### 2.7 马赛克

- 马赛克是自由绘制画笔，不是矩形选区。
- 画笔提供细 12 pt、中 24 pt、粗 40 pt 三档，默认中档 24 pt；对应像素块视觉尺寸固定为画笔宽度的一半，即 6、12、20 pt。
- 每次按下、拖动、抬起形成一条独立马赛克笔画和一个撤销步骤。
- 马赛克只处理原始截图内容，并始终位于矢量标注和文字下方，保证后加文字、箭头仍然清晰。
- 已完成的马赛克笔画不可移动、缩放或改色；只能撤销，或由选择工具命中后删除整笔。

### 2.8 二次裁剪

二次裁剪是编辑会话级、非破坏性的裁剪，不直接改写源 PNG：

- 会话保存 `originalPixelBounds` 和 `appliedCropRect`；初始 `appliedCropRect` 等于完整源图。草稿可以是浮点源像素坐标，应用时固定执行 `floor(minX/minY)` 与 `ceil(maxX/maxY)`，再与 `originalPixelBounds` 求交，确保用户框住的边缘像素不会被舍弃；得到的 `appliedCropRect` 必须是整数像素矩形。
- 点击裁剪按钮进入裁剪模式：画布暂时以完整源图为基准显示源图和全部既有标注，当前裁剪框内正常显示，框外的源图与标注一起覆盖 55% 暖石墨遮罩；裁剪框显示规则三分线、四角和四边共八个控制点，控制点点击目标至少 44×44 pt。裁剪模式只命中裁剪框、框内拖动区和八个控制点，既有标注不得被选择、移动、编辑或删除。
- 拖动框内移动裁剪框，拖动控制点自由改变宽高；不提供固定比例、比例预设或自动主体识别。裁剪框不得越过原图边界，最小尺寸为 32×32 源像素。
- 进入模式时建立独立 `draftCropRect`。Return、`Command+Return`、双击框内或再次点击已激活的裁剪按钮，会把草稿应用为新的 `appliedCropRect`；只有取整后确实发生变化时才递增 `contentRevision` 并产生一个撤销步骤，无变化时只退出裁剪模式。Esc 只丢弃草稿并恢复进入模式前的已应用裁剪，不取消整个截图会话。
- 切换到其他工具、进入 OCR、保存或确认时，先自动应用有效裁剪草稿；工具栏“取消”仍取消整个编辑会话，而不是只取消裁剪草稿。
- 裁剪草稿活动时，工具栏撤销与 `Command+Z` 的第一次操作都只丢弃草稿并退出裁剪模式，不弹出已提交撤销栈；此时撤销按钮的 accessibility label 临时改为“取消裁剪调整”。退出后再次撤销才回退上一项已提交操作。即使草稿尚未变化，第一次撤销也只退出裁剪模式。
- 再次进入裁剪模式时仍显示完整原图，因此可以扩大先前的裁剪范围。已存在标注继续保存在原始源图坐标中：完全或部分位于裁剪框外的内容不删除，只在普通编辑预览、命中测试、OCR 和最终输出时被裁切；扩大裁剪或撤销裁剪后可重新出现。
- 应用裁剪后，普通编辑模式只 aspect-fit 显示 `appliedCropRect`，所有坐标仍以原始源图左上角为原点。最终输出尺寸等于取整后的裁剪矩形像素宽高，渲染时把内容平移 `(-cropRect.minX, -cropRect.minY)`。
- 选择框、裁剪遮罩、三分线和控制点都是辅助层，不得进入保存或确认的 PNG。

### 2.9 OCR

OCR 工具整合现有两套本地能力：

- 进入 OCR 工具前先应用有效裁剪草稿，再把当前 `appliedCropRect`、马赛克和标注合成为裁剪后尺寸的临时图，使用 VisionKit 分析可选择文字。
- 分析成功后，允许在图片原位置拖选文字，通过右键或 `Command+C` 复制当前选区。
- OCR 工具的二级区域提供“复制全部文字”；点击后使用现有 Vision OCR 对同一张当前合成图识别并复制全文。
- 不在截图完成后自动执行 OCR。
- OCR 模式中暂停对象选择、绘制和文字输入，离开 OCR 模式后恢复。
- 任意图片编辑都会取消或使旧 OCR 请求失效，并清空当前合成版本的 OCR 缓存。
- OCR 必须针对已经裁剪且包含马赛克的合成图运行，不能识别裁剪框外或被遮挡区域。
- VisionKit 选区、状态提示和识别框都不得进入保存或确认的 PNG。
- 同一时间全应用最多运行一个 Vision 全文 OCR；另一项 OCR 正在运行时显示“请等待当前文字识别完成”，不得启动第二项。
- 如果最终合成版本已有成功的全文 OCR 结果，确认时把结果写入对应历史项缓存；否则历史项 OCR 状态为 `idle`。
- `OCRServing` 必须继续把空字符串和未发现文字视为 `OCRError.noText`，不存在“成功但空文本”的结果。无文字或失败只显示可重试状态：未修改历史图继续使用 `.preserve`，已修改历史图和新截图使用 `.clear`，不得用失败覆盖有效旧缓存。
- OCR 拖选视图的实现形态锁定为画布 overlay，不复用“整窗口预览”形态：Step 5 拆出的 `EditorOCRSelectionView` 内嵌 `ImageAnalysisOverlayView`，OCR 模式时在 `EditorCanvasView` 的 aspect-fit 图片矩形上显示当前合成图并接管鼠标/键盘命中；普通编辑模式或退出 OCR 模式后隐藏，其选区、识别框和状态提示不进入渲染器。OCR 模式期间画布标注层不接收命中；任何使当前合成版本失效的图片编辑都会立即隐藏 host、取消未完成分析并使请求代次失效。

### 2.10 撤销、保存、确认和取消

**撤销**覆盖：应用裁剪、新增对象、移动、缩放、删除、改色、描边粗细修改、文字内容修改、字体修改、字号修改、文字旋转以及每一笔马赛克。一次裁剪应用、一次旋转手柄拖动或一次离散角度菜单动作各生成一个撤销记录。工具切换、裁剪草稿变化、当前工具默认样式修改、OCR、复制、保存不进入撤销栈。本期不增加重做按钮。

**保存到桌面**：

- 提交当前文字输入并应用有效裁剪草稿后，按 `appliedCropRect` 的像素尺寸渲染当前合成图。
- 调用现有 `DesktopExportService`，继续使用无覆盖命名规则。
- 保存成功后窗口保持打开，不修改剪贴板和历史。
- 保存失败时窗口和全部编辑保持不变，可再次尝试。

**确认**：

- 提交当前文字输入并应用有效裁剪草稿后，按 `appliedCropRect` 的像素尺寸渲染最终 PNG。
- 历史编辑必须先在主 Actor 上确认目标 ID 仍存在；不存在时直接拒绝提交，不得先改剪贴板。
- 先写剪贴板，再写历史；只有剪贴板成功才允许修改历史并关闭窗口。
- 新截图确认后插入历史首位。
- 历史图片确认后保留原 `id`、`capturedAt` 和排序，只替换 `pngData`。
- 历史图片内容发生改变时清空旧 `recognizedText` 和 OCR 状态；可复用当前最终版本刚完成的 OCR 结果。
- 剪贴板失败时显示内联错误，保留编辑器并允许重试。

**取消**：

- 工具栏取消、所有内层交互均不活动时的 Esc 和关闭窗口完全等价。
- 新截图会话不写剪贴板、不加入历史。
- 历史编辑会话不修改原历史项。
- 即使此前“保存到桌面”成功，取消也只丢弃会话；已保存文件继续保留。

## 3. 内部数据结构与接口

在 `SnapClip/EditorModels.swift` 增加以下内部类型；名称可以按 Swift 风格微调，但职责和字段不得省略：

```swift
enum EditorTarget: Equatable, Sendable {
  case newCapture(capturedAt: Date)
  case historyItem(id: UUID, capturedAt: Date, sourceRevision: UInt64)
}

enum EditorTool: Equatable, Sendable {
  case selection, rectangle, ellipse, line, arrow, text, mosaic, crop, ocr
}

enum EditorFontDesign: String, CaseIterable, Equatable, Sendable {
  case system, serif, rounded, monospaced
}

struct RGBAColor: Equatable, Sendable {
  var red: Double
  var green: Double
  var blue: Double
  var alpha: Double
}

struct StrokeStyleDefaults: Equatable, Sendable {
  var nominalLineWidth: CGFloat
  var color: RGBAColor
}

struct StrokeStyle: Equatable, Sendable {
  var nominalLineWidth: CGFloat
  var renderedLineWidthInPixels: CGFloat
  var color: RGBAColor
}

struct TextStyleDefaults: Equatable, Sendable {
  var fontDesign: EditorFontDesign
  var nominalFontSize: CGFloat
  var rotationDegrees: Double
  var color: RGBAColor
}

struct TextStyle: Equatable, Sendable {
  var fontDesign: EditorFontDesign
  var nominalFontSize: CGFloat
  var renderedFontSizeInPixels: CGFloat
  var rotationDegrees: Double
  var color: RGBAColor
}

struct MosaicStyleDefaults: Equatable, Sendable {
  var nominalBrushWidth: CGFloat
}

struct MosaicStyle: Equatable, Sendable {
  var nominalBrushWidth: CGFloat
  var renderedBrushWidthInPixels: CGFloat
  var renderedPixelScaleInPixels: CGFloat
}

struct CropState: Equatable, Sendable {
  let originalPixelBounds: CGRect
  var appliedCropRect: CGRect
  var draftCropRect: CGRect?
}

enum OCRCacheDisposition: Equatable, Sendable {
  case preserve
  case clear
  case replace(String)
}

struct EditorOutput: Equatable, Sendable {
  let target: EditorTarget
  let pngData: Data
  let contentChanged: Bool
  let ocrCache: OCRCacheDisposition
}
```

标注模型必须满足：

- 每个对象有稳定 UUID。
- 几何数据保存在原图坐标系中，不保存窗口坐标。
- 窗口缩放只改变显示变换，不修改对象几何。
- 颜色使用 `RGBAColor`，不要在 Sendable 模型中直接存 `NSColor`。
- 文字对象保存字符串、字体设计、实际字号、规范化旋转角度、颜色和未旋转的局部布局矩形。
- 马赛克保存原图坐标系中的采样点、画笔宽度和像素块尺寸。
- 裁剪不是 `EditorAnnotation`；会话单独保存 `CropState`，从而允许扩大裁剪或撤销后恢复框外标注。
- `EditorAnnotation` 是带稳定顺序的枚举，至少包含以下 payload：

```swift
enum EditorAnnotation: Identifiable, Equatable, Sendable {
  case rectangle(ShapeAnnotation)
  case ellipse(ShapeAnnotation)
  case line(LineAnnotation)
  case arrow(LineAnnotation)
  case text(TextAnnotation)
  case mosaic(MosaicAnnotation)
}

struct ShapeAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var rect: CGRect
  var style: StrokeStyle
}

struct LineAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var start: CGPoint
  var end: CGPoint
  var style: StrokeStyle
}

struct TextAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var text: String
  var frame: CGRect
  var style: TextStyle
}

struct MosaicAnnotation: Identifiable, Equatable, Sendable {
  let id: UUID
  var points: [CGPoint]
  var style: MosaicStyle
}
```

所有 `CGPoint`、`CGRect`、裁剪矩形、`renderedLineWidthInPixels`、`renderedFontSizeInPixels`、`renderedBrushWidthInPixels` 和 `renderedPixelScaleInPixels` 统一使用“原始源图片像素坐标系”：左上角为 `(0, 0)`，x 向右、y 向下；应用裁剪后不得把已有几何改写为裁剪后局部坐标。`nominalLineWidth`、`nominalFontSize` 和 `nominalBrushWidth` 只用于二级菜单显示与档位/范围约束。AppKit 左下原点只存在于视图适配层，进入模型前必须转换；ImageIO 以 `.up` 方向解码并标准化，渲染时再完成 Core Graphics y 轴翻转和平移裁剪原点。

会话首次以完整源图布局后计算并冻结 `initialPointsToImageScale = sourcePixelWidth / fullSourceAspectFitRect.width`。当前选中的 2/4/8 pt 线宽、10–96 pt 字号、12/24/40 pt 画笔及其 6/12/20 pt 像素块等 UI 数值，在创建或修改对象时乘以该固定比例后写入对应像素字段，并同时保留名义 pt 值。窗口缩放或应用/扩大裁剪时只改变显示变换，不重算该比例、模型样式或对象几何；普通编辑视图使用 `appliedCropRect` 到当前 aspect-fit 矩形的变换，裁剪模式改用完整源图到 aspect-fit 矩形的变换。文字角点缩放同时按比例修改名义 pt 和像素字号，最后把名义值限制在 10–96 pt。Retina backing scale 不参与该换算，因为 `NSView` 事件和布局本身已经使用 point；测试必须覆盖 1×/2× backing scale 下相同结果。

两类 pt 换算不得混用：`initialPointsToImageScale` 只负责描边/字号/笔刷等“名义样式参数”在输出像素中的不变性，不负责命中容差、最小尺寸与越界约束；后一类按第 2.5 节的当前显示变换实时换算。文字框初始宽高、行高上下 4 pt 内边距等持久内容几何在创建或编辑时按事件当时的显示变换落为源像素，此后窗口再缩放不改写已存模型；旋转手柄、选择框等纯视图辅助控件不进入模型，由视图按当前显示变换实时绘制。

增加一个仅在主线程使用的 `EditorToolStyleStore`。它跨编辑会话只持有不依赖图片的 `StrokeStyleDefaults`（默认 4 pt、珊瑚色）、`TextStyleDefaults`（默认系统黑体、18 pt、0°、珊瑚色）、`MosaicStyleDefaults`（默认 24 pt）以及图形/文字各自最近一次有效自定义颜色；绝不保存或复用任何 `rendered...InPixels` 值，也不写入 `UserDefaults`。

每个编辑会话使用自己的 `initialPointsToImageScale`：新建对象时，把 defaults 的名义值乘以本会话比例，生成完整 `StrokeStyle`、`TextStyle` 或 `MosaicStyle` 快照；修改已有对象样式时，也使用该对象所属会话的比例重新派生像素字段。马赛克像素块名义尺寸始终为名义画笔宽度的一半。后续修改 defaults 不得反向改变已有对象。

编辑会话维护单调递增的 `contentRevision: UInt64`：应用裁剪、新增、移动、缩放、删除、改色、描边粗细改变、文字内容/字体/字号/角度改变和马赛克内容改变都会递增；工具切换、未应用的裁剪草稿、选择变化、仅修改下一对象所用的默认样式、OCR、复制和保存不会递增。全文 OCR 结果必须与产生它的 revision 一起保存，只有 revision 仍相等时才可进入 `EditorOutput`。

增加以下可测试边界：

```swift
protocol ScreenshotRendering: Sendable {
  func render(
    sourcePNG: Data,
    cropRect: CGRect,
    annotations: [EditorAnnotation]
  ) async throws -> Data
}

@MainActor
protocol ScreenshotEditing: AnyObject {
  var isPresenting: Bool { get }
  func presentNewCapture(pngData: Data, capturedAt: Date) throws
  func presentHistoryItem(_ item: ScreenshotItem) throws
  func discardActiveSession()
  func focus()
}
```

渲染责任必须保持唯一：`EditorWindowController` 持有并调用注入的 `ScreenshotRendering`。保存和确认时由控制器先快照已应用的整数像素 `cropRect` 与 annotations，再异步渲染；确认渲染完成后再把已经包含最终 PNG 的 `EditorOutput` 交给 `AppModel`，`AppModel` 不再次渲染。

控制器使用以下 delegate 契约；它是确认能否关闭窗口的唯一依据：

```swift
enum EditorCommitResult: Equatable {
  case accepted
  case rejected(message: String)
}

@MainActor
protocol EditorSessionDelegate: AnyObject {
  func editorDidBeginSession()
  func editorDidCancelSession()
  func editorDidRequestCommit(_ output: EditorOutput) -> EditorCommitResult
}
```

- 控制器收到 `.accepted` 后才清空会话并关闭窗口。
- 收到 `.rejected` 时显示消息并保留会话。
- `EditorSessionState?` 是“是否正在编辑”的唯一真源；`ScreenshotEditing.isPresenting` 从它计算。`AppModel.isEditing` 只由 begin/cancel/accepted 生命周期回调更新，作为菜单 UI 的发布镜像，不得反向驱动控制器。
- `presentNewCapture` 和 `presentHistoryItem` 只允许抛出 `EditorPresentationError.invalidImage` 或 `.windowUnavailable`。失败时控制器不得建立半成品会话，`AppModel` 恢复到非编辑状态并显示错误。
- 控制器注入 `ScreenshotRendering`、`DesktopExportServing`、`ClipboardServing`、现有 `LiveTextAnalyzing` 和共享的全文 OCR gate；其中剪贴板、桌面保存和 OCR 必须与 `AppModel` 使用同一服务实例，测试使用 stub/spy 替代真实服务。
- 共享全文 OCR gate 包装唯一的 `OCRServing` 调用，提供忙碌拒绝和请求 UUID。菜单历史 OCR 与编辑器全文 OCR 必须使用同一个实例。复用仓库现有 `ClipboardServing`、`DesktopExportServing`、`OCRServing` 和 `LiveTextAnalyzing` 签名，不另建重复协议；只新增下列 gate：

```swift
actor OCRExecutionGate {
  func recognize(requestID: UUID, pngData: Data) async throws -> String
  func cancel(requestID: UUID) async
}

enum OCRExecutionError: LocalizedError, Equatable {
  case busy
}
```

`cancel(requestID:)` 只标记对应请求取消并向底层 Task 发送取消；即使调用方已不再等待，gate 仍保持 busy，直到底层 Vision 调用真实返回或抛错后才释放槽位。因此物理上始终最多一个 Vision 全文请求。非当前请求的取消不得影响正在执行的 OCR。调用方仍使用会话 UUID、请求 UUID 和 `contentRevision` 三重校验决定结果是否可见。

菜单历史 OCR 与编辑器全文 OCR 共用同一个注入的 gate；`AppModel` 不得再保留第二套直接调用 `OCRServing` 的路径或自持忙碌锁（现有 `recognizingItemID`/`ocrTask` 在 Step 6 拆除），菜单“识别中”与编辑器的“请等待当前文字识别完成”提示由 gate 生命周期发布镜像驱动。

`ScreenshotItem` 增加 `imageRevision: UInt64`，新项目从 0 开始，只在 PNG 内容真正替换时递增。`HistoryStore` 增加编辑提交接口：

```swift
func commitEditorOutput(
  id: UUID,
  expectedImageRevision: UInt64,
  pngData: Data,
  contentChanged: Bool,
  ocrCache: OCRCacheDisposition
) -> Bool
```

返回 `false` 表示目标历史项已不存在或 `imageRevision` 已变化。成功时保持 ID、时间和数组位置：

- `contentChanged == false`：保留原始 `pngData` 和 `imageRevision`，只应用 OCR cache disposition；控制器不得重新编码图片，`EditorOutput.pngData` 直接复用源 PNG。
- `contentChanged == true`：替换 `pngData` 并把 `imageRevision` 加 1；此时 `.preserve` 非法，只能 `.clear` 或 `.replace(text)`。
- `.preserve` 保留旧结果与状态，`.clear` 清空结果并置为 `idle`，`.replace(text)` 保存非空结果并置为 `completed`。新截图不能使用 `.preserve`。

历史编辑会话分别记录历史项的 `sourceRevision` 和会话内容的 `contentRevision = 0`。未产生任何内容修改且没有新的全文 OCR 时输出 `contentChanged: false` 与 `.preserve`；内容有修改但当前 content revision 没有成功 OCR 时输出 `contentChanged: true` 与 `.clear`；当前 revision 有成功且非空的 OCR 时输出 `.replace(text)`。这样未修改历史图直接确认不会重编码图片或丢失旧缓存。

所有历史 OCR 写回也必须携带开始时的 `expectedImageRevision`。把现有方法调整为 `markRecognizing(id:expectedImageRevision:) -> Bool`、`storeRecognizedText(_:id:expectedImageRevision:) -> Bool` 和 `markOCRFailed(_:id:expectedImageRevision:) -> Bool`；只有 ID 与图片版本都匹配时才可修改项目。图片被编辑提交后，旧 OCR 的晚到结果必须静默丢弃。

## 4. 文件级实施步骤

严格按以下顺序执行，每一步完成后先编译再进入下一步。

若按自然顺序执行，Step 5 第 1–2 项（旧预览能力拆分）须先于 Step 3 的 OCR overlay host 完成；实施时可以先完成这两项拆分（编译通过），再按 Step 1–4 继续，避免在画布阶段才回退处理旧文件。Step 5 其余窗口升级工作仍放在工具栏稳定后。

### Step 1：建立编辑模型和纯逻辑

1. 新建 `SnapClip/EditorModels.swift`。
2. 实现工具、目标、颜色、`StrokeStyle`、带旋转角度的 `TextStyle`、`MosaicStyle`、`CropState`、`EditorToolStyleStore`、标注模型、选择状态和撤销记录。
3. 抽出可测试的 `EditorInteractionReducer`：鼠标和键盘先转换为纯输入事件，再由 reducer 更新草稿、标注、选择和撤销；`NSView` 不直接拥有业务状态机。
4. 实现左上原点原始源像素坐标与“普通编辑裁剪区/裁剪模式完整源图”两套 aspect-fit/AppKit 显示矩形之间的双向转换，并冻结会话的 `initialPointsToImageScale`。
5. 实现旋转文字的逆变换命中、逆序命中、控制点计算、边界夹取、不翻转和最小尺寸约束；6 pt 类显示阈值由视图适配层按第 2.5 节换算成源像素后传入，reducer 内部只使用源像素单位。
6. 按第 2.5 节分别实现矩形/椭圆 6 pt 显示宽高阈值与线/箭头 3 pt 欧氏长度阈值（均以换算后的源像素执行）。
7. 实现裁剪框移动/八点缩放/整数像素取整，以及文字角度规范化、Shift 15° 吸附和旋转手柄单事务 reducer。
8. 添加纯逻辑单元测试后编译。

### Step 2：实现最终图片渲染器

1. 新建 `SnapClip/ScreenshotRenderer.swift`，实现 `ScreenshotRendering`。
2. 使用 ImageIO 解码原始 PNG、规范为 `.up` 方向并取得准确像素尺寸。
3. 在后台任务中创建与整数像素 `cropRect` 宽高相同的 sRGB RGBA 位图上下文；渲染输入只含源图、已应用裁剪矩形与内容标注，不接受选择框、裁剪辅助层、控制点或 OCR overlay。
4. 将上下文平移到裁剪原点，先绘制源图的裁剪区域；任何绘制都裁切在 `cropRect` 内。
5. 使用 `CIPixellate` 生成原图像素化版本，只通过马赛克笔画构成的 mask 混合回底图。
6. 按对象顺序绘制矩形、椭圆、直线、箭头和文字；文字先用第 2.6 节锁定的共享排版 helper 在局部 frame 排版，再围绕 frame 中心旋转整个绘制上下文。
7. 使用 ImageIO 编码 PNG；不得改变宽高、裁切或输出 JPEG。
8. 添加裁剪输出尺寸/原点平移、三档描边、颜色、箭头、旋转文字和三档马赛克渲染测试后编译；使用固定 sRGB fixture 和容差断言，不对系统字体做逐像素快照。
9. 添加共享排版 helper 测试：同一文本/宽度输入下，原位编辑估算与 renderer 使用同一 helper，intrinsic height 与换行结果一致。

### Step 3：实现编辑画布

1. 新建 `SnapClip/EditorCanvasView.swift`，使用 AppKit `NSView` 处理高频鼠标事件和绘制。
2. 画布只在 aspect-fit 图片矩形内接受绘制；图片外拖动不得创建标注。
3. 实现每个工具的鼠标按下、拖动、抬起状态机。
4. 实现选择、命中测试、控制点拖动、文字旋转手柄、Delete/Backspace 和双击文字。
5. 嵌入原位 `NSTextView`，按第 2.6 节处理提交与取消。
6. 实现第 2.8 节的完整源图裁剪遮罩、三分线、八个控制点、移动/缩放、应用/取消和重新扩大裁剪。
7. 在预览层绘制马赛克效果；最终结果仍以渲染器为准。
8. 确保选择、旋转和裁剪辅助层不参与最终渲染。
9. 为 OCR 模式在图片矩形上挂载第 2.9 节锁定的 `EditorOCRSelectionView` overlay host；OCR 时 host 接管命中、右键与 `Command+C`，其他模式隐藏且不进入命中或渲染。

### Step 4：实现工具栏和各工具二级菜单

1. 新建 `SnapClip/EditorToolbarView.swift`，用 SwiftUI 实现底部悬浮栏。
2. 按第 2.2 节固定顺序放置按钮和分隔线。
3. 实现 `StrokeStylePopover`：左侧三档 2/4/8 pt 粗细，右侧六个预设色与一个调色板色块；矩形、椭圆、直线和箭头复用同一实例与共享样式状态。
4. 实现 `TextStylePopover`：四种字体、14/18/24/32/48 pt 字号、0/45/90/180° 角度预设、字号与角度步进器、六个预设色与一个调色板色块。
5. 实现 `MosaicStylePopover`：只显示 12/24/40 pt 三档笔刷粗细，并由档位派生 6/12/20 pt 像素块尺寸。
6. 实现第 2.4 节规定的首次选工具自动打开、画布点击关闭、再次点击当前工具重开、切换工具换菜单，以及修改选项后保持打开。
7. 使用选择工具选中已有图形或文字时，Popover 读取对象当前样式；修改后立即更新对象与对应当前样式，并登记撤销。马赛克样式修改只影响新笔画。裁剪按钮无下拉指示，激活时再次点击执行应用裁剪。
8. 使用主线程 `ColorPanelCoordinator` 和 `NSColorPanel` 实现最后一个调色板色块，严格按第 2.3 节冻结目标、实时预览、合并撤销、Esc 回滚、sRGB 转换及会话/事务 UUID 校验。
9. 为工具按钮、下拉指示、粗细档位、色块、调色板入口、字体、字号、旋转角度、裁剪应用状态和确认/取消添加明确 accessibility label、help、选中状态和禁用状态。
10. 添加工具栏状态测试后编译。

### Step 5：把现有预览窗口升级为编辑窗口

第 1–2 项（旧预览能力拆分）必须先于 Step 3 的 OCR overlay host 完成；第 3 项以后在工具栏稳定后实施。

1. 新建 `SnapClip/LiveTextAnalysis.swift`：把 `PreviewWindowController.swift` 中的 `LiveTextAnalyzing`、`VisionKitLiveTextAnalyzer` 与请求代次门迁入，代次门可命名为 `EditorOCRRequestGate`（或保持原名，但语义只服务编辑会话）；编辑器全文 OCR 与 OCR 拖选分析共用这些类型。
2. 新建 `SnapClip/EditorOCRSelectionView.swift`：把 `SelectableImagePreviewView` 中承载 `ImageAnalysisOverlayView` 的部分迁移/重写为可在 `EditorCanvasView` 图片矩形上叠加的 host；它只负责“把给定合成图交给 VisionKit、拖选文字并支持右键/`Command+C` 复制”，不再承载窗口、标题、整屏预览或长期状态提示职责；状态提示改由编辑器内联状态层呈现。
3. 新建 `SnapClip/EditorWindowController.swift`：用 `NSHostingView` 承载 SwiftUI 工具栏，用 `EditorCanvasView` 承载图片与标注，并按第 2.6 节安装会话唯一的 Esc event monitor、按第 2.9 节挂载 OCR overlay host。
4. 设置透明标题栏、工作区背景、窗口尺寸、单窗口复用和关闭代理。
5. 实现裁剪模式切换、OCR 模式切换、全文 OCR、内联状态、保存、确认与取消。
6. 切换图片、关闭窗口或内容 `contentRevision` 变化时，取消 VisionKit 分析与全文 OCR、清除选择与 OCR overlay、使请求代次失效并释放位图。
7. 新控制器与历史卡片“编辑”入口替换测试通过后，才删除旧 `PreviewWindowController.swift`，并从 `SnapClip.xcodeproj` 移除其文件引用；不得保留两套预览窗口路径，也不得因删除动作带走 `LiveTextAnalyzing`、请求代次门或 OCR overlay host。

### Step 6：改造 AppModel 和历史事务

1. 将 `ScreenshotItem.pngData` 从 `let` 改为 `var`，增加 `imageRevision`，并在 `HistoryStore` 增加 `commitEditorOutput` 及带 expected revision 的 OCR 更新方法；不得重新创建项目来模拟替换。
2. 在 `AppModel.swift` 增加 `isEditing`，注入 `ScreenshotEditing` 与共享 `OCRExecutionGate`；渲染器只注入编辑控制器，不注入 `AppModel`。
3. 修改 `capture(_:)`：截图成功后不再立即调用剪贴板或 `history.insert`，而是创建新编辑会话。
4. 收到新的截图触发意图且编辑器已打开时先 `discardActiveSession()`，再启动系统截图；取消或失败不恢复旧会话。
5. 实现确认 delegate：控制器已经完成渲染，`AppModel` 只执行“剪贴板 → 插入/替换历史”，成功返回 `.accepted`，失败返回 `.rejected`。
6. 实现剪贴板失败时保留窗口和编辑状态。
7. 历史项目确认替换前再次按 ID 查询；若已被清空或淘汰，则不复活旧项目，保留编辑窗口并提示“原历史截图已不存在”。
8. 菜单历史 OCR 启动时捕获 `imageRevision`，所有完成和失败写回都携带该版本；版本不匹配时静默丢弃。
9. `shutdown()` 必须取消编辑器 OCR/保存任务并关闭会话。
10. 拆除 `AppModel` 的第二个全文 OCR 入口：`copyRecognizedText` 不再自持 `recognizingItemID`/`ocrTask` 或直接调用 `ocrService`，改经与编辑器同一个 `OCRExecutionGate` 发起；“识别中”忙碌与禁用状态改由 gate 生命周期镜像驱动，历史写回仍按第 8 条携带 `imageRevision`。

### Step 7：调整菜单栏入口与状态

1. 将历史卡片“打开”改为调用编辑器入口，按钮标题改为“编辑”，图标使用合适的 SF Symbol。
2. 编辑期间状态显示“正在编辑截图”。
3. 编辑期间允许截图按钮继续响应，因为其语义是丢弃当前会话并重截。
4. 编辑期间禁止清空历史和启动另一个历史 OCR，避免目标消失或重复 OCR；已有 OCR 可结束，但编辑器全文 OCR 必须服从全局忙碌门。历史卡片的“识别中/忙碌/禁用”状态改由共享 `OCRExecutionGate` 的镜像驱动，不再读取 `AppModel.recognizingItemID`。
5. 保留历史缩略图点击复制、历史“复制文字”和“保存”能力。

### Step 8：更新工程配置和文档

1. `SnapClip.xcodeproj` 是第 8 节构建门槛唯一权威配置：新增 App 源文件（`EditorModels.swift`、`ScreenshotRenderer.swift`、`EditorCanvasView.swift`、`EditorToolbarView.swift`、`LiveTextAnalysis.swift`、`EditorOCRSelectionView.swift`、`EditorWindowController.swift`）要同时加入 `SnapClip` 组的 PBXFileReference 与该 target 的 Sources build phase；新增测试文件加入 `SnapClipTests` target 的对应两处；删除 `PreviewWindowController.swift` 时同步移除其文件引用与 build phase 条目。每步编译失败先查工程接线，再查 Swift 错误。
2. `Package.swift` 不参与本文档列出的 `xcodebuild -project` 门槛，不为 CoreImage 显式链接也可通过编译（Swift autolink 系统框架），因此不把 Package.swift 修改列为验收条件。若额外维护 SwiftPM 构建，仅需同步新增源文件自动纳入的目录结构与必要的 linkerSettings，不得把 SPM 产物当作本阶段唯一构建证明。
3. 更新 `docs/PRD.md`：删除“截图标注、马赛克”为非目标，加入编辑事务、二次裁剪、文字旋转、其他工具、OCR 和异常边界。
4. 更新 `README.md` 的核心流程、功能列表和技术结构。
5. 更新 `docs/brand-spec.md`：增加编辑窗口规范、悬浮栏和“标注颜色不属于界面色”的例外。
6. 对本次新建或实质更新的 Markdown 文件，按全局 `AGENTS.md` 检查并创建 Obsidian 绝对符号链接；不得使用 `ln -sf`，目标冲突时停止并报告。

## 5. 错误与并发规则

- 截图进程、最终渲染、全文 OCR 和桌面写入不得阻塞主线程。
- 同时最多一个截图进程、一个编辑会话、一个 Vision 全文 OCR 和一个桌面保存任务。
- 保存渲染期间禁用重复保存、确认和取消，但仍允许继续编辑；保存使用触发时的裁剪矩形与 annotations 快照，所以后续裁剪、旋转或其他编辑不会进入该次文件。确认一经触发则提交文字输入、应用有效裁剪草稿并冻结画布、工具、颜色、OCR、保存、确认和取消，直到成功关闭或失败后整体解冻，确保不会提交旧快照。新的全局截图快捷键仍可替换会话，此时取消旧任务并用会话 UUID 丢弃晚到结果。
- 开始确认时取消当前会话的 VisionKit 和全文 OCR，不等待它们完成；只有已经完成且 revision 匹配的全文结果才能写入缓存。
- 保存与 OCR 可以并行，因为二者都使用触发时的不可变内容快照；保存期间确认按钮禁用，OCR 完成后仍需通过 revision 校验。
- 保存失败、渲染失败、OCR 失败和剪贴板失败都不得清空编辑状态。
- 关闭或替换会话时，晚到的渲染、保存或 OCR 结果必须通过会话 UUID/请求代次被丢弃。
- 新截图替换旧编辑会话时，如果旧会话有保存任务，取消任务并忽略晚到结果；已经原子落盘的文件不删除。
- 自定义颜色面板按第 2.3 节执行单事务语义：关闭提交最后有效颜色，Esc 回滚事务前颜色，无效或无法转换为 sRGB 的事件不改变状态。
- 任意导出仍必须是有效 PNG，并提供 PNG 与可生成时的 TIFF 剪贴板表示。

## 6. 自动化测试清单

### 6.1 编辑模型

- aspect-fit 坐标正反转换。
- 左上原点源像素坐标、AppKit 左下原点和 1×/2× backing scale 的转换结果一致。
- 显示 pt 类交互阈值（6/3 pt 约束、马赛克 +4 pt 命中）按当前显示变换实时换算成源像素；窗口缩放或应用/扩大裁剪后换算随之变化，不沿用冻结的 `initialPointsToImageScale`。
- 图片外绘制不创建对象。
- 裁剪框移动和八点缩放不越过源图，最小为 32×32 源像素，应用时得到整数像素 rect；Esc 恢复进入模式前的 rect，Return/双击/再次点裁剪按钮只生成一个撤销步骤。裁剪草稿活动时第一次撤销只退出裁剪模式，第二次才弹出已提交撤销栈。
- 应用裁剪后普通编辑使用裁剪区变换，重新进入裁剪使用完整源图变换；扩大或撤销裁剪能恢复此前位于框外的标注。
- 矩形/椭圆按 6 pt 宽高阈值，线/箭头按 3 pt 欧氏长度阈值；水平线和垂直线可提交。
- 矩形、椭圆、线、箭头和旋转文字的命中测试。
- 移动、八点缩放、线端点调整、文字按比例改字号和局部坐标缩放。
- 图形的 2/4/8 pt 三档粗细、六个预设色和自定义 RGBA 改色；四种图形工具共享当前描边样式。
- 选中已有图形后修改粗细或颜色立即更新对象，并各自产生一个撤销步骤。
- 文字的四种字体、14/18/24/32/48 pt 预设、10–96 pt 字号边界、0/45/90/180° 角度预设、-179° 至 180° 角度循环步进（180° + 1° = -179°，-179° - 1° = 180°）、六个预设色和自定义 RGBA。
- 选中已有文字后，字体、字号、旋转、颜色修改各自产生一个撤销步骤；旋转拖动连续事件只合并为一个步骤，Shift 吸附 15°。
- 修改已有文字的字体或字号后保持原宽度、重算高度并按底边规则上移/裁切；一次撤销同时恢复旧 style 和旧 frame。
- 马赛克 12/24/40 pt 三档笔刷分别派生 6/12/20 pt 像素块；切换档位只影响后续新笔画。
- 跨会话样式仓库只复用名义值；相同 4 pt/18 pt/24 pt 默认值在两个不同 `initialPointsToImageScale` 的会话中分别生成正确像素字段，不复用上一会话数值。
- 马赛克单笔撤销和整笔删除。
- 连续拖动只产生一个撤销步骤。
- 文字编辑中打开样式 Popover 或 `NSColorPanel` 不触发失焦提交，关闭后恢复原插入点和选区。
- Esc 按“颜色事务 → 文字样式 Popover → 文字编辑 → 裁剪草稿 → 整个会话”逐层消费，每次只关闭当前最内层且不向外传播。
- 文字框初始宽高、靠近右边界时左移、自动增高、触底上移和超高裁切符合第 2.6 节。
- 原位 `NSTextView` 与最终 renderer 对同一文本/宽度输入使用同一共享排版 helper，intrinsic height 与换行结果一致。

### 6.2 渲染

- 输出 PNG 能被 ImageIO 解码。
- 未裁剪时输出像素宽高与输入严格相等；裁剪后输出宽高与整数像素 `cropRect` 严格相等，首尾像素对应正确源图坐标。
- 六个预设色在避开抗锯齿边缘的实心采样点按每通道 1 个值的容差写入 sRGB。
- 图形的 2/4/8 pt 三档描边、单箭头和 0/45/90/180° 多行文字可渲染；旋转中心与裁切正确。四种字体只断言字体 descriptor 设计映射正确、绘制包围盒非空，不做跨系统逐像素快照。
- 使用固定 sRGB fixture；12/24/40 pt 三档马赛克的 mask 核心区域与原图不同，像素块尺寸分别正确，远离抗锯齿边缘的区域外像素在每通道 1 个值的容差内保持一致。
- 马赛克在矢量标注下方。
- 渲染请求只接受源图、裁剪矩形与内容标注，接口层面不能传入选择框、旋转手柄、裁剪遮罩/三分线/控制点或 OCR 覆盖层。

### 6.3 AppModel 与历史

- 截图成功后只打开编辑器，不写剪贴板和历史。
- 使用可注入的 clipboard/history spy 记录调用序列，断言新截图确认后先复制再插入历史。
- 剪贴板失败时不插入历史且编辑器保持打开。
- 新截图取消后剪贴板和历史不变。
- 编辑中重截会丢弃旧会话。
- 历史编辑确认保留 ID、时间和排序。
- 未修改历史图直接确认使用 `.preserve`；修改后无 OCR 使用 `.clear`；当前 revision OCR 成功使用 `.replace`。
- 历史编辑取消不改变原项目。
- 历史项目消失后确认不会复活项目。
- 历史图片替换后 `imageRevision` 加 1，旧版本 OCR 的成功或失败回写均被拒绝。
- 内容改变后旧 OCR 缓存被清空；当前最终版本缓存可复用。
- 菜单历史 OCR 必须通过注入的 `OCRExecutionGate` 发起；使用 gate spy 断言 AppModel 不存在绕过 gate 直接调用 `OCRServing` 的路径。
- 保存到桌面不提交、不关闭、不改历史。
- 裁剪或文字旋转会令 `contentChanged` 为 true、递增 revision，并使旧 OCR 缓存失效；只进入又取消裁剪模式不算内容变化。

### 6.4 OCR 与请求隔离

- OCR 只在用户进入 OCR 或点击复制全文时运行。
- OCR 输入是当前裁剪后的合成图而不是完整原图。
- 编辑后旧分析失效。
- 切换、取消和关闭后晚到结果不会覆盖新会话。
- 全局 OCR 忙碌时不启动第二个 Vision 请求。
- 菜单历史 OCR 与编辑器全文 OCR 走同一个 `OCRExecutionGate`；应用代码中不存在第二条直接调用 `OCRServing` 的路径。
- gate 收到取消后在底层请求真实结束前仍保持 busy。
- 确认时取消未完成 OCR；保存与 OCR 并行时分别使用各自触发时的不可变 revision 快照。
- 无文字和识别失败不修改剪贴板。

### 6.5 控制器集成

- `presentNewCapture` 和 `presentHistoryItem` 解码失败时不建立会话并返回明确错误。
- delegate 返回 `.rejected` 时窗口保持打开，返回 `.accepted` 时才关闭。
- 关闭、切图和重截都会取消任务并拒绝旧会话晚到结果。
- 保存、确认和 OCR 分别使用触发时不可变的 crop rect、annotation snapshot 与 revision。
- 确认渲染期间画布和全部编辑控件冻结；失败后解冻，成功后关闭。
- Esc 事件只经编辑会话的单一 local event monitor 分发并逐层消费；晚到的旧会话/旧颜色事务 Esc 被 UUID 丢弃，不产生双重处理。
- 首次选择矩形、椭圆、直线、箭头、文字或马赛克时自动打开正确二级菜单；点击画布关闭但不切换工具，再点当前工具可重开，切换工具会替换菜单。裁剪按钮直接进入模式且不打开菜单。
- 图形菜单固定为左侧 2/4/8 pt 粗细、右侧六个预设色和调色板入口；文字菜单包含字体、字号、旋转和颜色；马赛克菜单只包含 12/24/40 pt 笔刷粗细。
- 修改菜单选项后 Popover 保持打开；点击调色板入口打开 `NSColorPanel`，连续有效 sRGB 事件实时预览但只合并成一个撤销步骤，Esc 回滚，关闭提交，转换失败保留最后有效颜色。
- 调色板打开后切换工具或对象会先提交冻结目标再开启新上下文；旧会话或旧颜色事务的晚到事件不会修改当前对象。
- 选择已有图形或文字时，选择按钮能打开对应上下文菜单并显示对象当前值；文字的旋转边框、手柄和角度值同步，各控件的 accessibility label、help 和选中状态可查询。
- 裁剪模式显示完整源图与全部标注，框外统一变暗，且只命中裁剪交互层；遮罩、三分线、八个控制点、移动、应用、Esc/撤销取消、自动应用和再次扩大流程正确，辅助层不进入 renderer。
- OCR 模式中 `EditorOCRSelectionView` 只存在于 aspect-fit 图片矩形上并接管鼠标/键盘与复制；非 OCR 模式隐藏，不进入命中或渲染。
- SwiftUI 工具栏状态、AppKit 画布状态和 `AppModel.isEditing` 的生命周期镜像保持一致。
- 选择框、旋转手柄、裁剪遮罩/三分线/控制点、活动 `NSTextView` 和 VisionKit overlay 只存在于视图树，不参与 `ScreenshotRendering` 请求。

## 7. 人工验收清单

在签名稳定的本机 Xcode 构建中逐项验证：

1. `Shift+Command+4` 选区和窗口截图完成后自动出现编辑器。
2. `Shift+Command+3` 主显示器截图进入同一编辑流程。
3. 七种编辑工具和选择工具在浅色、深色模式均清晰可见；首次选择工具、画布点击、再次点击当前工具和切换工具时，二级菜单开关行为符合第 2.4 节。
4. 矩形、椭圆、直线和箭头菜单均为左侧细/中/粗、右侧六个预设色加调色板入口；四种工具共享当前样式，默认中档 4 pt、珊瑚色。
5. 选中已有图形后修改粗细或颜色立即生效并可撤销；最后一个色块能打开系统调色板并使用任意有效 sRGB 颜色。
6. 文字二级菜单可以改四种字体、10–96 pt 字号、-179° 至 180° 角度和任意颜色；旋转手柄支持连续旋转及 Shift 15° 吸附，菜单与画布状态同步，所有旋转操作可撤销。
7. 旋转文字的命中、移动、局部缩放、原位编辑与裁切正确，旋转不会改变排版宽度、换行或字号。
8. 马赛克二级菜单只提供细 12 pt、中 24 pt、粗 40 pt；修改后只影响新笔画，已有笔画不改变。
9. 二次裁剪显示完整源图和全部标注，框外内容统一变暗且不可编辑；裁剪框可移动和八点缩放，Return、双击框内或再次点击裁剪按钮应用，Esc 取消草稿，切换工具/保存/确认自动应用。
10. 应用裁剪后输出像素尺寸正确；再次裁剪可扩大范围，框外标注能重新出现；裁剪及其撤销均只产生一个预期步骤。
11. 大图、窄长图、小图和 Retina 截图保持正确比例；未裁剪时保持原像素尺寸，裁剪后严格使用裁剪像素尺寸。
12. 窗口缩放或裁剪后继续绘制，最终输出位置、旋转中心和线宽无漂移。
13. 马赛克后的区域、裁剪框外区域无法通过编辑器 OCR 读取原始文字。
14. 实况文本可拖选，全文 OCR 可复制简中、繁中和英文。
15. 裁剪模式中第一次撤销只取消裁剪草稿，第二次才撤销上一项已提交操作；其他连续撤销不会破坏图片、裁剪状态或跨会话撤销。
16. 保存后窗口继续存在；再次保存生成无覆盖序号文件。
17. 确认后最终图可在聊天、文档和图片应用粘贴，并出现在历史首位或替换原历史项。
18. 验证文字编辑焦点与 Esc 优先级：打开文字样式菜单或调色板不提交草稿；Esc 按“颜色事务 → 文字样式菜单 → 文字编辑 → 裁剪草稿 → 整个会话”处理当前最内层状态；工具栏取消、关闭窗口和编辑中重截符合已锁定的丢弃语义。
19. VoiceOver 能读出工具、菜单展开状态、粗细、颜色、字体、字号、角度、裁剪状态、保存、取消和确认。
20. 空闲状态无新增轮询、无网络请求，退出后会话和历史仍按原规则释放。

## 8. 构建与完成门槛

每个实施阶段至少运行一次无签名编译检查：

```sh
xcodebuild \
  -project SnapClip.xcodeproj \
  -scheme SnapClip \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/SnapClip-editor-derived \
  -jobs 1 \
  CODE_SIGNING_ALLOWED=NO \
  build
```

最终在有可用开发签名和 test runner 的本机环境运行：

```sh
xcodebuild \
  -project SnapClip.xcodeproj \
  -scheme SnapClip \
  -destination 'platform=macOS,arch=arm64' \
  -jobs 1 \
  test
```

完成标准：

- 所有新增和既有单元测试通过。
- 无 Swift 6 并发错误、无新的编译警告。
- 第 7 节人工验收全部通过。
- README、PRD、品牌规范与实际行为一致。
- `git status` 中不包含 DerivedData、临时截图、测试结果包或其他构建产物。

## 9. 明确不做

本期不实现：固定比例/比例预设/自动主体裁剪、自由画笔、高亮、编号、贴纸、阴影、任意数值或连续滑杆式线宽调节、图形与马赛克旋转、多选、图层面板、持久化可编辑工程、多个并行编辑窗口、云端 OCR、滚动截图、录屏，以及截图完成后停留在原屏幕坐标的全屏覆盖编辑。
