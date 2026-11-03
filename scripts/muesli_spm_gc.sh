#!/usr/bin/env bash
# Reports, and with --apply removes, SwiftPM worktree caches whose worktree is
# gone. Only direct children of <cache root>/worktrees are considered.
#
#   scripts/muesli_spm_gc.sh                       # dry run: report only
#   scripts/muesli_spm_gc.sh --apply               # remove orphaned caches
#   scripts/muesli_spm_gc.sh --apply --include-unowned
#                                                  # also remove unattributed ones
#   scripts/muesli_spm_gc.sh --cache-root DIR      # another cache root
#
# Each entry is classified:
#   live      its recorded worktree root (.muesli-worktree-root) exists, or its
#             <name>-<hash> matches a worktree of this repository
#   orphaned  its recorded worktree root no longer exists
#   unowned   no usable root marker and no matching worktree (caches from before
#             root markers, hand-named paths, other clones of the repository)
#   in-use    orphaned or unowned, but a running process (a seed clone included)
#             names it, or something in it changed in the last few minutes or
#             cannot be read; never removed
#   skipped   a symlink or a file; never followed or removed
#
# Leftover seed temporaries (*.seed-tmp.<pid>, *.seed-stamp.<pid>) whose process
# is gone are removed with --apply. Deleting a cache only removes rebuildable
# build artifacts. Sizes are du, so blocks shared by APFS clones are counted in
# every entry that holds them.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/muesli_spm_cache.sh"

usage() {
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
}

apply=0
include_unowned=0
cache_root=""
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --apply) apply=1 ;;
    --include-unowned) include_unowned=1 ;;
    --cache-root)
      [[ "$#" -ge 2 ]] || usage
      cache_root="$2"
      shift
      ;;
    -h | --help) usage ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      ;;
  esac
  shift
done

[[ -n "$cache_root" ]] || cache_root="$(muesli_default_spm_cache_root)"
worktrees_dir="$cache_root/worktrees"
if [[ ! -d "$worktrees_dir" ]]; then
  echo "No worktree caches under $cache_root; nothing to do."
  exit 0
fi

# Cache dir names of every worktree of this repository, main checkout included.
live_names=" "
if listing="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null)"; then
  while IFS= read -r line; do
    [[ "$line" == "worktree "* ]] || continue
    live_names+="$(muesli_spm_worktree_dir_name "${line#worktree }") "
  done <<<"$listing"
else
  if [[ "$apply" == "1" && "$include_unowned" == "1" ]]; then
    echo "Cannot list this repository's worktrees; refusing to remove unowned caches." >&2
    exit 1
  fi
  echo "warning: cannot list this repository's worktrees; hash-named caches report as unowned." >&2
fi

human_size() {
  awk -v kib="$1" 'BEGIN {
    if (kib >= 1048576) printf "%.1fG", kib / 1048576
    else if (kib >= 1024) printf "%.0fM", kib / 1024
    else printf "%dK", kib
  }'
}

entry_kib() {
  du -sk "$1" 2>/dev/null | awk '{print $1}' || true
}

# Sets status and detail for one entry.
classify() {
  local entry="$1" name marker root process
  name="$(basename "$entry")"
  if [[ -L "$entry" || ! -d "$entry" ]]; then
    status="skipped"
    detail="not a directory; never followed"
    return 0
  fi
  marker="$entry/$MUESLI_SPM_ROOT_MARKER"
  root=""
  [[ -s "$marker" ]] && root="$(sed -n '1p' "$marker" 2>/dev/null || true)"
  if [[ -n "$root" && -d "$root" ]]; then
    status="live"
    detail="$root"
  elif [[ -n "$root" ]]; then
    status="orphaned"
    detail="worktree gone: $root"
  elif [[ "$live_names" == *" $name "* ]]; then
    status="live"
    detail="matches a worktree of this repository"
  else
    status="unowned"
    detail="no recorded worktree root"
  fi
  [[ "$status" == "orphaned" || "$status" == "unowned" ]] || return 0
  if process="$(muesli_spm_path_in_use_by_process "$entry" "" 1)"; then
    status="in-use"
    detail="named by a running process: ${process:0:100}"
  elif muesli_spm_path_modified_recently "$entry"; then
    status="in-use"
    detail="modified in the last $MUESLI_SPM_BUSY_MINUTES minutes, or unreadable"
  fi
  return 0
}

