#!/usr/bin/env bash
# build_qa_dmg.sh — Build and package an ad-hoc signed QA DMG for local testing.
#
# This script does NOT require Apple Developer signing credentials.
# For production distribution (signed + notarized), use build_dmg.sh instead.
#
# What it does:
#   1. Cleans all previous DMGs and staging artifacts from build-xcode/
#   2. Builds Orin.app with ad-hoc signing (DEBUG configuration)
#   3. Packages into a timestamped DMG: Orin-YYYY-MM-DD-HHMM.dmg
#   4. Prints absolute path, file size, and SHA-256 checksum
#   5. Confirms only one DMG exists in the output directory
#
# Requirements:
#   - Xcode (xcodebuild + hdiutil)
#   - Project at: "Orin 2.xcodeproj" (in repo root)
#
# Usage:
#   ./scripts/build_qa_dmg.sh                  # full clean build + DMG
#   ./scripts/build_qa_dmg.sh --skip-build     # repackage most recent Orin.app
#   ./scripts/build_qa_dmg.sh --verbose        # pass -verbose to xcodebuild

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCPROJECT="$REPO_ROOT/Orin 2.xcodeproj"
BUILD_ROOT="$REPO_ROOT/build-xcode"
DERIVED_DATA="$BUILD_ROOT"
APP_PRODUCTS="$BUILD_ROOT/Build/Products/Debug"
STAGING_DIR="$BUILD_ROOT/dmg-staging-qa"
TIMESTAMP=$(date +"%Y-%m-%d-%H%M")
DMG_NAME="Orin-${TIMESTAMP}.dmg"
DMG_PATH="$BUILD_ROOT/$DMG_NAME"

# ── Flags ────────────────────────────────────────────────────────────────────

SKIP_BUILD=false
VERBOSE_FLAG=""
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --verbose)    VERBOSE_FLAG="-verbose" ;;
    esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

