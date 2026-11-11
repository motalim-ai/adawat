#!/bin/zsh
# Builds Adawat.app into build/ from the Swift package.
#   scripts/build-app.sh             release build in build/Adawat.app
#   scripts/build-app.sh --install   also copies it to /Applications and opens it there
#   scripts/build-app.sh --dmg       also makes build/Adawat-<version>.dmg for sharing
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="1.2.0"
INSTALL=false
DMG=false
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=true ;;
    --dmg) DMG=true ;;
  esac
done

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Adawat"

APP="build/Adawat.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Tools"
cp "$BIN" "$APP/Contents/MacOS/Adawat"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Translations: one .lproj folder per language.
for lproj in Resources/*.lproj(N); do cp -R "$lproj" "$APP/Contents/Resources/"; done

# Bundle the media tools so the app works on Macs without Homebrew.
find_tool() { for dir in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin; do [[ -x "$dir/$1" ]] && { echo "$dir/$1"; return; }; done; }
# ffmpeg comes from scripts/build-ffmpeg.sh: static, GPL v3, free libraries only. A build that says it is
# not redistributable (one with nonfree parts) is never copied into the app.
FFMPEG="build/ffmpeg/bin/ffmpeg"
[[ -x "$FFMPEG" ]] || FFMPEG="$(find_tool ffmpeg)"
if [[ -n "$FFMPEG" ]] && "$FFMPEG" -hide_banner -L 2>&1 | grep -qi "not legally redistributable"; then
  echo "Skipping $FFMPEG: it has nonfree parts. Run scripts/build-ffmpeg.sh for one that can ship." >&2
  FFMPEG=""
fi
if [[ -n "$FFMPEG" ]] && ! otool -L "$FFMPEG" | tail -n +2 | grep -qv -e '/usr/lib/' -e '/System/'; then
  cp "$FFMPEG" "$APP/Contents/Resources/Tools/ffmpeg"   # a static build: no libraries to carry
elif [[ -n "$FFMPEG" ]]; then
  python3 scripts/bundle-tool.py "$FFMPEG" "$APP/Contents/Resources/Tools"
fi
CWEBP="$(find_tool cwebp)"
[[ -n "$CWEBP" ]] && python3 scripts/bundle-tool.py "$CWEBP" "$APP/Contents/Resources/Tools"
# Licenses of everything bundled travel with the app.
cp LICENSE THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Adawat</string>
    <key>CFBundleDisplayName</key><string>Adawat</string>
    <key>CFBundleIdentifier</key><string>app.adawat.mac</string>
    <key>CFBundleExecutable</key><string>Adawat</string>
    <key>LSHasLocalizedDisplayName</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>ar</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key><string>Adawat asks Pages, Keynote and Numbers to convert Pages, Keynote, PowerPoint and older Excel files.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP" >/dev/null
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if $INSTALL; then
  pkill -x Adawat 2>/dev/null || true
  sleep 1
  rm -rf /Applications/Adawat.app
  ditto "$APP" /Applications/Adawat.app
  echo "Installed /Applications/Adawat.app"
  open /Applications/Adawat.app
fi

if $DMG; then
  STAGE="build/dmg"
  rm -rf "$STAGE" "build/Adawat-$VERSION.dmg"
  mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Adawat.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -quiet -volname "Adawat $VERSION" -srcfolder "$STAGE" -ov -format UDZO "build/Adawat-$VERSION.dmg"
  rm -rf "$STAGE"
  echo "Made build/Adawat-$VERSION.dmg ($(du -sh "build/Adawat-$VERSION.dmg" | cut -f1))"
fi
