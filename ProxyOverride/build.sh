#!/bin/sh
# Builds ProxyOverride.app (menu bar app) into ./build. Usage: ./build.sh [--install]
set -e
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ProxyOverride"

APP=build/ProxyOverride.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProxyOverride"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Proxy Override</string>
    <key>CFBundleDisplayName</key><string>Proxy Override</string>
    <key>CFBundleIdentifier</key><string>local.ProxyOverride</string>
    <key>CFBundleExecutable</key><string>ProxyOverride</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally.
codesign --force --deep --sign - "$APP"
echo "built $APP"

if [ "$1" = "--install" ]; then
    # quit normally so the app restores the macOS proxy settings; pkill skips that
    if pgrep -x ProxyOverride >/dev/null; then
        osascript -e 'tell application id "local.ProxyOverride" to quit' 2>/dev/null || true
        for _ in 1 2 3 4 5; do pgrep -x ProxyOverride >/dev/null || break; sleep 1; done
        pkill -x ProxyOverride 2>/dev/null || true
    fi
    rm -rf /Applications/ProxyOverride.app
    cp -R "$APP" /Applications/
    echo "installed /Applications/ProxyOverride.app"
fi
