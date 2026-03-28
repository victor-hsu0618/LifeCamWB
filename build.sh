#!/usr/bin/env bash
set -euo pipefail

APP="LifeCamWB.app"
UNIVERSAL_DIR=".build/apple/Products/Release"

echo "==> Building Swift package (release, universal x86_64 + arm64)..."
swift build -c release --arch arm64 --arch x86_64 2>&1

echo "==> Creating app bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$UNIVERSAL_DIR/LifeCamWB" "$APP/Contents/MacOS/LifeCamWB"

# Verify universal binary
echo "==> Architectures:"
lipo -info "$APP/Contents/MacOS/LifeCamWB"

cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.local.LifeCamWB</string>
    <key>CFBundleName</key>
    <string>LifeCamWB</string>
    <key>CFBundleExecutable</key>
    <string>LifeCamWB</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>NSCameraUsageDescription</key>
    <string>LifeCamWB needs camera access to show the live preview.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)..."
ENTITLEMENTS_FILE=$(mktemp /tmp/lifecam.entitlements.XXXXXX.plist)
cat > "$ENTITLEMENTS_FILE" << 'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
ENT

codesign --force --sign - \
    --entitlements "$ENTITLEMENTS_FILE" \
    "$APP/Contents/MacOS/LifeCamWB"

codesign --force --sign - "$APP"
rm -f "$ENTITLEMENTS_FILE"

echo ""
echo "✓ Built: $APP (Universal — x86_64 + arm64)"
echo ""
echo "Run with:"
echo "  open $APP"
