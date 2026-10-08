#!/bin/bash
# Build the RazerCtl menu-bar widget: compiles the Rust core, the Swift
# menu-bar app, assembles the .app bundle and ad-hoc signs it.
#
# The bundle is built OUTSIDE the workspace (in /tmp) because iCloud
# File Provider sync on the workspace tree interferes with app bundles
# (evicts files, injects xattrs that break codesigning).
set -euo pipefail
cd "$(dirname "$0")"

CARGO="${CARGO:-$HOME/.cargo/bin/cargo}"
APP="${WIDGET_APP:-${TMPDIR:-/tmp}/RazerCtl.app}"

echo "==> Rust core"
"$CARGO" build --release

echo "==> Swift menu-bar app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# NOTE: the core must be named `razerctl-core`, never `razerctl` — on the
# case-insensitive macOS filesystem, `razerctl` and `RazerCtl` are the same
# path, and the swiftc output below would silently overwrite the core.
CORE="$APP/Contents/MacOS/razerctl-core"
GUI="$APP/Contents/MacOS/RazerCtl"
cp target/release/razerctl "$CORE"
cp menu-bar/Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$GUI" menu-bar/main.swift

echo "==> Verifying bundle integrity"
cmp -s target/release/razerctl "$CORE" || { echo "ERROR: core copy mismatch"; exit 1; }
CORE_INODE=$(stat -f %i "$CORE")
GUI_INODE=$(stat -f %i "$GUI")
[ "$CORE_INODE" != "$GUI_INODE" ] || { echo "ERROR: core and GUI share one file (name collision?)"; exit 1; }
file "$CORE" | grep -q "Mach-O" || { echo "ERROR: core is not a Mach-O binary"; exit 1; }
file "$GUI" | grep -q "Mach-O" || { echo "ERROR: GUI is not a Mach-O binary"; exit 1; }
# Smoke test: the core must identify itself as a CLI and exit immediately.
"$CORE" list >/dev/null || { echo "ERROR: core CLI smoke test failed"; exit 1; }
echo "    core: $(file -b "$CORE" | cut -d, -f1) ($(stat -f %z "$CORE") bytes)"
echo "    gui:  $(file -b "$GUI" | cut -d, -f1) ($(stat -f %z "$GUI") bytes)"

echo "==> Code signing"
xattr -cr "$APP" || true
# Prefer a stable identity (Developer ID / Apple Development) so that the
# macOS Input Monitoring (TCC) grant SURVIVES rebuilds. Ad-hoc signing
# creates a new identity every build, which silently invalidates the grant.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true)
fi
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "    signing with: $SIGN_IDENTITY"
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
    echo "    no stable identity found — falling back to ad-hoc (TCC grant will NOT survive rebuilds)"
    codesign --force --sign - "$APP"
fi
codesign --verify "$APP"

echo
echo "Built $APP — launch with:"
echo "  open $APP"