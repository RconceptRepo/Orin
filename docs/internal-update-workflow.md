# Orin Internal Developer Update Workflow

This document describes the persistent-app development workflow that replaced the
DMG-based testing process. It covers the full cycle: build → install → test → repeat.

---

## Why this workflow

The old DMG workflow required:

1. Build a DMG (`build_qa_dmg.sh`)
2. Run the cleanup script (which deleted the DMG)
3. Rebuild the DMG
4. Open the DMG, drag to Applications, authenticate
5. Grant Screen Recording and Microphone permissions again after `tccutil reset`

This was slow, fragile, and broke TCC permissions on every cycle.

**The new workflow:**

1. Build once → `release/Orin.app` (release-optimised)
2. Run `update-orin.sh` → quits Orin, replaces `/Applications/Orin.app`, relaunches
3. TCC permissions are preserved — no re-grant ever needed

Total time from code change to running app: ~60–90 seconds.

---

## How TCC permissions are preserved

macOS grants Screen Recording and Microphone access to an app by **bundle ID**
(`com.rconcept.orin`), not by file path or code signature.

In-place replacement (`ditto` copy, not DMG drag-and-drop) keeps the same bundle ID
across every update. The TCC database entry remains valid indefinitely.

**Do not change `CFBundleIdentifier` in `Info.plist`.** That would invalidate all
existing TCC grants and require a re-grant in System Settings.

---

## Scripts

### `scripts/build_release.sh`

Compiles with full release optimisations and outputs `release/Orin.app`.

```bash
./scripts/build_release.sh            # full build (2–3 minutes first run, ~60s warm)
./scripts/build_release.sh --verbose  # show full swift build output
./scripts/build_release.sh --skip-build  # re-sign the existing binary without recompiling
```

**What it does:**
1. Runs `swift build --configuration release`
2. Copies the Xcode bundle template from `build-xcode/Build/Debug/Orin.app`
3. Grafts in the release binary
4. Ad-hoc signs with `Orin-local.entitlements`
5. Writes the result to `release/Orin.app`

**Template requirement:** `build-xcode/Build/Debug/Orin.app` must exist. This is the
Xcode-built bundle that provides `Info.plist`, compiled assets, and entitlements.
Create it once by running Xcode Build (Cmd+B), then you never need to do it again
unless you change Info.plist or assets.

---

### `update-orin.sh`

Installs `release/Orin.app` into `/Applications/` and relaunches.

```bash
./update-orin.sh               # standard: quit → backup → replace → launch
./update-orin.sh --no-launch   # install without launching (for background testing)
```

**What it does:**
1. Checks `release/Orin.app` exists (run `build_release.sh` first if not)
2. Quits Orin gracefully (`osascript quit`), force-kills after 5s if needed
3. Backs up `/Applications/Orin.app` → `release/Orin.app.bak`
4. Replaces `/Applications/Orin.app` with the new build (`ditto --norsrc`)
5. Launches the updated app (`open -a`)
6. Logs everything to `release/update.log`

---

## Standard update cycle

```bash
# 1. Make code changes

# 2. Build
./scripts/build_release.sh

# 3. Install and launch
./update-orin.sh

# 4. Test — logs at:
#    ~/Library/Application Support/Orin/Logs/
```

---

## Directory layout

```
orin-v1-complete-macos-development-specification/
├── scripts/
│   ├── build_release.sh        # → release/Orin.app
│   ├── build_qa_dmg.sh         # legacy DMG builder (kept for reference)
│   └── build_dmg.sh            # signed production DMG (not used internally)
├── release/
│   ├── Orin.app                # current release build (gitignored)
│   ├── Orin.app.bak            # previous build backup (gitignored)
│   └── update.log              # install history (tracked in git)
├── build-xcode/
│   └── Build/Debug/Orin.app    # Xcode bundle template (binary not tracked)
└── update-orin.sh              # developer update script (root level for quick access)
```

---

## Gitignore

App bundles in `release/` are excluded from git. The update log is tracked:

```gitignore
release/Orin.app
release/Orin.app.bak
```

`release/update.log` is intentionally tracked — it provides a changelog of which
build was installed when, useful for correlating logs with code changes.

---

## Checking which build is installed

```bash
defaults read /Applications/Orin.app/Contents/Info CFBundleVersion
```

The build number matches the `CURRENT_PROJECT_VERSION` in `Orin.xcodeproj`.

---

## Troubleshooting

**"release/Orin.app not found"**
→ Run `./scripts/build_release.sh` first.

**"Bundle template not found at build-xcode/Build/Debug/Orin.app"**
→ Open Xcode, press Cmd+B once to produce the template. Only needed when
  `Info.plist` or compiled assets change.

**Orin won't launch after update (codesign error)**
→ The ad-hoc signature may be stale. Run `./scripts/build_release.sh --skip-build`
  to re-sign without recompiling, then `./update-orin.sh`.

**Screen Recording or Microphone permissions lost**
→ This should not happen with in-place updates. If it does, check that
  `CFBundleIdentifier` in `Info.plist` is still `com.rconcept.orin`. If someone
  ran `tccutil reset` accidentally, re-grant in System Settings → Privacy.

**Orin froze and update-orin.sh can't quit it**
→ Force quit manually (`Cmd+Option+Esc`), then re-run `./update-orin.sh`.
