#!/usr/bin/env bash

# Shared SwiftPM scratch-path resolution for local Muesli builds.
#
# Resolution precedence, unless disabled:
#   1. MUESLI_SWIFTPM_SCRATCH_PATH, when explicitly set
#   2. MUESLI_EXTERNAL_SPM_CACHE_ROOT/<channel>, when that root exists
#   3. ~/Library/Caches/muesli-spm/<channel>
#
# MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1 takes precedence over all other path
# settings and lets SwiftPM use the package-local .build directory.
#
# Worktree-scoped paths (<cache root>/worktrees/<name>-<hash>/<channel>) stay
# private to one worktree. SwiftPM makes a second build into the same scratch
# path wait for the first, and its build state is keyed to absolute source and
# scratch paths, so sharing one writable scratch path between worktrees would
# block agents and rebuild on every switch.
#
# What can be shared is the content: a new worktree's scratch path (and debug
# DerivedData) is seeded with an APFS clone of an idle donor, the main
# checkout's first and then the most recently modified sibling's. The paths
# SwiftPM and git record inside the clone are rebased onto the seed, so it never
# depends on its donor. Dependency checkouts and path-independent outputs share
# blocks copy-on-write and the first build skips dependency resolution. Seeding fails open: any problem means
# a cold build and one line on stderr. MUESLI_SWIFTPM_SEED=0 turns it off, and CI
# never seeds.
#
# Each worktree cache dir records its source root in .muesli-worktree-root so
# scripts/muesli_spm_gc.sh can find caches whose worktree no longer exists.

[[ -n "${_MUESLI_SPM_CACHE_LOADED:-}" ]] && return 0
_MUESLI_SPM_CACHE_LOADED=1

MUESLI_SPM_ROOT_MARKER=".muesli-worktree-root"
# A donor or GC entry with anything modified this recently is treated as in use.
MUESLI_SPM_BUSY_MINUTES=2

muesli_spm_scratch_disabled() {
  [[ "${MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH:-0}" == "1" ]]
}

muesli_default_spm_cache_root() {
  local external_root="${MUESLI_EXTERNAL_SPM_CACHE_ROOT:-}"
  if [[ -n "$external_root" && -d "$external_root" ]]; then
    printf '%s\n' "$external_root"
  else
    printf '%s\n' "$HOME/Library/Caches/muesli-spm"
  fi
}

muesli_resolve_spm_scratch_path() {
  local channel="${1:-dev}"
  if [[ -n "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" ]]; then
    printf '%s\n' "$MUESLI_SWIFTPM_SCRATCH_PATH"
    return 0
  fi
  if [[ -n "${MUESLI_SWIFTPM_SCRATCH_CHANNEL:-}" ]]; then
    channel="$MUESLI_SWIFTPM_SCRATCH_CHANNEL"
  fi
  printf '%s/%s\n' "$(muesli_default_spm_cache_root)" "$channel"
}

# <root> -> <basename>-<cksum of the absolute root path>
muesli_spm_worktree_dir_name() {
  local root="$1"
  local root_hash
  root_hash="$(printf '%s' "$root" | cksum | awk '{print $1}')"
  printf '%s-%s\n' "$(basename "$root")" "$root_hash"
}

muesli_worktree_spm_scratch_channel() {
  local channel="${1:-dev}"
  local root="${2:-$PWD}"
  printf 'worktrees/%s/%s\n' "$(muesli_spm_worktree_dir_name "$root")" "$channel"
}

muesli_spm_artifacts_dir() {
  local package_dir="$1"
  local scratch_path="${2:-}"
  if [[ -n "$scratch_path" ]]; then
    printf '%s/artifacts\n' "$scratch_path"
  else
    printf '%s/.build/artifacts\n' "$package_dir"
  fi
}

muesli_spm_note() {
  printf 'muesli-spm: %s\n' "$*" >&2
}

# Prints the main checkout root of the repository containing <root>, or nothing.
muesli_spm_main_checkout_root() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  [[ "$(basename "$common")" == ".git" ]] || return 0
  dirname "$common"
}

