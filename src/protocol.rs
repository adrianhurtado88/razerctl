//! Razer USB HID control protocol.
//!
//! Reverse-engineered protocol as implemented by the OpenRazer project
//! (GPL-2.0-or-later, https://github.com/openrazer/openrazer).
//!
//! Commands are 90-byte HID **feature reports** (report ID 0) exchanged with a
//! specific USB interface on the device:
//!
//! ```text
//! offset  size  field
//! 0       1     status (0x00 on request; response code on reply)
//! 1       1     transaction id (echoed by device)
//! 2       2     remaining packets (big endian, always 0)
//! 4       1     protocol type (0x00)
//! 5       1     data size
//! 6       1     command class
//! 7       1     command id
//! 8       80    arguments
//! 88      1     CRC: XOR of bytes 2..88
//! 89      1     reserved (0x00)
//! ```

pub const REPORT_LEN: usize = 90;

/// Razer's USB vendor ID.
pub const USB_VENDOR_ID: u16 = 0x1532;

// "Variable storage" / LED identifiers (driver/razercommon.h)
pub const VARSTORE: u8 = 0x01;
pub const LED_ALL: u8 = 0x00;
pub const LED_SCROLL_WHEEL: u8 = 0x01;
pub const LED_LOGO: u8 = 0x04;
pub const LED_BACKLIGHT: u8 = 0x05;

// Response status codes (driver/razercommon.h)
pub const STATUS_BUSY: u8 = 0x01;
pub const STATUS_SUCCESSFUL: u8 = 0x02;
pub const STATUS_FAILURE: u8 = 0x03;
pub const STATUS_TIMEOUT: u8 = 0x04;
pub const STATUS_NOT_SUPPORTED: u8 = 0x05;

/// An RGB color.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgb(pub u8, pub u8, pub u8);

impl Rgb {
    /// Parse a hex color like `FF00AA`, `#FF00AA` or `0xFF00AA`.
    pub fn parse(s: &str) -> Option<Rgb> {
        let s = s.trim_start_matches('#').trim_start_matches("0x");
        if s.len() != 6 || !s.bytes().all(|b| b.is_ascii_hexdigit()) {
            return None;
        }
        let v = u32::from_str_radix(s, 16).ok()?;
        Some(Rgb(
            ((v >> 16) & 0xFF) as u8,
            ((v >> 8) & 0xFF) as u8,
            (v & 0xFF) as u8,
        ))
    }
}

/// A 90-byte Razer control report.
#[derive(Clone, Copy)]
pub struct Report {
    pub bytes: [u8; REPORT_LEN],
}

impl Report {
    pub fn new(transaction_id: u8, command_class: u8, command_id: u8, data_size: u8) -> Self {
        let mut bytes = [0u8; REPORT_LEN];
        bytes[1] = transaction_id;
        bytes[5] = data_size;
        bytes[6] = command_class;
        bytes[7] = command_id;
        Report { bytes }
    }

    pub fn set_arg(&mut self, idx: usize, value: u8) -> &mut Self {
        self.bytes[8 + idx] = value;
        self
    }

    pub fn arg(&self, idx: usize) -> u8 {
        self.bytes[8 + idx]
    }

    /// Compute the XOR checksum over bytes 2..88 and store it at byte 88.
    pub fn finalize(mut self) -> Self {
        let mut crc = 0u8;
        for i in 2..88 {
            crc ^= self.bytes[i];
        }
        self.bytes[88] = crc;
        self
    }

    /// Response status byte.
    pub fn status(&self) -> u8 {
        self.bytes[0]
    }
}

// ---------------------------------------------------------------------------
// Standard commands (command class 0x00)
// ---------------------------------------------------------------------------

/// Get the device firmware version. Response: args[0].args[1] = major.minor.
pub fn get_firmware(txid: u8) -> Report {
    Report::new(txid, 0x00, 0x81, 0x02)
}

/// Set the polling rate: 125 / 500 / 1000 Hz.
pub fn set_poll_rate(txid: u8, rate: u16) -> Report {
    let code = match rate {
        1000 => 0x01,
        500 => 0x02,
        125 => 0x08,
        _ => 0x02,
    };
    let mut r = Report::new(txid, 0x00, 0x05, 0x01);
    r.set_arg(0, code);
    r
}

/// Get the polling rate. Response: args[0] = 0x01/0x02/0x08.
pub fn get_poll_rate(txid: u8) -> Report {
    Report::new(txid, 0x00, 0x85, 0x01)
}

// ---------------------------------------------------------------------------
// Mouse hardware commands (command class 0x04)
// ---------------------------------------------------------------------------

/// Set DPI for both axes (each 100..=26000 for the Basilisk V3).
pub fn set_dpi_xy(txid: u8, dpi_x: u16, dpi_y: u16) -> Report {
    let mut r = Report::new(txid, 0x04, 0x05, 0x07);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, (dpi_x >> 8) as u8);
    r.set_arg(2, dpi_x as u8);
    r.set_arg(3, (dpi_y >> 8) as u8);
    r.set_arg(4, dpi_y as u8);
    r
}

