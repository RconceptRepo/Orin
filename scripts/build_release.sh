#!/usr/bin/env bash
# build_release.sh — Build a release-optimised Orin.app in release/Orin.app.
#
# What it does:
#   1. Compiles with `swift build --configuration release` (full optimisations)
#   2. Grafts the release binary into the Xcode app bundle template
#   3. Ad-hoc signs with Orin-local.entitlements
#   4. Writes the result to release/Orin.app (replaces any previous build)
#
# TCC permissions are preserved across updates because bundle ID never changes
# (com.rconcept.orin). No tccutil reset or Screen Recording re-grant is needed.
#
# Requirements:
#   - Xcode command-line tools (swift, codesign)
#   - build-xcode/Build/Debug/Orin.app must exist as the bundle template.
#     Create it once with: xcodebuild build -project Orin.xcodeproj -target Orin
#   - Package.swift at repo root
#   - Orin-local.entitlements at repo root
#
# Usage:
#   ./scripts/build_release.sh            # build + output release/Orin.app
#   ./scripts/build_release.sh --verbose  # verbose swift build output
#   ./scripts/build_release.sh --skip-build  # re-sign without recompiling

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_APP="$REPO_ROOT/build-xcode/Build/Debug/Orin.app"
RELEASE_DIR="$REPO_ROOT/release"
OUTPUT_APP="$RELEASE_DIR/Orin.app"
ENTITLEMENTS="$REPO_ROOT/Orin-local.entitlements"
STAGING="/tmp/OrinRelease-staging-$$"

# ── Flags ─────────────────────────────────────────────────────────────────────

SKIP_BUILD=false
VERBOSE=""
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --verbose)    VERBOSE="-v" ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

log()     { echo "▶ $*"; }
info()    { echo "  $*"; }
warn()    { echo "⚠  $*"; }
die()     { echo "✖ ERROR: $*" >&2; exit 1; }
divider() { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

# ── 0. Pre-flight ─────────────────────────────────────────────────────────────

log "Pre-flight checks..."
command -v swift    >/dev/null || die "swift not found — install Xcode command-line tools."
command -v codesign >/dev/null || die "codesign not found — install Xcode command-line tools."

[[ -f "$REPO_ROOT/Package.swift" ]]  || die "Package.swift not found at $REPO_ROOT"
[[ -f "$ENTITLEMENTS" ]]             || die "Orin-local.entitlements not found at $REPO_ROOT"
[[ -d "$TEMPLATE_APP" ]]             || die "Bundle template not found at $TEMPLATE_APP\nRun once: xcodebuild build -project Orin.xcodeproj -target Orin"

mkdir -p "$RELEASE_DIR"

# ── 1. Compile ────────────────────────────────────────────────────────────────

if [[ "$SKIP_BUILD" == false ]]; then
    log "Compiling Orin (Release, full optimisations)..."
    echo ""
    swift build --configuration release $VERBOSE 2>&1 | \
        grep --line-buffered -E "(error:|warning:|Build complete|build error)" || true
    echo ""
fi

SPM_BIN_DIR="$(swift build --configuration release --show-bin-path 2>/dev/null)"
SPM_BINARY="$SPM_BIN_DIR/Orin"
[[ -f "$SPM_BINARY" ]] || die "Release binary not found at $SPM_BINARY"
info "Binary: $SPM_BINARY ($(du -sh "$SPM_BINARY" | cut -f1))"

# ── 2. Assemble app bundle ────────────────────────────────────────────────────

log "Assembling release app bundle..."

# Stage in /tmp so codesign doesn't encounter iCloud xattrs
mkdir -p "$STAGING"
STAGED_APP="$STAGING/Orin.app"

ditto --norsrc "$TEMPLATE_APP" "$STAGED_APP"
ditto --norsrc "$SPM_BINARY"   "$STAGED_APP/Contents/MacOS/Orin"

# ── 3. Sign ───────────────────────────────────────────────────────────────────

log "Applying ad-hoc signature..."
codesign --force --deep --sign "-" \
    --entitlements "$ENTITLEMENTS" \
    "$STAGED_APP" 2>&1 || die "codesign failed"

if codesign -d --entitlements :- "$STAGED_APP" 2>/dev/null | \
    grep -q "com.apple.security.device.audio-input"; then
    info "Entitlements verified ✓"
else
    warn "audio-input entitlement not detected — check $ENTITLEMENTS"
fi

# ── 4. Install into release/ ──────────────────────────────────────────────────

log "Installing to release/Orin.app..."
rm -rf "$OUTPUT_APP"
ditto --norsrc "$STAGED_APP" "$OUTPUT_APP"

# ── 5. Report ─────────────────────────────────────────────────────────────────

BUNDLE_VERSION=$(defaults read "$OUTPUT_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
SHORT_VERSION=$(defaults read "$OUTPUT_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
APP_SIZE=$(du -sh "$OUTPUT_APP" | cut -f1)

echo ""
divider
echo "  Release build complete"
divider
echo ""
printf "  %-16s %s\n" "Version:"   "$SHORT_VERSION ($BUNDLE_VERSION)"
printf "  %-16s %s\n" "Size:"      "$APP_SIZE"
printf "  %-16s %s\n" "Output:"    "$OUTPUT_APP"
printf "  %-16s %s\n" "Binary:"    "Release (optimised)"
printf "  %-16s %s\n" "Signed:"    "Ad-hoc (com.rconcept.orin)"
echo ""
echo "  Next step: ./update-orin.sh"
echo ""
divider
echo ""
