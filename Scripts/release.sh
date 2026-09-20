#!/bin/bash
# Build the distributable zip for a GitHub release.
#
#   Scripts/release.sh 0.0.1
#
# The app is ad-hoc signed, not Developer ID signed or notarised, so macOS
# quarantines a downloaded copy and Gatekeeper refuses it until the person
# clears the quarantine flag. The README's "Install from a release" section
# documents that step; nothing here can remove the need for it.
#
# This builds and verifies only. It does not tag, push or publish — the last
# line printed is the command that would.

set -euo pipefail

VERSION="${1:?usage: Scripts/release.sh <version>   e.g. 0.0.1}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/.build/VoiceChat.app"
DIST="$ROOT/dist"
ZIP="$DIST/VoiceChat-$VERSION.zip"

echo "==> Checking the version is $VERSION everywhere it is written down"
fail=0
check() {
    if [ "$2" != "$VERSION" ]; then
        echo "    MISMATCH: $1 is '$2', expected '$VERSION'" >&2
        fail=1
    fi
}
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$ROOT/App/Info.plist"; }
constant() { grep -Eo '"[0-9]+\.[0-9]+\.[0-9]+"' "$1" | head -1 | tr -d '"'; }
check "App/Info.plist CFBundleShortVersionString" "$(plist CFBundleShortVersionString)"
check "App/Info.plist CFBundleVersion" "$(plist CFBundleVersion)"
check "Sources/VoiceChatKit/VoiceChatVersion.swift" "$(constant "$ROOT/Sources/VoiceChatKit/VoiceChatVersion.swift")"
if [ "$fail" -ne 0 ]; then
    echo "    Update those to $VERSION and re-run." >&2
    exit 1
fi

echo "==> Building universal release app"
UNIVERSAL=1 "$ROOT/Scripts/make-app.sh" release

echo "==> Checking architectures"
for bin in VoiceChat voicechat-mcp; do
    archs="$(lipo -archs "$APP/Contents/MacOS/$bin")"
    echo "    $bin: $archs"
    case "$archs" in *arm64*x86_64*|*x86_64*arm64*) ;; *)
        echo "    expected a universal binary" >&2; exit 1 ;;
    esac
done

echo "==> Packaging"
mkdir -p "$DIST"
rm -f "$ZIP" "$ZIP.sha256"
# ditto, not zip: it preserves the bundle's signature, symlinks and attributes.
ditto -c -k --keepParent "$APP" "$ZIP"
( cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256" )

echo "==> Verifying the zip round-trips with a valid signature"
CHECK="$(mktemp -d)"
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k "$ZIP" "$CHECK"
codesign --verify --deep --strict "$CHECK/VoiceChat.app"
echo "    signature intact after unzip"

echo
echo "Built:"
ls -lh "$ZIP" | awk '{print "    " $5 "  " $9}'
sed 's/^/    /' "$ZIP.sha256"
echo
NOTES="$ROOT/release-notes/v$VERSION.md"
[ -f "$NOTES" ] || echo "WARNING: no release notes at $NOTES" >&2
PRE=""
case "$VERSION" in 0.*) PRE=" --prerelease" ;; esac
echo "To publish (not run):"
echo "    gh release create v$VERSION \"$ZIP\" \"$ZIP.sha256\" --title \"VoiceChat $VERSION\" --notes-file \"$NOTES\"$PRE"
