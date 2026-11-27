# macOS Native Design Guidelines

## macOS 原生应用统一设计与开发规范

**适用范围：** 使用 SwiftUI、AppKit 或两者混合开发的 macOS 原生应用、小工具、菜单栏应用及系统 Utility。本项目（EncoBattery）的所有 UI 改动按此执行，项目落地要点见文末。

**设计目标：**

> 让每一个自建 macOS 应用，都像 macOS 系统本身的一部分，而不是一个套着 macOS 外壳的第三方应用。

---

# 1. 核心设计理念

统一遵循以下设计关键词：

- Native macOS
- Minimal
- Quiet
- Refined
- Information First
- System Utility
- Consistent
- Functional

核心原则：

1. 原生优先：优先使用 Apple 提供的系统控件、API、交互模式。
2. 简洁克制：不为了视觉效果增加无意义的装饰。
3. 信息优先：让用户快速理解核心信息和当前状态。
4. 一致性：不同应用遵循相同的视觉语言。
5. 功能驱动：界面设计服务于功能，而不是展示设计技巧。
6. 适度精致：细节可以精致，但不能喧宾夺主。

**注意：统一的是设计语言，不是所有应用的布局。**

根据应用类型选择合适的原生交互模式，不要强行套用同一种卡片或面板结构。

# 2. 原生视觉语言

## 2.1 系统控件优先

优先考虑：

- SwiftUI 原生组件
- AppKit 原生组件
- SF Symbols
- 系统字体
- 系统语义颜色
- 系统 Material
- 系统菜单、Popover、Toolbar、Window
- 系统原生交互反馈

不要为了实现简单而使用 Web 风格组件模拟原生界面。

不要为了追求视觉一致性而放弃系统已经提供的成熟控件。

如果 SwiftUI 无法准确实现目标，可以合理使用 AppKit，不要局限于单一框架。

## 2.2 Typography

优先使用 macOS 系统字体。

推荐遵循系统字体层级：

| 内容 | 设计原则 |
|---|---|
| 页面标题 | 清晰、适度强调 |
| 区域标题 | 中等字重 |
| 主要数据 | 根据重要程度突出 |
| 正文 | Regular |
| 辅助信息 | Secondary |
| 时间、说明 | Tertiary |

具体字号根据界面密度和系统控件规范调整。

禁止：

- 第三方装饰性字体
- 不必要的超大标题
- 过度粗体
- 全大写装饰文字
- 夸张字间距

## 2.3 Color System

优先使用系统语义颜色：

- `.primary`
- `.secondary`
- `.tertiary`
- `.quaternary`
- 系统 Accent Color
- AppKit Semantic Colors

颜色应该具有明确的功能意义。

推荐：

- 正常状态：默认前景色。
- 成功状态：系统绿色。
- 警告状态：系统橙色。
- 错误状态：系统红色。
- 禁用状态：Secondary / Tertiary。

禁止随意使用固定 HEX 颜色。

禁止无意义的蓝紫渐变、霓虹色、彩色光晕。

## 2.4 Spacing & Shape

建立统一的空间节奏：

- 4pt：微小间距。
- 8pt：紧凑元素间距。
- 12pt：常规内容间距。
- 16pt：区域内边距。
- 20~24pt：较大区域间距。

以上是参考值，不是强制限制。

优先遵循 macOS 系统控件自身的尺寸、内边距和圆角。

避免：

- 过度圆角。
- 卡片套卡片。
- 大面积边框。
- 不必要的分割线。
- 装饰性阴影。

# 3. 根据应用类型选择原生布局

不要给所有应用使用同一种布局。

根据实际功能选择最合适的系统交互模式。

| 应用类型 | 优先考虑 |
|---|---|
| 菜单栏工具 | NSStatusItem / MenuBarExtra |
| 状态查看器 | NSPopover / 紧凑面板 |
| 独立桌面应用 | 原生 Window |
| 数据管理工具 | 原生 List / Table |
| 文件处理工具 | 原生 Toolbar / FileImporter |
| 设置页面 | Settings / Form |
| 搜索工具 | 原生 SearchField |
| 快捷操作工具 | Menu / Command / Keyboard Shortcut |
| 监控工具 | 紧凑数据视图 / 原生图表 |

布局应该由使用场景决定。

不要为了看起来高级，强行增加侧边栏、Dashboard、卡片网格或多层导航。

# 4. 信息架构

遵循 Information First。

用户打开应用后，应该能够快速回答：

