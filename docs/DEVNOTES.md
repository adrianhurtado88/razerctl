# Development notes

Working notes from the build — the hard-won details that don't belong in
the README but are worth keeping. Written as the project progressed;
some sections reference earlier states.

## Mouse lighting capability summary (Basilisk V3)

13 independently addressable RGB zones: 11-zone side strip + logo + wheel.

| Mode | Per-zone? | Where |
|---|---|---|
| Spectrum (animated rainbow) | — | CLI `effect spectrum`, widget Lighting |
| Static single color (all zones) | no | CLI `effect static RRGGBB`, widget |
| Static per-zone ("custom frame") | **yes** | CLI `zones c1,c2,…` / `rainbow [n]`, widget "Rainbow (static, per-zone)" |
| Per-LED (logo / wheel separately) | per-LED | CLI `effect static RRGGBB --led logo\|scroll` |

Custom frame protocol (verified live): row write = class `0x0F` cmd `0x03`,
data size `0x47`, args `[2]=row [3]=start [4]=stop` + RGB at `args[5]`;
then activate = class `0x0F` cmd `0x02`, size `0x0C`, effect `0x08`
(OpenRazer: `set_custom_frame` then `set_custom_effect`, per ripple_effect.py).

Keyboard (Ornata V3 X): single-zone backlight — one color at a time only,
no per-key/per-zone lighting (hardware). Verified effect support:

| Effect | Keyboard | Mouse |
|---|---|---|
| Spectrum (animated rainbow) | ✅ | ✅ |
| Static color | ✅ | ✅ |
| Off | ✅ | ✅ |
| Wave (animated) | ❌ refused by device | ✅ |
| Breath (single/dual/random fade) | ✅ | ❌ refused by device |
| Static per-zone (custom frame) | n/a (1 zone) | ✅ (11 zones) |

The widget menu shows only the effects each device actually accepts
(spectrum + wave + rainbow for the mouse; spectrum + breath for the
keyboard). CLI: `effect wave --dev mouse`, `effect breath --dev keyboard`,
`effect breath-single RRGGBB --dev keyboard`.
## Known environment quirks

- **macOS filenames are case-insensitive.** `razerctl` and `RazerCtl` are the
  same path — the first bundle shipped with the swiftc output silently
  overwriting the Rust core, so every status call re-launched the whole GUI
  app: a fork bomb of 40+ menu-bar icons. The core is now bundled as
  `razerctl-core` (no collision possible) and `build-widget.sh` verifies the
  two executables are distinct files (`cmp` + inode check) before signing.
- **Workspace is iCloud-synced** (File Provider). App bundles built inside
  it get evicted/xattr-poisoned and break codesigning — hence `build-widget.sh`
  assembles the bundle in `$TMPDIR`. Keep built bundles out of
  `~/Documents/deepseek-harness/**` or pause iCloud sync for the folder.
- **TCC/privacy**: opening HID collections from a terminal app may need a
  one-time System Settings → Privacy & Security → Input Monitoring grant.
  (The Razer control collections used here did not require it; keyboard
  input collections do.)
- Ad-hoc signature means Gatekeeper can't validate across machines; for
  personal use, `open` works fine.

## Widget debugging notes (hard-won)

- **Freeze while dragging the brightness slider**: NSSlider in a menu is
  continuous (fires every drag tick); each `razerctl` run is ~100 ms of
  device I/O. Fix: every menu action goes through a **serial background
  DispatchQueue** (never the main thread, never concurrent — concurrent
  core processes fight over the HID devices), and the slider is
  `isContinuous = false` so it fires once on release.
- **TCC / Input Monitoring**: the GUI app needs the Input Monitoring grant
  to open the keyboard's control collection (the mouse's consumer-control
  collection is not gated). Ad-hoc signing creates a NEW identity per
  build, silently invalidating the grant. The app is now signed with a
  **Developer ID Application** identity (auto-detected in
  `build-widget.sh`), so the grant survives every rebuild. If it is ever
  lost: `tccutil reset ListenEvent local.razerctl.widget`, relaunch, and
  re-toggle in System Settings → Privacy & Security → Input Monitoring.
- **Widget log**: every core call (args + output + exit code) is appended
  to `/tmp/razerctl-widget.log` — the single best diagnostic when the UI
  and the devices disagree.

