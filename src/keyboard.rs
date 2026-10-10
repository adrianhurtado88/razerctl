//! Ornata V3 X mode indicators, separate from Chroma brightness.
use crate::devices::{Handle, Profile};
use crate::protocol::{Report, STATUS_SUCCESSFUL, VARSTORE};

pub const MACRO: u8 = 0x07;
pub const GAMING: u8 = 0x08;

pub fn supported(p: &Profile) -> bool {
    // Only the USB product whose state queries were verified in this audit.
    p.pid == 0x02A2
}

pub fn report(led: u8, value: Option<bool>) -> Report {
    let mut r = Report::new(0xFF, 0x03, if value.is_some() { 0x00 } else { 0x80 }, 3);
    r.set_arg(0, VARSTORE)
        .set_arg(1, led)
        .set_arg(2, value.unwrap_or(false) as u8);
    r
}

pub fn decode(r: &Report, led: u8, command: u8) -> Result<bool, String> {
    if r.status() != STATUS_SUCCESSFUL
        || r.bytes[1] != 0xFF
        || r.bytes[5] != 3
        || r.bytes[6] != 3
        || r.bytes[7] != command
        || r.arg(0) != VARSTORE
        || r.arg(1) != led
        || r.arg(2) > 1
    {
        return Err("keyboard mode response was not a confirmed state".into());
    }
    Ok(r.arg(2) == 1)
}

pub fn read(h: &Handle, led: u8) -> Result<bool, String> {
    if !supported(h.profile()) {
        return Err("keyboard mode controls are unavailable for this model".into());
    }
    let response = h.execute(report(led, None)).map_err(|e| e.0)?;
    decode(&response, led, 0x80)
}

pub fn parse(args: &[&str]) -> Result<(u8, Option<(bool, bool)>), String> {
    let led = match args.first().copied() {
        Some("macro") => MACRO,
        Some("gaming") => GAMING,
        _ => return Err(
            "usage: keyboard-mode <macro|gaming> [<on|off> <expected-on|expected-off>] --id <id>"
                .into(),
        ),
    };
    if args.len() == 1 {
        return Ok((led, None));
    }
    if args.len() != 3 {
        return Err("mode writes require a desired state and an expected current state".into());
    }
    let value = match args[1] {
        "on" => true,
        "off" => false,
        _ => return Err("mode must be on or off".into()),
    };
    let expected = match args[2] {
        "expected-on" => true,
        "expected-off" => false,
        _ => return Err("expected state must be expected-on or expected-off".into()),
    };
    Ok((led, Some((value, expected))))
}

pub fn command(handles: &[Handle], args: &[&str], selected: bool) -> Result<String, String> {
    let (led, change) = parse(args)?;
    if !selected || handles.len() != 1 {
        return Err("keyboard modes require one exact --id target".into());
    }
    let h = &handles[0];
    let current = read(h, led)?;
    let value = if let Some((desired, expected)) = change {
        transition(
            current,
            desired,
            expected,
            || read(h, led),
            |value| {
                let reply = h.execute(report(led, Some(value))).map_err(|e| e.0)?;
                if decode(&reply, led, 0x00)? != value {
                    return Err("keyboard did not acknowledge the requested mode".into());
                }
                Ok(())
            },
        )?
    } else {
        current
    };
    Ok(format!(
        "{}={}",
        if led == MACRO {
            "macro_recording"
        } else {
            "gaming_mode"
        },
        value as u8
    ))
}