/// Get DPI. Response: args[1..2] = X (big endian), args[3..4] = Y.
pub fn get_dpi_xy(txid: u8) -> Report {
    Report::new(txid, 0x04, 0x85, 0x07)
}

/// Configure the onboard DPI stages (cycle with the DPI stage button).
/// `stages` holds 2..=5 DPI values; `active` is the 1-based stage to activate.
pub fn set_dpi_stages(txid: u8, active: u8, stages: &[u16]) -> Report {
    let count = stages.len().min(5) as u8;
    let mut r = Report::new(txid, 0x04, 0x06, 0x26);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, active);
    r.set_arg(2, count);
    let mut off = 3;
    for (i, &dpi) in stages.iter().take(5).enumerate() {
        r.set_arg(off, i as u8);
        r.set_arg(off + 1, (dpi >> 8) as u8);
        r.set_arg(off + 2, dpi as u8);
        r.set_arg(off + 3, (dpi >> 8) as u8);
        r.set_arg(off + 4, dpi as u8);
        // reserved x2
        off += 7;
    }
    r
}

/// Get DPI stages. Response: args[1] = active stage, args[2] = count,
/// then per stage: stage#, X hi, X lo, Y hi, Y lo, 0, 0.
pub fn get_dpi_stages(txid: u8) -> Report {
    Report::new(txid, 0x04, 0x86, 0x26)
}

// ---------------------------------------------------------------------------
// Scroll wheel commands (command class 0x02, Basilisk HyperScroll)
// ---------------------------------------------------------------------------

/// Set scroll mode: `false` = tactile (notched), `true` = free spin.
pub fn set_scroll_mode(txid: u8, free_spin: bool) -> Report {
    let mut r = Report::new(txid, 0x02, 0x14, 0x02);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, if free_spin { 1 } else { 0 });
    r
}

/// Get scroll mode. Response: args[1] = 0 (tactile) / 1 (free spin).
pub fn get_scroll_mode(txid: u8) -> Report {
    Report::new(txid, 0x02, 0x94, 0x02)
}

// ---------------------------------------------------------------------------
// Lighting effects
// ---------------------------------------------------------------------------

/// Supported lighting effects (per effect command variant).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    None,
    Static(Rgb),
    Spectrum,
    /// Wave direction: 0 = left, 1 = right (keyboards).
    Wave(u8),
    BreathRandom,
    BreathSingle(Rgb),
}

impl Effect {
    pub fn name(&self) -> &'static str {
        match self {
            Effect::None => "none",
            Effect::Static(_) => "static",
            Effect::Spectrum => "spectrum",
            Effect::Wave(_) => "wave",
            Effect::BreathRandom => "breath",
            Effect::BreathSingle(_) => "breath-single",
        }
    }
}

/// Keyboard lighting: command class 0x0F, command 0x02 ("extended matrix").
/// Per-key/zone capable devices report a matrix; the Ornata V3 X exposes a
/// single backlight zone.
pub fn keyboard_effect(txid: u8, led: u8, effect: Effect) -> Report {
    let (data_size, effect_id) = match effect {
        Effect::None => (0x06, 0x00),
        Effect::Static(_) => (0x09, 0x01),
        Effect::Spectrum => (0x06, 0x03),
        Effect::Wave(_) => (0x06, 0x04),
        Effect::BreathRandom => (0x06, 0x02),
        Effect::BreathSingle(_) => (0x09, 0x02),
    };
    let mut r = Report::new(txid, 0x0F, 0x02, data_size);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, led);
    r.set_arg(2, effect_id);
    match effect {
        Effect::Static(Rgb(rr, gg, bb)) => {
            r.set_arg(5, 0x01);
            r.set_arg(6, rr);
            r.set_arg(7, gg);
            r.set_arg(8, bb);
        }
        Effect::Wave(dir) => {
            r.set_arg(3, dir);
            r.set_arg(4, 0x28); // speed (lower = faster), per driver
        }
        Effect::BreathSingle(Rgb(rr, gg, bb)) => {
            r.set_arg(3, 0x01);
            r.set_arg(5, 0x01);
            r.set_arg(6, rr);
            r.set_arg(7, gg);
            r.set_arg(8, bb);
        }
        _ => {}
    }
    r
}

/// Mouse lighting: the Basilisk V3 uses the SAME "extended matrix" command
/// as keyboards (OpenRazer: `razer_chroma_extended_matrix_effect_*(VARSTORE,
/// ZERO_LED)`), just with different LED ids: 0x00 all, 0x01 scroll wheel,
/// 0x04 logo.
pub fn mouse_effect(txid: u8, led: u8, effect: Effect) -> Report {
    // Wave is special on mice: OpenRazer's wave_common sends it with
    // transaction id 0x3F even on 0x1F-generation devices.
    let txid = if matches!(effect, Effect::Wave(_)) {
        0x3F
    } else {
        txid
    };
    let (data_size, effect_id) = match effect {
        Effect::None => (0x06, 0x00),
        Effect::Static(_) => (0x09, 0x01),
        Effect::Spectrum => (0x06, 0x03),
        Effect::Wave(_) => (0x06, 0x04),
        Effect::BreathRandom => (0x06, 0x02),
        Effect::BreathSingle(_) => (0x09, 0x02),
    };
    let mut r = Report::new(txid, 0x0F, 0x02, data_size);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, led);
    r.set_arg(2, effect_id);
    match effect {
        Effect::Static(Rgb(rr, gg, bb)) => {
            r.set_arg(5, 0x01);
            r.set_arg(6, rr);
            r.set_arg(7, gg);
            r.set_arg(8, bb);
        }
        Effect::Wave(dir) => {
            r.set_arg(3, dir);
            r.set_arg(4, 0x28); // speed (lower = faster), per driver
        }
        Effect::BreathSingle(Rgb(rr, gg, bb)) => {
            r.set_arg(3, 0x01);
            r.set_arg(5, 0x01);
            r.set_arg(6, rr);
            r.set_arg(7, gg);
            r.set_arg(8, bb);
        }
        _ => {}
    }
    r
}

