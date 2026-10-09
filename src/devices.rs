//! Device profiles and HID transport.

use std::error::Error;
use std::fmt;
use std::time::Duration;

use hidapi::{BusType, DeviceInfo, HidApi, HidDevice};
use serde::Serialize;

use crate::protocol::*;

/// What kind of device this is (drives which commands apply).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Keyboard,
    Mouse,
}

/// Everything needed to talk to a supported Razer device.
#[derive(Clone, Copy, Debug)]
pub struct Profile {
    /// USB product ID (VID is always Razer's 0x1532).
    pub pid: u16,
    /// Human-readable model name.
    pub name: &'static str,
    /// USB interface number hosting the control collection.
    pub interface: i32,
    /// Usage page of the control collection (HID matching).
    pub usage_page: u16,
    /// Usage of the control collection (HID matching).
    pub usage: u16,
    /// Transaction ID for this device generation.
    pub txid: u8,
    /// Device kind.
    pub kind: Kind,
    /// Maximum DPI (mice).
    pub dpi_max: u16,
    pub effects: &'static [&'static str],
    pub scroll: bool,
    pub zones: usize,
    /// Some USB receivers need 31 ms between request and response.
    pub response_wait_ms: u64,
}

impl Profile {
    pub fn is_mouse(&self) -> bool {
        self.kind == Kind::Mouse
    }

    pub fn matches(&self, info: &DeviceInfo) -> bool {
        usb_control_transport(info.bus_type())
            && self.matches_collection(
                info.vendor_id(),
                info.product_id(),
                info.interface_number(),
                info.usage_page(),
                info.usage(),
            )
    }

    fn matches_collection(
        &self,
        vendor: u16,
        pid: u16,
        interface: i32,
        page: u16,
        usage: u16,
    ) -> bool {
        vendor == USB_VENDOR_ID
            && pid == self.pid
            && interface == self.interface
            && page == self.usage_page
            && usage == self.usage
    }

    pub fn supports(&self, effect: Effect) -> bool {
        let name = match effect {
            Effect::None => "none",
            Effect::Static(_) => "static",
            Effect::Spectrum => "spectrum",
            Effect::Wave(_) => "wave",
            Effect::BreathRandom | Effect::BreathSingle(_) => "breath",
        };
        self.effects.contains(&name)
    }
}

/// These profiles describe USB control collections, not Bluetooth reports.
pub fn usb_control_transport(bus: BusType) -> bool {
    matches!(bus, BusType::Usb)
}

const KEYBOARD_EFFECTS: &[&str] = &["spectrum", "breath", "static", "none"];
const MATRIX_EFFECTS: &[&str] = &["spectrum", "wave", "breath", "static", "none"];

const fn keyboard(
    pid: u16,
    name: &'static str,
    interface: i32,
    effects: &'static [&'static str],
) -> Profile {
    Profile {
        pid,
        name,
        interface,
        usage_page: if interface == 2 { 1 } else { 12 },
        usage: if interface == 2 { 2 } else { 1 },
        txid: 0x1F,
        kind: Kind::Keyboard,
        dpi_max: 0,
        effects,
        scroll: false,
        zones: 0,
        response_wait_ms: 1,
    }
}

const fn performance_mouse(pid: u16, name: &'static str, dpi_max: u16) -> Profile {
    Profile {
        pid,
        name,
        interface: 0,
        usage_page: 1,
        usage: 2,
        txid: 0x1F,
        kind: Kind::Mouse,
        dpi_max,
        effects: &[],
        scroll: false,
        zones: 0,
        response_wait_ms: 31,
    }
}

/// Known devices.
///
/// The interface/usage_page/usage triple identifies the ONE control
/// collection per device (values proven by the OpenRGB detector table).
/// Everything else on the device is an input interface — those must never be
/// written to, or the firmware resets itself (the user feels a "drop").
pub const PROFILES: &[Profile] = &[
    keyboard(0x02A2, "Razer Ornata V3 X", 2, KEYBOARD_EFFECTS),
    keyboard(0x0294, "Razer Ornata V3 X", 2, KEYBOARD_EFFECTS),
    keyboard(0x02A1, "Razer Ornata V3", 2, MATRIX_EFFECTS),
    keyboard(0x028F, "Razer Ornata V3", 2, MATRIX_EFFECTS),
    keyboard(0x02A3, "Razer Ornata V3 TKL", 2, MATRIX_EFFECTS),
    keyboard(0x026B, "Razer Huntsman V2 TKL", 3, MATRIX_EFFECTS),
    keyboard(0x026C, "Razer Huntsman V2", 3, MATRIX_EFFECTS),
    Profile {
        pid: 0x0099,
        name: "Razer Basilisk V3",
        interface: 3,
        usage_page: 0x000C,
        usage: 0x0001,
        txid: 0x1F,
        kind: Kind::Mouse,
        dpi_max: 26000,
        effects: &["spectrum", "wave", "rainbow", "static", "none"],
        scroll: true,
        zones: 11,
        response_wait_ms: 1,
    },
    // No lighting or motorized wheel on these models. Only the common
    // DPI/stage and 125/500/1000 Hz protocol is enabled.
    performance_mouse(0x00A5, "Razer Viper V2 Pro (Wired)", 30000),
    performance_mouse(0x00A6, "Razer Viper V2 Pro (Wireless)", 30000),
    // Use Razer's published 30K limit rather than upstream's 35K value.
    performance_mouse(0x00B6, "Razer DeathAdder V3 Pro (Wired)", 30000),
    performance_mouse(0x00B7, "Razer DeathAdder V3 Pro (Wireless)", 30000),
    performance_mouse(0x00C2, "Razer DeathAdder V3 Pro (Wired)", 30000),
    performance_mouse(0x00C3, "Razer DeathAdder V3 Pro (Wireless)", 30000),
];

