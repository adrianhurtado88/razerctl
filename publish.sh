#!/bin/bash
# Publish a release: bump the embedded version, build, zip, tag, upload.
#
# Usage:
#   ./publish.sh 1.2        # publishes v1.2 from the current source
#
# After this, every running copy of RazerCtl sees the new release and
# offers a one-click self-update (same Developer ID team => the Input
# Monitoring grant survives the swap).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?usage: ./publish.sh <version>  (e.g. ./publish.sh 1.2)}"
TAG="v$VERSION"

# 1. Bump the embedded version (Store.appVersion + Info.plist).
sed -i '' "s/static let appVersion = \"[^\"]*\"/static let appVersion = \"$VERSION\"/" menu-bar/main.swift
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" menu-bar/Info.plist

# 2. Build the app bundle (verifies core/GUI integrity + signs it).
./build-widget.sh

# 3. Zip the signed bundle.
STAGE="$(mktemp -d)"
cp -R "${TMPDIR:-/tmp}/RazerCtl.app" "$STAGE/"
( cd "$STAGE" && zip -r -q "RazerCtl-$TAG.zip" RazerCtl.app )

# 4. Commit the version bump, tag, push, release with the artifact.
git add -A
git commit -q -m "v$VERSION" || true
git tag "$TAG"
git push origin main "$TAG"
gh release create "$TAG" --title "razerctl $TAG" --generate-notes "$STAGE/RazerCtl-$TAG.zip"

echo
echo "Published $TAG — installed copies will pick it up within 10 minutes"
echo "of opening the panel, or immediately via relaunch."