/// Set device brightness (0..=255).
///
/// These devices use the EXTENDED matrix brightness command (OpenRazer:
/// `razer_chroma_extended_matrix_brightness`) — class 0x0F, cmd 0x04.
/// Keyboard: led = BACKLIGHT_LED (0x05); mouse: led = ZERO_LED (0x00, all
/// zones). The older "standard" command (class 0x03/0x03) is refused by both.
pub fn set_brightness(txid: u8, led: u8, value: u8) -> Report {
    let mut r = Report::new(txid, 0x0F, 0x04, 0x03);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, led);
    r.set_arg(2, value);
    r
}

/// Read device brightness (class 0x0F, cmd 0x84). Response: args[2] = 0..255.
pub fn get_brightness(txid: u8, led: u8) -> Report {
    let mut r = Report::new(txid, 0x0F, 0x84, 0x03);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, led);
    r
}

/// Diagnostic: a brightness read with explicit class/cmd — used to probe
/// which read-back variant a device actually accepts (extended 0x0F/0x84
/// vs standard 0x03/0x83, per-LED ids).
pub fn read_brightness_variant(txid: u8, class: u8, cmd: u8, led: u8) -> Report {
    let mut r = Report::new(txid, class, cmd, 0x03);
    r.set_arg(0, VARSTORE);
    r.set_arg(1, led);
    r
}

// ---------------------------------------------------------------------------
// Per-zone ("custom frame") lighting — Basilisk V3: 1 row × 11 zones
// ---------------------------------------------------------------------------

/// Write one row of per-zone colors. `start` is the first zone index,
/// `colors` the colors from that zone onward (up to 11 for the Basilisk V3).
/// OpenRazer: razer_chroma_extended_matrix_set_custom_frame(), class 0x0F,
/// cmd 0x03, data size 0x47, args[2]=row [3]=start [4]=stop, RGB at args[5].
pub fn mouse_set_row(txid: u8, start: u8, colors: &[Rgb]) -> Report {
    let stop = start + colors.len() as u8 - 1;
    let mut r = Report::new(txid, 0x0F, 0x03, 0x47);
    r.set_arg(2, 0); // row index — the mouse matrix has only row 0
    r.set_arg(3, start);
    r.set_arg(4, stop);
    for (i, &Rgb(rr, gg, bb)) in colors.iter().enumerate() {
        let base = 5 + i * 3;
        r.set_arg(base, rr);
        r.set_arg(base + 1, gg);
        r.set_arg(base + 2, bb);
    }
    r
}

/// Activate custom-frame mode: display whatever zone colors were written.
/// OpenRazer: razer_chroma_extended_matrix_effect_custom_frame(), class
/// 0x0F, cmd 0x02, data size 0x0C, effect id 0x08.
pub fn mouse_custom_effect(txid: u8) -> Report {
    let mut r = Report::new(txid, 0x0F, 0x02, 0x0C);
    r.set_arg(0, 0x00);
    r.set_arg(1, 0x00);
    r.set_arg(2, 0x08); // custom frame effect
    r
}

/// `n` colors evenly spaced around the hue wheel (a static rainbow).
pub fn rainbow(n: usize) -> Vec<Rgb> {
    (0..n)
        .map(|i| {
            // HSV with s = v = 1; hue = i / n of the wheel.
            let h = i as f32 / n as f32 * 360.0;
            let (r, g, b) = hsv_to_rgb(h, 1.0, 1.0);
            Rgb(
                (r * 255.0).round() as u8,
                (g * 255.0).round() as u8,
                (b * 255.0).round() as u8,
            )
        })
        .collect()
}

fn hsv_to_rgb(h: f32, s: f32, v: f32) -> (f32, f32, f32) {
    let c = v * s;
    let hp = h / 60.0;
    let x = c * (1.0 - (hp % 2.0 - 1.0).abs());
    let (r1, g1, b1) = match hp as u8 % 6 {
        0 => (c, x, 0.0),
        1 => (x, c, 0.0),
        2 => (0.0, c, x),
        3 => (0.0, x, c),
        4 => (x, 0.0, c),
        _ => (c, 0.0, x),
    };
    let m = v - c;
    (r1 + m, g1 + m, b1 + m)
}