1. 当前发生了什么？
2. 当前状态是什么？
3. 我能做什么？
4. 下一步应该怎么做？

设计时：

- 最重要的信息优先显示。
- 次要信息适当弱化。
- 低频功能放入菜单或设置。
- 技术实现细节默认隐藏。
- 不展示用户不需要理解的内部参数。
- 避免重复信息。
- 避免冗余说明文字。

不要将普通 Utility 做成复杂的管理后台。

**一个界面只需要承载完成当前任务所必需的信息。**

# 5. Background & Material

优先让 macOS 系统管理：

- Window Background
- Popover Background
- Material
- Shadow
- Corner Radius
- Window Appearance
- Dark / Light Appearance

禁止无意义地模拟系统窗口：

- 不要自行绘制一层背景再套 Card。
- 不要叠加多层 `.ultraThinMaterial`。
- 不要用大量 RoundedRectangle 模拟 Web 卡片。
- 不要用阴影制造虚假的层级。

需要自定义背景时，必须有明确的功能和视觉理由。

# 6. Iconography

统一使用 SF Symbols。

遵循：

- 图标含义明确。
- 图标尺寸协调。
- 图标视觉重量统一。
- 优先使用系统默认 Symbol Weight。
- 使用语义正确的系统图标。
- 装饰性图标能删则删。

禁止：

- Emoji 作为 UI 图标。
- 不同风格图标混用。
- 随意使用彩色图标。
- 为简单功能设计复杂 Logo。
- 无意义的图标堆砌。

# 7. Interaction & UX

交互必须符合 macOS 用户习惯。

优先支持：

- 鼠标操作。
- 键盘快捷键。
- 原生菜单。
- Context Menu。
- 系统标准操作反馈。
- 合理的焦点管理。
- 标准窗口行为。
- 合适的拖放交互。

不要为了所谓的高级感给所有元素增加 Hover 动画。

只有真正可交互的元素才需要 Hover 状态。

不要增加无意义的按钮。

操作应该有明确反馈，但不要用过多 Toast、弹窗和提示打扰用户。

# 8. Animation

动效必须克制。

允许：

- 轻微淡入淡出。
- 状态切换过渡。
- 适度的尺寸变化。
- 轻微的进度变化。
- 系统原生过渡动画。

推荐参考：

- 100~150ms：轻量状态反馈。
- 150~200ms：普通状态过渡。

禁止：

- 大幅弹跳。
- Spring 滥用。
- 呼吸灯。
- 流光。
- 数字滚动。
- 无意义的旋转。
- 夸张的缩放。
- 为了装饰而持续运行的动画。

**动画应该帮助用户理解变化，而不是让用户注意到动画本身。**

同时尊重系统 Reduce Motion 设置。

# 9. Light / Dark Mode

必须正确支持：

- Light Mode
- Dark Mode

优先使用动态语义颜色和系统 Material。

禁止写死白色、黑色及固定背景色来实现主题。

检查：

- 文本对比度。
- 图标可见性。
- 分割线。
- 禁用状态。
- 状态颜色。
- Popover 和 Window 背景。

两种模式都必须自然，不能只是简单反色。

# 10. Accessibility

不要为了视觉效果牺牲可访问性。

必须考虑：

- VoiceOver。
- Accessibility Label。
- Accessibility Value。
- Dynamic Type。
- 键盘导航。
- 焦点状态。
- 足够的颜色对比度。
- Reduce Motion。

颜色不能成为表达状态的唯一方式。

# 11. 工程实现原则

设计和代码质量同样重要。

遵循：

1. 优先复用项目现有技术栈。
2. 不为 UI 改造重写已经稳定的业务逻辑。
3. 不为了视觉效果引入不必要的第三方依赖。
4. 不为了拆分组件而过度工程化。
5. 保持清晰的 View / Model / Service 职责。
6. 优先使用系统 API。
7. 避免不必要的状态复制。
8. 注意内存管理、生命周期和 Retain Cycle。
9. 避免主线程执行耗时操作。
10. 确保应用兼容项目声明的最低 macOS 版本。

如果 AppKit 和 SwiftUI 混用能够更好地实现原生交互，可以采用混合架构。

不要为了追求纯 SwiftUI 而牺牲体验。

# 12. 开发实施流程

所有 UI 改造和新功能开发，按照以下流程执行。

## Phase 1 — Audit

如果是已有项目：

