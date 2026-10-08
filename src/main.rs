//! razerctl — tiny controller for Razer keyboards and mice.
//!
//! A lightweight, local alternative to Razer Synapse for the handful of
//! settings that actually matter: DPI, polling rate, lighting, scroll wheel.

mod devices;
mod protocol;

use devices::{Handle, Kind, PROFILES};
use protocol::*;
use std::process::ExitCode;

const USAGE: &str = "\
razerctl — control your Razer peripherals without Synapse

USAGE:
  razerctl list                          Show detected devices
  razerctl info                          Firmware + current settings (human)
  razerctl status                        Same, machine-readable key=value

  razerctl dpi <x> [<y>]                  Set mouse DPI (defaults y = x)
  razerctl stages <v1,v2,...> [active]   Set onboard DPI stages (2-5 values),
                                         e.g. `stages 400,800,1600 2`
  razerctl poll <125|500|1000>           Set mouse polling rate (Hz)
  razerctl scroll <tactile|free>         Basilisk scroll-wheel mode

  razerctl effect <name> [args]          Set a lighting effect
  razerctl brightness <0-100>            Set lighting brightness
  razerctl zones <c1,c2,...>             Mouse only: per-zone static colors
                                         (2-11 zones), e.g. `zones FF0000,00FF00`
  razerctl rainbow [n]                   Mouse only: static rainbow over n zones
  razerctl probe                         Transport diagnostics (safe: control
                                         collections only, firmware query only)

EFFECTS (per device — the hardware refuses the rest):
  mouse:      spectrum · static <RRGGBB> · wave [left|right] · none
  keyboard:   spectrum · static <RRGGBB> · breath · breath-single <RRGGBB> · none

OPTIONS:
  --dev <keyboard|mouse>                 Target one device only
  --led <all|scroll|logo>                Mouse brightness target

EXAMPLES:
  razerctl dpi 1600
  razerctl effect static FF00AA --dev mouse
  razerctl effect wave right
  razerctl rainbow 11
  razerctl brightness 42
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(msg) => {
            if !msg.is_empty() {
                println!("{msg}");
            }
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("error: {e}");
            eprintln!("run `razerctl` with no arguments for usage");
            ExitCode::FAILURE
        }
    }
}

