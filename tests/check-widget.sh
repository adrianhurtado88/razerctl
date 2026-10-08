#!/bin/bash
# Native widget regressions, using an isolated CLI stub. No device writes.
set -euo pipefail
cd "$(dirname "$0")/.."
WIDGET_TEST_DIR=$(mktemp -d /tmp/razerctl-widget-check.XXXXXX)
export WIDGET_TEST_DIR
trap 'rm -rf "$WIDGET_TEST_DIR"' EXIT
python3 - <<'PY'
import os
from pathlib import Path
source = Path('menu-bar/main.swift').read_text().split('// MARK: - App bootstrap')[0]
source = Path('menu-bar/KeyboardShortcuts.swift').read_text() + '\n' + source
source = Path('menu-bar/MouseButtons.swift').read_text() + '\n' + source
source = source.replace(
    'URL(fileURLWithPath: "/tmp/razerctl-widget.log")',
    'URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("store.log")'
)
Path(os.environ['WIDGET_TEST_DIR'], 'main.swift').write_text(
    source + '\n' + Path('tests/widget-regression.swift').read_text()
    + '\n' + Path('tests/shortcuts-regression.swift').read_text()
    + '\n' + Path('tests/mouse-buttons-regression.swift').read_text()
)
PY
swiftc -O -o "$WIDGET_TEST_DIR/widget-check" "$WIDGET_TEST_DIR/main.swift"
"$WIDGET_TEST_DIR/widget-check"