1. 阅读项目结构。
2. 了解当前技术栈。
3. 找到应用入口和生命周期。
4. 理解主要 UI 结构。
5. 梳理 View / Model / Service 之间的依赖。
6. 识别核心业务逻辑。
7. 识别现有 UI 的问题。

先输出简短审查结论和实施计划。

不要未经审查就直接修改代码。

## Phase 2 — Design

根据实际功能确定：

- 应用交互模式。
- 信息架构。
- 视觉层级。
- 窗口和面板尺寸。
- 组件结构。
- 状态展示。
- 操作流程。

不要为了套用规范而增加不必要的 UI。

## Phase 3 — Implementation

开始实现。

要求：

- 优先修改 UI 层。
- 尽量保留稳定业务逻辑。
- 复用系统原生组件。
- 保持代码简洁。
- 不引入无意义依赖。
- 不擅自扩大需求范围。

## Phase 4 — State Verification

根据应用实际功能检查：

- 正常状态。
- 加载状态。
- 空状态。
- 异常状态。
- 错误状态。
- 禁用状态。
- 边界数据。
- 用户取消操作。
- 网络中断或设备离线（如果适用）。

不适用的状态不必强行实现。

## Phase 5 — Visual Polish

最后再调整：

- Spacing
- Typography
- Icon Size
- Alignment
- Window Size
- Dark Mode
- Light Mode
- Animation
- Interaction Feedback

不要一开始就堆视觉效果。

## Phase 6 — Final Review

检查：

- 是否符合 macOS 原生视觉语言。
- 是否存在 Web UI 感。
- 是否存在 Dashboard 感。
- 是否存在冗余信息。
- 是否存在多余交互。
- 是否存在不必要动画。
- 是否正确支持深色和浅色模式。
- 是否符合 Accessibility。
- 是否存在编译警告。
- 是否存在布局问题。
- 是否破坏现有功能。

最终说明：

1. 修改了什么。
2. 为什么这样设计。
3. 修改了哪些文件。
4. 是否涉及业务逻辑。
5. 测试了哪些场景。
6. 还有哪些值得优化的地方。

没有实际验证的内容，不得声称已经通过测试。

# 13. 最终设计判断

当两个设计方案都能满足功能时，始终优先选择：

- 更简单，而不是更复杂。
- 更安静，而不是更炫。
- 更少颜色，而不是更多颜色。
- 更少文字，而不是更多说明。
- 更少装饰，而不是更多效果。
- 更自然的系统交互，而不是自定义模拟。
- 更清晰的信息，而不是更复杂的视觉层级。

不要为了展示 UI 技巧而设计界面。

不要为了证明 AI 能力而增加功能。

不要擅自改变已经确定的设计方向。

---

# 最终目标

为所有自建 macOS 应用建立统一的原生设计语言：

**Native · Minimal · Refined · Consistent**

让不同应用拥有不同的功能和布局，但始终保持相同的产品气质。

> 最好的 macOS Utility，不是看起来设计得有多复杂，而是让用户觉得它本来就应该长这样。

---

# EncoBattery 落地要点

本项目实践中补充的硬规则，与上文冲突时以本节为准：

- **自绘可点控件必须用 `Button` + `.buttonStyle(.plain)` 打底**，不要用 `Text.onTapGesture`——在 NSPopover 里手势会被吞，点击无响应（已踩坑）。
- **UI 是回显驱动的**：所有降噪/音效切换只渲染耳机回发的状态，不做乐观更新；等待回显时显示 ProgressView 并禁用对应分段控件。
- **小窗口禁止经典滚动条**：窗口高度贴合内容；固定高度时配 `.scrollIndicators(.hidden)`（设置窗口固定 360×372）。
- **离屏渲染的 Form 必须固定 frame**：`ImageRenderer` 下 grouped Form 自然高度会塌缩（实测塌成 122pt），不能依赖 fittingSize。
- **窗口样式**：设置窗口 `[.titled, .closable]` 不可缩放； popover 用系统 NSPopover，不自绘背景。
- 动画：分段选中滑块 150ms；展开/收起用手动逐帧 reveal 驱动 200ms easeInOut（NSPopover 窗口尺寸没有原生动画，靠 SwiftUI 逐帧重排让宿主窗口跟着动），全部走 `reduceMotion` 退化瞬切。
- 颜色只用语义色；电量状态色：充电 `systemGreen`、≤10% `systemRed`、≤20% `systemOrange`。
- UI 文案极简：窗口标题栏已有的信息不在正文重复；不确定的状态如实显示「未知」。
