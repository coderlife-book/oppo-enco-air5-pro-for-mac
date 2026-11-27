# OPPO Enco Air5 Pro for Mac 开发约定

OPPO Enco Air5 Pro 的 macOS 菜单栏助手。使用 SwiftUI + AppKit，源码位于 `Sources/`，`build.sh` 出通用二进制。

## UI 规范

所有 UI 改动必须遵守 [DESIGN.md](DESIGN.md)（macOS 原生设计规范 + 本项目落地要点）。改 UI 前先读它，重点：

- 系统控件、系统字体、语义色优先；不做 Web 卡片风。
- 自绘可点控件用 `Button(.plain)` 打底，别用 `onTapGesture`。
- UI 只认耳机回显，不乐观更新。
- 小窗口不出现经典滚动条；文案极简。

## 协议与测试红线

- 写命令（降噪/音效）只发一次、永不重试；确认靠耳机回显。
- 新协议命令必须先有实机抓包，不许凭相似型号推断。
- 降噪写入需要耳机在佩戴状态，盒内会被拒（`0484 0e`）。
- 调试钩子：`EB_FAKE`（演示数据）、`EB_RENDER`/`EB_RENDER_SETTINGS`/`EB_SHOT`（离屏截图）、`EB_TEST`（无头发写命令）、`EB_ADDRESS`（指定设备）。改完 UI 用这些钩子渲染验证再提交。

## 发布

- Release 标题/正文中文优先（英文可附后）；仓库 description 中英并置；topics 英文。
- 版本号在 `build.sh` 的 `VERSION`/`BUILD`，DMG 用 `make_dmg.sh` 出到 `dist/`。