# Records <root> as the owner of a worktree cache dir. Never fails.
muesli_spm_mark_worktree_root() {
  local dir="$1" root="$2"
  local marker="$dir/$MUESLI_SPM_ROOT_MARKER"
  [[ -s "$marker" ]] && return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  if printf '%s\n' "$root" > "$marker.$$" 2>/dev/null; then
    mv -f "$marker.$$" "$marker" 2>/dev/null || rm -f "$marker.$$"
  fi
  return 0
}

muesli_spm_ere_escape() {
  printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|]/\\&/g'
}

# Prints the first process command line that names <path> or a path inside it.
# Fails when no process matches; an unreadable process table counts as a match,
# to stay conservative.
# muesli_spm_path_in_use_by_process <path> [skipped child] [count seeders: 0|1]
#   skipped child: references to <path>/<child> alone do not count (a lane
#     building into the donor's DerivedData does not make its scratch busy).
#   count seeders: by default a seed clone (*.seed-tmp.*) reading <path> does not
#     count, so seeders do not block each other; the GC passes 1.
muesli_spm_path_in_use_by_process() {
  local path="$1" skip="${2:-}" count_seeders="${3:-0}" processes match
  processes="$(ps -A -ww -o command= 2>/dev/null)" || {
    printf 'process table unreadable\n'
    return 0
  }
  if [[ "$count_seeders" != "1" ]]; then
    processes="$(printf '%s\n' "$processes" | grep -v -F '.seed-tmp.' || true)"
  fi
  if [[ -n "$skip" ]]; then
    processes="$(printf '%s\n' "$processes" | MUESLI_SPM_CUT="$path/$skip" awk '{
      cut = ENVIRON["MUESLI_SPM_CUT"]
      while ((i = index($0, cut)) > 0) {
        rest = substr($0, i + length(cut))
        sub(/^[^ \t]*/, "", rest)
        $0 = substr($0, 1, i - 1) rest
      }
      print
    }')"
  fi
  match="$(printf '%s\n' "$processes" | grep -E -- "$(muesli_spm_ere_escape "$path")(\$|[/[:space:]])" || true)"
  [[ -n "$match" ]] || return 1
  printf '%s\n' "$match" | sed -n '1p'
}

# muesli_spm_find_hit <dir> <skipped child or ""> <find predicate>...: true when
# anything under <dir>, outside the skipped child, matches the predicate.
# A find error (an unreadable or vanished entry) also counts as a hit: callers
# ask "busy?" or "changed?", and an unknown answer must not read as "no".
muesli_spm_find_hit() {
  local dir="$1" skip="$2" hit status=0
  shift 2
  if [[ -n "$skip" ]]; then
    hit="$(find "$dir" -path "$dir/$skip" -prune -o "$@" -print -quit 2>/dev/null)" || status=$?
  else
    hit="$(find "$dir" "$@" -print -quit 2>/dev/null)" || status=$?
  fi
  [[ -n "$hit" || "$status" -ne 0 ]]
}

# muesli_spm_path_modified_recently <dir> [skipped child]
muesli_spm_path_modified_recently() {
  muesli_spm_find_hit "$1" "${2:-}" -mmin "-$MUESLI_SPM_BUSY_MINUTES"
}

# True when <path> is being written or used: a recent modification (outside the
# skipped child) or a running process that names it.
# muesli_spm_path_busy <dir> [skipped child]
muesli_spm_path_busy() {
  muesli_spm_path_modified_recently "$1" "${2:-}" && return 0
  muesli_spm_path_in_use_by_process "$1" "${2:-}" >/dev/null && return 0
  return 1
}

