#!/usr/bin/env bash
# build_dmg.sh — Build, sign, notarize, and package Orin.app into a DMG.
#
# Prerequisites:
#   - Xcode with Developer ID certificate installed in Keychain
#   - App Store Connect API key or Apple ID credentials for notarytool
#   - hdiutil (built-in macOS)
#   - create-dmg (optional, for custom background: brew install create-dmg)
#
# Environment variables (all required for signing/notarization):
#   DEVELOPER_ID_APP     — e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_TEAM_ID        — Your 10-character Apple team ID
#   NOTARY_APPLE_ID      — Apple ID email for notarytool (or leave empty to use API key)
#   NOTARY_PASSWORD      — App-specific password for notarytool (or @keychain:...)
#   NOTARY_API_KEY_ID    — App Store Connect API key ID (alternative to Apple ID)
#   NOTARY_API_KEY_PATH  — Path to .p8 API key file (alternative to Apple ID)
#
# Usage:
#   ./scripts/build_dmg.sh                # uses current Xcode project
#   ./scripts/build_dmg.sh --skip-notary  # build + sign only, no notarization

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Orin.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Orin.app"
DMG_DIR="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/Orin.dmg"
XCPROJECT="$REPO_ROOT/Orin.xcodeproj"

SKIP_NOTARY=false
for arg in "$@"; do
  [[ "$arg" == "--skip-notary" ]] && SKIP_NOTARY=true
done

# ── Helpers ─────────────────────────────────────────────────────────────────

log() { echo "▶ $*"; }
die() { echo "✖ ERROR: $*" >&2; exit 1; }

check_env() {
  local var="$1"
  [[ -n "${!var:-}" ]] || die "Environment variable $var is not set."
}

# ── 0. Pre-flight checks ─────────────────────────────────────────────────────

log "Checking prerequisites..."
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."
[[ -f "$XCPROJECT/project.pbxproj" ]] || die "Orin.xcodeproj not found at $XCPROJECT. Run: xcodegen generate"

if [[ "$SKIP_NOTARY" == false ]]; then
  check_env DEVELOPER_ID_APP
  check_env APPLE_TEAM_ID
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── 1. Archive ───────────────────────────────────────────────────────────────

log "Archiving Orin..."
xcodebuild archive \
  -project "$XCPROJECT" \
  -scheme Orin \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}" \
  CODE_SIGN_STYLE="Manual" \
  CODE_SIGN_IDENTITY="${DEVELOPER_ID_APP:-}" \
  | xcpretty 2>/dev/null || true

[[ -d "$ARCHIVE_PATH" ]] || die "Archive failed — check Xcode build log."

# ── 2. Export ────────────────────────────────────────────────────────────────

log "Exporting app..."
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>${APPLE_TEAM_ID:-YOURTEAMID}</string>
  <key>signingStyle</key>
  <string>manual</string>
  <key>signingCertificate</key>
  <string>${DEVELOPER_ID_APP:-Developer ID Application}</string>
  <key>hardendedRuntime</key>
  <true/>
  <key>stripSwiftSymbols</key>
  <true/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  | xcpretty 2>/dev/null || true

[[ -d "$APP_PATH" ]] || die "Export failed — Orin.app not found at $APP_PATH."

# ── 3. Notarize ──────────────────────────────────────────────────────────────

if [[ "$SKIP_NOTARY" == false ]]; then
  log "Creating zip for notarization..."
  ZIP_PATH="$BUILD_DIR/Orin.zip"
  ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

  log "Submitting to Apple Notary Service..."
  if [[ -n "${NOTARY_API_KEY_ID:-}" ]]; then
    xcrun notarytool submit "$ZIP_PATH" \
      --key "$NOTARY_API_KEY_PATH" \
      --key-id "$NOTARY_API_KEY_ID" \
      --issuer "$APPLE_TEAM_ID" \
      --wait \
      --timeout 600
  else
    check_env NOTARY_APPLE_ID
    check_env NOTARY_PASSWORD
    xcrun notarytool submit "$ZIP_PATH" \
      --apple-id "$NOTARY_APPLE_ID" \
      --password "$NOTARY_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait \
      --timeout 600
  fi

  log "Stapling notarization ticket..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  log "Notarization complete."
fi

# ── 4. Package DMG ───────────────────────────────────────────────────────────

log "Creating DMG..."
rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/Orin.app"
ln -sf /Applications "$DMG_DIR/Applications"

hdiutil create \
  -volname "Orin" \
  -srcfolder "$DMG_DIR" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "$DMG_PATH"

if [[ "$SKIP_NOTARY" == false && -n "${DEVELOPER_ID_APP:-}" ]]; then
  log "Signing DMG..."
  codesign --sign "${DEVELOPER_ID_APP}" --timestamp "$DMG_PATH"

  log "Notarizing DMG..."
  if [[ -n "${NOTARY_API_KEY_ID:-}" ]]; then
    xcrun notarytool submit "$DMG_PATH" \
      --key "$NOTARY_API_KEY_PATH" \
      --key-id "$NOTARY_API_KEY_ID" \
      --issuer "$APPLE_TEAM_ID" \
      --wait
  else
    xcrun notarytool submit "$DMG_PATH" \
      --apple-id "$NOTARY_APPLE_ID" \
      --password "$NOTARY_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" \
      --wait
  fi
  xcrun stapler staple "$DMG_PATH"
fi

# ── 5. Verify ────────────────────────────────────────────────────────────────

log "Verifying DMG..."
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 || true

echo ""
echo "✅ Done! DMG ready at: $DMG_PATH"
echo ""
echo "Install on a clean machine:"
echo "  1. Open $DMG_PATH"
echo "  2. Drag Orin.app to Applications"
echo "  3. Launch from /Applications — Gatekeeper will verify the notarization ticket."
echo "  4. Enable 'Launch at login' in Orin → Settings → General."
echo "  5. Grant Calendar, Microphone, Speech Recognition, and Apple Events permissions."
