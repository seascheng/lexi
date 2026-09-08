# 文本回写与 Toolbar 升级设计方案

基于对 `~/Downloads/ai_project/tinycast`（文本注入）与 `~/Downloads/ai_project/openclip`（选词工具栏）的源码调研。所有引用均落到两个项目的具体文件与 lexi 当前代码行。

---

## 1. 对提案的评估（先评估，不盲从）

| 提案点 | 评估 | 结论 |
|---|---|---|
| 从 tinycast 学「直接替换当前编辑的文本」 | tinycast `TextInjector.swift` 是三层交付契约（AX 直写 + 回读验证 → Unicode 键击 → 临时剪贴板租约 + ⌘V），工程细节完整（Blink 4-UTF-16 截断、Chromium 假 success、租约单一 item 防串味）。lexi 完全没有回写能力，翻译结果只能看不能落 | **采纳**，作为 Phase A |
| 从 tinycast 学「note 回车后插入到鼠标所在输入区」 | 事实修正：tinycast 的 Notes **没有**注入功能（`docs/features/notes.md` 只做焦点恢复）。交互基准实为 **Hapigo**：打字中快捷键唤出粘贴板/note 浮层 → 选中 → Enter → 内容自动填写到原输入框。tinycast 提供的是同机制的可移植实现——Snippets 面板链：打开面板前捕获 `previousApp` → 提交时 activate + 注入（`docs/features/snippets.md:210-213`）。对 lexi 的正确移植是「popup/NotesPanel 插入到**唤出前的焦点 app**」，不是鼠标位置——鼠标下的窗口未必是 key window | **修正后采纳**，作为 Phase D（核心工作流），复用 Phase A 引擎 |
| 从 openclip 学 toolbar 弹出规则 | lexi 已有 70%（拖拽/多击判定、text-area 门、pre/post 选区对比、menu-copy/cmd-c 回退）。缺：浏览器 AX 直读（`ax-web-area` 策略）、键盘选择手势触发、方向感知定位、光标距离消失、popup 打开时抑制 | **部分采纳**：取词为 Phase B，规则补齐并入 Phase C |
| 从 openclip 学 toolbar 设计样式 | lexi 现在是纯色块 + 系统阴影；openclip 的 vibrancy 材质（classic/glass 双主题）、按钮规格（34×29）、圆角（8.5）、hover accent 值得照搬。其 SwiftUI 阴影环（16pt inset + hit-test 排除）是 SwiftUI 特有问题，AppKit `NSVisualEffectView` 不需要 | **采纳**，作为 Phase C |
| openclip 的 per-app 规则引擎 / hold-to-popup 长按呼出 | 规则表是为多策略入口选择服务的；lexi 串行链（ax-text → web-area → menu → cmd-c）单次失败成本仅一次 CFTypeRef 调用，不需要规则表。长按呼出是可选交互 | **不采纳**（YAGNI）；长按呼出记为 Phase C 可选项 |
| openclip 的 keyboard-copy 策略 | lexi 已有等价物 `read_selected_text_via_cmd_c()`（含完整 Cmd 修饰序列） | **不采纳**（已存在） |

---

## 2. 现状盘点（lexi，grounded）

**取词链** `src-tauri/src/native_toolbar.rs`（2542 行）：
- CGEventTap (HeadInsert)：mouse-down 快照选区（:1036-1045）→ mouse-up 80ms 延迟后 `selection_read_guard()` 串行读（:1080）
- 链：`read_selected_text_via_ax()`（:1439，kAXSelectedText → AXValue+range 切片）→ `read_selected_text_via_menu()`（:1541，AXPress Edit▸Copy + 剪贴板借还）→ `read_selected_text_via_cmd_c()`（:1664，完整修饰序列合成 ⌘C）
- 浏览器：AX 读不到 → 依赖用户先 Cmd+C（`LAST_COPIED_TEXT` 5s 新鲜窗口，:170）或 Chrome 扩展 POST（:799）
- 剪贴板安全：`pasteboard_safe_to_borrow()`（仅文本才借）+ `restore_pasteboard()` + changeCount 门

