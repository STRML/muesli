#!/usr/bin/env bash
set -euo pipefail

# One command for a fork-local dev build that keeps its macOS permissions: build unsigned without
# launching it, re-sign with a stable Apple Development identity and the iCloud profile, then
# launch with logs in ~/Library/Logs/MuesliDev. macOS ties permission grants (microphone,
# accessibility, screen recording) to the signing identity, so the identity must never change
# between builds and the unsigned build must never run.
#
#   ./scripts/dev-test-local.sh
#
# Defaults suit the fork maintainer's machine; override any of them from the environment:
#   MUESLI_DEV_BUNDLE_ID, MUESLI_SIGN_IDENTITY, MUESLI_PROVISIONING_PROFILE,
#   MUESLI_ICLOUD_CONTAINER_ID, MUESLI_ICLOUD_CONTAINER_ENVIRONMENT

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="/Applications/MuesliDev.app"
LOG_DIR="$HOME/Library/Logs/MuesliDev"

IDENTITY="${MUESLI_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -n 1)}"
if [[ -z "$IDENTITY" ]]; then
  echo "ERROR: no Apple Development signing identity found. Set MUESLI_SIGN_IDENTITY." >&2
  exit 1
fi

# Replacing the app under a running recording would lose it.
if pgrep -f "$APP/Contents/MacOS" >/dev/null 2>&1; then
  echo "ERROR: MuesliDev is running. Stop any recording and quit it, then run this again." >&2
  exit 1
fi

# Xcode 27+ delivers the Metal toolchain as a downloadable mounted component; SwiftPM's
# `muesli-cli` sub-build fails with "missing Metal Toolchain" unless EXTERNAL_TOOLCHAINS_DIR
# and TOOLCHAINS include the mounted Metal toolchain when `xcrun -f metal` isn't already wired.
if [[ -z "${EXTERNAL_TOOLCHAINS_DIR:-}" ]] && ! xcrun -f metal >/dev/null 2>&1; then
  METAL_INFO="$(xcodebuild -showComponent MetalToolchain 2>/dev/null || true)"
  METAL_SEARCH_PATH="$(printf '%s\n' "$METAL_INFO" | sed -n 's/^Toolchain Search Path: //p' | head -n 1)"
  METAL_ID="$(printf '%s\n' "$METAL_INFO" | sed -n 's/^Toolchain Identifier: //p' | head -n 1)"
  if [[ -n "$METAL_SEARCH_PATH" && -d "$METAL_SEARCH_PATH" && -n "$METAL_ID" ]]; then
    export EXTERNAL_TOOLCHAINS_DIR="$METAL_SEARCH_PATH"
    export TOOLCHAINS="${TOOLCHAINS:-$METAL_ID com.apple.dt.toolchain.XcodeDefault}"
    echo "Using mounted MetalToolchain: $METAL_ID ($METAL_SEARCH_PATH)"
  fi
fi

MUESLI_DEV_BUNDLE_ID="${MUESLI_DEV_BUNDLE_ID:-com.samuelreed.muesli.dev}" \
MUESLI_TRUST_PACKAGE_PLUGINS=1 \
MUESLI_SKIP_SIGN=1 \
MUESLI_DEV_NO_LAUNCH=1 \
  "$ROOT/scripts/dev-test.sh"

MUESLI_SIGN_IDENTITY="$IDENTITY" \
MUESLI_PROVISIONING_PROFILE="${MUESLI_PROVISIONING_PROFILE:-$HOME/.muesli-signing/MuesliDev.provisionprofile}" \
MUESLI_ICLOUD_CONTAINER_ID="${MUESLI_ICLOUD_CONTAINER_ID:-iCloud.com.samuelreed.muesli}" \
MUESLI_ICLOUD_CONTAINER_ENVIRONMENT="${MUESLI_ICLOUD_CONTAINER_ENVIRONMENT:-Production}" \
  "$ROOT/scripts/dev-sign-cloud.sh" "$APP"

mkdir -p "$LOG_DIR"
open --stdout "$LOG_DIR/stdout.log" --stderr "$LOG_DIR/stderr.log" "$APP"
echo "Launched $APP signed as: $IDENTITY"
