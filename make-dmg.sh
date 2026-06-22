#!/bin/bash
#
# make-dmg.sh — package a built .app into a shareable .dmg
#
# Produces a compressed disk image containing the app plus a drag-to-install
# "Applications" shortcut. The DMG is named "<App Name> <version>.dmg" using
# the values from the app's Info.plist.
#
# Usage:
#   ./make-dmg.sh /path/to/Web\ Stats\ Scraper.app [output-dir]
#
#   - The first argument is the path to the .app bundle (export it from Xcode
#     via Product → Archive → Distribute App → Custom → Copy App).
#   - The optional second argument is where to write the .dmg
#     (defaults to the folder the .app lives in).
#
# Note: the resulting app is unsigned. On first launch, recipients should
# right-click the app → Open (or use System Settings → Privacy & Security →
# "Open Anyway") to clear Gatekeeper. This is a one-time step.

set -euo pipefail

# --- Arguments -------------------------------------------------------------
APP="${1:-}"
if [[ -z "$APP" ]]; then
    echo "Usage: $0 /path/to/YourApp.app [output-dir]" >&2
    exit 1
fi

# Strip any trailing slash so basename/Info.plist lookups behave.
APP="${APP%/}"

if [[ ! -d "$APP" ]]; then
    echo "Error: '$APP' is not a directory (.app bundle expected)." >&2
    exit 1
fi

INFO_PLIST="$APP/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
    echo "Error: no Info.plist found inside '$APP' — is this a valid .app?" >&2
    exit 1
fi

OUT_DIR="${2:-$(dirname "$APP")}"
mkdir -p "$OUT_DIR"

# --- Read app metadata -----------------------------------------------------
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$INFO_PLIST" 2>/dev/null || true)"
[[ -z "$APP_NAME" ]] && APP_NAME="$(basename "$APP" .app)"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
[[ -z "$VERSION" ]] && VERSION="1.0"

DMG_PATH="$OUT_DIR/$APP_NAME $VERSION.dmg"

# --- Stage contents --------------------------------------------------------
STAGE_PARENT="$(mktemp -d)"
STAGE="$STAGE_PARENT/$APP_NAME"
mkdir -p "$STAGE"

# Clean up the temp staging dir no matter how the script exits.
trap 'rm -rf "$STAGE_PARENT"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# --- Build the DMG ---------------------------------------------------------
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

# --- Verify ----------------------------------------------------------------
if hdiutil verify "$DMG_PATH" >/dev/null 2>&1; then
    SIZE="$(du -h "$DMG_PATH" | cut -f1)"
    echo "✅ Created: $DMG_PATH ($SIZE)"
else
    echo "⚠️  Created $DMG_PATH but verification failed." >&2
    exit 1
fi