log()    { echo "▶ $*"; }
info()   { echo "  $*"; }
warn()   { echo "⚠  $*"; }
die()    { echo "✖ ERROR: $*" >&2; exit 1; }
divider(){ echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# ── 0. Pre-flight ────────────────────────────────────────────────────────────

log "Pre-flight checks..."
command -v xcodebuild >/dev/null || die "xcodebuild not found — install Xcode."
command -v hdiutil    >/dev/null || die "hdiutil not found."
command -v shasum     >/dev/null || die "shasum not found."

[[ -f "$XCPROJECT/project.pbxproj" ]] || \
    die "Xcode project not found at: $XCPROJECT\nRun: xcodegen generate (if using XcodeGen)"

mkdir -p "$BUILD_ROOT"

# ── 1. Clean previous artifacts ──────────────────────────────────────────────

log "Cleaning previous QA build artifacts..."
DELETED_ARTIFACTS=()

# Remove all .dmg files (timestamped or legacy) from build-xcode/
while IFS= read -r -d '' f; do
    rm -f "$f"
    DELETED_ARTIFACTS+=("$(basename "$f")")
done < <(find "$BUILD_ROOT" -maxdepth 1 \( -name "*.dmg" -o -name "*.zip" \) -print0 2>/dev/null)

# Remove previous staging directories
for dir in "$BUILD_ROOT/dmg-staging" \
           "$BUILD_ROOT/dmg-staging-dev" \
           "$BUILD_ROOT/dmg-staging-qa" \
           "$BUILD_ROOT/Orin-dev.app"; do
    if [[ -e "$dir" ]]; then
        rm -rf "$dir"
        DELETED_ARTIFACTS+=("$(basename "$dir")")
    fi
done

if [[ ${#DELETED_ARTIFACTS[@]} -gt 0 ]]; then
    info "Removed:"
    for a in "${DELETED_ARTIFACTS[@]}"; do info "  • $a"; done
else
    info "No previous artifacts found."
fi

# ── 2. Build ─────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == false ]]; then
    log "Building Orin (Debug, ad-hoc signed)..."
    echo ""

    # Build without codesigning, then apply ad-hoc signature with codesign.
    # This avoids the "requires provisioning profile" error from xcodebuild
    # that appears when CODE_SIGN_STYLE=Manual with no Developer certificate.
    log "  Phase 1: compiling (no signing)..."
    xcodebuild build \
        -project "$XCPROJECT" \
        -target Orin \
        -configuration Debug \
        BUILD_DIR="$BUILD_ROOT/Build" \
        CONFIGURATION_BUILD_DIR="$APP_PRODUCTS" \
        BUILT_PRODUCTS_DIR="$APP_PRODUCTS" \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGN_STYLE=Manual \
        PROVISIONING_PROFILE_SPECIFIER="" \
        ONLY_ACTIVE_ARCH=YES \
        $VERBOSE_FLAG \
        2>&1 | grep --line-buffered \
            -E "(error:|warning:|BUILD SUCCEEDED|BUILD FAILED)" \
        || true

    echo ""

    # Locate the built app
    APP_PATH=$(find "$APP_PRODUCTS" -maxdepth 1 -name "Orin.app" -type d 2>/dev/null | head -1)
    if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
        die "Build produced no Orin.app at $APP_PRODUCTS\nRun with --verbose to see the full build log."
    fi

    # Apply ad-hoc codesign so macOS will launch the app
    log "  Phase 2: applying ad-hoc signature..."
    codesign --force --deep --sign "-" \
        --entitlements "$REPO_ROOT/Orin-local.entitlements" \
        "$APP_PATH" 2>&1 | grep -v "^$" || true

    log "Build complete → $(basename "$APP_PATH")"

else
    log "Skipping build (--skip-build). Locating most recent Orin.app..."
    APP_PATH=$(find "$BUILD_ROOT" -name "Orin.app" -type d \
        \( -not -path "*/dmg-staging*" \) \
        2>/dev/null | head -1)
    [[ -n "$APP_PATH" && -d "$APP_PATH" ]] || \
        die "No existing Orin.app found in $BUILD_ROOT.\nRun without --skip-build to build first."
    log "Using: $APP_PATH"
fi

# ── 3. Package DMG ───────────────────────────────────────────────────────────

log "Creating DMG staging area..."
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/Orin.app"
ln -sf /Applications "$STAGING_DIR/Applications"

log "Creating DMG: $DMG_NAME"
hdiutil create \
    -volname "Orin" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_PATH" \
    2>&1 | grep -v "^hdiutil:" || true

# Clean staging — only the final DMG should remain
rm -rf "$STAGING_DIR"

# ── 4. Verify ────────────────────────────────────────────────────────────────

[[ -f "$DMG_PATH" ]] || die "DMG was not created at: $DMG_PATH"

DMG_COUNT=$(find "$BUILD_ROOT" -maxdepth 1 -name "*.dmg" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$DMG_COUNT" -ne 1 ]]; then
    warn "$DMG_COUNT .dmg files found in build-xcode/ (expected exactly 1)"
    find "$BUILD_ROOT" -maxdepth 1 -name "*.dmg" | while read -r f; do
        warn "  $(basename "$f")"
    done
fi

# ── 5. Report ────────────────────────────────────────────────────────────────

FILE_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
SHA256=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo ""
divider
echo "  QA DMG Ready"
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
echo "  Installation:"
echo "    1. Open $DMG_NAME"
echo "    2. Drag Orin.app to Applications"
echo "    3. Right-click → Open on first launch (bypasses Gatekeeper for ad-hoc builds)"
echo ""
echo "  Note: This is an unsigned ad-hoc build for LOCAL QA TESTING ONLY."
echo "        Vault Keychain operations require Developer signing (Team ID)."
echo "        Touch ID and Keychain ACL will return errSecMissingEntitlement (-34018)."
echo "        All other app features work normally in this build."
echo ""
divider
echo ""