**Toolbar** `src-tauri/native/SelectionToolbarHelper.swift`（933 行，AppKit + NWListener HTTP）：
- NSPanel：borderless + nonactivatingPanel，level `.screenSaver`，hasShadow，纯色背景，圆角 8（:560-594）
- 定位：光标上方固定 gap 6，屏内 clamp（:837-850），**无拖拽方向感知**
- 隐藏：仅点击面板外部（local/global mouse-down monitor，:596-608）；**无光标距离消失、无 Esc、无滚轮隐藏**
- action 点击 → POST `/action` → Rust `dispatch_toolbar_action`（:2162）→ 工具即时执行或 `open_popup_with_feature`

**回写**：无。仅有 `do_handoff()`（:2330）——osascript 内插文本（换行未转义，**多行文本必然语法错误**，真实 bug）、1s 硬延迟、破坏剪贴板。

**前端**：`TranslationWindow.tsx:1018-1026` 结果操作行有 Copy 按钮；`NotesPanel.tsx` 支持复制 note；均无插入回源能力。

---

## 3. 目标架构

### 3.1 模块边界

```
src-tauri/src/
  ax.rs                  # 新增：共享 AX 底层（extern、focused element、attribute 读写、
                         #   web-area 发现、marker range 解析）。native_toolbar 与 text_injection 共用
  text_injection.rs      # 新增：回写引擎（三层交付 + previousApp 门 + 租约）
  native_toolbar.rs      # 改：取词链插入 web-area 层；show_toolbar 记录 SelectionTarget；
                         #   键盘手势触发；popup 抑制；删 do_handoff 的 osascript 实现
src-tauri/native/
  SelectionToolbarHelper.swift   # 改：方向感知定位、距离消失、Esc、vibrancy 材质
src/components/translation/
  TranslationWindow.tsx  # 改：结果操作行加 Replace 按钮
  NotesPanel.tsx         # 改：note 行加 Insert 按钮 + Enter 插入
```

理由：`native_toolbar.rs` 已 2542 行，注入是独立职责（tinycast 把它做成独立 `Features/TextInjection/`），抽 `ax.rs` 共享底层避免两份 AX extern（AGENTS.md：职责分离但不过度碎片化——只抽两个模块，不抽更多）。

### 3.2 共享状态：选区来源

```rust
// native_toolbar.rs（show_toolbar 与 popup 唤出时写入，text_injection 读取）
pub struct SelectionTarget {
    pub pid: i32,
    pub bundle_id: String,
    pub captured_at: Instant,   // 超过 60s 视为陈旧，回写拒绝
}
pub static SELECTION_TARGET: OnceLock<Mutex<Option<SelectionTarget>>> = ...;
```

这对应 tinycast 的 `previousApp` 捕获（面板打开前记录，提交时 activate + 等待就位）与 openclip 的 `previousFrontmostApp`（`PopupWindowController.enterKeyMode` 同款语义）。

### 3.3 新增 Tauri 命令

```rust
#[tauri::command]
pub fn insert_at_focus(text: String) -> Result<String, String>;
// 返回实际交付层："ax" | "typed" | "pasted"；无选区 = 在光标处插入
```

> `replace_selection` 命令曾随 Phase A 一并实施，后因用户反馈撤销：LLM 翻译输出包含解释性大段文本，整体替换原文不可行。引擎（`deliver_text`）保留，仅服务于 `insert_at_focus` 与 handoff。

---

## 4. Phase A：文本回写引擎（text_injection.rs）✅ 已实施 2026-09-07（新增 `src-tauri/src/text_injection.rs` 三层引擎 + `src-tauri/src/ax.rs` 共享 AX 模块；`insert_at_focus` 命令已注册；`SelectionTarget` 在 toolbar/popup 唤出时捕获；~~前端 Replace 按钮~~ 已按用户反馈撤销（见 §3.3）；`do_handoff` 与 `tools.rs::tool_handoff` 双实现已合并重写为引擎调用。自测：handoff 经租约粘贴交付，剪贴板恢复验证通过）

### 4.1 三层交付契约（照 tinycast `TextInjector.swift:280-338` 顺序）

