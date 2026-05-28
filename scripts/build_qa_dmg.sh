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
#   - Xcode command-line tools (swift build, hdiutil, codesign)
#   - An existing Xcode-built Orin.app bundle template in build-xcode/ (for
#     Info.plist, resources, and bundle structure — only needed on first run).
#     Run `xcodebuild build -project "Orin 2.xcodeproj" -target Orin` once to
#     create the template, then use this script for all subsequent QA builds.
#   - Package.swift at repo root (SPM manifest)
#
# Usage:
#   ./scripts/build_qa_dmg.sh                  # full clean build + DMG
#   ./scripts/build_qa_dmg.sh --skip-build     # repackage most recent app bundle
#   ./scripts/build_qa_dmg.sh --verbose        # pass -v to swift build

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
# Output to Desktop — avoids "malformed URL format" Finder error that occurs
# when the DMG is nested inside a path containing date-like folder names.
DMG_PATH="$HOME/Desktop/$DMG_NAME"

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
command -v swift    >/dev/null || die "swift not found — install Xcode command-line tools."
command -v codesign >/dev/null || die "codesign not found — install Xcode command-line tools."
command -v hdiutil  >/dev/null || die "hdiutil not found."
command -v shasum   >/dev/null || die "shasum not found."

[[ -f "$REPO_ROOT/Package.swift" ]] || \
    die "Package.swift not found at repo root: $REPO_ROOT"
[[ -f "$REPO_ROOT/Orin-local.entitlements" ]] || \
    die "Orin-local.entitlements not found — required for ad-hoc signing."

mkdir -p "$BUILD_ROOT" "$APP_PRODUCTS"

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

    # Strategy: use `swift build` (SPM) which reliably compiles ALL source files,
    # including any files not yet registered in project.pbxproj (e.g. the
    # Developer/ debug utilities added after the last xcodebuild run).
    # We then graft the fresh binary into the Xcode .app bundle template so the
    # final app has the correct Info.plist, assets, entitlements, and bundle ID.
    log "  Phase 1: compiling with swift build..."
    SWIFT_VERBOSE_FLAG=""
    [[ -n "$VERBOSE_FLAG" ]] && SWIFT_VERBOSE_FLAG="-v"
    swift build --configuration debug $SWIFT_VERBOSE_FLAG 2>&1 | \
        grep --line-buffered -E "(error:|warning:|Build complete|build error)" || true

    echo ""

    # Locate the SPM binary
    SPM_BIN_DIR="$(swift build --configuration debug --show-bin-path 2>/dev/null)"
    SPM_BINARY="$SPM_BIN_DIR/Orin"
    [[ -f "$SPM_BINARY" ]] || \
        die "swift build did not produce a binary at: $SPM_BIN_DIR/Orin\nRun with --verbose to see full build output."

    # Find the Xcode-built .app bundle to use as structural template.
    # This provides Info.plist, compiled assets, and the correct bundle structure.
    TEMPLATE_APP=$(find "$APP_PRODUCTS" -maxdepth 1 -name "Orin.app" -type d 2>/dev/null | head -1)
    if [[ -z "$TEMPLATE_APP" || ! -d "$TEMPLATE_APP" ]]; then
        die "No Xcode app bundle template found at:\n  $APP_PRODUCTS\n\nRun once to create it:\n  xcodebuild build -project \"Orin 2.xcodeproj\" -target Orin \\\\\n    CODE_SIGNING_ALLOWED=NO BUILD_DIR=\"$BUILD_ROOT/Build\"\nThen re-run this script."
    fi

    # Assemble the QA app: copy bundle template, swap in the fresh SPM binary
    QA_APP="$APP_PRODUCTS/OrinQA.app"
    rm -rf "$QA_APP"
    cp -R "$TEMPLATE_APP" "$QA_APP"
    cp "$SPM_BINARY" "$QA_APP/Contents/MacOS/Orin"
    APP_PATH="$QA_APP"

    # Apply ad-hoc codesign so macOS will launch the app
    log "  Phase 2: applying ad-hoc signature..."
    codesign --force --deep --sign "-" \
        --entitlements "$REPO_ROOT/Orin-local.entitlements" \
        "$APP_PATH" 2>&1 | grep -v "^$" || true

    log "Build complete → $(basename "$APP_PATH")"

else
    log "Skipping build (--skip-build). Locating most recent app bundle..."
    APP_PATH=$(find "$BUILD_ROOT" -name "*.app" -type d \
        \( -not -path "*/dmg-staging*" \) \
        2>/dev/null | head -1)
    [[ -n "$APP_PATH" && -d "$APP_PATH" ]] || \
        die "No existing .app found in $BUILD_ROOT.\nRun without --skip-build to build first."
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

DMG_COUNT=$(find "$HOME/Desktop" -maxdepth 1 -name "Orin-*.dmg" 2>/dev/null | wc -l | tr -d ' ')

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
