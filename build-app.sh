#!/bin/sh
# 编译并打包成可直接运行的 MiniShot.app 和 MiniShot.zip
set -e
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

APP=build/MiniShot.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MiniShot" "$APP/Contents/MacOS/MiniShot"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

VERSION="${VERSION:-0.1.0}"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MiniShot</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.minishot</string>
    <key>CFBundleName</key>
    <string>MiniShot</string>
    <key>CFBundleDisplayName</key>
    <string>MiniShot</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- 只在菜单栏显示，不出现在 Dock -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# 没有开发者证书，用 ad-hoc 签名
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" build/MiniShot.zip
echo "已生成 $APP 和 build/MiniShot.zip"
