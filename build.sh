#!/bin/zsh
# Builds Utter.app and installs it to /Applications.
# Usage: ./build.sh [model.bin]   (default: models/ggml-large-v3-turbo-q5_0.bin)
set -euo pipefail
cd "${0:A:h}"

MODEL="${1:-$PWD/models/ggml-large-v3-turbo-q5_0.bin}"
WHISPER="$(command -v whisper-cli || echo /opt/homebrew/bin/whisper-cli)"
IDENTITY="Utter Local Signing"
[[ -f "$MODEL" ]] || { echo "Model not found: $MODEL"; exit 1; }

swift build -c release

# App icon (generated once).
if [[ ! -f build/AppIcon.icns ]]; then
  mkdir -p build/AppIcon.iconset
  swift scripts/make-icon.swift build/icon-1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

APP="$PWD/build/Utter.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Utter "$APP/Contents/MacOS/Utter"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Fonts "$APP/Contents/Resources/Fonts"
cp "$MODEL" "$APP/Contents/Resources/model.bin"
# A self-contained whisper-cli (built by scripts/build-whisper.sh) makes the app work without Homebrew.
if [[ -x build/whisper-cli ]]; then cp build/whisper-cli "$APP/Contents/MacOS/whisper-cli"; fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.utter</string>
  <key>CFBundleName</key><string>Utter</string>
  <key>CFBundleDisplayName</key><string>Utter</string>
  <key>CFBundleExecutable</key><string>Utter</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSMicrophoneUsageDescription</key><string>Utter records your voice while you are dictating or taking meeting notes.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Utter shows a card when a meeting on your calendar is about to start.</string>
  <key>NSCalendarsUsageDescription</key><string>Utter shows a card when a meeting on your calendar is about to start.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Utter records meeting audio to write meeting notes.</string>
  <key>UtterWhisperPath</key><string>$WHISPER</string>
</dict></plist>
PLIST

# A stable identity keeps the Accessibility permission across rebuilds; fall back to ad-hoc.
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  echo "No '$IDENTITY' identity (run scripts/make-cert.sh); signing ad-hoc"
  codesign --force --sign - "$APP"
fi

pkill -x Utter 2>/dev/null && sleep 1 || true
rm -rf /Applications/Utter.app
ditto "$APP" /Applications/Utter.app
echo "Installed /Applications/Utter.app"
