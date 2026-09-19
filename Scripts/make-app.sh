#!/bin/bash
# Assemble VoiceChat.app from the SwiftPM build products.
#
# Spec §14.2 — the daemon needs a real bundle: microphone and speech-recognition
# authorisation (TCC) is granted to a signed application bundle, and macOS
# terminates any process that asks for the microphone without the usage
# descriptions in Info.plist.
#
#   Scripts/make-app.sh [debug|release]

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/VoiceChat.app"
BUNDLE_ID="dev.sandipchitale.voicechat"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG" --product voicechatd
swift build -c "$CONFIG" --product voicechat-mcp

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ROOT/App/Info.plist" "$APP/Contents/Info.plist"
cp "$BUILD/voicechatd"     "$APP/Contents/MacOS/VoiceChat"
# R-ARCH-2 — one install provides both halves, so their versions cannot drift.
cp "$BUILD/voicechat-mcp"  "$APP/Contents/MacOS/voicechat-mcp"

echo "==> Signing"
# No Developer ID on this machine, so this is ad-hoc. `-i` pins a stable
# identifier so TCC has something durable to attach consent to; the cdhash
# still changes on every rebuild, so macOS may re-ask for the microphone after
# a build. A real signing identity removes the re-prompting.
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" -i "$BUNDLE_ID.mcp" \
    --options runtime --timestamp=none \
    "$APP/Contents/MacOS/voicechat-mcp" 2>/dev/null \
  || codesign --force --sign "$IDENTITY" -i "$BUNDLE_ID.mcp" "$APP/Contents/MacOS/voicechat-mcp"

codesign --force --sign "$IDENTITY" -i "$BUNDLE_ID" \
    --entitlements "$ROOT/App/VoiceChat.entitlements" \
    --options runtime --timestamp=none \
    "$APP" 2>/dev/null \
  || codesign --force --sign "$IDENTITY" -i "$BUNDLE_ID" \
       --entitlements "$ROOT/App/VoiceChat.entitlements" "$APP"

echo "==> Verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" | sed 's/^/    bundle id: /'

echo
echo "Built $APP"
echo "MCP server: $APP/Contents/MacOS/voicechat-mcp"
