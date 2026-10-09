# Device discovery and customization

RazerCtl scans at launch and checks the HID inventory every three seconds.
When the inventory changes, it reads firmware and supported settings on
the serial device queue. The Detect button and reopening the panel use
the same scan path. Overlapping requests are coalesced. A failed scan
keeps the previous inventory visible, disables its controls, and shows
an error so the user can retry.

## Support boundary

Enumeration includes HID products advertising Razer's USB vendor ID, 1532,
and Bluetooth HID products advertising its Bluetooth company ID, 068E.
Unknown products are named from their HID metadata, displayed with a connection type and
product ID, and never opened or sent protocol requests. If multiple HID
collections represent one unknown product, they are grouped by product
ID and serial number; identical unknown products without serial numbers
appear as one product entry. USB profiles cannot match Bluetooth collections,
even if product IDs or usages happen to coincide.

Supported devices use an exact product/interface/usage-page/usage match
before any report is sent. Each control path has a separate device ID,
including two identical supported devices. The widget attaches that ID
to every setting command, including custom colors and rainbow lighting;
disconnecting one device cannot redirect its commands to another.

Keyboard privacy remains app-wide: every keyboard section observes the same
owner used by the panel and sleep/session/quit cleanup. Device rescans and
disconnects do not create or release secure-input requests or App Nap protection.

The catalog has 14 product variants:

- Ornata V3 X: 0294, 02A2; spectrum, breath, static, off, brightness.
- Ornata V3: 028F, 02A1; the above lighting plus wave.
- Ornata V3 TKL: 02A3; the above lighting plus wave.
- Huntsman V2 TKL / V2: 026B / 026C; the above lighting plus wave.
- Basilisk V3: 0099; existing lighting, 11-zone rainbow, brightness,
  DPI/stages, polling, and motorized-wheel controls.
- Viper V2 Pro wired / receiver: 00A5 / 00A6; DPI up to 30,000,
  stages and 125/500/1000 Hz polling.
- DeathAdder V3 Pro wired / receiver, including alternate IDs:
  00B6 / 00B7 / 00C2 / 00C3; DPI up to 30,000, stages and
  125/500/1000 Hz polling.

Only Ornata V3 X (02A2) and Basilisk V3 have prior hardware verification
in this project. The additional profiles require user checks on those
devices. Higher polling modes, remapping, macros, battery controls and
per-key editors are outside this change.

## Initial native Bluetooth support

The menu-bar app also has a CoreBluetooth backend, separate from the Rust
USB controller. It retrieves system-connected peripherals exposing Razer's
vendor service; it does not scan nearby unpaired devices or perform pairing.
Pair devices using macOS Bluetooth settings first. Bluetooth access is
requested by the app, and denied permission or an off Bluetooth adapter
produces a visible message without disabling USB controls.

The initial Bluetooth profiles are Basilisk V3 X HyperSpeed (068E:00BA,
100-18,000 DPI) and Basilisk V3 Pro (068E:00AC, 100-30,000 DPI). Known exact
device-name aliases plus the vendor service identify these profiles; renamed
or differently named devices may remain unsupported. Both paths implement
DPI selection/custom values, brightness and static color, using the
[OpenSnek Bluetooth protocol specification](https://github.com/gh123man/opensnek/blob/main/docs/protocol/BLE_PROTOCOL.md).
This implementation is independent; the packet format is documented by that
Apache-2.0 project from captured device traffic. RazerCtl has not yet verified
these paths on physical Bluetooth hardware.

Features are enabled only after valid setting reads. Discovery does not
write user settings. DPI changes first read the existing stage table,
preserve visible stage IDs, X/Y values and reserved bytes, and either select
an existing symmetric preset or edit the active stage; inactive slots missing
from a short response are filled from the final visible stage. The active byte
is treated as a stage token before considering an index. The current single
slider requires equal read-back brightness across V3 Pro's three lighting
zones. Static color applies across the supported zones. Writes are acknowledged
and read back; failure or a mismatch is shown rather than reported as success.
Profiles and onboard profile-bank switching are not implemented. V3 Pro
settings are enabled only when its active-target read confirms the default
live/projection bank (1); other banks produce an unsupported-profile message
instead of displaying or changing a potentially different bank's settings.

Bluetooth operations use exact CoreBluetooth UUIDs; a missing device is never
replaced with another same-name device. Notifications must be enabled before
requests; exchanges are serialized, correlate response IDs, require complete
payloads and write acknowledgements, and time out with an actionable error.
USB HID reports are never sent to Bluetooth interfaces. The UI merges native
Bluetooth UUID entries with HID inventory, retaining separate wired devices
and multiple identical Bluetooth devices. Unsupported Bluetooth keyboards
and mice are listed when macOS exposes their Razer HID metadata or vendor
service; detection is not guaranteed for every model.

Additional models need transport-specific, documented controls and physical
verification before being added. Bluetooth polling rate, wheel modes,
remapping, battery display and keyboard lighting are not included here.

Feature profiles come from the [OpenRGB detector table](https://github.com/CalcProgrammer1/OpenRGB/blob/master/Controllers/RazerController/RazerControllerDetect.cpp),
[OpenRazer keyboard driver](https://github.com/openrazer/openrazer/blob/master/driver/razerkbd_driver.c),
[mouse driver](https://github.com/openrazer/openrazer/blob/master/driver/razermouse_driver.c),
and its [keyboard](https://github.com/openrazer/openrazer/blob/master/daemon/openrazer_daemon/hardware/keyboards.py)
and [mouse](https://github.com/openrazer/openrazer/blob/master/daemon/openrazer_daemon/hardware/mouse.py)
device definitions. New mouse receivers use their documented 31 ms
response delay. Ornata V3 wave direction codes differ from the other
extended-matrix keyboards and are translated per profile.

DeathAdder V3 Pro's DPI ceiling follows Razer's published 30,000 maximum
in its [official guide](https://dl.razerzone.com/master-guides/RazerSynapse3/DEATHADDERV3PRO-00000194-en.pdf),
rather than the higher value in the upstream device definition.

Brightness, DPI, polling and wheel controls are shown only when their
read-back succeeds. DPI values and polling codes are checked before
becoming settings. Lighting effects follow documented model support;
they cannot be queried from these devices, so the menu initially says
Choose instead of claiming an active effect. Detection never applies
defaults. Repeated scans retain per-device local colors and selections,
and update brightness from real reads.

## Validation

- `cargo test`: exact control-collection matching, feature exclusions,
  model DPI limits for both axes and stages, polling codes and metadata.
- `bash tests/check-widget.sh`: an isolated controller stub exercises
  startup/manual/automatic detection, empty and unknown-device states,
  permission errors, failed scans and recovery, multiple device targeting,
  independent colors, debounce, and visible command failures. Existing
  native-control checks remain included.
  Bluetooth packet fixtures cover short and fragmented replies, response-ID
  matching, rejected commands, DPI stage tokens/axes/markers, and invalid data;
  an injected backend covers exact Bluetooth targeting, HID deduplication,
  permission recovery and USB isolation without accessing hardware.
- Physical-device interaction, real reconnect timing, new profiles,
  and the running popover still need user verification. The automated
  checks never send commands to attached peripherals.
