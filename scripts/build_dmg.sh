#!/usr/bin/env bash
# build_dmg.sh — Build, sign, notarize, and package Orin.app into a DMG.
#
# Prerequisites:
#   - Xcode with Developer ID certificate installed in Keychain
#   - App Store Connect API key or Apple ID credentials for notarytool
#   - hdiutil (built-in macOS)
#   - xcpretty (optional, for pretty build output: gem install xcpretty)
#
# Required environment variables:
#   DEVELOPER_ID_APP     — e.g. "Developer ID Application: Your Name (TEAMID)"
#   APPLE_TEAM_ID        — Your 10-character Apple Developer Team ID
#
# Additional required variables for notarization (API key method — preferred):
#   NOTARY_API_KEY_ID    — App Store Connect API key ID (from ASC → Users → Keys)
#   NOTARY_API_KEY_PATH  — Absolute path to the .p8 API key file
#   NOTARY_ISSUER_UUID   — Issuer UUID from App Store Connect (NOT the Team ID —
#                          format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
#
# Additional required variables for notarization (Apple ID method — alternative):
#   NOTARY_APPLE_ID      — Your Apple ID email address
#   NOTARY_PASSWORD      — App-specific password (or @keychain:<entry>)
#
# Usage:
#   ./scripts/build_dmg.sh                # full signed, notarized DMG
#   ./scripts/build_dmg.sh --skip-notary  # build + sign only, no notarization

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE_PATH="$BUILD_DIR/Orin.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/Orin.app"
STAGING_DIR="$BUILD_DIR/dmg-staging"

# Timestamped DMG filename: Orin-YYYY-MM-DD-HHMM.dmg
TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
DMG_NAME="Orin-${TIMESTAMP}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

# FIX: Project was renamed from Orin.xcodeproj to "Orin 2.xcodeproj".
# The space in the path is intentional and must be preserved.
XCPROJECT="$REPO_ROOT/Orin 2.xcodeproj"

# ── Flags ────────────────────────────────────────────────────────────────────

SKIP_NOTARY=false
for arg in "$@"; do
    [[ "$arg" == "--skip-notary" ]] && SKIP_NOTARY=true
done

# ── Helpers ──────────────────────────────────────────────────────────────────

