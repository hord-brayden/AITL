#!/bin/bash
# Builds AITL Bridge.app from the SwiftPM target (bundle + Info.plist + icon + ad-hoc signature).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP="AITL Bridge"; EXE="AITLBridge"
SCRATCH="${SCRATCH_PATH:-$HOME/.cache/aitl-build}"      # outside iCloud Drive on purpose
DIST="${DIST_DIR:-$ROOT/dist}"; BUNDLE="$DIST/$APP.app"
info() { printf '\033[1;33m▸\033[0m %s\n' "$1"; }; ok() { printf '\033[1;32m✓\033[0m %s\n' "$1"; }
mkdir -p "$SCRATCH"
info "Compiling ($CONFIGURATION, arm64)…"
swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --scratch-path "$SCRATCH" 2>&1 | grep -vE "^\[|^$" || true
BIN="$(swift build --package-path "$ROOT" --configuration "$CONFIGURATION" --scratch-path "$SCRATCH" --show-bin-path)/$EXE"
[[ -f "$BIN" ]] || { echo "no binary at $BIN" >&2; exit 1; }
info "Assembling bundle…"
rm -rf "$BUNDLE"; mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$EXE"
cp "$ROOT/scripts/Info.plist" "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
info "Rendering icon…"
ICONSET="$SCRATCH/AppIcon.iconset"; rm -rf "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICONSET" >/dev/null
iconutil --convert icns "$ICONSET" --output "$BUNDLE/Contents/Resources/AppIcon.icns"
xattr -cr "$BUNDLE" 2>/dev/null || true
info "Signing (ad-hoc)…"
codesign --force --deep --sign - --timestamp=none --identifier "com.caeruli-obscuri.aitl" "$BUNDLE"
codesign --verify --strict "$BUNDLE" && ok "Signature verified"
ok "$BUNDLE"