# True when <dir> is on an APFS volume, so cp -c clones instead of copying.
# (cp -c silently falls back to a full copy elsewhere, which would cost GBs.)
muesli_spm_dir_on_apfs() {
  [[ "$(uname -s)" == "Darwin" ]] || return 1
  local mount_point mount_line
  mount_point="$(df -P "$1" 2>/dev/null | awk 'NR == 2 { print $NF }')" || return 1
  [[ -n "$mount_point" ]] || return 1
  mount_line="$(mount 2>/dev/null | grep -F " on $mount_point (" || true)"
  [[ "$mount_line" == *"(apfs"* ]]
}

muesli_spm_same_device() {
  local first second
  first="$(stat -f %d "$1" 2>/dev/null)" || return 1
  second="$(stat -f %d "$2" 2>/dev/null)" || return 1
  [[ -n "$first" && "$first" == "$second" ]]
}

muesli_spm_pid_alive() {
  [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null
}

# Atomic publish: rename(2) refuses a non-empty destination, where mv would
# move the source inside it.
muesli_spm_rename_no_clobber() {
  command -v perl >/dev/null 2>&1 || return 1
  perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2" 2>/dev/null
}

muesli_spm_dir_empty() {
  [[ -d "$1" && -z "$(ls -A "$1" 2>/dev/null)" ]]
}

# muesli_spm_clone_tree <src> <dest> <skipped child or "">: APFS-clones <src>
# to the new path <dest>, leaving out one top-level child.
muesli_spm_clone_tree() {
  local src="$1" dest="$2" skip="$3" entry
  if [[ -z "$skip" ]]; then
    cp -c -R "$src" "$dest" 2>/dev/null
    return
  fi
  local entries
  entries="$(find "$src" -mindepth 1 -maxdepth 1 2>/dev/null)" || return 1
  mkdir "$dest" 2>/dev/null || return 1
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "$(basename "$entry")" == "$skip" ]] && continue
    cp -c -R "$entry" "$dest/" 2>/dev/null || return 1
  done <<<"$entries"
  return 0
}