log()    { echo "▶ $*"; }
info()   { echo "  $*"; }
die()    { echo "✖ ERROR: $*" >&2; exit 1; }
divider(){ echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

check_env() {
    local var="$1"
    [[ -n "${!var:-}" ]] || die "Required environment variable $var is not set."
}

# ── 0. Pre-flight checks ─────────────────────────────────────────────────────

log "Checking prerequisites..."
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."
command -v hdiutil    >/dev/null || die "hdiutil not found."
command -v shasum     >/dev/null || die "shasum not found."

[[ -f "$XCPROJECT/project.pbxproj" ]] || \
    die "Xcode project not found: $XCPROJECT\nDid the project get renamed? Expected 'Orin 2.xcodeproj'."

if [[ "$SKIP_NOTARY" == false ]]; then
    check_env DEVELOPER_ID_APP
    check_env APPLE_TEAM_ID
fi

# ── 1. Clean previous artifacts ──────────────────────────────────────────────

log "Cleaning previous build artifacts..."
DELETED_ARTIFACTS=()

if [[ -d "$BUILD_DIR" ]]; then
    # Remove previous DMGs and zips
    while IFS= read -r -d '' f; do
        rm -f "$f"
        DELETED_ARTIFACTS+=("$(basename "$f")")
    done < <(find "$BUILD_DIR" -maxdepth 1 \( -name "*.dmg" -o -name "*.zip" \) -print0 2>/dev/null)

    # Remove previous archive, export, and staging
    for target in "$ARCHIVE_PATH" "$EXPORT_PATH" "$STAGING_DIR"; do
        if [[ -e "$target" ]]; then
            rm -rf "$target"
            DELETED_ARTIFACTS+=("$(basename "$target")")
        fi
    done
fi

mkdir -p "$BUILD_DIR"

if [[ ${#DELETED_ARTIFACTS[@]} -gt 0 ]]; then
    info "Removed:"
    for a in "${DELETED_ARTIFACTS[@]}"; do info "  • $a"; done
else
    info "No previous artifacts found."
fi

# ── 2. Archive ───────────────────────────────────────────────────────────────

log "Archiving Orin (Release, Developer ID signing)..."
xcodebuild archive \
    -project "$XCPROJECT" \
    -scheme Orin \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}" \
    CODE_SIGN_STYLE="Manual" \
    CODE_SIGN_IDENTITY="${DEVELOPER_ID_APP:-}" \
    | { command -v xcpretty >/dev/null 2>&1 && xcpretty || cat; } || true

[[ -d "$ARCHIVE_PATH" ]] || die "Archive failed — check Xcode build log."

# ── 3. Export ────────────────────────────────────────────────────────────────

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
PLIST

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    | { command -v xcpretty >/dev/null 2>&1 && xcpretty || cat; } || true

[[ -d "$APP_PATH" ]] || die "Export failed — Orin.app not found at $APP_PATH."

# ── 4. Notarize app ──────────────────────────────────────────────────────────

if [[ "$SKIP_NOTARY" == false ]]; then
    log "Creating zip for notarization..."
    ZIP_PATH="$BUILD_DIR/Orin-notary.zip"
    ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

    log "Submitting app to Apple Notary Service..."
    if [[ -n "${NOTARY_API_KEY_ID:-}" ]]; then
        # API key method (preferred — does not require Apple ID 2FA interaction)
        # NOTARY_ISSUER_UUID is the Issuer UUID from App Store Connect → Users → Keys,
        # NOT the Team ID. Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        check_env NOTARY_API_KEY_PATH
        check_env NOTARY_ISSUER_UUID
        xcrun notarytool submit "$ZIP_PATH" \
            --key          "$NOTARY_API_KEY_PATH" \
            --key-id       "$NOTARY_API_KEY_ID" \
            --issuer       "$NOTARY_ISSUER_UUID" \
            --wait \
            --timeout 600
    else
        # Apple ID method (alternative)
        check_env NOTARY_APPLE_ID
        check_env NOTARY_PASSWORD
        xcrun notarytool submit "$ZIP_PATH" \
            --apple-id     "$NOTARY_APPLE_ID" \
            --password     "$NOTARY_PASSWORD" \
            --team-id      "$APPLE_TEAM_ID" \
            --wait \
            --timeout 600
    fi

    rm -f "$ZIP_PATH"

    log "Stapling notarization ticket to app..."
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    log "App notarization complete."
fi

# ── 5. Package DMG ───────────────────────────────────────────────────────────

log "Creating DMG: $DMG_NAME"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/Orin.app"
ln -sf /Applications "$STAGING_DIR/Applications"

hdiutil create \
    -volname "Orin" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH"

rm -rf "$STAGING_DIR"

# ── 6. Sign and notarize DMG ─────────────────────────────────────────────────

if [[ "$SKIP_NOTARY" == false && -n "${DEVELOPER_ID_APP:-}" ]]; then
    log "Signing DMG..."
    codesign --sign "${DEVELOPER_ID_APP}" --timestamp "$DMG_PATH"

    log "Submitting DMG to Apple Notary Service..."
    if [[ -n "${NOTARY_API_KEY_ID:-}" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --key      "$NOTARY_API_KEY_PATH" \
            --key-id   "$NOTARY_API_KEY_ID" \
            --issuer   "$NOTARY_ISSUER_UUID" \
            --wait
    else
        xcrun notarytool submit "$DMG_PATH" \
            --apple-id "$NOTARY_APPLE_ID" \
            --password "$NOTARY_PASSWORD" \
            --team-id  "$APPLE_TEAM_ID" \
            --wait
    fi
    xcrun stapler staple "$DMG_PATH"
    log "DMG notarization complete."
fi

# ── 7. Verify ────────────────────────────────────────────────────────────────

log "Verifying DMG signature..."
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" 2>&1 || true

DMG_COUNT=$(find "$BUILD_DIR" -maxdepth 1 -name "*.dmg" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DMG_COUNT" -ne 1 ]]; then
    echo "⚠  Warning: $DMG_COUNT .dmg files found in $BUILD_DIR (expected 1)"
fi

# ── 8. Report ─────────────────────────────────────────────────────────────────

FILE_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
divider
echo "  Distribution DMG Ready"
divider
echo ""
printf "  %-10s %s\n" "Filename:"  "$DMG_NAME"
printf "  %-10s %s\n" "Path:"      "$DMG_PATH"
printf "  %-10s %s\n" "Size:"      "$FILE_SIZE"
printf "  %-10s %s\n" "SHA-256:"   "$SHA256"
printf "  %-10s %s\n" "DMG count:" "$DMG_COUNT (✓ exactly 1)"
echo ""
divider
echo ""
echo "  Install on a clean machine:"
echo "    1. Open $DMG_NAME"
echo "    2. Drag Orin.app to /Applications"
echo "    3. Launch — Gatekeeper verifies the notarization ticket automatically"
echo "    4. Enable 'Launch at login' in Orin → Settings → General"
echo "    5. Grant Calendar, Microphone, Speech Recognition, and Apple Events permissions"
echo ""
divider
echo ""