## Final status: COMPLETE — all features verified on hardware by the user

- Keyboard: Spectrum ✓ (slow whole-board color cycle), Breath ✓,
  Static color ✓, Brightness ✓
- Mouse: DPI stages + custom ✓, Polling rate ✓, Wave (txid 0x3F quirk
  fixed) ✓, Rainbow static per-zone (custom frame) ✓, Static ✓,
  Brightness ✓ (read via per-zone LED — the Basilisk refuses
  `led=all` for reads, only writes; both sliders seed from real values), Free-spin scroll toggle ✓
- Widget: frozen build at `~/Applications/RazerCtl.app`, Developer ID
  signed, Input Monitoring granted (survives rebuilds), serial background
  command queue (no UI freezes), per-device menu sections, widget log at
  `/tmp/razerctl-widget.log`

## Resume here

1. User clicks through the menu-bar widget (DPI submenu, poll rate,
   lighting incl. static-color picker, brightness slider, scroll toggle);
   fix anything that misbehaves.
2. Install location: move `RazerCtl.app` to `~/Applications`, add to Login
   Items if desired.
3. Optional polish: per-zone editor beyond the rainbow preset,
   device hot-plug refresh.

## Keyboard shortcut customiser

`menu-bar/KeyboardShortcuts.swift` contains the native editor, a local Codable
rule model, Carbon global-hotkey registration, and a separate action runner.
The menu-bar panel and More menu open the same retained editor window.
Assignments persist in the app's UserDefaults; startup registers enabled
assignments and shutdown unregisters them. No default assignments are installed.

These are Mac-wide shortcuts, not USB firmware mappings or Ornata-only input.
Only the selected combinations are registered; no general keyboard event tap or
keystroke logging is used. Function keys and combinations with Command, Control
or Option can trigger an action. Ordinary letters alone are rejected. Reserved
system shortcuts and registration failures are displayed beside the assignment.

Sending an output shortcut requires Accessibility. It waits up to three seconds
for physical modifiers to be released and cancels if the active app changes.
Edits, pause, recording and shutdown cancel pending output. App and HTTP(S)
website actions use NSWorkspace. Output combinations cannot match any enabled
assignment's trigger, preventing direct or indirect shortcut loops. Failed edits
keep the old saved rule and attempt to restore its registration.

Validation: `bash tests/check-widget.sh` passes the existing widget regressions
and shortcut capture, validation, conflict rollback, loop prevention, pause,
recording, disabling, dispatch, persistence and unreadable-data preservation
checks with fake registration and execution. The test suite reserves no global
shortcuts, posts no keystrokes and does not request permissions. Physical key
handling, OS permission grants, native window interaction and app launching
still require a user check; automated checks are not hardware verification.

## Mouse button customiser

`menu-bar/MouseButtons.swift` adds a separate editor, persisted mouse rules, and
a CoreGraphics event tap restricted to `otherMouseDown`, `otherMouseUp` and
`otherMouseDragged`. Rules reuse the keyboard shortcut action editor and runner.
The tap starts only when an enabled assignment or button capture needs it and
Accessibility is granted. It never subscribes to keyboard input, left/right
clicks, pointer motion or scroll-wheel events. Assignments apply to all mice on
this Mac while the app runs; no firmware mapping writes are performed.

The pure router suppresses paired down/up events for assigned buttons and runs
one action on release. Edits, recording, pause and deletion cancel pending
actions while draining any already-consumed click's release. Unassigned input
passes through, including a release whose down was passed through before an
assignment was created. Button recording captures one extra button and consumes
its click without invoking an action. Recording an output shortcut also suspends
the keyboard customiser, so existing global shortcuts cannot fire during capture.

No rules or permission prompts are installed by default. Permission failures,
invalid saved rules and action errors are shown in the editor and main panel.
Saved data that cannot be decoded is retained instead of silently overwritten.
DPI, scroll-mode and tilt controls that do not report ordinary mouse-button
events are outside this software path; their physical behavior is unverified.

`bash tests/check-widget.sh` now also checks paired click routing, capture,
pause/edit/delete while held, queued-action cancellation, output recording,
permission/retry handling, validation and persistence with fake monitoring.
It intercepts no real mouse events, posts no actions and writes no device state.
The native window, permission grant and physical Basilisk buttons require a user
check; passing these isolated checks does not verify those interactions.