```
入口门（每层之前都重查）：
  SelectionTarget 有效（60s 内）· pid 存活 · IsSecureEventInputEnabled() == false
  · AX 权限已授（不再弹窗）· frontmost == target pid（activate 后轮询 50×20ms 就位，tinycast :515-543）

第 1 层 AX 直写（原生 app：Notes/TextEdit/Mail/Word/Pages/微信）：
  focused element 来自 target app 的 AXFocusedApplication → AXFocusedUIElement
  （不从 systemWide 取——openclip 文档明确这是脏读来源）
  1. 元素暴露 kAXSelectedTextMarkerRange → 渲染面（Chromium/Monaco），跳到第 2 层
  2. AXUIElementIsAttributeSettable(kAXSelectedText / kAXSelectedTextRange) 均 true 才继续
  3. 读 kAXValue + kAXSelectedTextRange → setSelectedRange(原 range) →
     AXUIElementSetAttributeValue(kAXSelectedText, text)
  4. 回读 kAXValue 重建期望串逐字比对（Chromium 返回 success 却不写入——tinycast :47-60
     confirmsReplacement；值未变 → 降级第 2 层；值变成别的 → 拒绝，报告失败）
  5. 成功后 setSelectedRange(range.location + text.utf16_len, 0) 把光标落到译文末尾

第 2 层 Unicode 键击（≤100 字符且不含换行；tinycast :346-356）：
  CGEventKeyboardSetUnicodeString，每击最多 4 个 UTF-16 单元（Blink 的
  WebKeyboardEvent::kTextLengthCap 固定 4，超了静默丢弃——tinycast :895-914），
  按 Unicode scalar 边界分块，击间 8ms，全部 postToPid(target pid)

第 3 层 临时剪贴板租约 + 合成 ⌘V（长文本/多行）：
  1. pasteboard_safe_to_borrow()（已有）——图像/文件剪贴板不借，降级第 2 层逐块键击
  2. 记录 changeCount → 写入单一 NSPasteboardItem（纯文本，不带原剪贴板任何其他
     flavor——tinycast :1083-1090 教训：保留 public.html 会让富文本编辑器粘出上一次的内容）
  3. 合成完整修饰序列：Cmd-FlagsChanged(down) → v-down → v-up → Cmd-FlagsChanged(up)
     （复用 post_cmd_c_and_read 的现成模式 native_toolbar.rs:1668-1705）
  4. 轮询确认：AX 文本状态变化（80×25ms，tinycast :690-721）或 pasteboard changeCount
     未被第三方推进则恢复原文本
  5. 恢复前再比对 changeCount，被用户手动复制覆盖则不恢复
```

### 4.2 需要 extern 的新符号（ApplicationServices/CoreGraphics）

```
AXUIElementIsAttributeSettable, AXUIElementSetAttributeValue,
CGEventKeyboardSetUnicodeString, IsSecureEventInputEnabled
```

（前两个属性名 `kAXSelectedTextAttribute` 等以 `&str` 传入即可，lexi 已有此风格的 `accessibility_string_attribute`。）

### 4.3 顺带清理：重写 `do_handoff`

- 修真 bug：`do_handoff`（:2338-2347）把 `text` 内插 AppleScript 字符串，只转义 `\` 与 `"`，**换行直接破坏脚本语法**；且 `delay 1.0` 硬延迟、写剪贴板不恢复。
- 重写为：`NSRunningApplication`（bundle id 激活，Rust 已有 `frontmost_bundle_id` 同款 objc 调用）→ 等 frontmost 就位 → 第 3 层租约粘贴。删掉 osascript 路径。

### 4.4 前端落点（已撤销）

原计划在结果操作行 Copy 旁加 Replace 按钮，**已撤销**：LLM 翻译输出是「译文 + 解释」的大段文本，直接替换用户选中的原文不可行。回写引擎的消费者改为 Phase D 的 `insert_at_focus`（note 内容是用户自写的短语，插入语义成立）与 handoff。

### 4.5 预期达到的效果

1. **原生 app**（Notes/TextEdit/Mail/Pages/Word/微信）：译文一键原地替换选区，AX 直写路径 **<50ms**，`pasteboard changeCount 不变`（可用 ClipBook 之类剪贴板历史工具验证零扰动），光标自动落在译文末尾。
2. **Chromium 系**（Chrome/Edge/VS Code/Slack/ChatGPT 网页）：自动降级键击或租约粘贴，同样替换成功；≤100 字符单行译文走键击层，剪贴板同样零扰动。
3. **安全边界**：密码框/Secure Input 激活时（锁屏、sudo 密码）静默拒绝并 toast「目标输入区不允许替换」，绝不乱发键击。
4. **剪贴板永不丢内容**：租约恢复 + changeCount 双保险；用户在替换瞬间手动复制，其新内容优先。
5. `do_handoff`（交给 ChatGPT）多行文本不再失败，延迟从 ≥1s 降到 <300ms。
6. 可观测性：`/tmp/lexi-native-toolbar.log` 记录每次交付的层级（ax/typed/pasted）与耗时，方便回归排查。

