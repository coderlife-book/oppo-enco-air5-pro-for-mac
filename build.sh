#!/bin/bash
# 编译 EncoBattery.app（本机 macOS，需 Xcode Command Line Tools）
# 产出通用二进制（Apple Silicon + Intel），可直接拷给别的 Mac 用。
set -euo pipefail
cd "$(dirname "$0")"

APP="EncoBattery.app"
VERSION="1.0.0"
BUILD="1"
ARCHS=(arm64 x86_64)

mkdir -p build
for arch in "${ARCHS[@]}"; do
    swiftc -O -swift-version 5 \
        -target "${arch}-apple-macosx13.0" \
        -framework Cocoa -framework IOBluetooth \
        -o "build/EncoBattery-${arch}" EncoBattery.swift
done
lipo -create -output build/EncoBattery "${ARCHS[@]/#/build/EncoBattery-}"

[ -f EncoBattery.icns ] || python3 gen_icon.py

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv build/EncoBattery "$APP/Contents/MacOS/EncoBattery"
cp EncoBattery.icns "$APP/Contents/Resources/EncoBattery.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>EncoBattery</string>
    <key>CFBundleDisplayName</key>     <string>耳机电量</string>
    <key>CFBundleExecutable</key>      <string>EncoBattery</string>
    <key>CFBundleIdentifier</key>      <string>local.encobattery</string>
    <key>CFBundleIconFile</key>        <string>EncoBattery</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>         <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSBluetoothAlwaysUsageDescription</key> <string>读取已配对耳机的电量</string>
</dict>
</plist>
PLIST

# 本地 ad-hoc 签名（没有开发者证书也能跑；对方首次打开需在「隐私与安全性」里放行）
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/EncoBattery")) — 运行: open $APP"
