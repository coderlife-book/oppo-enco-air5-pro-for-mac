#!/bin/bash
# 打包可分发的 DMG：dist/EncoBattery-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" EncoBattery.app/Contents/Info.plist)
STAGE="build/dmg"
DMG="dist/EncoBattery-$VERSION.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE" dist
cp -R EncoBattery.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
EncoBattery —— 在菜单栏显示 OPPO Enco Air5 Pro 的左右耳和充电仓电量，
还能切换降噪模式和音效、查看固件版本。

安装
1. 把左边的 EncoBattery 拖到右边的 Applications（应用程序）文件夹。
2. 首次打开会被 macOS 拦下（没有开发者证书、未公证），这是正常现象，放行一次即可：
   先双击打开一次 → 提示「Apple 无法验证…」→ 点「完成」；
   然后打开「系统设置 → 隐私与安全性」，页面下方找到 EncoBattery，点「仍要打开」→ 输入密码。
   （macOS 14 及更早版本也可以直接在 Finder 里右键点 EncoBattery →「打开」→ 再点「打开」。）
3. 打开后 Dock 里没有图标，电量显示在屏幕右上角菜单栏（耳机图标 + 百分比）。
   左键点它：看左右耳和充电仓电量、切换降噪（降噪/关闭/通透 + 强度）和音效、看固件版本。
   右键点它：刷新、重连耳机、退出。

降噪小贴士
· 降噪模式需要耳机在佩戴状态才能切换；耳机在充电盒里时耳机会拒绝切换（提示未确认）。
· 当前降噪模式由耳机主动回报，第一次切换或用手机切换后才会显示。

前提
· macOS 13 或更新（Intel 和 Apple Silicon 都支持）。
· 耳机需要先在这台 Mac 上完成蓝牙配对并连接。
· 只在耳机连着本机时才读得到；耳机在仓里时才会多出「充电仓」这一项。
TXT

rm -f "$DMG"
hdiutil create -volname "EncoBattery $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "打包完成: $DMG ($(du -h "$DMG" | cut -f1))"
