# Floating Recording Widget Validation

**Date:** 2026-05-30  
**File:** `Sources/Orin/Services/FloatingRecordingWidgetWindowManager.swift`  
**Protocol:** `OverlayProvider`

---

## Pre-Fix State

| Requirement | Pre-Fix Status | Issue |
|---|---|---|
| Always on top | ✅ Working | `NSWindowLevel.floating` + `orderFrontRegardless()` |
| Draggable | ✅ Working | `isMovableByWindowBackground = true` |
| Multi-monitor | ❌ **FAILING** | `panel.center()` always placed on primary screen |
| Full-screen support | ✅ Working | `.fullScreenAuxiliary` collection behavior |
| App minimised/hidden | ✅ Working | `hidesOnDeactivate = false` |
| NSPanel coupling | ❌ **FAILING** | No protocol abstraction; `FloatingRecordingWidgetWindowManager.shared` referenced directly |
| Position persisted | ✅ Working | `setFrameAutosaveName("OrinFloatingRecordingWidget")` |

---

## Fixes Applied

### 1. Multi-Monitor Support

**Root cause:** `panel.center()` computes the center of the primary screen (`NSScreen.main`), not the screen where the user is currently working.

**Fix:** Added `placeOnActiveScreen(_ panel: NSPanel)` which reads the cursor position via `NSEvent.mouseLocation` and selects the `NSScreen` whose frame contains the cursor:

```swift
private func placeOnActiveScreen(_ panel: NSPanel) {
    let cursor = NSEvent.mouseLocation
    let targetScreen = NSScreen.screens.first { screen in
        NSMouseInRect(cursor, screen.frame, false)
    } ?? NSScreen.main ?? NSScreen.screens.first!

    let panelSize = panel.frame.size
    let origin = NSPoint(
        x: targetScreen.visibleFrame.midX - panelSize.width / 2,
        y: targetScreen.visibleFrame.minY + targetScreen.visibleFrame.height * 0.80
    )
    panel.setFrameOrigin(origin)
}
```

This runs only on **first show** (when `panel == nil`). Subsequent shows use `setFrameAutosaveName` to restore the last dragged position — which may be on any screen the user moved it to.

### 2. OverlayProvider Conformance

Added `extension FloatingRecordingWidgetWindowManager: OverlayProvider` so the widget can be injected via the protocol:

```swift
extension FloatingRecordingWidgetWindowManager: OverlayProvider {
    func showRecordingWidget(recordingService: RecordingService, onStop: @escaping () -> Void) {
        show(recordingService: recordingService, onStop: onStop)
    }
    func hideRecordingWidget() { hide() }
}
```

`NSPanelOverlayProvider` delegates to `FloatingRecordingWidgetWindowManager.shared`, making it injectable in tests or future replacements.

### 3. Content Refresh on Re-Show

Previous code replaced `contentView` on every `show()` call even when the panel already existed. This is correct behavior (ensures the `onStop` closure is always fresh), but the comment now documents the intent explicitly.

---

## Post-Fix Validation

| Requirement | Status | Implementation |
|---|---|---|
| **Always on top** | ✅ | `NSWindowLevel.floating` + `orderFrontRegardless()` |
| **Draggable** | ✅ | `isMovableByWindowBackground = true` |
| **Multi-monitor** | ✅ Fixed | `placeOnActiveScreen()` targets cursor's screen |
| **Full-screen apps** | ✅ | `.fullScreenAuxiliary` makes panel appear over fullscreen |
| **All Spaces** | ✅ | `.canJoinAllSpaces` — follows user across all virtual desktops |
| **App minimised** | ✅ | `hidesOnDeactivate = false` — panel persists when Orin is not frontmost |
| **App hidden** | ✅ | Same — NSPanel with floating level and hidesOnDeactivate=false stays |
| **Position memory** | ✅ | `setFrameAutosaveName` persists position across launches |
| **Protocol abstraction** | ✅ Fixed | `OverlayProvider` conformance added |

---

## Behavior Specification

### First Show
1. New `NSPanel` created with correct properties
2. `placeOnActiveScreen()` positions it at 80% height on the cursor's screen
3. `orderFrontRegardless()` makes it visible above all other windows

### Subsequent Shows (during same session)
1. Existing panel re-used (no new NSPanel allocation)
2. `contentView` replaced to refresh the `onStop` closure binding
3. `orderFrontRegardless()` brings it to front (in case it was obscured)

### Hide
1. `panel?.orderOut(nil)` — panel is hidden but not destroyed
2. Frame is remembered via `setFrameAutosaveName`
3. Next `show()` call re-uses the panel and calls `orderFrontRegardless()`

### Multi-Monitor Scenarios

| Scenario | Behavior |
|---|---|
| Single monitor | Places at 80% height, centered |
| Primary + external, cursor on external | Places on external monitor ✅ |
| Primary + external, cursor on primary | Places on primary monitor ✅ |
| Cursor between screens | Falls back to `NSScreen.main` |
| User drags widget to external | Next session restores to external position (autosave) |
| Monitor disconnected with saved position | NSPanel restores to visible area (macOS corrects off-screen panels) |

---

## Known Limitations

| Limitation | Severity | Notes |
|---|---|---|
| `placeOnActiveScreen` uses cursor not active window | Low | Cursor position is a good proxy for "where the user is" |
| `setFrameAutosaveName` restores position from previous session | Low | If monitor layout changed, position may appear offset — macOS auto-corrects |
| No animated appearance/disappearance | Low | Panel appears immediately (no fade-in). UX improvement opportunity. |
| Widget requires Screen Recording for ScreenCaptureKit | None | Widget itself does not use Screen Recording; SystemAudioCaptureService does |
