#!/usr/bin/env bash
# Prints this worktree's SwiftPM scratch path for a channel, for direct
# `swift build` / `swift test` runs:
#
#   swift test --package-path native/MuesliNative \
#     --scratch-path "$(scripts/muesli_spm_scratch_path.sh test)"
#
# The path is <cache root>/worktrees/<worktree>-<hash>/<channel>. On first use
# it is seeded with an APFS clone of an idle donor (see muesli_spm_cache.sh) and
# the worktree root is recorded for scripts/muesli_spm_gc.sh. Notes go to stderr.
#
# MUESLI_SWIFTPM_SCRATCH_PATH and MUESLI_SWIFTPM_SCRATCH_CHANNEL are honoured as
# in the build scripts (no seeding). MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1 prints
# the package-local .build directory.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/muesli_spm_cache.sh"

channel="${1:-test}"
if [[ ! "$channel" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "usage: $(basename "$0") [channel]   (channel: letters, digits, '.', '_', '-')" >&2
  exit 2
fi

if muesli_spm_scratch_disabled; then
  printf '%s\n' "$ROOT/native/MuesliNative/.build"
  exit 0
fi

muesli_worktree_spm_scratch_path "$channel" "$ROOT"
