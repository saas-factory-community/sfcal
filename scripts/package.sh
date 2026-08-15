#!/bin/bash
# Empaqueta sfcal como .app, firma ad-hoc e instala en ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/sfcal.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/SFCal "$APP/Contents/MacOS/sfcal"
cp assets/icon.icns "$APP/Contents/Resources/icon.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>sfcal</string>
  <key>CFBundleDisplayName</key><string>sfcal</string>
  <key>CFBundleIdentifier</key><string>com.saasfactory.sfcal</string>
  <key>CFBundleVersion</key><string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>sfcal</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict>
</plist>
EOF

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Firma ad-hoc estable: sin firma, Gatekeeper re-escanea el bundle en cada launch.
codesign --force --deep --sign - "$APP"

rm -rf "$HOME/Applications/sfcal.app"
mkdir -p "$HOME/Applications"
cp -R "$APP" "$HOME/Applications/sfcal.app"
codesign --verify "$HOME/Applications/sfcal.app"
echo "INSTALL_OK $HOME/Applications/sfcal.app"