---

## 5. Phase B：浏览器 AX 直读（ax-web-area 策略）✅ 已实施 2026-09-07（`native_toolbar.rs`：`read_selected_text_via_web_area` 及其辅助函数；两条链均已接入，链序 `ax-text → ax-web-area → menu-copy → cmd-c → last-copied`）

### 5.1 机制（照 openclip `AXWebAreaStrategy.swift` + `AXElementInspector.swift:63-94`）

```
插入位置：read_selected_text_via_ax() 失败之后、read_selected_text_via_menu() 之前

1. 从 target app 的 focused element 向上走祖先（≤25 层）找 role == "AXWebArea"
   找不到 → kAXFocusedWindow 下 DFS（≤6 层）找第一个 AXWebArea 子节点
2. 读 focused element（回退 webArea）的 "AXSelectedTextMarkerRange" 属性 → CFTypeRef
   拿到即说明是 WebKit/Blink 渲染面（tinycast 用同一特征识别并主动绕开 AX 写入）
3. AXUIElementCopyParameterizedAttributeValue(webArea, "AXStringForTextMarkerRange",
   markerRange, &out) → String                       ← 参数化属性，公开 C API，Rust 可 extern
4. settle-retry：文本为空/过短时隔 50ms 重读，最多 3 次（openclip 用 6 次，lexi 取 3
   控制弹出延迟；页面未渲染完的瞬间读不到是正常收敛过程）
5. （可选加分）同 API 读 "AXBoundsForTextMarkerRange" 拿选区矩形 → 未来 toolbar 可
   贴选区而非贴光标；首版不接 UI，仅记日志
```

不需要 `AXTextMarkerRangeGetTypeID` 私有符号：marker range 作为不透明 `CFTypeRef` 直接传给参数化查询，失败即失败（类型判别只是防御，openclip fixture 路径已证明可以不带）。

### 5.2 降级顺序保持不变

`ax-text → ax-web-area → menu-copy → cmd-c → LAST_COPIED_TEXT(5s)`。Chrome 扩展服务器（:799）保留兼容，但从「浏览器主要取词路径」退为可选增强。

### 5.3 预期达到的效果

1. **Chrome/Safari/Edge/Arc 里拖选即弹 toolbar**，不再需要先 ⌘C——这是当前日常最高频痛点。目标成功率 ≥95%（Google Docs canvas 类自绘编辑器仍走 ⌘C 回退）。
2. 取词延迟：拖选释放到 toolbar 出现 **<150ms**（marker 读取 <1ms，主要开销仍是既有 80ms 等待 + AX 查询）。
3. 零剪贴板扰动：AX 路径不触碰 pasteboard（openclip 的「No Clipboard Pollution」保证）。
4. `trigger_popup_with_selection`（快捷键路径）同样先走 web-area，浏览器里 Ctrl+Ctrl 直接触发翻译，不再依赖 5s 内的复制记录。

---

## 6. Phase C：Toolbar 弹出规则与视觉升级

### 6.1 定位（照 openclip `PopupPositioner.swift:100-169`）

- `ShowPayload` 增加 `downX/downY`（Rust 侧已有 `ClickState.down_x/down_y`，透传即可）。
- helper 定位规则：`release.y - down.y < -10`（从上往下拖，文本在光标上方）→ toolbar 放光标**下方**；其余（从下往上拖、水平拖、双击）→ 放**上方**（现状）。越出屏幕 `visibleFrame` 自动翻转 + 现有 6pt clamp 保留。
- 多屏：现有「Rust 传光标坐标 + screens.contains 校验」（helper :821-835）已经正确，不动。

### 6.2 隐藏规则（照 openclip `PopupWindowController` + `PopupMetrics`）

