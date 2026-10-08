//! Device profiles and HID transport.

use std::error::Error;
use std::fmt;
use std::time::Duration;

use hidapi::{HidApi, HidDevice};

use crate::protocol::*;

/// What kind of device this is (drives which commands apply).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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
}

impl Profile {
    pub fn is_mouse(&self) -> bool {
        self.kind == Kind::Mouse
    }
}

/// Known devices.
///
/// The interface/usage_page/usage triple identifies the ONE control
/// collection per device (values proven by the OpenRGB detector table).
/// Everything else on the device is an input interface — those must never be
/// written to, or the firmware resets itself (the user feels a "drop").
pub const PROFILES: &[Profile] = &[
    Profile {
        pid: 0x02A2,
        name: "Razer Ornata V3 X",
        interface: 2,
        usage_page: 0x0001,
        usage: 0x0002,
        txid: 0x1F,
        kind: Kind::Keyboard,
        dpi_max: 0,
    },
    Profile {
        pid: 0x0099,
        name: "Razer Basilisk V3",
        interface: 3,
        usage_page: 0x000C,
        usage: 0x0001,
        txid: 0x1F,
        kind: Kind::Mouse,
        dpi_max: 26000,
    },
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
    pub fn open(api: &HidApi, profile: &'static Profile) -> Result<Handle, RazerError> {
        let present = api
            .device_list()
            .any(|d| d.vendor_id() == USB_VENDOR_ID && d.product_id() == profile.pid);
        if !present {
            return err(format!(
                "{} (USB {:04X}:{:04X}) not found — is it plugged in?",
                profile.name, USB_VENDOR_ID, profile.pid
            ));
        }

        let control = api.device_list().find(|d| {
            d.vendor_id() == USB_VENDOR_ID
                && d.product_id() == profile.pid
                && d.interface_number() == profile.interface
                && d.usage_page() == profile.usage_page
                && d.usage() == profile.usage
        });
        let info = match control {
            Some(i) => i,
            None => {
                return err(format!(
                    "{} is connected but its control collection is not available",
                    profile.name
                ))
            }
        };

        let dev = api
            .open_path(info.path())
            .map_err(|e| RazerError(format!("{}: HID open failed: {e}", profile.name)))?;
        let handle = Handle {
            device: dev,
            profile,
            firmware: (0, 0),
        };
        match handle.execute(get_firmware(profile.txid)) {
            Ok(resp) => Ok(Handle {
                device: handle.device,
                profile,
                firmware: (resp.arg(0), resp.arg(1)),
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
            std::thread::sleep(Duration::from_millis(1));

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
                let head: Vec<String> = content[..16]
                    .iter()
                    .map(|b| format!("{b:02X}"))
                    .collect();
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
pub fn open_all(api: &HidApi) -> (Vec<Handle>, Vec<String>) {
    let mut handles = Vec::new();
    let mut failures = Vec::new();
    for profile in PROFILES {
        let present = api
            .device_list()
            .any(|d| d.vendor_id() == USB_VENDOR_ID && d.product_id() == profile.pid);
        if !present {
            continue;
        }
        match Handle::open(api, profile) {
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
        out.push_str(&format!("== {} (1532:{:04X}) ==\n", profile.name, profile.pid));
        for info in api
            .device_list()
            .filter(|d| d.vendor_id() == USB_VENDOR_ID && d.product_id() == profile.pid)
        {
            // Whitelist: control collections only.
            let is_control = match profile.pid {
                0x02A2 => {
                    info.interface_number() == 2
                        && info.usage_page() == 0x0001
                        && info.usage() == 0x0002
                }
                0x0099 => {
                    info.interface_number() == 3
                        && info.usage_page() == 0x000C
                        && info.usage() == 0x0001
                }
                _ => false,
            };
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
                    out.push_str(&format!("    quiescent rid 0: GET {n} bytes: {}\n", hex.join(" ")));
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
