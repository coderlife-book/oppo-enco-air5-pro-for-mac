# 交接文档

给下一个会话/Agent 的接力棒。更新时间：2026-11-27。

## 现状

- 代码全部在 `EncoBattery.swift`（单文件，约 2000 行），版本 **2.1.0**（`build.sh` 里 `VERSION=2.1.0 BUILD=4`），已提交推送，HEAD = `08571ba`。
- 本机 `/Applications/EncoBattery.app` 是 build 4，正在运行。
- 仓库：https://github.com/coderlife-book/oppo-enco-battery ，远端 main。
- **GitHub 最新 release 仍是 v2.0.0。2.1.0 代码完成但未发布，等用户验收 UI。**

## 2.1.0 相对 2.0.0 的变化

- 设置窗口（弹窗右下角齿轮，或右键菜单「设置…」，快捷键 `,`）：菜单栏图标开关 + 左耳/右耳/充电仓三个独立电量开关；「关于」节显示固件版本和应用版本。
- 菜单栏可选分耳电量（充电绿、≤10 红、≤20 橙；无数据的槽不显示）。
- 面板渐进式披露：「声音设置」入口默认折叠（显示当前摘要），点开才是降噪/强度/音效三段分段控件。
- 展开/收起动画 200ms：手动逐帧 reveal 驱动，窗口与内容同步（NSPopover 尺寸没有原生动画，实测单帧瞬跳）。
- 充电误报修复：`sideInCase` 放置门禁（0402 placement 04=盒内、05=盒外），盒外时充电标记强制清 false。

## 下一步（按序）

1. **等用户真鼠标点测**：分段按钮是否可点、展开/收起动画是否顺眼。通过才发版；点不动再查（先看是不是旧构建残留）。
2. 发版：`./build.sh && ./make_dmg.sh` 出 `dist/EncoBattery-2.1.0.dmg`，重渲染 README 截图（钩子见下），`gh release create v2.1.0`——标题正文中文优先，英文附后。
3. 功能候选（**用户没挑之前不要做**）：开机自启（SMAppService）、低电量通知、游戏低延迟（协议 0x0d01 查询 / 0x0304 写，必须先 `EB_TEST` 实机抓包验证）、全局快捷键、检查更新。

## 调试钩子（环境变量）

| 变量 | 作用 |
|---|---|
| `EB_FAKE=full\|charging\|empty\|anc\|smart\|eq\|offline` | 演示数据，不碰蓝牙 |
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
| `EncoBattery.swift` | 全部逻辑：帧编解码/协议 → EncoLink 会话 → BatteryModel → SwiftUI UI → AppDelegate |
| `build.sh` | 通用二进制构建，`VERSION`/`BUILD` 在这里改 |
| `make_dmg.sh` | DMG + 安装说明（安装说明.txt 也在这维护） |
| `DESIGN.md` | UI 设计规范 + 本项目落地要点，**改 UI 前必读** |
| `AGENTS.md` | 开发约定（新会话在这个目录会自动加载） |
| `README.md` | 用户文档（功能、协议原理、FAQ、环境变量表） |
| `assets/` | README 截图；`dist/` DMG 产物；`gen_icon.py` 图标生成 |
