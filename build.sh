#!/bin/bash
set -e
cd "$(dirname "$0")"

APP="MiddlePaste.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# MultitouchSupport 是系统私有框架，四指轻点要用到它
swiftc -O main.swift -o "$APP/Contents/MacOS/MiddlePaste" \
    -F /System/Library/PrivateFrameworks -framework MultitouchSupport

# 用 icon.png 生成应用图标（icon.png 要和本脚本放在同一个文件夹）
if [ -f icon.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
    echo "提示：没找到 icon.png，将使用默认图标"
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MiddlePaste</string>
    <key>CFBundleIdentifier</key><string>local.middlepaste</string>
    <key>CFBundleExecutable</key><string>MiddlePaste</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>用于读取 Finder 中选中的文件路径</string>
</dict>
</plist>
EOF

# 本地签名，让"辅助功能"授权在重新编译后不容易失效
codesign --force --sign - "$APP"

# 刷新图标缓存，避免 Finder 还显示旧的空白图标
touch "$APP"

echo "完成：$(pwd)/$APP"
echo "运行：open $APP"