# Ornata V3 X indicators

## Audit evidence

The connected keyboard is a USB Razer Ornata V3 X, `1532:02A2`, firmware
2.0. Its main backlight reports brightness 255. The five lamps above the
number pad are separate from that backlight:

| Lamp | Meaning | Evidence |
|---|---|---|
| C | Caps Lock | Adrian verified that it lights with Caps Lock and turns off when typing returns to lowercase. |
| 1 | Num Lock | The OS's declared USB LED output element read 0 in the audit snapshot. |
| S | Scroll Lock | The OS's declared USB LED output element read 0 in the audit snapshot. |
| M | Macro recording | The vendor state query succeeded and read 0; the app previously had no macro recorder. |
| Gaming symbol | Gaming Mode | The vendor state query succeeded and read 0; the app previously had no mode control. |

Inactive states do not establish broken lamps. Caps Lock does not need a
repair based on the physical check. Num/Scroll are shown from the OS's
reported LED state; this change does not implement a global Num/Scroll
Lock remapper or override their lamps to make them look active.

macOS declares three one-bit LED output elements on one keyboard
collection, report ID 0. Its other keyboard collection has no LED outputs.
Vendor feature packets belong exclusively to interface 2, usage page 1,
usage 2. Normal LED outputs and vendor 90-byte feature reports are different
protocols.

## Approved implementation

Adrian selected option 1 and requested a collapsible section. **Keyboard
controls**, beneath Lighting, starts collapsed. It contains the five
status lights, Gaming Mode, macros and the existing shortcut editor.
Keyboard privacy remains outside the disclosure. Tall expanded device lists scroll
within a bounded area, including when a keyboard and mouse are both connected.

- **Lock states:** a read-only IOKit query decodes the selected control path's
  registry ID, requires a matching USB control collection, and binds the
  keyboard LED collection by its nonzero physical location. It does not
  capture typing or write lock reports. Unknown reads stay Unknown.
- **Gaming Mode:** the toggle changes the keyboard's firmware mode using
  the OpenRazer Gaming LED command, reads the current state before writing,
  and confirms the resulting state. The intended effect is the keyboard's
  Windows-key block (the corresponding Command key on macOS); its physical
  effect on this Mac remains a user check. No system-wide key filter was added.
  The chosen firmware mode persists until toggled again.
- **Macros:** an explicit, focused native recorder collects key-down/up
  events and relative timing for up to 60 seconds / 512 events. It swallows
  its captured keys, ignores auto-repeat, and records no input from other
  apps. Click it again to finish; Escape, focus loss, closing the window,
  sleep/session lock, Secure Keyboard Entry or device removal cancel a take.
  Saved macros live in the existing local assignment storage and run through
  a chosen shortcut while RazerCtl is open. They are Mac-wide assignments,
  not onboard firmware macros or an implementation of Fn+F9.
- **M lamp:** recording starts only after its on-state is confirmed. It
  refuses an already-on lamp rather than taking over another session. Stop
  and cancellation release an acquisition made by this recorder, with
  read-back. Failed cleanup remains Unknown and exposes a retry. Normal
  quit waits for pending mode operations/cleanup. Forced process termination
  or unplugging during a write can prevent cleanup; no crash-recovery claim
  is made.
- **Playback:** requires Accessibility and refuses Secure Keyboard Entry.
  It waits for the trigger's physical modifiers to be released, checks the
  active app and access before every event, and cancels/releases posted keys
  on pause, recording, configuration changes, sleep/session lock or quit.
  Output combinations that would trigger another assignment are rejected.
  No macro key contents are sent to the device core or its command log.

Mode support is restricted to USB product `02A2`, whose state reads were
verified. Other products remain visible with mode controls unavailable.
Discovery and expansion perform reads; an explicit user action starts a write.
All mode changes require one exact `--id`, strict arguments, a successful
matching reply, valid state fields and read-back. An acknowledgement or
read-back failure attempts restoration and reports failure honestly.

## Verification

- `cargo test`: protocol/model/argument validation, Busy/malformed response
  rejection, refusal of foreign acquisitions, read-back and rollback checks.
- `bash tests/check-widget.sh`: existing regressions plus macro bounds,
  balanced keys/timing, legacy storage, recursion rejection, native recorder
  stop/cancellation, Secure Input rejection, playback cancellation/releases,
  pending indicator cleanup, retry and read-only lock monitoring. Fakes
  register no global shortcuts, capture no global input and post no keys.
- Optional `WIDGET_RENDER_DIR=... bash tests/check-widget.sh`: production
  native views rendered offscreen with fixtures for collapsed, expanded,
  unavailable and mode-error states and the macro editor. These are not
  screenshots of the running app or physical keyboard.
- Isolated Developer ID signed app build and strict signature verification.
  The installed app was not replaced.
- Read-only discovery with the built core on the connected Ornata V3 X
  returned `gaming_mode=0`, `macro_recording=0`, both capabilities available,
  and `kbd_brightness=255`. The Swift lock reader independently returned
  Num/Caps/Scroll false for that exact control path. No mode was written
  in these hardware checks.

Before merging, Adrian should check actual disclosure expansion, keyboard
navigation/VoiceOver, Gaming lamp + Command-key behavior, M lamp during
record/stop/Escape, and replay in a harmless text document. Caps Lock should
continue working. Physical mode writes, real playback and TCC grants are
not proved by fixtures or the build.

## Protocol sources

- [Razer Ornata V3 X master guide](https://dl.razerzone.com/master-guides/RazerSynapse3/ORNATAV3X-00000660-en.pdf): lamp meanings, Fn+F9, Fn+F10, Synapse recording requirement and Gaming Mode.
- [OpenRazer keyboard driver](https://github.com/openrazer/openrazer/blob/master/driver/razerkbd_driver.c): model-specific macro/Gaming transactions.
- [OpenRazer standard commands](https://github.com/openrazer/openrazer/blob/master/driver/razerchromacommon.c): indicator get/set packets.

State packets use transaction `0xFF`, class `0x03`, get `0x80` / set `0x00`,
data size 3, storage `0x01`, and LED `0x07` (M) / `0x08` (Gaming). A Busy
reply is not confirmation of a mode change.
