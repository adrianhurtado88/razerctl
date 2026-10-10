# Collapsible keyboard controls: Design QA

**Final result: passed** for offscreen native views. Physical lamp behavior,
real input playback, permissions and the live menu-bar popover remain user checks.

## Evidence and normalization

- Source visual truth: [approved option 1 with disclosure](docs/design/keyboard-indicators/approved-design.png), 972 × 1619 pixels.
- Implementation: [expanded](docs/design/keyboard-indicators/expanded.png), 360 × 639 points/pixels; [collapsed](docs/design/keyboard-indicators/collapsed.png), 360 × 381.
- [Full comparison](docs/design/keyboard-indicators/comparison-final.png) and [focused comparison](docs/design/keyboard-indicators/controls-comparison.png) place the actual source and production render together in one image.
- The source is downsampled to 360 × 600 for a 360-point panel comparison (the 0.4-pixel rounding difference is immaterial). Native captures are 1×; focused crops preserve that scale. No CSS viewport applies to these SwiftUI/AppKit views.
- State: Static lighting, brightness 100%, inactive fixture lock/mode values, controls expanded. The default state is collapsed; privacy stays outside it.
- The production views were rendered without launching the application bootstrap, displaying windows, capturing global input or posting keys. Fixture values are not hardware observations. Popover chrome/shadow in the reference is excluded from fidelity requirements.

## Findings and fixes

1. [First comparison](docs/design/keyboard-indicators/comparison-v1.png): blocked. [P2] status markers used rectangles rather than the source's circular markers; [P2] missing row separators weakened grouping; [P2] the macro description sat in an extra row; [P2] the shortcut label differed and looked disabled. Fixed with circular outlines, separators, a two-column macro row, the approved label and primary foreground.
2. Offscreen macro-editor inspection: blocked. [P2] the new recording instructions pushed Save against the scroll viewport edge at 550 points. The editor now opens at 700 × 620, with a 600-point minimum height. [Revised editor](docs/design/keyboard-indicators/macro-editor.png) shows the form and Save/Cancel controls.
3. Two-device inspection: blocked. [P2] an expanded keyboard plus mouse reached 924 points. Expansion now notifies the parent panel, which bounds the device list to a scroll area while retaining the header/footer. [Revised two-device view](docs/design/keyboard-indicators/two-devices-expanded.png) is 360 × 660; its regression asserts a height at most 700.
4. Final full/focused comparisons: passed. The new section preserves the approved order, circular status markers, mode switch, macro action and shortcut link. No actionable P0/P1/P2 issue remains in the rendered states.

## Fidelity surfaces

- **Fonts and typography:** native SF system type, 13-point control headings and 11-point captions, consistent with the existing panel. Labels and descriptions are legible; wrapped unavailable/error messages have sufficient height. The generated reference's larger type and switch proportions are treated as native-control translation, rather than requiring a different typography system.
- **Spacing and layout:** existing 18-point outer insets, lighting above a compact disclosure, separated rows and privacy outside. The single-device and bounded two-device states fit. The macro editor retains its assignment list and form layout.
- **Colors and tokens:** the existing charcoal surface, white headings, secondary labels and pink keyboard accent remain. Off-state markers are dim; errors use orange. The source's background gradient/outer chrome is an acceptable difference from the existing flat native panel.
- **Image quality and assets:** keyboard and controller glyphs are native SF Symbols; no new raster UI artwork is required. The approved reference is retained for review. Text markers represent actual lock names rather than substitute product imagery.
- **Copy and content:** the disclosure, mode label and macro action follow the chosen design. Macro copy specifies keys rather than arbitrary actions. Detect, USB/firmware metadata, the accurate existing Secure Keyboard Entry section and update footer remain product requirements absent from the generated mock.

## Additional states and interactions

- [Unavailable controls](docs/design/keyboard-indicators/unavailable.png): recording and the mode switch are disabled, with retry guidance; readable lock states remain shown.
- [Mode confirmation failure](docs/design/keyboard-indicators/mode-error.png): an inline orange message appears, with no fabricated confirmed state.
- Automated checks exercise expansion state, native recording/stop/Escape/focus loss, secure-input rejection, balanced storage, cancelled playback/key releases, pending indicator acquisition/cleanup and retry. They use fakes.
- The native disclosure exposes its expanded/collapsed value, indicators expose names and On/Off/Unknown states, and switches/buttons retain native accessibility semantics. VoiceOver and real focus/navigation remain manual checks.

## Validation and remaining checks

`cargo test` passed 20 tests. The native widget regression suite and isolated
Developer ID signed app build passed; strict bundle verification passed.
Clippy is unavailable in the installed Rust toolchain. The compiler's
`onChange` deprecation warning comes from retaining the API compatible with
the app's macOS 12 minimum.

Read-only hardware discovery confirmed inactive M/Gaming states and capability
availability on the exact connected Ornata V3 X. It did not test mode writes,
lamp transitions or Command-key suppression. Adrian should check the live
popover, scrolling, native keyboard navigation/VoiceOver, M during record/stop,
Gaming Mode and harmless macro replay before merging.
