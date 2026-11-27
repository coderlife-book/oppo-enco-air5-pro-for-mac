#!/bin/bash
# 打包可分发的 DMG 到 dist/。
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP="EncoBattery.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
PRODUCT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$APP/Contents/Info.plist")
STAGE="build/dmg"
DMG="dist/${PRODUCT// /-}-$VERSION.dmg"

rm -rf "$STAGE"
mkdir -p "$STAGE" dist
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'TXT'
OPPO Enco Air5 Pro for Mac

需要 macOS 13 或更新版本，支持 Apple Silicon 和 Intel。
先将 OPPO Enco Air5 Pro 与 Mac 配对并连接。

1. 升级时请先退出旧版，再将 EncoBattery.app 拖入「应用程序」。
2. 从「应用程序」打开。安装包采用临时签名，未经 Apple 公证。
   如果 macOS 阻止打开，请先核对下载来源，再到「系统设置 → 隐私与安全性」点击「仍要打开」。
3. 点击菜单栏的耳机图标查看电量，展开「声音设置」可切换降噪、通透和音效。
   切换降噪时请佩戴耳机。点击右下角齿轮可打开设置，查看固件版本。

https://github.com/coderlife-book/oppo-enco-air5-pro-for-mac
TXT

hdiutil create -volname "$PRODUCT $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "打包完成: $DMG ($(du -h "$DMG" | cut -f1))"