# Rebases the absolute paths that SwiftPM and git record inside a scratch path
# (or a DerivedData's SourcePackages) from the donor's location to the seed's:
# workspace-state.json, and each checkout's origin URL and objects/info/alternates.
# Without this a seeded checkout borrows git objects from the donor and breaks
# once the donor is collected. Handles plain and JSON-escaped (\/) slashes, and
# fails when any of those files still names the donor in either form.
muesli_spm_rebase_paths() {
  local tree="$1" from="$2" to="$3" from_real base file old old_escaped
  command -v perl >/dev/null 2>&1 || return 1
  from_real="$(cd "$from" 2>/dev/null && pwd -P)" || from_real="$from"
  for base in "$tree" "$tree/SourcePackages"; do
    for file in "$base/workspace-state.json" "$base"/checkouts/*/.git/config \
      "$base"/checkouts/*/.git/objects/info/alternates; do
      [[ -f "$file" ]] || continue
      for old in "$from" "$from_real"; do
        MUESLI_SPM_FROM="$old" MUESLI_SPM_TO="$to" perl -pi -e '
          BEGIN {
            $f = $ENV{MUESLI_SPM_FROM}; $t = $ENV{MUESLI_SPM_TO};
            ($fe = $f) =~ s{/}{\\/}g; ($te = $t) =~ s{/}{\\/}g;
          }
          s/\Q$f\E(?=[\/"\s]|$)/$t/g;
          s/\Q$fe\E(?=\\\/|["\s]|$)/$te/g;
        ' "$file" 2>/dev/null || return 1
        old_escaped="${old//\//\\/}"
        if grep -qF -e "$old/" -e "$old\"" -e "$old_escaped\\/" -e "$old_escaped\"" "$file" 2>/dev/null; then
          return 1
        fi
      done
    done
  done
  return 0
}

# muesli_spm_clone_into <dest> <prune> <donor>: clone, verify, publish.
# Returns 0 when <dest> was published; 1 to try the next donor; 2 to stop.
muesli_spm_clone_into() {
  local dest="$1" prune="$2" donor="$3"
  local tmp="$dest.seed-tmp.$$" stamp="$dest.seed-stamp.$$"

  if ! muesli_spm_same_device "$donor" "$(dirname "$dest")"; then
    muesli_spm_note "seed donor on another volume, skipping: $donor"
    return 1
  fi
  rm -rf "$tmp" "$stamp" 2>/dev/null
  if ! : > "$stamp" 2>/dev/null; then
    muesli_spm_note "cannot write in $(dirname "$dest"); cold build"
    return 2
  fi
  if ! muesli_spm_clone_tree "$donor" "$tmp" "$prune"; then
    rm -rf "$tmp" "$stamp" 2>/dev/null
    muesli_spm_note "clone of $donor failed; cold build"
    return 2
  fi
  if muesli_spm_find_hit "$donor" "$prune" -newer "$stamp"; then
    rm -rf "$tmp" "$stamp" 2>/dev/null
    muesli_spm_note "seed donor changed during the clone, discarded: $donor"
    return 1
  fi
  rm -f "$stamp" 2>/dev/null
  if ! muesli_spm_rebase_paths "$tmp" "$donor" "$dest"; then
    rm -rf "$tmp" 2>/dev/null
    muesli_spm_note "could not rebase $donor's recorded paths onto $dest; cold build"
    return 2
  fi
  if [[ -e "$dest" ]] && ! muesli_spm_dir_empty "$dest"; then
    rm -rf "$tmp" 2>/dev/null
    muesli_spm_note "$dest appeared during the clone; seed discarded"
    return 2
  fi
  if ! muesli_spm_rename_no_clobber "$tmp" "$dest"; then
    rm -rf "$tmp" 2>/dev/null
    if [[ -e "$dest" ]] && ! muesli_spm_dir_empty "$dest"; then
      muesli_spm_note "$dest appeared during the clone; seed discarded"
    else
      muesli_spm_note "could not publish the seed for $dest; cold build"
    fi
    return 2
  fi
  muesli_spm_note "seeded $dest from $donor"
  return 0
}

# muesli_seed_spm_dir <dest> <prune subdir or ""> <donor>...
# Seeds a missing or empty <dest> with an APFS clone of the first idle donor.
# Never fails; on any problem <dest> is left for a cold build.
muesli_seed_spm_dir() {
  local dest="$1" prune="$2"
  shift 2

  [[ "${MUESLI_SWIFTPM_SEED:-1}" != "0" ]] || return 0
  [[ "${CI:-}" != "true" ]] || return 0
  muesli_spm_scratch_disabled && return 0
  [[ ! -e "$dest" ]] || muesli_spm_dir_empty "$dest" || return 0

  local parent
  parent="$(dirname "$dest")"
  if ! mkdir -p "$parent" 2>/dev/null; then
    muesli_spm_note "cannot create $parent; cold build"
    return 0
  fi
  if ! muesli_spm_dir_on_apfs "$parent"; then
    muesli_spm_note "APFS clones unavailable for $parent; cold build"
    return 0
  fi
  if [[ "$#" -eq 0 ]]; then
    muesli_spm_note "no seed donor for $dest; cold build"
    return 0
  fi

  # No lock: two seeders of one path both clone, and the no-clobber rename
  # publishes exactly one of them.
  local donor status seeded=0
  for donor in "$@"; do
    [[ -n "$donor" && "$donor" != "$dest" && -d "$donor" && ! -L "$donor" ]] || continue
    if muesli_spm_path_busy "$donor" "$prune"; then
      muesli_spm_note "seed donor busy, skipping: $donor"
      continue
    fi
    status=0
    muesli_spm_clone_into "$dest" "$prune" "$donor" || status=$?
    if [[ "$status" -eq 0 ]]; then
      seeded=1
      break
    fi
    [[ "$status" -eq 1 ]] || {
      seeded=2
      break
    }
  done
  if [[ "$seeded" -eq 0 ]]; then
    muesli_spm_note "no idle seed donor for $dest; cold build"
  fi
  return 0
}

# Prints seed donors for one worktree cache dir, best first: the main
# checkout's matching path, then siblings' by the modification time of the donor
# directory itself (a proxy for recent use).
# muesli_spm_seed_donors <root> <relative path under the worktree cache dir>...
muesli_spm_seed_donors() {
  local root="$1"
  shift
  local cache_root own main_root main_dir relative candidate
  cache_root="$(muesli_default_spm_cache_root)"
  own="$cache_root/worktrees/$(muesli_spm_worktree_dir_name "$root")"
  main_root="$(muesli_spm_main_checkout_root "$root")"
  main_dir=""
  [[ -n "$main_root" ]] && main_dir="$cache_root/worktrees/$(muesli_spm_worktree_dir_name "$main_root")"

  # $relative stays unquoted in the loops below: it may be a glob pattern.
  for relative in "$@"; do
    if [[ -n "$main_dir" && "$main_dir" != "$own" ]]; then
      # shellcheck disable=SC2231
      for candidate in "$main_dir"/$relative; do
        [[ -d "$candidate" ]] && printf '%s\n' "$candidate"
      done
    fi
  done
  for relative in "$@"; do
    local siblings=()
    # shellcheck disable=SC2231
    for candidate in "$cache_root"/worktrees/*/$relative; do
      [[ -d "$candidate" ]] || continue
      [[ "$candidate" == "$own"/* ]] && continue
      [[ -n "$main_dir" && "$candidate" == "$main_dir"/* ]] && continue
      siblings+=("$candidate")
    done
    [[ "${#siblings[@]}" -gt 0 ]] && ls -1dt "${siblings[@]}" 2>/dev/null
  done
  return 0
}

# muesli_spm_prepare_worktree_dir <dest> <root> <prune> <relative pattern>...:
# records the root marker and seeds <dest>. Never fails.
muesli_spm_prepare_worktree_dir() {
  local dest="$1" root="$2" prune="$3"
  shift 3
  local cache_root donors=() donor
  cache_root="$(muesli_default_spm_cache_root)"
  muesli_spm_mark_worktree_root "$cache_root/worktrees/$(muesli_spm_worktree_dir_name "$root")" "$root"
  local seen=$'\n'
  while IFS= read -r donor; do
    [[ -n "$donor" && "$seen" != *$'\n'"$donor"$'\n'* ]] || continue
    seen+="$donor"$'\n'
    donors+=("$donor")
  done < <(muesli_spm_seed_donors "$root" "$@")
  muesli_seed_spm_dir "$dest" "$prune" ${donors[@]+"${donors[@]}"} || true
  return 0
}

# Resolves the worktree-scoped scratch path for <channel>, and when nothing
# overrides it, records the worktree root and seeds the path.
muesli_worktree_spm_scratch_path() {
  local channel="${1:-dev}"
  local root="${2:-$PWD}"
  local path prune=""
  path="$(muesli_resolve_spm_scratch_path "$(muesli_worktree_spm_scratch_channel "$channel" "$root")")"
  if [[ -z "${MUESLI_SWIFTPM_SCRATCH_PATH:-}" && -z "${MUESLI_SWIFTPM_SCRATCH_CHANNEL:-}" ]] &&
    ! muesli_spm_scratch_disabled; then
    # Debug DerivedData lives under the dev scratch; it is seeded per app name.
    [[ "$channel" == "dev" ]] && prune="xcodebuild"
    muesli_spm_prepare_worktree_dir "$path" "$root" "$prune" "$channel" || true
  fi
  printf '%s\n' "$path"
}

# Seeds a worktree's debug DerivedData (<dev scratch>/xcodebuild/<name>) from a
# donor's, preferring the same app name. Skipped when MUESLI_XCODEBUILD_DERIVED_DATA,
# MUESLI_SWIFTPM_SCRATCH_PATH or MUESLI_SWIFTPM_SCRATCH_CHANNEL is set. Never fails.
muesli_seed_worktree_derived_data() {
  local dest="$1" root="$2" name="$3"
  [[ -z "${MUESLI_XCODEBUILD_DERIVED_DATA:-}${MUESLI_SWIFTPM_SCRATCH_PATH:-}${MUESLI_SWIFTPM_SCRATCH_CHANNEL:-}" ]] || return 0
  muesli_spm_scratch_disabled && return 0
  local config="${name##*-}"
  muesli_spm_prepare_worktree_dir "$dest" "$root" "" \
    "dev/xcodebuild/$name" "dev/xcodebuild/*-$config" || true
  return 0
}