| 规则 | 常量 | 实现 |
|---|---|---|
| 光标离开自动隐藏 | 距离 > `max(180, min(屏宽×0.12, 280))`pt | helper 加全局 `mouseMoved` monitor（panel 非 key 也能收） |
| Esc 隐藏 | — | helper 加全局 `keyDown` monitor（accessibility 已授） |
| 滚轮隐藏 | — | 全局 `scrollWheel` monitor |
| 点击外部隐藏 | 已有 | 不动 |

### 6.3 触发补齐（Rust 侧）

- 键盘选择手势：tap 的 `KeyDown` 分支识别 ⌘A 与 ⇧/⌥⇧/⌘⇧+方向键/Home/End/PageUp/PageDown（剥 capsLock/function/numericPod 设备位，openclip `MacSelectionMonitor.swift:171-197` 的判法），150ms debounce 后走与 mouse-up 相同的取词管线（不含 `is_text_area_at_position` 门——键盘手势没有鼠标坐标）。
- popup 抑制：popup_card 可见期间 `show_toolbar` 直接跳过（Rust 侧维护 `POPUP_VISIBLE` 静态，`show_popup_now`/`hide` 时更新）——对应 openclip 的 `isSuppressed`，解决「结果卡片看着，一选词 toolbar 又弹出来盖住」。

### 6.4 视觉（照 openclip `PopupMetrics` + `LiquidGlass.swift`，映射到 AppKit）

| 项 | 现状 | 目标 |
|---|---|---|
| 背景 | 纯色 CALayer | `NSVisualEffectView(material: .menu, blendingMode: .behindWindow)`，dark/light 主题透传（对应 openclip glass 主题 scrim black 0.32 / white 0.38 的 AppKit 等价） |
| 圆角/描边 | 8pt 无描边 | 8.5pt 圆角 + 0.5pt 描边（light `black 0.20` / dark `white 0.22`） |
| 按钮 | 34×30 | 34×29（openclip 基准），hover 背景 `controlAccentColor`、图标反白 |
| 阴影 | 系统阴影 | 保留系统阴影（openclip 的 16pt 阴影环是 SwiftUI 裁边问题，AppKit 无此问题，不引入） |
| 图标 | 16pt | 16pt 不变 |

### 6.5 预期达到的效果

1. **toolbar 永不遮挡刚选中的文本**：向下拖选时出现在下方（当前一律出现在上方，向下拖选会把选中词盖住）。
2. 选完不想理它：光标移开 >~200pt 或滚动或 Esc 即消失，无需先点别处；四种隐藏路径全覆盖。
3. ⌘A / ⇧+方向键选词同样触发 toolbar（纯键盘工作流）。
4. 结果卡片阅读期间 toolbar 不再弹出干扰。
5. 视觉与 macOS 原生（PopClip/Raycast 一类）一致：毛玻璃材质随系统亮暗，按钮 hover 呈现系统强调色。
6. 定位与隐藏规则在多显示器（含不同缩放）下不跳屏——沿用 Rust 传坐标的既有方案。

---

## 7. Phase D：Hapigo 式回车填写（Note / 结果插入当前输入框）✅ 已实施 2026-09-07（`NotesPanel.tsx`：Enter/双击行/hover ↵ 按钮 → `insert_at_focus`，成功后关 popup，失败面板保留；⌘C 保持复制。「无选区也弹 popup」由既有双击 Ctrl 路径覆盖——`show_popup` 先于取词调用，读不到选区时 popup 照常显示）

> 交互基准：Hapigo 的粘贴板/note 浮层——正在任意输入框打字 → 快捷键唤出浮层 → 选中一项 → Enter → 内容自动填写到原输入框光标处。tinycast 的 Notes 无此功能；其 Snippets 面板链（打开面板前捕获 `previousApp` → 提交时 activate + 注入）是同一机制的实现参考。

### 7.1 交互

- **唤出**：快捷键（Ctrl+Ctrl / 自定义）唤出 popup。现状 `trigger_popup_with_selection` 读不到选区时静默不弹（:1355-1357）——改为**无选区也显示 popup**（直接落到 NotesPanel / 输入态）：打字中取 note 的场景没有选区，这正是 Hapigo 的主路径。
- **选择**：NotesPanel 列表已有键盘导航（`selectedIdx`），选中态按 **Enter** → `invoke("insert_at_focus", { text })`；行 hover 加 Insert 按钮（lucide `CornerDownLeft`）同义。复制保持现有 ⌘C/按钮。
- **落点**：结果区不加第二入口（Replace 已覆盖选区场景），避免按钮堆砌。

