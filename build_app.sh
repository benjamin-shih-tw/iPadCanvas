#!/bin/zsh
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

APP_NAME="iPadCanvas"
APP_BUNDLE="$PROJECT_DIR/${APP_NAME}.app"
BUILD_DIR="$PROJECT_DIR/build"
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
TARGET_TRIPLE="arm64-apple-macosx${MACOS_MAJOR}.0"

echo "==> [1/4] 編譯 AirPlay 無線鏡像 C 核心程式庫 (${TARGET_TRIPLE})..."
mkdir -p "$BUILD_DIR/obj"
clang -target "$TARGET_TRIPLE" -O2 -DNOHOLD -DEXTERNAL_DNS_SD -DUXPLAY_HAVE_APPLE_P2P -DPLIST_210 -DPLIST_230 \
    -IVendor/uxplay_lib \
    -IVendor/uxplay_lib/playfair \
    -IVendor/uxplay_lib/llhttp \
    -I/opt/homebrew/opt/openssl@3/include \
    -I/opt/homebrew/opt/libplist/include \
    -c Vendor/uxplay_lib/*.c \
       Vendor/uxplay_lib/playfair/*.c \
       Vendor/uxplay_lib/llhttp/*.c \
       Vendor/uxplay_lib/dns_sd/*.c \
       Sources/CAirPlayBridge/airplay_bridge.c
mv *.o "$BUILD_DIR/obj/"
ar rcs "$BUILD_DIR/libairplay_core.a" "$BUILD_DIR/obj/"*.o

echo "==> [2/4] 編譯原生 macOS Swift + VideoToolbox 硬體解碼程式..."
swiftc -target "$TARGET_TRIPLE" -O \
    -import-objc-header Sources/CAirPlayBridge/include/airplay_bridge.h \
    Sources/iPadCanvas/*.swift \
    "$BUILD_DIR/libairplay_core.a" \
    /opt/homebrew/opt/openssl@3/lib/libcrypto.a \
    /opt/homebrew/opt/libplist/lib/libplist-2.0.a \
    -framework AppKit \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreMediaIO \
    -framework CoreVideo \
    -framework VideoToolbox \
    -framework QuartzCore \
    -framework IOSurface \
    -framework Carbon \
    -o "$BUILD_DIR/$APP_NAME"

echo "==> [3/4] 封裝 macOS 應用程式套件 (${APP_NAME}.app)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [ -f "$PROJECT_DIR/Resources/AppIcon.png" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_TW</string>
    <key>CFBundleDisplayName</key>
    <string>iPad 畫布視窗</string>
    <key>CFBundleExecutable</key>
    <string>iPadCanvas</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.busyhertz.ipadcanvas</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>iPad 畫布視窗</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>需要視訊輸入權限以透過 USB 顯示 iPad 畫面。</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>需要區域網路權限以作為視窗化 AirPlay 接收器顯示 iPad 畫面。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_airplay._tcp</string>
        <string>_raop._tcp</string>
    </array>
</dict>
</plist>
EOF

echo "==> [4/4] 簽署應用程式套件..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "✅ 建置完成：$APP_BUNDLE"