fn run(args: &[String]) -> Result<String, String> {
    if args.is_empty() {
        return Ok(USAGE.to_string());
    }

    // Separate flags from positional args.
    let mut positional: Vec<&str> = Vec::new();
    let mut led: Option<u8> = None;
    let mut dev_filter: Option<Kind> = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--led" => {
                i += 1;
                let v = args.get(i).ok_or("--led needs a value")?;
                led = Some(match v.as_str() {
                    "all" => LED_ALL,
                    "scroll" | "wheel" => LED_SCROLL_WHEEL,
                    "logo" => LED_LOGO,
                    "backlight" => LED_BACKLIGHT,
                    other => return Err(format!("unknown LED zone '{other}'")),
                });
            }
            "--dev" | "--device" => {
                i += 1;
                let v = args.get(i).ok_or("--dev needs a value")?;
                dev_filter = Some(match v.as_str() {
                    "keyboard" | "kbd" => Kind::Keyboard,
                    "mouse" => Kind::Mouse,
                    other => return Err(format!("unknown device '{other}'")),
                });
            }
            other if other.starts_with("--") => {
                return Err(format!("unknown option '{other}'"));
            }
            other => positional.push(other),
        }
        i += 1;
    }

    let cmd = positional
        .first()
        .ok_or_else(|| "no command given".to_string())?;
    let rest = &positional[1..];

    let api = hidapi::HidApi::new().map_err(|e| format!("hidapi init failed: {e}"))?;

    match *cmd {
        "list" => cmd_list(&api),
        "probe" => Ok(devices::probe_all(&api)),
        _ => {
            let (handles, failures) = devices::open_all(&api);
            for f in &failures {
                eprintln!("{f}");
            }
            match *cmd {
                "info" => cmd_info(&handles),
                "status" => cmd_status(&handles, &failures),
                "dpi" => cmd_dpi(&handles, rest),
                "stages" => cmd_stages(&handles, rest),
                "poll" => cmd_poll(&handles, rest),
                "scroll" => cmd_scroll(&handles, rest),
                "effect" => cmd_effect(&handles, rest, led, dev_filter),
                "brightness" => cmd_brightness(&handles, rest, led, dev_filter),
                "zones" => cmd_zones(&handles, rest),
                "rainbow" => cmd_rainbow(&handles, rest),
                other => Err(format!("unknown command '{other}'")),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Command implementations
// ---------------------------------------------------------------------------

fn cmd_list(api: &hidapi::HidApi) -> Result<String, String> {
    let mut out = String::new();
    for p in PROFILES {
        let found = api
            .device_list()
            .any(|d| d.vendor_id() == USB_VENDOR_ID && d.product_id() == p.pid);
        let status = if found { "connected" } else { "not connected" };
        out.push_str(&format!(
            "{:<22} USB 1532:{:04X}  control iface {}   {}\n",
            p.name, p.pid, p.interface, status
        ));
    }
    Ok(out.trim_end().to_string())
}

fn cmd_info(handles: &[Handle]) -> Result<String, String> {
    if handles.is_empty() {
        return Err("no supported Razer devices are connected".into());
    }
    let mut out = String::new();
    for h in handles {
        let p = h.profile();
        out.push_str(&format!(
            "{}\n  firmware:  v{}.{}\n",
            p.name,
            h.firmware.0,
            h.firmware.1
        ));
        if p.is_mouse() {
            if let Ok(resp) = h.execute(get_dpi_xy(p.txid)) {
                let x = ((resp.arg(1) as u16) << 8) | resp.arg(2) as u16;
                let y = ((resp.arg(3) as u16) << 8) | resp.arg(4) as u16;
                out.push_str(&format!("  dpi:       {x} x {y}\n"));
            }
            if let Ok(resp) = h.execute(get_dpi_stages(p.txid)) {
                let active = resp.arg(1);
                let count = resp.arg(2).min(5);
                let stages: Vec<String> = (0..count)
                    .filter_map(|i| {
                        let base = 3 + (i as usize) * 7;
                        let x = ((resp.arg(base + 1) as u16) << 8) | resp.arg(base + 2) as u16;
                        let y = ((resp.arg(base + 3) as u16) << 8) | resp.arg(base + 4) as u16;
                        Some(if x == y { format!("{x}") } else { format!("{x}x{y}") })
                    })
                    .collect();
                out.push_str(&format!(
                    "  stages:    [{}] (active: {})\n",
                    stages.join(", "),
                    active + 1
                ));
            }
            if let Ok(resp) = h.execute(get_poll_rate(p.txid)) {
                let rate = match resp.arg(0) {
                    0x01 => 1000,
                    0x02 => 500,
                    0x08 => 125,
                    other => other as u16,
                };
                out.push_str(&format!("  poll rate: {rate} Hz\n"));
            }
            if let Ok(resp) = h.execute(get_scroll_mode(p.txid)) {
                let mode = if resp.arg(1) == 1 { "free spin" } else { "tactile" };
                out.push_str(&format!("  scroll:    {mode}\n"));
            }
        }
    }
    Ok(out.trim_end().to_string())
}

/// Machine-readable status for the menu-bar widget (key=value lines).
/// Includes `keyboard_error=` / `mouse_error=` lines when a device is
/// present but refuses communication, so the UI can show the reason.
fn cmd_status(handles: &[Handle], failures: &[String]) -> Result<String, String> {
    let mut out = String::new();
    for f in failures {
        out.push_str(f);
        out.push('\n');
    }
    for h in handles {
        let p = h.profile();
        match p.kind {
            Kind::Keyboard => {
                out.push_str(&format!(
                    "keyboard={} keyboard_fw={}.{}\n",
                    p.name, h.firmware.0, h.firmware.1
                ));
                if let Ok(resp) = h.execute(get_brightness(p.txid, LED_BACKLIGHT)) {
                    out.push_str(&format!("kbd_brightness={}\n", resp.arg(2)));
                }
            }
            Kind::Mouse => {
                out.push_str(&format!(
                    "mouse={} mouse_fw={}.{}\n",
                    p.name, h.firmware.0, h.firmware.1
                ));
                if let Ok(resp) = h.execute(get_dpi_xy(p.txid)) {
                    let x = ((resp.arg(1) as u16) << 8) | resp.arg(2) as u16;
                    let y = ((resp.arg(3) as u16) << 8) | resp.arg(4) as u16;
                    out.push_str(&format!("dpi={x}\ndpi_y={y}\n"));
                }
                if let Ok(resp) = h.execute(get_dpi_stages(p.txid)) {
                    let active = resp.arg(1);
                    let count = resp.arg(2).min(5);
                    let stages: Vec<String> = (0..count)
                        .filter_map(|i| {
                            let base = 3 + (i as usize) * 7;
                            let x =
                                ((resp.arg(base + 1) as u16) << 8) | resp.arg(base + 2) as u16;
                            Some(x.to_string())
                        })
                        .collect();
                    out.push_str(&format!(
                        "stages={}\nactive_stage={}\n",
                        stages.join(","),
                        active + 1
                    ));
                }
                if let Ok(resp) = h.execute(get_poll_rate(p.txid)) {
                    let rate = match resp.arg(0) {
                        0x01 => 1000,
                        0x02 => 500,
                        0x08 => 125,
                        other => other as u16,
                    };
                    out.push_str(&format!("poll={rate}\n"));
                }
                if let Ok(resp) = h.execute(get_scroll_mode(p.txid)) {
                    out.push_str(&format!(
                        "scroll={}\n",
                        if resp.arg(1) == 1 { "free" } else { "tactile" }
                    ));
                }
                if let Ok(resp) = h.execute(get_brightness(p.txid, LED_ALL)) {
                    out.push_str(&format!("brightness={}\n", resp.arg(2)));
                }
            }
        }
    }
    Ok(out.trim_end().to_string())
}

fn cmd_dpi(handles: &[Handle], args: &[&str]) -> Result<String, String> {
    let x: u16 = args
        .first()
        .ok_or("usage: razerctl dpi <x> [<y>]")?
        .parse()
        .map_err(|_| "DPI must be a number".to_string())?;
    let y: u16 = match args.get(1) {
        Some(v) => v
            .parse()
            .map_err(|_| "DPI must be a number".to_string())?,
        None => x,
    };
    let mut out = String::new();
    for h in handles.iter().filter(|h| h.profile().is_mouse()) {
        let p = h.profile();
        if x > p.dpi_max || y > p.dpi_max {
            return Err(format!(
                "DPI {} exceeds the {}'s maximum of {}",
                x.max(y),
                p.name,
                p.dpi_max
            ));
        }
        h.execute(set_dpi_xy(p.txid, x, y))
            .map_err(|e| format!("{}: {e}", p.name))?;
        out.push_str(&format!("✓ {}: DPI → {x} x {y}\n", p.name));
    }
    if out.is_empty() {
        return Err("no mouse connected".into());
    }
    Ok(out.trim_end().to_string())
}

fn cmd_stages(handles: &[Handle], args: &[&str]) -> Result<String, String> {
    let raw = args
        .first()
        .ok_or("usage: razerctl stages <v1,v2,...> [active]")?;
    let stages: Vec<u16> = raw
        .split(',')
        .map(|s| s.trim().parse::<u16>())
        .collect::<Result<_, _>>()
        .map_err(|_| format!("'{raw}' is not a comma-separated list of numbers"))?;
    if !(2..=5).contains(&stages.len()) {
        return Err("provide between 2 and 5 DPI stages".into());
    }
    let active: u8 = match args.get(1) {
        Some(v) => {
            let n = v
                .parse::<u8>()
                .map_err(|_| "active stage must be a number".to_string())?;
            // Stages are 1-based on the wire; guard the 0 case instead of
            // underflowing (which panics in debug builds).
            n.checked_sub(1)
                .ok_or("active stage must be 1 or greater")?
        }
        None => 0,
    };
    if active as usize >= stages.len() {
        return Err(format!("active stage {} is out of range", active + 1));
    }
    let mut out = String::new();
    for h in handles.iter().filter(|h| h.profile().is_mouse()) {
        let p = h.profile();
        h.execute(set_dpi_stages(p.txid, active, &stages))
            .map_err(|e| format!("{}: {e}", p.name))?;
        out.push_str(&format!(
            "✓ {}: DPI stages → [{}] (active: {})\n",
            p.name,
            stages
                .iter()
                .map(|s| s.to_string())
                .collect::<Vec<_>>()
                .join(", "),
            active + 1
        ));
    }
    if out.is_empty() {
        return Err("no mouse connected".into());
    }
    Ok(out.trim_end().to_string())
}

fn cmd_poll(handles: &[Handle], args: &[&str]) -> Result<String, String> {
    let rate: u16 = args
        .first()
        .ok_or("usage: razerctl poll <125|500|1000>")?
        .parse()
        .map_err(|_| "polling rate must be a number".to_string())?;
    if ![125, 500, 1000].contains(&rate) {
        return Err("polling rate must be 125, 500 or 1000 Hz".into());
    }
    let mut out = String::new();
    for h in handles.iter().filter(|h| h.profile().is_mouse()) {
        let p = h.profile();
        h.execute(set_poll_rate(p.txid, rate))
            .map_err(|e| format!("{}: {e}", p.name))?;
        out.push_str(&format!("✓ {}: polling rate → {rate} Hz\n", p.name));
    }
    if out.is_empty() {
        return Err("no mouse connected".into());
    }
    Ok(out.trim_end().to_string())
}

fn cmd_scroll(handles: &[Handle], args: &[&str]) -> Result<String, String> {
    let free = match args.first() {
        Some(&"free") | Some(&"freespin") | Some(&"free-spin") => true,
        Some(&"tactile") | Some(&"notched") | Some(&"ratchet") => false,
        _ => return Err("usage: razerctl scroll <tactile|free>".into()),
    };
    let mut out = String::new();
    for h in handles.iter().filter(|h| h.profile().is_mouse()) {
        let p = h.profile();
        h.execute(set_scroll_mode(p.txid, free))
            .map_err(|e| format!("{}: {e}", p.name))?;
        let mode = if free { "free spin" } else { "tactile" };
        out.push_str(&format!("✓ {}: scroll mode → {mode}\n", p.name));
    }
    if out.is_empty() {
        return Err("no mouse connected".into());
    }
    Ok(out.trim_end().to_string())
}

fn parse_effect(args: &[&str]) -> Result<Effect, String> {
    let name = args.first().ok_or("usage: razerctl effect <name> [args]")?;
    match *name {
        "none" | "off" => Ok(Effect::None),
        "static" => {
            let c = args
                .get(1)
                .ok_or("static needs a color, e.g. `effect static 00FF88`")?;
            Ok(Effect::Static(Rgb::parse(c).ok_or_else(|| {
                format!("'{c}' is not a hex color (expected RRGGBB)")
            })?))
        }
        "spectrum" | "rainbow" => Ok(Effect::Spectrum),
        "wave" => {
            // RAW device values (OpenRazer DBus): 1 = left-to-right,
            // 2 = right-to-left.
            let dir = match args.get(1) {
                None | Some(&"left") => 1u8,
                Some(&"right") => 2u8,
                Some(other) => return Err(format!("unknown wave direction '{other}'")),
            };
            Ok(Effect::Wave(dir))
        }
        "breath" | "breathe" => Ok(Effect::BreathRandom),
        "breath-single" | "breath1" => {
            let c = args
                .get(1)
                .ok_or("breath-single needs a color, e.g. `effect breath-single 00FF88`")?;
            Ok(Effect::BreathSingle(Rgb::parse(c).ok_or_else(|| {
                format!("'{c}' is not a hex color (expected RRGGBB)")
            })?))
        }
        other => Err(format!("unknown effect '{other}'")),
    }
}

fn cmd_effect(
    handles: &[Handle],
    args: &[&str],
    led: Option<u8>,
    dev_filter: Option<Kind>,
) -> Result<String, String> {
    let effect = parse_effect(args)?;
    let mut out = String::new();
    let mut targeted = 0;
    for h in handles {
        let p = h.profile();
        if let Some(k) = dev_filter {
            if p.kind != k {
                continue;
            }
        }
        let report = match p.kind {
            Kind::Keyboard => keyboard_effect(p.txid, LED_BACKLIGHT, effect),
            Kind::Mouse => mouse_effect(p.txid, led.unwrap_or(LED_ALL), effect),
        };
        h.execute(report).map_err(|e| format!("{}: {e}", p.name))?;
        out.push_str(&format!("✓ {}: effect → {}\n", p.name, effect.name()));
        targeted += 1;
    }
    if targeted == 0 {
        return Err("no matching device connected".into());
    }
    Ok(out.trim_end().to_string())
}

/// Apply per-zone colors to the mouse (custom frame mode).
/// Shared by `zones` (explicit colors) and `rainbow` (generated hues).
fn apply_zones(handles: &[Handle], colors: &[Rgb]) -> Result<String, String> {
    let mut out = String::new();
    let mut targeted = 0;
    for h in handles.iter().filter(|h| h.profile().is_mouse()) {
        let p = h.profile();
        if colors.len() > 11 {
            return Err(format!("{}: too many colors ({}), max 11 zones", p.name, colors.len()));
        }
        if colors.is_empty() {
            return Err("no colors given".into());
        }
        // Order per OpenRazer's ripple effect: write row, then activate.
        h.execute(mouse_set_row(p.txid, 0, colors))
            .map_err(|e| format!("{}: {e}", p.name))?;
        h.execute(mouse_custom_effect(p.txid))
            .map_err(|e| format!("{}: {e}", p.name))?;
        let hexes: Vec<String> = colors
            .iter()
            .map(|Rgb(r, g, b)| format!("{r:02X}{g:02X}{b:02X}"))
            .collect();
        out.push_str(&format!(
            "✓ {}: {} zones → [{}]\n",
            p.name,
            colors.len(),
            hexes.join(",")
        ));
        targeted += 1;
    }
    if targeted == 0 {
        return Err("no mouse connected".into());
    }
    Ok(out.trim_end().to_string())
}

/// `razerctl zones FF0000,00FF00,...` — explicit per-zone colors.
fn cmd_zones(handles: &[Handle], args: &[&str]) -> Result<String, String> {
    let raw = args
        .first()
        .ok_or("usage: razerctl zones <RRGGBB,RRGGBB,...> (2-11 zones)")?;
    let colors: Vec<Rgb> = raw
        .split(',')
        .map(|s| {
            Rgb::parse(s)
                .ok_or_else(|| format!("'{s}' is not a hex color (expected RRGGBB)"))
        })
        .collect::<Result<_, _>>()?;
    apply_zones(handles, &colors)
}

/// `razerctl rainbow` — a static rainbow across the mouse zones.
fn cmd_rainbow(handles: &[Handle], args: &[&str]) -> Result<String, String> {
    let count: usize = match args.first() {
        Some(v) => v
            .parse()
            .map_err(|_| "zone count must be a number".to_string())?,
        None => 11,
    };
    if !(2..=11).contains(&count) {
        return Err("zone count must be 2-11".into());
    }
    apply_zones(handles, &rainbow(count))
}

fn cmd_brightness(
    handles: &[Handle],
    args: &[&str],
    led: Option<u8>,
    dev_filter: Option<Kind>,
) -> Result<String, String> {
    let pct: u8 = args
        .first()
        .ok_or("usage: razerctl brightness <0-100>")?
        .parse()
        .map_err(|_| "brightness must be 0-100".to_string())?;
    if pct > 100 {
        return Err("brightness must be 0-100".into());
    }
    let value = (pct as f32 / 100.0 * 255.0).round() as u8;
    let mut out = String::new();
    let mut targeted = 0;
    for h in handles {
        let p = h.profile();
        if let Some(k) = dev_filter {
            if p.kind != k {
                continue;
            }
        }
        let target = match p.kind {
            Kind::Keyboard => LED_BACKLIGHT,
            Kind::Mouse => led.unwrap_or(LED_ALL),
        };
        h.execute(set_brightness(p.txid, target, value))
            .map_err(|e| format!("{}: {e}", p.name))?;
        out.push_str(&format!("✓ {}: brightness → {pct}%\n", p.name));
        targeted += 1;
    }
    if targeted == 0 {
        return Err("no matching device connected".into());
    }
    Ok(out.trim_end().to_string())
}

