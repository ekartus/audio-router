#!/bin/bash
# Build MixerApp and assemble a menu-bar .app bundle, then ad-hoc sign it.
# Portable/defensive: no `set -u` (so a stray/empty var never hard-aborts), and
# every variable has an explicit default.
set -eo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIG="${1:-release}"
case "$CONFIG" in
    debug|release) ;;
    *) echo "> Ignoring invalid configuration '$CONFIG'; using release."; CONFIG="release" ;;
esac

APP_NAME="Audio Router"
BUNDLE_ID="com.mixerapp.AudioRouter"
BUILD_DIR=".build/${CONFIG}"
APP_DIR="dist/${APP_NAME}.app"

echo "> Building MixerApp (${CONFIG})..."
swift build -c "${CONFIG}" --product MixerApp

echo "> Assembling bundle at ${APP_DIR}..."
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS" "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/MixerApp" "${APP_DIR}/Contents/MacOS/MixerApp"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>MixerApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Audio Router captures the audio of the apps you choose so it can send it to your selected output device.</string>
</dict>
</plist>
PLIST

echo "> Ad-hoc signing..."
codesign --force --deep --sign - "${APP_DIR}"

if [ -d "${APP_DIR}" ]; then
    echo "OK: built ${APP_DIR}"
    echo "    Launch with:  open \"${APP_DIR}\""
else
    echo "ERROR: bundle was not created at ${APP_DIR}" >&2
    exit 1
fi