deletable() {
  [[ "$1" == "orphaned" ]] && return 0
  [[ "$1" == "unowned" && "$include_unowned" == "1" ]] && return 0
  return 1
}

# Seed temporaries whose seeding process is gone.
sweep_seed_leftovers() {
  local entry="$1" leftover pid
  while IFS= read -r leftover; do
    [[ -n "$leftover" ]] || continue
    pid="${leftover##*.}"
    muesli_spm_pid_alive "$pid" && continue
    if [[ "$apply" == "1" ]]; then
      if rm -rf "$leftover"; then
        printf '%-9s %9s  %s\n' "removed" "-" "stale seed temporary: $leftover"
      else
        failures=$((failures + 1))
      fi
    else
      printf '%-9s %9s  %s\n' "stale" "-" "seed temporary from a dead process: $leftover"
    fi
  done < <(find "$entry" -maxdepth 3 \( -name '*.seed-tmp.*' -o -name '*.seed-stamp.*' \) -prune -print 2>/dev/null || true)
}

mode="dry run"
[[ "$apply" == "1" ]] && mode="apply"
echo "SwiftPM worktree caches in $worktrees_dir ($mode)"

failures=0
removed_kib=0
removed_count=0
orphaned_kib=0
orphaned_count=0
unowned_kib=0
unowned_count=0
for entry in "$worktrees_dir"/* "$worktrees_dir"/.[!.]*; do
  [[ -e "$entry" || -L "$entry" ]] || continue
  classify "$entry"
  kib=0
  [[ "$status" == "skipped" ]] || kib="$(entry_kib "$entry")"
  kib="${kib:-0}"
  case "$status" in
    orphaned)
      orphaned_kib=$((orphaned_kib + kib))
      orphaned_count=$((orphaned_count + 1))
      ;;
    unowned)
      unowned_kib=$((unowned_kib + kib))
      unowned_count=$((unowned_count + 1))
      ;;
  esac

  if [[ "$apply" == "1" ]] && deletable "$status"; then
    # Re-check right before removing: a build may have started since.
    if muesli_spm_path_in_use_by_process "$entry" "" 1 >/dev/null || muesli_spm_path_modified_recently "$entry"; then
      status="in-use"
      detail="started being used during GC; kept"
    elif rm -rf "$entry"; then
      status="removed"
      removed_kib=$((removed_kib + kib))
      removed_count=$((removed_count + 1))
    else
      echo "error: could not fully remove $entry" >&2
      failures=$((failures + 1))
    fi
  fi
  printf '%-9s %9s  %s  %s\n' "$status" "$(human_size "$kib")" "$(basename "$entry")" "$detail"
  if [[ "$status" != "removed" && "$status" != "skipped" ]]; then
    sweep_seed_leftovers "$entry"
  fi
done

if [[ "$apply" == "1" ]]; then
  echo "Removed $removed_count cache(s), $(human_size "$removed_kib")."
  if [[ "$include_unowned" != "1" && "$unowned_count" -gt 0 ]]; then
    echo "$unowned_count unowned cache(s), $(human_size "$unowned_kib"), kept; add --include-unowned to remove them."
  fi
else
  echo "Would remove $orphaned_count orphaned cache(s), $(human_size "$orphaned_kib"), with --apply."
  if [[ "$unowned_count" -gt 0 ]]; then
    echo "$unowned_count unowned cache(s), $(human_size "$unowned_kib"), are removed only with --apply --include-unowned."
  fi
fi

[[ "$failures" -eq 0 ]]