fn transition(
    current: bool,
    desired: bool,
    expected: bool,
    mut read: impl FnMut() -> Result<bool, String>,
    mut write: impl FnMut(bool) -> Result<(), String>,
) -> Result<bool, String> {
    // Releasing an already-off indicator is harmless. Acquiring an already-on
    // macro indicator would take over another recorder and is refused.
    if current != expected {
        if !desired && !current {
            return Ok(false);
        }
        return Err("keyboard mode changed elsewhere; refresh before trying again".into());
    }
    let result = (|| {
        if current != desired {
            write(desired)?;
        }
        let actual = read()?;
        if actual != desired {
            return Err("keyboard mode read-back did not match the requested state".into());
        }
        Ok(actual)
    })();
    if let Err(error) = result {
        // A write can land even when its acknowledgement/read-back fails.
        // Restore the state observed immediately before this transaction.
        if current != desired {
            let rollback = (|| {
                if read()? != current {
                    write(current)?;
                }
                if read()? != current {
                    return Err("restore read-back failed".to_string());
                }
                Ok(())
            })();
            if let Err(restore) = rollback {
                return Err(format!(
                    "{error}; original mode could not be restored: {restore}"
                ));
            }
        }
        return Err(error);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::devices::PROFILES;
    #[test]
    fn exact_model_and_packets() {
        for p in PROFILES {
            assert_eq!(supported(p), p.pid == 0x02A2);
        }
        let r = report(MACRO, Some(true)).finalize();
        assert_eq!(&r.bytes[..11], &[0, 255, 0, 0, 0, 3, 3, 0, 1, 7, 1]);
        assert_eq!(report(GAMING, None).bytes[7], 0x80);
        assert_eq!(r.bytes[88], r.bytes[2..88].iter().fold(0, |a, b| a ^ b));
    }
    #[test]
    fn rejects_unconfirmed_or_malformed_responses() {
        let mut r = report(GAMING, None);
        r.bytes[0] = STATUS_SUCCESSFUL;
        assert_eq!(decode(&r, GAMING, 0x80), Ok(false));
        r.set_arg(2, 1);
        assert_eq!(decode(&r, GAMING, 0x80), Ok(true));
        for (offset, value) in [
            (0, 1),
            (1, 31),
            (5, 2),
            (6, 4),
            (7, 0),
            (8, 0),
            (9, 7),
            (10, 2),
        ] {
            let mut bad = r;
            bad.bytes[offset] = value;
            assert!(decode(&bad, GAMING, 0x80).is_err());
        }
    }
    #[test]
    fn transitions_preserve_foreign_state_and_roll_back_failed_write() {
        use std::cell::{Cell, RefCell};
        let state = Cell::new(false);
        let writes = RefCell::new(Vec::new());
        let write = |value| {
            writes.borrow_mut().push(value);
            state.set(value);
            Ok(())
        };
        assert_eq!(
            transition(false, true, false, || Ok(state.get()), write),
            Ok(true)
        );
        assert_eq!(*writes.borrow(), vec![true]);
        assert!(transition(true, true, false, || Ok(state.get()), write).is_err());
        assert_eq!(
            *writes.borrow(),
            vec![true],
            "foreign recording must not be touched"
        );
        assert_eq!(
            transition(false, false, true, || Ok(false), write),
            Ok(false)
        );
        state.set(false);
        writes.borrow_mut().clear();
        let write = |value| {
            writes.borrow_mut().push(value);
            state.set(value);
            if value {
                Err("acknowledgement failed".into())
            } else {
                Ok(())
            }
        };
        assert!(transition(false, true, false, || Ok(state.get()), write).is_err());
        assert!(!state.get());
        assert_eq!(*writes.borrow(), vec![true, false]);
    }
    #[test]
    fn rollback_failure_is_reported() {
        let error = transition(
            false,
            true,
            false,
            || Err("disconnected".into()),
            |_| Ok(()),
        )
        .unwrap_err();
        assert!(error.contains("original mode could not be restored"));
    }
    #[test]
    fn strict_arguments_and_explicit_target() {
        assert_eq!(
            parse(&["macro", "on", "expected-off"]),
            Ok((MACRO, Some((true, false))))
        );
        for args in [
            vec![],
            vec!["caps"],
            vec!["macro", "on"],
            vec!["gaming", "yes", "expected-off"],
            vec!["macro", "on", "off"],
            vec!["gaming", "off", "expected-on", "extra"],
        ] {
            assert!(parse(&args).is_err());
        }
        assert!(command(&[], &["gaming"], false).is_err());
    }
}
