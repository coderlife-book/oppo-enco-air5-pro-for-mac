# 交接文档

给下一个会话/Agent 的接力棒。更新时间：2026-11-27。

## 现状

- 源码按职责放在 `Sources/`，版本 **2.1.0**（`build.sh` 里 `VERSION=2.1.0 BUILD=5`）。
- 仓库 https://github.com/coderlife-book/oppo-enco-air5-pro-for-mac ，默认分支 `main`。
- 应用包名和 bundle ID 继续使用 `EncoBattery.app` / `local.encobattery`，便于覆盖升级。

## 2.1.0 相对 2.0.0 的变化

- 设置窗口（弹窗右下角齿轮，或右键菜单「设置…」，快捷键 `,`）：菜单栏图标开关 + 左耳/右耳/充电仓三个独立电量开关；「关于」节显示固件版本和应用版本。
- 菜单栏可选分耳电量（充电绿、≤10 红、≤20 橙；无数据的槽不显示）。
- 面板渐进式披露：「声音设置」入口默认折叠（显示当前摘要），点开才是降噪/强度/音效三段分段控件。
- 展开/收起动画 200ms：手动逐帧 reveal 驱动，窗口与内容同步（NSPopover 尺寸没有原生动画，实测单帧瞬跳）。
- 充电误报修复：`sideInCase` 放置门禁（0402 placement 04=盒内、05=盒外），盒外时充电标记强制清 false。

## 发布

运行 `./make_dmg.sh`，产物位于 `dist/`。用 `codesign --verify --strict` 校验应用包，挂载 DMG 校验内容，再上传到 GitHub Releases。

演示环境变量只加到渲染命令上。不要用 `launchctl setenv EB_FAKE`，否则从 Finder 打开的应用也会进入演示模式，声音设置不会写入耳机。

## 调试钩子（环境变量）

| 变量 | 作用 |
|---|---|
| `EB_FAKE=full\|charging\|empty\|anc\|smart\|eq\|offline` | 演示数据，声音设置不会写入耳机 |
| `EB_DEBUG=1` | 协议日志（tx/rx/raw-rx 十六进制） |
| `EB_RENDER` / `EB_RENDER_SETTINGS` / `EB_SHOT` | 离屏渲染卡片/设置页/带菜单栏整图 |
| `EB_APPEARANCE=light\|dark` | 配合渲染钩子出深浅色截图 |
| `EB_EXPAND=1` | 启动即展开声音设置；`EB_EXPAND_AFTER`/`EB_COLLAPSE_AFTER` 定时展开/收起 |
| `EB_POPOVER_TEST=1` | 自动开面板并逐帧采样窗口高度（验证动画曲线） |
| `EB_TEST=noise:smart\|eq:0\|raw:<op>:<payload>` | 无头发写命令（+5s 发、+14s 退出），测协议写路径 |
| `EB_ADDRESS` | 指定蓝牙设备地址；`EB_INTERVAL` 心跳秒数（默认 15） |

## 已知坑（别再踩）

- 同进程**第一次** `openRFCOMMChannelSync` 必超时（`0xe00002bc`，约 3 秒），紧接着重试即成功。保留 3 次重试逻辑，别「优化」掉。
- 降噪/音效写命令只发一次、永不重试；确认 = 耳机回显（0402 count=1 块）或 `0484`/`0684` 状态字节。状态 `0x0e` = 拒绝 = 耳机不在佩戴状态（盒内必拒）。
- 协议**没有降噪查询命令**；初始降噪态未知，UI 显示「未知」直到耳机第一次主动推送。
- 自绘可点控件必须 `Button(.plain)` 打底，`onTapGesture` 在 NSPopover 里吞点击。
- NSPopover 窗口尺寸变化无动画；同步动画方案是逐帧 reveal（见 `toggleSound()` 与 DESIGN.md 落地要点）。
- 离屏渲染 grouped Form 必须固定 frame，否则 ImageRenderer 下高度塌陷。
- 降噪强度块 count=4 是「有效强度」伴随块，必须忽略，只认 count=1 的回显。

## 文件地图

| 文件 | 内容 |
|---|---|
| `Sources/main.swift` | 应用入口，先处理离屏渲染，再启动 AppKit |
| `Sources/EncoProtocol.swift` | 帧编解码、状态块解析和降噪/音效取值 |
| `Sources/EncoLink.swift` | RFCOMM 连接、命令队列、设备回报和会话快照 |
| `Sources/BatteryModel.swift` | SwiftUI 观察的电量、声音设置和连接状态 |
| `Sources/AppDelegate.swift` | 菜单栏、浮层和设置窗口的生命周期，连接会话与界面 |
| `Sources/BatteryPopover.swift` / `Sources/Settings.swift` | 菜单栏浮层、设置页与偏好持久化 |
| `Sources/DeveloperTools.swift` / `Sources/DebugLog.swift` | 演示数据、离屏渲染与调试日志 |
| `build.sh` | 通用二进制构建，`VERSION`/`BUILD` 在这里改 |
| `make_dmg.sh` | DMG + 安装说明（安装说明.txt 也在这维护） |
| `DESIGN.md` | UI 设计规范 + 本项目落地要点，**改 UI 前必读** |
| `AGENTS.md` | 开发约定（新会话在这个目录会自动加载） |
| `README.md` | 功能、截图、安装与构建 |
| `assets/` | README 截图；`dist/` DMG 产物；`gen_icon.py` 图标生成 |