#[derive(Debug)]
pub struct RazerError(pub String);

impl fmt::Display for RazerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl Error for RazerError {}

fn err<T>(msg: impl Into<String>) -> Result<T, RazerError> {
    Err(RazerError(msg.into()))
}

/// An opened connection to a Razer device.
pub struct Handle {
    device: HidDevice,
    profile: &'static Profile,
    /// Firmware version, read while probing.
    pub firmware: (u8, u8),
    pub id: String,
}

/// Opaque, exact control-path selector. Never select a different device if
/// a previously discovered path disappears.
pub fn device_id(info: &DeviceInfo) -> String {
    let path: String = info
        .path()
        .to_bytes()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    format!("{:04x}:{path}", info.product_id())
}

impl Handle {
    pub fn profile(&self) -> &'static Profile {
        self.profile
    }

    /// Locate and open the device's CONTROL collection (nothing else).
    ///
    /// Each Razer device exposes several HID collections, but only one is the
    /// control endpoint. The others are input interfaces — writing reports
    /// there makes the firmware reset (the peripheral visibly drops), so we
    /// only ever open the exact (interface, usage page, usage) triple from
    /// the device profile.
    pub fn open(
        api: &HidApi,
        profile: &'static Profile,
        info: &DeviceInfo,
    ) -> Result<Handle, RazerError> {
        if !profile.matches(info) {
            return err("refusing to open an unrecognized control collection");
        }

        let dev = api
            .open_path(info.path())
            .map_err(|e| RazerError(format!("{}: HID open failed: {e}", profile.name)))?;
        let handle = Handle {
            device: dev,
            profile,
            firmware: (0, 0),
            id: device_id(info),
        };
        match handle.execute(get_firmware(profile.txid)) {
            Ok(resp) => Ok(Handle {
                device: handle.device,
                profile,
                firmware: (resp.arg(0), resp.arg(1)),
                id: handle.id,
            }),
            Err(e) => err(format!("{}: {}", profile.name, e.0)),
        }
    }

    /// Fire a one-way command (SET_REPORT only).
    pub fn send(&self, report: Report) -> Result<(), RazerError> {
        let mut buf = [0u8; REPORT_LEN + 1];
        buf[0] = 0; // report ID 0
        buf[1..].copy_from_slice(&report.finalize().bytes);
        self.device
            .send_feature_report(&buf)
            .map(|_| ())
            .map_err(|e| RazerError(format!("HID write failed: {e}")))
    }

    /// Send a command and read back the device's response, with retries.
    ///
    /// The vendor feature report is exactly 90 bytes on both supported
    /// devices; the response arrives in that same report (standard Razer
    /// layout) — but only when the GET uses an exact 91-byte buffer
    /// (report-id byte + 90). Oversized GET buffers return a different
    /// IOKit view of the report space that does not contain the response.
    pub fn execute(&self, report: Report) -> Result<Report, RazerError> {
        let debug = std::env::var("RAZERCTL_DEBUG").is_ok();
        let mut last = String::from("no response");
        for _attempt in 0..5 {
            self.send(report)?;
            std::thread::sleep(Duration::from_millis(self.profile.response_wait_ms));

            let mut buf = [0u8; REPORT_LEN + 1]; // exact size matters
            buf[0] = 0;
            let n = match self.device.get_feature_report(&mut buf) {
                Ok(n) => n as usize,
                Err(_) => {
                    last = "no HID response".into();
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
            };
            // hidapi returns report-id + content; the response content is the
            // 90 bytes after the id byte.
            let content: &[u8] = if n >= REPORT_LEN + 1 {
                &buf[1..1 + REPORT_LEN]
            } else if n >= REPORT_LEN {
                &buf[..REPORT_LEN]
            } else {
                last = format!("short response ({n} bytes)");
                std::thread::sleep(Duration::from_millis(10));
                continue;
            };
            if debug {
                let head: Vec<String> = content[..16].iter().map(|b| format!("{b:02X}")).collect();
                eprintln!("[debug] response: {}", head.join(" "));
            }
            let mut resp = Report {
                bytes: [0; REPORT_LEN],
            };
            resp.bytes.copy_from_slice(content);

            // Validate: echo of transaction id + command class + command id.
            if resp.bytes[1] != report.bytes[1]
                || resp.bytes[6] != report.bytes[6]
                || resp.bytes[7] != report.bytes[7]
            {
                last = "response did not match request".into();
                std::thread::sleep(Duration::from_millis(10));
                continue;
            }
            match resp.status() {
                STATUS_SUCCESSFUL | STATUS_BUSY => return Ok(resp),
                STATUS_FAILURE => return err("device reported command failure"),
                STATUS_TIMEOUT => {
                    last = "device reported timeout".into();
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
                STATUS_NOT_SUPPORTED => return err("device does not support this command"),
                s => {
                    last = format!("unexpected status 0x{s:02X}");
                    std::thread::sleep(Duration::from_millis(10));
                    continue;
                }
            }
        }
        err(format!("{} (after 5 attempts)", last))
    }
}

/// Open every supported device that is currently plugged in.
/// Returns successfully opened handles plus one machine-readable failure
/// line per device that was present but refused communication, formatted
/// `keyboard_error=...` / `mouse_error=...` so `status` can surface the
/// reason to the widget UI.
pub fn open_all(api: &HidApi, id: Option<&str>, kind: Option<Kind>) -> (Vec<Handle>, Vec<String>) {
    let mut handles = Vec::new();
    let mut failures = Vec::new();
    for profile in PROFILES {
        if kind.is_some_and(|k| k != profile.kind) {
            continue;
        }
        let present = api.device_list().any(|d| {
            d.vendor_id() == USB_VENDOR_ID
                && d.product_id() == profile.pid
                && usb_control_transport(d.bus_type())
        });
        if !present {
            continue;
        }
        let controls: Vec<_> = api
            .device_list()
            .filter(|d| profile.matches(d))
            .filter(|d| id.is_none_or(|id| device_id(d) == id))
            .collect();
        if controls.is_empty() && id.is_none() {
            failures.push(format!(
                "{}_error={}: control collection is not available",
                if profile.is_mouse() {
                    "mouse"
                } else {
                    "keyboard"
                },
                profile.name
            ));
        }
        let mut seen = std::collections::HashSet::new();
        for info in controls {
            if !seen.insert(device_id(info)) {
                continue;
            }
            match Handle::open(api, profile, info) {
                Ok(h) => handles.push(h),
                Err(e) => {
                    let key = match profile.kind {
                        Kind::Keyboard => "keyboard_error",
                        Kind::Mouse => "mouse_error",
                    };
                    failures.push(format!("{key}={}", e.0));
                }
            }
        }
    }
    (handles, failures)
}

/// Diagnostic: on the device's CONTROL collection only, exchange a harmless
/// firmware-version request and dump what comes back.
///
/// SAFETY: only the OpenRGB/OpenRazer-designated control collections are ever
/// touched (keyboard: iface 2 mouse collection; mouse: iface 3 consumer
/// control). Input interfaces (mouse/pointer/keyboard collections) are never
/// opened or written — poking those makes the device firmware reset, which
/// the user feels as the peripheral dropping out.
pub fn probe_all(api: &HidApi) -> String {
    let mut out = String::new();
    for profile in PROFILES {
        out.push_str(&format!(
            "== {} (1532:{:04X}) ==\n",
            profile.name, profile.pid
        ));
        for info in api
            .device_list()
            .filter(|d| d.vendor_id() == USB_VENDOR_ID && d.product_id() == profile.pid)
        {
            // Whitelist: control collections only.
            let is_control = profile.matches(info);
            if !is_control {
                continue;
            }
            let tag = format!(
                "iface {} usage {:04X}:{:04X}",
                info.interface_number(),
                info.usage_page(),
                info.usage()
            );
            let dev = match api.open_path(info.path()) {
                Ok(d) => d,
                Err(e) => {
                    out.push_str(&format!("  {tag}: OPEN FAILED: {e}\n"));
                    continue;
                }
            };
            out.push_str(&format!("  {tag}: open OK\n"));

            // Quiescent state of report 0 (big buffer to learn true size).
            let mut rcv = [0u8; 512];
            rcv[0] = 0;
            match dev.get_feature_report(&mut rcv) {
                Ok(n) => {
                    let hex: Vec<String> = rcv[..(n as usize).min(24).max(1)]
                        .iter()
                        .map(|b| format!("{b:02X}"))
                        .collect();
                    out.push_str(&format!(
                        "    quiescent rid 0: GET {n} bytes: {}\n",
                        hex.join(" ")
                    ));
                }
                Err(e) => out.push_str(&format!("    quiescent rid 0: GET failed: {e}\n")),
            }

            let req = get_firmware(profile.txid).finalize().bytes;

            let get_dump = |dev: &hidapi::HidDevice, label: &str, rid: u8, out: &mut String| {
                let mut rcv = [0u8; 512];
                rcv[0] = rid;
                match dev.get_feature_report(&mut rcv) {
                    Ok(n) => {
                        // First 100 bytes hex; then nonzero tail as +off=val.
                        let head: Vec<String> = rcv[..(n as usize).min(100).max(1)]
                            .iter()
                            .map(|b| format!("{b:02X}"))
                            .collect();
                        let mut line = format!("    {label}: GET {n}B: {}", head.join(" "));
                        if n as usize > 100 {
                            let tail: Vec<String> = rcv[100..n as usize]
                                .iter()
                                .enumerate()
                                .filter(|(_, b)| **b != 0)
                                .map(|(i, b)| format!("+{:03X}={:02X}", i + 100, b))
                                .collect();
                            if !tail.is_empty() {
                                line.push_str(&format!(" | tail: {}", tail.join(" ")));
                            }
                        }
                        out.push_str(&line);
                        out.push('\n');
                    }
                    Err(e) => out.push_str(&format!("    {label}: GET failed: {e}\n")),
                }
            };

            get_dump(&dev, "quiescent rid0", 0, &mut out);

            // One proper SET per device: [rid 0][exact 90-byte request].
            // The collection's vendor feature report is exactly 90 bytes;
            // oversize or misaligned SETs wedge the interface, so nothing
            // else is tried here.
            let req_plain: Vec<u8> = req.to_vec();
            let tests: Vec<(&str, u8, Vec<u8>)> = vec![("plain 90B", 0, req_plain)];

            for (label, rid, payload) in &tests {
                let mut snd = vec![0u8; payload.len() + 1];
                snd[0] = *rid;
                snd[1..].copy_from_slice(payload);
                if let Err(e) = dev.send_feature_report(&snd) {
                    out.push_str(&format!("    {label}: SET failed: {e}\n"));
                    continue;
                }
                std::thread::sleep(Duration::from_millis(2));
                get_dump(&dev, &format!("{label} → get rid {rid}"), *rid, &mut out);
                // Also read the exact-sized vendor report (91-byte buffer):
                // some devices answer in the 90-byte report itself rather than
                // IOKit's whole-report-space view.
                let mut rcv = [0u8; 91];
                rcv[0] = 0;
                match dev.get_feature_report(&mut rcv) {
                    Ok(n) => {
                        let hex: Vec<String> = rcv[..(n as usize).min(91)]
                            .iter()
                            .map(|b| format!("{b:02X}"))
                            .collect();
                        out.push_str(&format!(
                            "    {label} → exact 91B GET: {n}B: {}\n",
                            hex.join(" ")
                        ));
                    }
                    Err(e) => out.push_str(&format!("    {label} → exact 91B GET failed: {e}\n")),
                }
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_exact_catalogued_control_collections_match() {
        assert!(usb_control_transport(BusType::Usb));
        assert!(!usb_control_transport(BusType::Bluetooth));
        assert!(!usb_control_transport(BusType::Unknown));
        for p in PROFILES {
            assert!(p.matches_collection(USB_VENDOR_ID, p.pid, p.interface, p.usage_page, p.usage));
            assert!(!p.matches_collection(
                USB_VENDOR_ID,
                p.pid,
                p.interface + 1,
                p.usage_page,
                p.usage
            ));
            assert!(!p.matches_collection(USB_VENDOR_ID, p.pid, p.interface, 0xFF00, p.usage));
            assert!(!p.matches_collection(USB_VENDOR_ID, p.pid, p.interface, p.usage_page, 6));
            assert!(!p.matches_collection(0x1234, p.pid, p.interface, p.usage_page, p.usage));
            assert!(!p.matches_collection(
                USB_VENDOR_ID,
                0xFFFF,
                p.interface,
                p.usage_page,
                p.usage
            ));
        }
        let ids: std::collections::HashSet<_> = PROFILES.iter().map(|p| p.pid).collect();
        assert_eq!(
            ids.len(),
            PROFILES.len(),
            "Profiles must have unique product IDs"
        );
    }
}
