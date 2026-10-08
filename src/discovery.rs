//! Enumerate every Razer HID product; query only catalogued control paths.

use crate::devices::{device_id, usb_control_transport, Handle, Kind, Profile, PROFILES};
use crate::protocol::USB_VENDOR_ID;
use hidapi::{BusType, DeviceInfo, HidApi};
use serde::Serialize;
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Default, Serialize)]
pub struct Capabilities {
    pub effects: Vec<&'static str>,
    pub brightness: bool,
    pub dpi_max: u16,
    pub dpi_stages: bool,
    pub poll_rates: Vec<u16>,
    pub scroll: bool,
    pub zones: usize,
}

impl Capabilities {
    fn for_profile(p: &Profile) -> Self {
        Self {
            effects: p.effects.to_vec(),
            brightness: !p.effects.is_empty(),
            dpi_max: p.dpi_max,
            dpi_stages: p.is_mouse(),
            poll_rates: if p.is_mouse() {
                vec![125, 500, 1000]
            } else {
                vec![]
            },
            scroll: p.scroll,
            zones: p.zones,
        }
    }

    // A read failure must not become a fabricated slider value or setting.
    fn retain_readable(&mut self, settings: &BTreeMap<String, String>, kind: Kind) {
        self.brightness &= settings.contains_key(if kind == Kind::Mouse {
            "mouse_brightness"
        } else {
            "kbd_brightness"
        });
        if !settings.contains_key("dpi") {
            self.dpi_max = 0;
        }
        self.dpi_stages &= settings.contains_key("stages");
        if !settings.contains_key("poll") {
            self.poll_rates.clear();
        }
        self.scroll &= settings.contains_key("scroll");
    }
}

#[derive(Serialize)]
pub struct DetectedDevice {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub usb_id: String,
    pub transport: &'static str,
    pub supported: bool,
    pub capabilities: Capabilities,
    pub settings: BTreeMap<String, String>,
    pub error: Option<String>,
    #[serde(skip)]
    control: Option<DeviceInfo>,
    #[serde(skip)]
    profile: Option<&'static Profile>,
}

fn transport_name(bus: BusType) -> &'static str {
    match bus {
        BusType::Usb => "usb",
        BusType::Bluetooth => "bluetooth",
        _ => "unknown",
    }
}

// Bluetooth SIG's Razer company ID differs from Razer's USB vendor ID.
// See the capture-backed OpenSnek Bluetooth protocol documentation.
fn is_razer(vendor: u16, bus: BusType) -> bool {
    vendor == USB_VENDOR_ID || (vendor == 0x068E && matches!(bus, BusType::Bluetooth))
}

fn kind_name(kind: Kind) -> &'static str {
    match kind {
        Kind::Keyboard => "keyboard",
        Kind::Mouse => "mouse",
    }
}

