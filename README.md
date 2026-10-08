# razerctl — lightweight Razer peripheral control for macOS

A tiny native alternative to Razer Synapse for the **Ornata V3 X** keyboard
and **Basilisk V3** mouse. No Electron, no cloud, no login. Rust core
(335 KB binary, ~9.5 MB peak RSS, ~30 ms per invocation) + Swift menu-bar
widget (~50 MB idle).

## Status: paused — core DONE & hardware-verified, widget built, UI unverified

Last state (see "Resume here" below):

- ✅ Protocol fully reverse-engineered from OpenRazer/OpenRGB sources:
  90-byte feature reports, XOR CRC over bytes 2..88, per-device transaction
  ID `0x1F`.
- ✅ **macOS transport solved** (the hard part). Two quirks vs. Linux:
  1. The control endpoint is a *specific HID collection*, not just an
     interface number: keyboard = iface 2 / usage 01:02 (mouse page),
     Basilisk = iface 3 / usage 0C:01 (consumer). Opening *any other*
     collection wedges the firmware (the mouse visibly drops) — the code
     now hard-whitelists the control collections only.
  2. `get_feature_report` must use an **exact 91-byte buffer**; larger
     buffers return a different IOKit view with no protocol response in it.
- ✅ Reads verified live: firmware, DPI + stages, poll rate, scroll mode
  for both devices (`razerctl info` / `razerctl status`).
- ✅ Writes verified live: static colors applied to both devices and
  visually confirmed by user, then restored to spectrum.
- ✅ Menu-bar widget builds, signs (ad-hoc), launches, and idles with zero
  child processes (spawn-loop fixed by caching status).
- ⚠️ **Widget UI itself not yet clicked through by the user** — menu items
  and actions are unverified in real use.

## Install

**On this Mac**: already done — the app lives at `~/Applications/RazerCtl.app`,
launches at login (Login Items), and the Input Monitoring grant is tied to
the Developer ID signature (survives rebuilds).

**On any Mac, from the release** (no build tools needed):

```sh
# 1. Download and unzip
curl -LO https://github.com/adrianhurtado88/razerctl/releases/download/v1.0/RazerCtl-v1.0.zip
unzip RazerCtl-v1.0.zip
# 2. Install
mv RazerCtl.app /Applications/   # or ~/Applications/
# 3. First launch (clears the downloaded-file quarantine prompt)
xattr -dr com.apple.quarantine RazerCtl.app && open RazerCtl.app
# 4. One-time privacy grant
#    System Settings → Privacy & Security → Input Monitoring → RazerCtl → ON
#    (needed for keyboard control; the mouse works without it)
```

**From source** (Xcode command-line tools + Rust):

```sh
git clone https://github.com/adrianhurtado88/razerctl && cd razerctl
./build-widget.sh          # cargo + swiftc + bundle + Developer ID/ad-hoc sign
open "${TMPDIR}RazerCtl.app"
```

Notes for other machines: without a Developer ID identity (only present on
the build Mac), the script falls back to ad-hoc signing — macOS treats each
rebuild as a new identity, so the Input Monitoring grant must be re-toggled
after every rebuild. The release zip is Developer-ID-signed, so the grant
is stable there.

## Build & run

```sh
cd razer-widget
./build-widget.sh          # cargo + swiftc + bundle + ad-hoc sign
open "${TMPDIR:-/tmp}/RazerCtl.app"
```

CLI alone:

```sh
target/release/razerctl info                # current hardware state
target/release/razerctl status               # key=value (widget format)
target/release/razerctl dpi 1600             # mouse DPI
target/release/razerctl stages 400,800,1600,3200,6400 1
target/release/razerctl poll 1000            # 125|500|1000 Hz
target/release/razerctl scroll free          # free|tactile wheel mode
target/release/razerctl effect static FF00AA  # + spectrum|none|wave|breath…
target/release/razerctl effect wave --dev keyboard
target/release/razerctl brightness 60        # + --led all|scroll|logo|backlight
```

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