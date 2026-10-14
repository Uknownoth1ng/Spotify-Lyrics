#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="SpotLyrics Bar"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
EXECUTABLE="$ROOT_DIR/.build/release/SpotLyricsBar"

cd "$ROOT_DIR"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/SpotLyricsBar"

# Generate app icon if source PNG exists, otherwise skip.
ICON_SRC="$ROOT_DIR/Assets/AppIcon.png"
if [ -f "$ICON_SRC" ]; then
    ICONSET="$ROOT_DIR/.build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true
    rm -rf "$ICONSET"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SpotLyricsBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>local.spotlyrics.bar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>SpotLyrics Bar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SpotLyrics Bar reads the current Spotify track and playback position to show synced lyrics.</string>
    <key>NSSystemAudioRecordingUsageDescription</key>
    <string>SpotLyrics Bar captures system audio to transcribe podcast speech in real-time for subtitles.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>SpotLyrics Bar captures system audio to transcribe podcast speech in real-time for subtitles.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>SpotLyrics Bar uses the audio-capture TCC class to access Core Audio process taps for podcast transcription. The microphone itself is not recorded.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>SpotLyrics Bar uses speech recognition to generate real-time subtitles for podcasts.</string>
</dict>
</plist>
PLIST


# Ad-hoc sign so macOS gives the binary a stable code-signature identity. Without
# this, every fresh build is treated as a new app by the Keychain, which fires a
# password prompt at launch on every reinstall.
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "Created: $APP_DIR"
