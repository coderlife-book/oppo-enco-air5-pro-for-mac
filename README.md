# OPPO Enco Air5 Pro for Mac

在 macOS 菜单栏查看左右耳和充电仓电量，切换降噪、通透和音效。设置中可选择显示哪些电量，并查看固件版本。

[下载最新版 DMG](https://github.com/coderlife-book/oppo-enco-air5-pro-for-mac/releases/latest) · macOS 13+ · Apple Silicon / Intel

## 截图

| 外观 | 电量概览 | 声音设置 | 设置窗口 |
| --- | :---: | :---: | :---: |
| 浅色 | ![浅色电量概览](assets/battery-overview-light.png) | ![浅色声音设置](assets/sound-controls-light.png) | ![浅色设置窗口](assets/settings-window-light.png) |
| 深色 | ![深色电量概览](assets/battery-overview-dark.png) | ![深色声音设置](assets/sound-controls-dark.png) | ![深色设置窗口](assets/settings-window-dark.png) |

## 安装

1. 将 OPPO Enco Air5 Pro 与 Mac 配对并连接。
2. 打开 DMG，将 `EncoBattery.app` 拖入「应用程序」。升级前请退出旧版。
3. 打开应用后，点击菜单栏的耳机图标。切换降噪时请佩戴耳机。

安装包采用临时签名，未经 Apple 公证。如果首次打开被拦截，请核对下载来源，再按 Apple 的说明操作。[在 Mac 上安全打开 App](https://support.apple.com/zh-cn/102445)

## 从源码构建

需要 Xcode Command Line Tools。

```bash
./build.sh
open EncoBattery.app
```

[MIT 许可证](LICENSE) · OPPO Enco Air5 Pro 的独立社区项目。
