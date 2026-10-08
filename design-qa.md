# Lighting-first widget design QA

Date: 2026-10-08.

final result: passed

This result covers rendered native views and isolated control checks. Physical device behavior and the running menu-bar popover still require a user check. The installed app was not replaced during validation.

## Target and evidence

- Source visual truth: [approved design](docs/design/lighting-first/approved-design.png), the selected third design.
- Rendered implementation: [native preview](docs/design/lighting-first/preview.png), [full comparison](docs/design/lighting-first/comparison-final.png), and [focused controls comparison](docs/design/lighting-first/controls-comparison.png).
- Source image: 1098 × 1433 pixels. Panel crop: (31, 50)–(1066, 1394), 1035 × 1344 pixels, normalized to 360 × 467 logical pixels.
- Implementation viewport: 360 × 470 collapsed; 360 × 616 expanded. Native offscreen backing was 1x; cache export was 720 × 940 for the collapsed view. Normalize exports to logical dimensions when comparing. These are not physical Retina screenshots.
- The production SwiftUI/AppKit views were rendered offscreen without launching the app bootstrap or accessing hardware. The source's outer rounded panel, arrow and shadow belong to NSPopover and are excluded from the content comparison.
- Matching fixture: both devices, Static lighting, pink/cyan colors, 100% brightness, 1800 DPI, 500 Hz, tactile scroll, collapsed performance, and an available update. Runtime values are not forced to match this fixture; no lighting command runs at launch.

## Comparison history and fixes

1. [First comparison](docs/design/lighting-first/comparison-v1.png): blocked. [P1] macOS ignored SwiftUI slider tint and added percentage tick marks. [P2] color wells stretched into pills. [P2] panel height was 510. Fixed with a tinted native slider cell, compact native color wells, and tighter section spacing.
2. [Second comparison](docs/design/lighting-first/comparison-v2.png): blocked. [P2] native menus centered their disclosure glyphs and the panel was still 504 high. Fixed with a native popup-button cell and reduced spacing.
3. [Final full comparison](docs/design/lighting-first/comparison-final.png) and [focused comparison](docs/design/lighting-first/controls-comparison.png): passed. The 360 × 470 panel preserves both device headers, aligned lighting controls, full-width brightness rails, a collapsed performance summary, and the update footer. No actionable P0/P1/P2 mismatch remains in the rendered comparison.
4. Expanded inspection found [P2] polling segments beyond the right inset and a centered scroll row. Fixed with the small native segmented-control size and a label-left/switch-right row. [Revised expanded view](docs/design/lighting-first/expanded.png): all controls fit at 360 × 616.
5. Single-keyboard inspection found a doubled divider. Fixed by rendering the inter-device divider only when both devices appear. [Revised keyboard-only view](docs/design/lighting-first/keyboard.png): 360 × 260.

## Required fidelity surfaces

- **Fonts and typography:** system SF typography, 18-point app title, 15-point device headings, 13-point controls, 12-point secondary text, and monospaced digits. Full and focused comparisons show readable labels without truncation.
- **Spacing and layout:** one charcoal surface, 18-point horizontal insets, wide brightness controls, restrained separators, and a compact mouse disclosure. Expanded custom DPI has a full input and Apply button. Normal, single-device, empty, permission and update-error layouts were rendered.
- **Colors and tokens:** graphite surface, white primary text, readable gray secondary text, pink/cyan accents, and yellow update state. Static lighting uses the selected color; other effects use a device-identification accent rather than claiming a live hardware color.
- **Image and asset quality:** native SF Symbols provide icons; native controls retain interaction and accessibility. No screenshot is embedded as functioning UI. Offscreen text backing is recorded above; real Retina sharpness is not claimed.
- **Copy and content:** firmware metadata no longer leaks into device names and remains in tooltips. Existing effects, read-back performance values, custom DPI, polling and scroll remain. Color wells appear only for Static. Updates and errors occupy the footer and reflect runtime state.

## Validation

- `bash tests/check-widget.sh`: passed with a temporary CLI stub and offscreen controls, without device access. Covers status metadata, error values containing equals signs, RGB arguments for Static, immediate color-state publication, color-write debounce, device action dispatch, slider release commits, keyboard/accessibility action paths, and native effect-menu selection.
- `WIDGET_APP=<review-directory>/RazerCtl.app ./build-widget.sh`: passed, including core/GUI integrity and Developer ID signing.
- `codesign --verify --strict`: passed with the installed copy's bundle identifier and signing team.
- ZIP integrity and `git diff --check`: passed.
- Additional rendered states: [Spectrum](docs/design/lighting-first/spectrum.png), [empty](docs/design/lighting-first/empty.png), [mouse only](docs/design/lighting-first/mouse.png), [permission denied](docs/design/lighting-first/permission.png), and [update failure](docs/design/lighting-first/update-error.png). Permission grants and update installation were not activated.

## Remaining checks

- User check: actual popover expansion, native menu/color-panel interaction, keyboard navigation/VoiceOver, and physical keyboard/mouse effects and read-back values. Offscreen rendering and isolated action tests do not verify these.
- [P3] The native slider track is slightly thinner than the mockup, and the surface uses a solid color rather than texture. These do not change hierarchy or core use.