/// HID collections are not physical devices. For supported products, the
/// exact control path is the identity (including two identical peripherals).
/// Unknown products are grouped by product ID + USB serial if available;
/// devices without a serial are deliberately shown as one product entry.
fn inventory<'a>(infos: impl Iterator<Item = &'a DeviceInfo>) -> Vec<DetectedDevice> {
    let infos: Vec<_> = infos
        .filter(|d| is_razer(d.vendor_id(), d.bus_type()))
        .collect();
    let mut devices = Vec::new();
    let mut seen = HashSet::new();
    for info in &infos {
        let profile = PROFILES.iter().find(|p| {
            p.pid == info.product_id()
                && info.vendor_id() == USB_VENDOR_ID
                && usb_control_transport(info.bus_type())
        });
        if let Some(p) = profile {
            if !p.matches(info) {
                continue;
            }
            let id = device_id(info);
            if !seen.insert(id.clone()) {
                continue;
            }
            devices.push(DetectedDevice {
                id,
                name: p.name.into(),
                kind: kind_name(p.kind).into(),
                usb_id: format!("1532:{:04X}", p.pid),
                transport: "usb",
                supported: true,
                capabilities: Capabilities::for_profile(p),
                settings: BTreeMap::new(),
                error: None,
                control: Some((*info).clone()),
                profile: Some(p),
            });
        } else {
            let serial = info.serial_number().unwrap_or("");
            let transport = transport_name(info.bus_type());
            let id = format!(
                "unknown:{}:{:04x}:{:04x}:{serial}",
                transport,
                info.vendor_id(),
                info.product_id()
            );
            if !seen.insert(id.clone()) {
                continue;
            }
            devices.push(DetectedDevice {
                id,
                name: info
                    .product_string()
                    .filter(|s| !s.trim().is_empty())
                    .map(str::to_string)
                    .unwrap_or_else(|| format!("Razer device {:04X}", info.product_id())),
                kind: "device".into(),
                usb_id: format!("{:04X}:{:04X}", info.vendor_id(), info.product_id()),
                transport,
                supported: false,
                capabilities: Capabilities::default(),
                settings: BTreeMap::new(),
                error: None,
                control: None,
                profile: None,
            });
        }
    }
    // Presence and permission errors must not look like an empty device list.
    for p in PROFILES {
        if infos.iter().any(|d| {
            d.product_id() == p.pid
                && d.vendor_id() == USB_VENDOR_ID
                && usb_control_transport(d.bus_type())
        }) && !devices
            .iter()
            .any(|d| d.profile.is_some_and(|known| known.pid == p.pid))
        {
            devices.push(DetectedDevice {
                id: format!("unavailable:{:04x}", p.pid),
                name: p.name.into(),
                kind: kind_name(p.kind).into(),
                usb_id: format!("1532:{:04X}", p.pid),
                transport: "usb",
                supported: true,
                capabilities: Capabilities::default(),
                settings: BTreeMap::new(),
                error: Some(
                    "Control connection is unavailable. Reconnect the device and click Detect."
                        .into(),
                ),
                control: None,
                profile: Some(p),
            });
        }
    }
    devices.sort_by(|a, b| {
        a.kind
            .cmp(&b.kind)
            .then(a.name.cmp(&b.name))
            .then(a.id.cmp(&b.id))
    });
    devices
}

pub fn detect(api: &HidApi, query_settings: bool) -> Result<String, String> {
    let mut devices = inventory(api.device_list());
    if query_settings {
        for device in &mut devices {
            let (Some(p), Some(info)) = (device.profile, device.control.as_ref()) else {
                continue;
            };
            match Handle::open(api, p, info) {
                Ok(handle) => {
                    let output = crate::cmd_status(&[handle], &[])?;
                    device.settings = parse_settings(&output);
                    device
                        .capabilities
                        .retain_readable(&device.settings, p.kind);
                }
                Err(e) => {
                    device.error = Some(e.to_string());
                }
            }
        }
    }
    serde_json::to_string(&serde_json::json!({ "devices": devices })).map_err(|e| e.to_string())
}

fn parse_settings(output: &str) -> BTreeMap<String, String> {
    let mut settings = BTreeMap::new();
    for line in output.lines() {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let fw_key = format!("{key}_fw");
        if let Some((name, fw)) = value.split_once(&format!(" {fw_key}=")) {
            settings.insert(key.into(), name.into());
            settings.insert(fw_key, fw.into());
        } else {
            settings.insert(key.into(), value.into());
        }
    }
    settings
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bluetooth_vendor_and_transport_are_distinct_from_usb() {
        assert!(is_razer(0x1532, BusType::Usb));
        assert!(is_razer(0x1532, BusType::Bluetooth));
        assert!(is_razer(0x068E, BusType::Bluetooth));
        assert!(!is_razer(0x068E, BusType::Usb));
        assert!(!is_razer(0x1234, BusType::Bluetooth));
        assert_eq!(transport_name(BusType::Bluetooth), "bluetooth");
    }

    #[test]
    fn capabilities_do_not_invent_mouse_hardware() {
        let p = PROFILES.iter().find(|p| p.pid == 0x00A5).unwrap();
        let mut caps = Capabilities::for_profile(p);
        assert!(caps.effects.is_empty());
        assert!(!caps.brightness && !caps.scroll && caps.zones == 0);
        assert_eq!(caps.dpi_max, 30000);
        caps.retain_readable(&BTreeMap::new(), p.kind);
        assert_eq!(caps.dpi_max, 0);
        assert!(!caps.dpi_stages && caps.poll_rates.is_empty());
    }

    #[test]
    fn legacy_status_preserves_names_and_firmware() {
        let settings =
            parse_settings("keyboard=Razer Ornata V3 X keyboard_fw=2.0\nkbd_brightness=255\n");
        assert_eq!(settings["keyboard"], "Razer Ornata V3 X");
        assert_eq!(settings["keyboard_fw"], "2.0");
        assert_eq!(settings["kbd_brightness"], "255");
    }
}
