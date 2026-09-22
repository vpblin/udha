#!/bin/bash
#
# Launch Udha.AIDesktop, self-healing the bundle first.
#
# The Debug build lives under /private/tmp, which macOS periodically prunes —
# that pruning corrupts the .app (invalid Info.plist / broken code signature),
# which both prevents launch (launchd POSIX error 153) AND makes macOS deny the
# app's Apple Events to Terminal (-1743), silently breaking click-to-focus.
#
# This script always runs an (incremental, ~3s) build so the launched binary is
# never behind the working tree — Spotlight and the Dock launch the bundle
# directly, so the bundle itself has to be the current version. A missing or
# corrupt bundle is rebuilt from scratch by the same step.
#
# Usage: ./run.sh            build if needed, then launch
#        ./run.sh --rebuild  force a clean rebuild first
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED="/private/tmp/udha-build"
APP="$DERIVED/Build/Products/Debug/Udha.AIDesktop.app"
BIN="$APP/Contents/MacOS/Udha.AIDesktop"
SCHEME="Udha.AIDesktop"

force_rebuild=0
[[ "${1:-}" == "--rebuild" ]] && force_rebuild=1

if [[ $force_rebuild -eq 1 ]]; then
  echo "▶ Clean rebuild requested"
  rm -rf "$DERIVED"
elif [[ ! -d "$APP" ]]; then
  echo "▶ App bundle missing — rebuilding"
elif ! /usr/bin/codesign --verify "$APP" 2>/dev/null; then
  echo "▶ Code signature invalid (likely /tmp pruning) — rebuilding"
  rm -rf "$DERIVED"
elif ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" >/dev/null 2>&1; then
  echo "▶ Info.plist unreadable — rebuilding"
  rm -rf "$DERIVED"
fi

before="$(/usr/bin/stat -f '%m' "$BIN" 2>/dev/null || echo none)"

# -destination is pinned: left to itself xcodebuild picks "the first of multiple
# matching destinations", and when it lands on the generic one automatic signing
# tries to register this Mac with the developer account and fails outright.
#
# -skipPackagePluginValidation: SwiftTerm ships a build-tool plugin that stamps
# its version into a generated source file. Xcode wants a human to approve any
# package plugin the first time; from a script there is nobody to click it, so
# the build fails with "Validate plug-in". The flag pre-approves it.
echo "▶ Building ${SCHEME}…"
build_ok=1
/usr/bin/xcodebuild \
  -project "$PROJECT_DIR/$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  -skipPackagePluginValidation \
  build || build_ok=0

# Final integrity gate: never launch a bundle that fails verification.
if ! /usr/bin/codesign --verify "$APP" 2>/dev/null; then
  echo "✗ Bundle invalid and the build did not fix it — aborting. Try: ./run.sh --rebuild" >&2
  exit 1
fi

# A failed build over a still-valid bundle means the binary is whatever was there
# before. Launch it rather than nothing, but say so loudly — running a stale
# build unknowingly is exactly what this script exists to prevent.
if [[ $build_ok -eq 0 ]]; then
  echo "⚠ BUILD FAILED — launching the previous build, which is out of date"
fi

after="$(/usr/bin/stat -f '%m' "$BIN")"

# Only disturb a running instance when the binary actually changed — otherwise
# a launch while Udha is already up just brings the existing app forward.
if [[ "$before" != "$after" ]] && /usr/bin/pgrep -x "$SCHEME" >/dev/null 2>&1; then
  echo "▶ Replacing running (now-stale) instance"
  /usr/bin/pkill -x "$SCHEME" 2>/dev/null || true
  sleep 1
fi

/usr/bin/open "$APP"
echo "✓ Launched $APP"