### 7.2 目标捕获：popup 唤出时写入，insert 时校验

`SelectionTarget` 写入点从 `show_toolbar` 扩展到 **popup 唤出路径**（`trigger_popup_with_selection` / `open_popup_with_feature`）——有无选区都记录 frontmost。

~~lexi 的一个既有优势：popup 经 `show_window_without_focus` 显示，不激活 lexi，源 app 保持 frontmost。~~ **用户实测推翻此推断**：`show_window_without_focus` 调用 `makeKeyWindow`（popup 需接收键盘输入），popup 成为全局 key window 的瞬间 lexi 被隐式激活，源 app 失活、输入框光标丢失——这正是与 Hapigo 体验的差距。Hapigo 面板完全不抢键盘（全局事件捕获 + 非 key 面板），架构不同。

**演进三段**（均被用户实测驱动）：① tinycast 式往返（makeKey 抢焦点→activate 回去）被否——源框光标丢失；② Hapigo 式非 key popup + tap 键盘转发被否——WebView 在非激活 app 下节流，eval 合成键盘不可靠，点击 popup 又致 `wait_for_frontmost` 失败；③ **最终方案：原生 Swift Notes 面板**（2026-09-07 已实施），popup_card 对此流程完全退出：

1. 双击 Ctrl 无选区 → Rust 读 SQLite 笔记（`sqlite3 -json`）→ `POST /notes-show` → helper 弹原生面板（NSPanel nonactivating + vibrancy，`SelectionToolbarHelper.swift`）；
2. 键盘全走 lexi 的 Default tap（劫持 ↑↓/Enter/Esc）：Rust 持有列表快照与选中索引（`NOTES_SNAPSHOT`/`NOTES_SELECTED`），helper 是**无状态渲染器**——原生重绘零节流；
3. Enter → Rust 直取笔记 → `deliver_text` 注入源 app 活光标 → `POST /notes-hide`；插入全程不过 webview；
4. 点击行 = `notes-click` action 回 Rust 走同一 Enter 管线；点击外部/Esc 关闭（helper 通知 `notes-hidden` 复位标志）；
5. 源 app 全程保持 active，光标持续闪动——Hapigo 同款体验。**用户实测通过**（2026-09-07：双击 Ctrl → 原生面板 → Enter → 文本插入原光标处）。注意语义边界：双击 Ctrl 时若有选区仍走翻译 popup（translate 面板）；无选区才进原生 Notes。

> **结果卡全功能对齐（2026-09-07 第二轮）**：原生卡复刻 WebView WorkspacePage 全部能力——多 run 标签（图标+标题+单关/清空）、loading/streaming/ready/error 四态、EntryTypeTags（word/phrase/pattern，随 save-vocab 落库）、Copy/Save（accent 胶囊）、AiForm 输入区（**单行时按钮与文本同行、多行时按钮组换行到下方并释放全宽**——与 WebView 版同一测量口径：行布局宽度下测高，防布局振荡；24–140 高度 clamp；focus 边框转 accent；Enter 提交默认 feature、Shift+Enter 换行）。输入经 `card-input` action 走 Rust（空 featureId=第一个 enabled feature）；`card-input-mode` 打开 idle 输入卡（入口：Notes 面板底部 "Type to translate…"）；事件带 runId/saved 路由到对应 run；卡片可拖动（背景拖动）、Esc/外点/✕ 关闭（card-hidden 复位 CARD_UP）。修复：save-vocab 此前落到 `_ =>` 静默失败的真 bug。

> **第三轮（2026-09-07）**：①修复流式窗口下跑 bug——`setFrameOrigin` 不改尺寸导致每个 chunk 顶边下坠出屏，改 `setFrame(新origin+新size)` 顶锚一次到位（HTTP 直推复现验证：三次增长 top 恒定）+ 屏内 clamp；②布局反转对齐 WebView：panel tabs（Actions/Notes/Review，来自 `panels` 表）→ AiForm 输入区 → run chips → 内容；③输入区按钮组改用 **Panel Config** 数据源（tools 的 `panelEnabled`（settings.toolbar_tools）+ enabled features，混合 panelSortOrder 排序），不再是 toolbar actions；④Notes tab（浏览 50 条笔记，点击复制）与 Review tab（due 词卡 + Reveal + Again/Hard/Good/Easy，Rust 复刻 `sm2.ts` 调度 + `iso_date_plus_days` Hinnant 算法，评分后自动下一词）；⑤顺手修复编辑事故：`clampedPanelOrigin` 的拖拽方向感知判定（belowCursor）被误删后恢复。

