#!/usr/bin/env bash
# Assembles a proper Maldari.app bundle from the SwiftPM executable.
# Needed because `swift build` produces a flat binary, and a flat binary
# shows a generic icon in System Preferences → Privacy.
#
# Usage:  bash Scripts/make-app.sh  [Debug|Release]
# Output: build/Maldari.app
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
CONFIG_LOWER=$(echo "$CONFIG" | tr '[:upper:]' '[:lower:]')

echo "==> swift build -c $CONFIG_LOWER"
swift build -c "$CONFIG_LOWER"

BIN_DIR=".build/arm64-apple-macosx/$CONFIG_LOWER"
BIN="$BIN_DIR/Translator"
if [[ ! -f "$BIN" ]]; then
    # Intel / universal fallback
    BIN_DIR=$(ls -d .build/*/$CONFIG_LOWER 2>/dev/null | head -1)
    BIN="$BIN_DIR/Translator"
fi

if [[ ! -f "$BIN" ]]; then
    echo "Could not find built executable under .build/" >&2
    exit 1
fi

# Bundle is Maldari.app; the executable inside stays "Translator" (matches
# CFBundleExecutable) and the bundle id stays com.translator.app so TCC
# permissions and Keychain items survive the product rename.
APP_DIR="build/Maldari.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

echo "==> copying binary"
cp "$BIN" "$APP_DIR/Contents/MacOS/Translator"
chmod +x "$APP_DIR/Contents/MacOS/Translator"

echo "==> copying Info.plist"
cp Translator/Info.plist "$APP_DIR/Contents/Info.plist"

echo "==> copying resource bundle (icon)"
RES_BUNDLE="$BIN_DIR/Translator_Translator.bundle"
if [[ -d "$RES_BUNDLE" ]]; then
    cp -R "$RES_BUNDLE" "$APP_DIR/Contents/Resources/"
fi

echo "==> placing icon at bundle root"
cp Translator/Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> stripping xattrs (extended attributes trip codesign)"
xattr -cr "$APP_DIR"

echo "==> ad-hoc code-signing"
codesign --force --deep --sign - --entitlements Translator/Translator.entitlements "$APP_DIR" 2>/dev/null || {
    echo "   (codesign without entitlements — fallback)"
    codesign --force --deep --sign - "$APP_DIR"
}

# Nudge LaunchServices to re-read the icon metadata. Without this, macOS
# often caches an older/generic icon for the bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DIR" >/dev/null 2>&1 || true
touch "$APP_DIR"

echo "==> done: $APP_DIR"
echo "    Launch it and grant Microphone and/or System Audio Recording to"
echo "    Maldari.app when prompted (System Settings → Privacy & Security)."
