#!/bin/bash
# Temporary signed fixtures only; no installed app is replaced or launched.
set -euo pipefail
cd "$(dirname "$0")/.."
UPDATE_TEST_DIR=$(mktemp -d /tmp/razerctl-update-check.XXXXXX)
trap 'rm -rf "$UPDATE_TEST_DIR"' EXIT
cp tests/updater-regression.swift "$UPDATE_TEST_DIR/main.swift"
swiftc -O -o "$UPDATE_TEST_DIR/update-check" "$UPDATE_TEST_DIR/main.swift" menu-bar/AppUpdate.swift
"$UPDATE_TEST_DIR/update-check"
