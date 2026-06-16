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

# Prefer a stable self-signed identity. Ad-hoc signing (`--sign -`) changes the
# code signature on every rebuild, and the login Keychain locks saved API keys
# to the signature that created them — so ad-hoc rebuilds lose the keys. A fixed
# cert keeps the signature (and Keychain ACL) constant. Create it once with:
#   openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
#     -keyout key.pem -out cert.pem -subj "/CN=Maldari Code Signing" \
#     -addext "basicConstraints=critical,CA:false" \
#     -addext "keyUsage=critical,digitalSignature" \
#     -addext "extendedKeyUsage=critical,codeSigning"
#   openssl pkcs12 -export -legacy -out id.p12 -inkey key.pem -in cert.pem -passout pass:maldari
#   security import id.p12 -k ~/Library/Keychains/login.keychain-db -P maldari -T /usr/bin/codesign
#   security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db cert.pem
SIGN_ID="Maldari Code Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> code-signing with stable identity: $SIGN_ID"
    SIGN="$SIGN_ID"
else
    echo "==> ad-hoc code-signing ('$SIGN_ID' not found — saved API keys will NOT"
    echo "    persist across rebuilds; see the comment in this script to create it)"
    SIGN="-"
fi
codesign --force --deep --sign "$SIGN" --entitlements Translator/Translator.entitlements "$APP_DIR" 2>/dev/null || {
    echo "   (codesign without entitlements — fallback)"
    codesign --force --deep --sign "$SIGN" "$APP_DIR"
}

# Nudge LaunchServices to re-read the icon metadata. Without this, macOS
# often caches an older/generic icon for the bundle.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP_DIR" >/dev/null 2>&1 || true
touch "$APP_DIR"

echo "==> done: $APP_DIR"
echo "    Launch it and grant Microphone and/or System Audio Recording to"
echo "    Maldari.app when prompted (System Settings → Privacy & Security)."
