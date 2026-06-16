#!/usr/bin/env bash
# update-orin.sh — Replace /Applications/Orin.app with release/Orin.app.
#
# What it does:
#   1. Checks release/Orin.app exists (run ./scripts/build_release.sh first)
#   2. Quits Orin if it is running
#   3. Backs up the current /Applications/Orin.app to release/Orin.app.bak
#   4. Replaces /Applications/Orin.app with the new build (in-place, same bundle ID)
#   5. Launches the updated app
#   6. Logs success/failure to release/update.log
#
# TCC permissions persist because build_release.sh signs with --requirement 'identifier
# "com.rconcept.orin"', giving a stable designated requirement that survives CDHash changes.
# Ad-hoc signing without --requirement auto-generates a cdhash-pinned DR that breaks TCC
# on every build. Screen Recording re-grant is only needed if the DR ever changes.
#
# Usage:
#   ./update-orin.sh                # standard update
#   ./update-orin.sh --no-launch    # install without launching

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_APP="$SCRIPT_DIR/release/Orin.app"
INSTALLED_APP="/Applications/Orin.app"
BACKUP_APP="$SCRIPT_DIR/release/Orin.app.bak"
LOG_FILE="$SCRIPT_DIR/release/update.log"

# ── Flags ─────────────────────────────────────────────────────────────────────

NO_LAUNCH=false
for arg in "$@"; do
    case "$arg" in
        --no-launch) NO_LAUNCH=true ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

log()      { local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"; echo "$msg"; echo "$msg" >> "$LOG_FILE"; }
log_only() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
die()      { log "ERROR: $*"; exit 1; }
divider()  { echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

# ── Pre-flight ────────────────────────────────────────────────────────────────

echo ""
divider
echo "  Orin Updater"
divider

mkdir -p "$(dirname "$LOG_FILE")"
log_only "─── update-orin.sh started ───────────────────────────────────"

[[ -d "$RELEASE_APP" ]] || die "release/Orin.app not found. Run: ./scripts/build_release.sh"

BUNDLE_VERSION=$(defaults read "$RELEASE_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
SHORT_VERSION=$(defaults read "$RELEASE_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")
log "New build: $SHORT_VERSION ($BUNDLE_VERSION) at $RELEASE_APP"

# ── 1. Quit Orin ─────────────────────────────────────────────────────────────

if pgrep -x "Orin" >/dev/null 2>&1; then
    log "Quitting Orin..."
    osascript -e 'tell application "Orin" to quit' 2>/dev/null || true
    # Give the app up to 5s to quit gracefully; force-kill if needed
    for i in 1 2 3 4 5; do
        sleep 1
        pgrep -x "Orin" >/dev/null 2>&1 || break
        if [[ $i -eq 5 ]]; then
            log "Orin did not quit gracefully — force killing..."
            pkill -x "Orin" 2>/dev/null || true
        fi
    done
    log "Orin stopped."
else
    log "Orin is not running — skipping quit."
fi

# ── 2. Backup current install ─────────────────────────────────────────────────

if [[ -d "$INSTALLED_APP" ]]; then
    log "Backing up current install to release/Orin.app.bak..."
    rm -rf "$BACKUP_APP"
    ditto --norsrc "$INSTALLED_APP" "$BACKUP_APP"
    log "Backup complete."
else
    log "No existing install found at $INSTALLED_APP — fresh install."
fi

# ── 3. Install ────────────────────────────────────────────────────────────────

log "Installing release/Orin.app → /Applications/Orin.app..."
rm -rf "$INSTALLED_APP"
ditto --norsrc "$RELEASE_APP" "$INSTALLED_APP"
log "Install complete."

# Verify
[[ -d "$INSTALLED_APP" ]] || die "Install failed — /Applications/Orin.app not found after copy."
INSTALLED_VERSION=$(defaults read "$INSTALLED_APP/Contents/Info" CFBundleVersion 2>/dev/null || echo "?")
log "Verified: /Applications/Orin.app build $INSTALLED_VERSION"

# ── 4. Launch ─────────────────────────────────────────────────────────────────

if [[ "$NO_LAUNCH" == false ]]; then
    log "Launching Orin..."
    open -a "$INSTALLED_APP"
    log "Orin launched."
else
    log "Skipping launch (--no-launch)."
fi

# ── 5. Done ───────────────────────────────────────────────────────────────────

echo ""
divider
printf "  %-12s %s\n" "Updated:"  "$SHORT_VERSION ($BUNDLE_VERSION)"
printf "  %-12s %s\n" "Backup:"   "$BACKUP_APP"
printf "  %-12s %s\n" "Log:"      "$LOG_FILE"
echo ""
divider
echo ""
log_only "─── update-orin.sh done ──────────────────────────────────────"