### 7.3 插入语义

无选区 = 在光标处插入（`kAXSelectedText` 对 len-0 range 即插入，tinycast `replaceSelection` 注释明确此语义）；有选区 = 替换选区。同一命令 `insert_at_focus` 统一两种。多行 Markdown 原样插入，不做模板展开（lexi 无 snippet 需求）。

### 7.4 预期达到的效果

1. **正在打字的任何输入框**（网页输入框、Slack、微信、编辑器、IDE）：快捷键唤出 popup → note 选中 → **Enter，内容直接出现在原输入框光标处**，全程剪贴板零扰动（AX 路径），打字光标不断流。
2. Chromium 系输入框（网页版 ChatGPT、VS Code）自动降级键击/租约，同样填写成功。
3. 唤出到填写完成 <300ms；源 app 未失焦路径 <50ms。
4. 原窗口已关闭/切走超 60s：明确兜底提示，绝不把文本打进错误的 app。

---

## 8. 交付顺序与依赖

```
Phase B（取词，独立，最小改动面）        ←— 可先行，日常收益最大
Phase A（回写引擎 + do_handoff 重写）    ←— 独立
Phase D（Hapigo 式回车填写，依赖 A）    ←— A 完成后立即收尾，核心工作流
Phase C（规则+视觉，独立）              ←— 任意时点可插入，建议最后做视觉打磨
```

每阶段独立可发布、可回归（AGENTS.md：每步都是完整可用的软件）。A/B/C 互不依赖，可并行开发。

---

## 9. 风险与边界

| 风险 | 缓解 |
|---|---|
| AX 写入在个别 app 造成意外编辑 | 回读验证 + 三层全失败即报错，不重试；`selection_read_guard` 语义扩展为 `ax_write_guard`，注入与取词互斥（AX client 缓存非线程安全，lexi 已踩过 SIGABRT） |
| 合成键击打到错误窗口 | 每击前重查 frontmost == target pid（tinycast :499-504 同款），不匹配立即中止 |
| 租约期间用户复制 | changeCount 比对，放弃恢复（用户内容优先） |
| Electron 应用 AXValue 常年为空 | marker 特征识别直接绕开 AX 写入层（tinycast Rule 1） |
| `AXStringForTextMarkerRange` 在非 WebKit app 报错 | 仅在找到 AXWebArea 后才调用；失败走既有 menu/cmd-c 链 |
| helper 全局 keyDown monitor 权限 | 与 CGEventTap 同源（Accessibility），lexi 已请求；无权限时 Esc 路径静默不可用，其余不受影响 |

---

## 10. 总体验收清单（发布前手工回归脚本）

1. Chrome 拖选 → toolbar <150ms 弹出，方向感知不遮文本；剪贴板历史无新条目。
2. Chrome ⌘A 全选 → toolbar 弹出（键盘手势）。
3. Notes 拖选 → 翻译 → Replace → 原文被译文替换，光标在末尾，剪贴板未变。
4. VS Code 选中多行长文本 → 翻译 → Replace → 租约粘贴成功，剪贴板恢复原内容。
5. 终端 sudo 密码提示时 Replace → 拒绝 + toast，无字符注入。
6. popup 卡片打开时再选词 → toolbar 不弹。
7. 光标移开 / Esc / 滚轮 / 点击外部 → toolbar 四路径均可隐藏。
8. 任意输入框打字中（无选区）快捷键唤出 popup → NotesPanel 选中 note 按 Enter → 内容填入原输入框光标处，剪贴板未变；原 app 已退出 → 兜底 toast + 复制。
9. 「交给 ChatGPT」多行文本 → 成功（do_handoff 回归）。
10. `/tmp/lexi-native-toolbar.log` 无 error 级条目；交付层级统计符合预期（原生 app 走 ax，浏览器走 typed/pasted）。
