#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Buds.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Buds" "$app/Contents/MacOS/Buds"
cp Sources/Buds/Resources/*.png "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Buds</string>
<key>CFBundleIdentifier</key><string>dev.buds.menubar</string>
<key>CFBundleName</key><string>Buds</string>
<key>CFBundleDisplayName</key><string>Buds</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Buds reads battery levels from your paired Pixel Buds.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Buds reads battery levels from your paired Pixel Buds.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
print "Built $app"
