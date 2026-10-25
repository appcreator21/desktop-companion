#!/bin/bash
# Builds Genie.app so you can double-click it and give it permissions.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP="build/Genie.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Genie "$APP/Contents/MacOS/Genie"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Genie</string>
    <key>CFBundleDisplayName</key><string>Genie</string>
    <key>CFBundleIdentifier</key><string>com.genie.companion</string>
    <key>CFBundleExecutable</key><string>Genie</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS remembers permissions between launches.
codesign --force --deep --sign - "$APP"
echo "Built $APP. Run it with: open $APP"
