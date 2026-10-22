#!/usr/bin/env bash
# Tests for SwiftPM scratch seeding (scripts/muesli_spm_cache.sh,
# scripts/muesli_spm_scratch_path.sh) and cache GC (scripts/muesli_spm_gc.sh).
#
# Runs on macOS (APFS clones are exercised) and on Linux CI (no clonefile, so
# every seed must degrade to a cold build). HOME points at a temp dir, so the
# real ~/Library/Caches/muesli-spm is never touched.
set -euo pipefail

SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
BG_PIDS=()
# Stops a background fixture and its children (bash -c keeps its sleep child).
stop_bg() {
  {
    pkill -P "$1" || true
    kill "$1" || true
    wait "$1" || true
  } 2>/dev/null
}

cleanup() {
  local pid
  for pid in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do
    stop_bg "$pid"
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

export HOME="$TEST_ROOT/home"
mkdir -p "$HOME"
unset MUESLI_SWIFTPM_SCRATCH_PATH MUESLI_SWIFTPM_SCRATCH_CHANNEL \
  MUESLI_EXTERNAL_SPM_CACHE_ROOT MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH \
  MUESLI_SWIFTPM_SEED MUESLI_XCODEBUILD_DERIVED_DATA CI
export GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

CACHE="$HOME/Library/Caches/muesli-spm"
EXPECT_CLONE=0
[[ "$(uname -s)" == "Darwin" ]] && EXPECT_CLONE=1
ERR="$TEST_ROOT/stderr.log"
REAL_CP="$(command -v cp)"
FAKE_BIN="$TEST_ROOT/fake-bin"
mkdir -p "$FAKE_BIN"

fail() {
  echo "FAIL: $*" >&2
  if [[ -s "$ERR" ]]; then
    echo "--- stderr of the last call ---" >&2
    cat "$ERR" >&2
  fi
  exit 1
}

pass() {
  echo "ok - $*"
}

backdate() {
  find "$1" -exec touch -h -t 202601010000 {} +
}

backdate_to() {
  find "$1" -exec touch -h -t "$2" {} +
}

wt_dir_name() {
  printf '%s-%s' "$(basename "$1")" "$(printf '%s' "$1" | cksum | awk '{print $1}')"
}

wt_cache_dir() {
  printf '%s/worktrees/%s' "${2:-$CACHE}" "$(wt_dir_name "$1")"
}

# make_scratch <dir> <tag>: a fake, idle scratch dir whose content names its origin.
make_scratch() {
  mkdir -p "$1/checkouts/dep" "$1/out"
  printf '%s\n' "$2" > "$1/checkouts/dep/origin.txt"
  printf 'db\n' > "$1/out/build.db"
  backdate "$1"
}

# make_git_scratch <dir> <tag> [subdir]: a scratch laid out like SwiftPM's (or
# DerivedData's SourcePackages with subdir=SourcePackages). The checkout borrows
# objects from repositories/ through git alternates and records absolute paths in
# its origin URL and in workspace-state.json, exactly as SwiftPM does.
make_git_scratch() {
  local dir="$1" tag="$2" sub="${3:-}"
  local base="$dir${sub:+/$sub}" work="$TEST_ROOT/work-$tag-$RANDOM"
  mkdir -p "$base/repositories" "$base/checkouts" "$dir/out"
  git -c init.defaultBranch=main init -q --bare "$base/repositories/dep-1234"
  git -c init.defaultBranch=main init -q "$work"
  printf '%s\n' "$tag" > "$work/origin.txt"
  git -C "$work" add origin.txt
  git -C "$work" commit -q -m dep
  git -C "$work" push -q "$base/repositories/dep-1234" HEAD:refs/heads/main
  git clone -q --shared "$base/repositories/dep-1234" "$base/checkouts/dep"
  printf '{"artifacts":[{"path":"%s/artifacts/x"}],"checkoutPath":"%s/checkouts/dep","unrelated":"%s2/elsewhere"}\n' \
    "$base" "$base" "$dir" > "$base/workspace-state.json"
  printf 'db\n' > "$dir/out/build.db"
  backdate "$dir"
}

# expect_self_contained <seed base> <donor base>: no recorded path points into the
# donor, and the checkout still works after the donor is gone.
expect_self_contained() {
  local seed="$1" donor="$2" file
  for file in "$seed/workspace-state.json" "$seed/checkouts/dep/.git/config" \
    "$seed/checkouts/dep/.git/objects/info/alternates"; do
    if grep -qF -e "$donor/" -e "$donor\"" "$file" || [[ "$(sed -n '1p' "$file")" == "$donor"* ]]; then
      fail "$file still points into the donor $donor"
    fi
  done
  grep -qF "$donor2_marker" "$seed/workspace-state.json" || fail "a path that only shares the donor's prefix was rewritten"
  grep -qF "$seed/repositories/dep-1234/objects" "$seed/checkouts/dep/.git/objects/info/alternates" ||
    fail "alternates not rebased onto the seed: $(cat "$seed/checkouts/dep/.git/objects/info/alternates")"
}

expect_checkout_survives_donor() {
  local checkout="$1" tag="$2"
  local fsck_output
  fsck_output="$(git -C "$checkout" fsck --connectivity-only 2>&1)" ||
    fail "seeded checkout lost its objects with the donor: $fsck_output"
  [[ "$(git -C "$checkout" show HEAD:origin.txt)" == "$tag" ]] || fail "seeded checkout cannot read its commit"
  git -C "$checkout" fetch -q origin 2>/dev/null || fail "seeded checkout's origin points at the removed donor"
}

origin_of() {
  cat "$1/checkouts/dep/origin.txt" 2>/dev/null || printf 'missing'
}

# scratch_path <worktree> <channel>: run the helper from a worktree.
scratch_path() {
  (cd "$1" && ./scripts/muesli_spm_scratch_path.sh "$2") 2>"$ERR"
}

no_seed_leftovers() {
  local parent="$1" leftover
  leftover="$(find "$parent" -maxdepth 1 \( -name '*.seed-tmp.*' -o -name '*.seed-stamp.*' \) -print 2>/dev/null | head -n 1 || true)"
  [[ -z "$leftover" ]] || fail "seed leftover in $parent: $leftover"
}

# expect_seeded <dest> <origin tag> <name>: the clone landed on macOS; Linux stays cold.
expect_seeded() {
  local dest="$1" tag="$2" name="$3"
  if [[ "$EXPECT_CLONE" == "1" ]]; then
    [[ "$(origin_of "$dest")" == "$tag" ]] || fail "$name: expected seed from $tag, got $(origin_of "$dest")"
    grep -q "seeded" "$ERR" || fail "$name: no 'seeded' note"
  else
    [[ ! -e "$dest" ]] || fail "$name: dest should stay absent without clonefile"
    grep -q "cold build" "$ERR" || fail "$name: no 'cold build' note"
  fi
  no_seed_leftovers "$(dirname "$dest")"
}

# --- fixture repository: a main checkout plus two linked worktrees ----------
MAIN="$TEST_ROOT/src/muesli"
mkdir -p "$MAIN/scripts"
for script in muesli_spm_cache.sh muesli_spm_scratch_path.sh muesli_spm_gc.sh; do
  "$REAL_CP" "$SRC_ROOT/scripts/$script" "$MAIN/scripts/$script"
done
git -C "$MAIN" init -q
git -C "$MAIN" add scripts
git -C "$MAIN" commit -q -m fixture
WT1="$MAIN/.claude/worktrees/wt1"
WT2="$MAIN/.claude/worktrees/wt2"
WT3="$MAIN/.claude/worktrees/wt3"
git -C "$MAIN" worktree add -q --detach "$WT1"
git -C "$MAIN" worktree add -q --detach "$WT2"
git -C "$MAIN" worktree add -q --detach "$WT3"

reset_cache() {
  rm -rf "$HOME/Library/Caches" "$TEST_ROOT/ext"
  rm -f "$FAKE_BIN"/*
  : > "$ERR"
}

# --- resolver behaviour that must not change --------------------------------
(
  source "$MAIN/scripts/muesli_spm_cache.sh"
  [[ "$(muesli_worktree_spm_scratch_channel dev "$WT1")" == "worktrees/$(wt_dir_name "$WT1")/dev" ]] ||
    fail "worktree channel format changed"
  [[ "$(muesli_resolve_spm_scratch_path release)" == "$CACHE/release" ]] || fail "default root changed"
  [[ "$(MUESLI_SWIFTPM_SCRATCH_PATH=/x/y muesli_resolve_spm_scratch_path dev)" == "/x/y" ]] ||
    fail "explicit path no longer wins"
  [[ "$(MUESLI_SWIFTPM_SCRATCH_CHANNEL=agent-1 muesli_resolve_spm_scratch_path dev)" == "$CACHE/agent-1" ]] ||
    fail "channel override changed"
)
pass "resolver precedence unchanged"

# --- helper prints the worktree-scoped path and records the root -----------
reset_cache
out="$(scratch_path "$WT1" test)"
[[ "$out" == "$(wt_cache_dir "$WT1")/test" ]] || fail "helper path: $out"
[[ "$(cat "$(wt_cache_dir "$WT1")/.muesli-worktree-root")" == "$WT1" ]] || fail "root marker not written"
[[ ! -e "$out/.muesli-worktree-root" ]] || fail "marker must sit above the channel dir"
grep -q "cold build" "$ERR" || fail "no donor should report a cold build"
pass "helper path + root marker, no donor -> cold build"

# --- seed from the main checkout's same channel -----------------------------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/test" main
out="$(scratch_path "$WT1" test)"
expect_seeded "$out" main "main donor"
[[ "$(origin_of "$(wt_cache_dir "$MAIN")/test")" == "main" ]] || fail "donor modified"
[[ ! -e "$out/.muesli-worktree-root" ]] || fail "donor marker copied into the channel"
pass "seed from main checkout"

# --- existing non-empty dest is left alone ----------------------------------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/test" main
make_scratch "$(wt_cache_dir "$WT1")/test" own
out="$(scratch_path "$WT1" test)"
[[ "$(origin_of "$out")" == "own" ]] || fail "existing scratch was replaced"
pass "existing scratch untouched"

# --- an empty dest dir counts as unseeded ------------------------------------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/test" main
mkdir -p "$(wt_cache_dir "$WT1")/test"
out="$(scratch_path "$WT1" test)"
if [[ "$EXPECT_CLONE" == "1" ]]; then
  [[ "$(origin_of "$out")" == "main" ]] || fail "empty dest not seeded"
fi
no_seed_leftovers "$(wt_cache_dir "$WT1")"
pass "empty dest seeded"

# --- opt-outs: MUESLI_SWIFTPM_SEED=0, CI, explicit paths, DISABLE -----------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/test" main
out="$(MUESLI_SWIFTPM_SEED=0 scratch_path "$WT1" test)"
[[ ! -e "$out" ]] || fail "MUESLI_SWIFTPM_SEED=0 still seeded"
[[ -f "$(wt_cache_dir "$WT1")/.muesli-worktree-root" ]] || fail "marker skipped with seeding off"
out="$(CI=true scratch_path "$WT1" test)"
[[ ! -e "$out" ]] || fail "CI=true still seeded"
out="$(MUESLI_SWIFTPM_SCRATCH_PATH="$TEST_ROOT/explicit" scratch_path "$WT2" test)"
[[ "$out" == "$TEST_ROOT/explicit" && ! -e "$TEST_ROOT/explicit" ]] || fail "explicit path seeded or changed: $out"
[[ ! -e "$(wt_cache_dir "$WT2")" ]] || fail "explicit path wrote a worktree marker"
out="$(MUESLI_SWIFTPM_SCRATCH_CHANNEL=agent-1 scratch_path "$WT2" test)"
[[ "$out" == "$CACHE/agent-1" && ! -e "$out" ]] || fail "channel override seeded or changed: $out"
out="$(MUESLI_DISABLE_SWIFTPM_SCRATCH_PATH=1 scratch_path "$WT2" test)"
[[ "$out" == "$WT2/native/MuesliNative/.build" ]] || fail "DISABLE should print package-local .build: $out"
pass "opt-outs leave behaviour unchanged"

# --- the main checkout never seeds from itself ------------------------------
reset_cache
out="$(scratch_path "$MAIN" test)"
[[ ! -e "$out" ]] || fail "main checkout seeded from somewhere"
grep -q "cold build" "$ERR" || fail "main checkout should report a cold build"
pass "main checkout is not its own donor"

# --- busy donor (recent writes) falls through to an idle sibling -----------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/test" main
touch "$(wt_cache_dir "$MAIN")/test/out/build.db"
make_scratch "$(wt_cache_dir "$WT2")/test" sibling
out="$(scratch_path "$WT1" test)"
if [[ "$EXPECT_CLONE" == "1" ]]; then
  grep -q "busy" "$ERR" || fail "busy donor not reported"
fi
expect_seeded "$out" sibling "busy main -> sibling"
pass "recently written donor skipped"

# --- busy donor (a running process names it) is skipped ---------------------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/test" main
make_scratch "$(wt_cache_dir "$WT2")/test" sibling
bash -c 'sleep 60; :' "$(wt_cache_dir "$MAIN")/test" >/dev/null 2>&1 &
BG_PIDS+=("$!")
busy_pid="$!"
sleep 0.5
out="$(scratch_path "$WT1" test)"
stop_bg "$busy_pid"
if [[ "$EXPECT_CLONE" == "1" ]]; then
  grep -q "busy" "$ERR" || fail "process-held donor not reported busy"
fi
expect_seeded "$out" sibling "process-held main -> sibling"
pass "donor in use by a process skipped"

# --- siblings are tried most recent first ------------------------------------
reset_cache
make_scratch "$(wt_cache_dir "$WT2")/test" older
make_scratch "$(wt_cache_dir "$WT3")/test" newer
backdate_to "$(wt_cache_dir "$WT2")/test" 202601010000
backdate_to "$(wt_cache_dir "$WT3")/test" 202602010000
out="$(scratch_path "$WT1" test)"
expect_seeded "$out" newer "sibling recency"
pass "most recent sibling first"

# --- external cache root -----------------------------------------------------
reset_cache
mkdir -p "$TEST_ROOT/ext"
make_scratch "$(wt_cache_dir "$MAIN" "$TEST_ROOT/ext")/test" external
out="$(MUESLI_EXTERNAL_SPM_CACHE_ROOT="$TEST_ROOT/ext" scratch_path "$WT1" test)"
[[ "$out" == "$(wt_cache_dir "$WT1" "$TEST_ROOT/ext")/test" ]] || fail "external root path: $out"
[[ -f "$(wt_cache_dir "$WT1" "$TEST_ROOT/ext")/.muesli-worktree-root" ]] || fail "external root marker"
expect_seeded "$out" external "external root"
[[ ! -e "$CACHE" ]] || fail "external root run wrote to the default root"
pass "external cache root"

# --- a seed stands alone: recorded donor paths are rebased onto the seed ------
reset_cache
main_test="$(wt_cache_dir "$MAIN")/test"
make_git_scratch "$main_test" main
donor2_marker="$main_test""2/elsewhere"
out="$(scratch_path "$WT1" test)"
expect_seeded "$out" main "git-backed donor"
if [[ "$EXPECT_CLONE" == "1" ]]; then
  expect_self_contained "$out" "$main_test"
  mv "$main_test" "$TEST_ROOT/donor-removed-by-gc"
  expect_checkout_survives_donor "$out/checkouts/dep" main
fi
pass "seeded scratch does not depend on its donor"

reset_cache
main_dd="$(wt_cache_dir "$MAIN")/dev/xcodebuild/MuesliDev-debug"
make_git_scratch "$main_dd" main-dd SourcePackages
donor2_marker="$main_dd""2/elsewhere"
(
  source "$WT1/scripts/muesli_spm_cache.sh"
  dd="$(wt_cache_dir "$WT1")/dev/xcodebuild/MuesliDev-debug"
  muesli_seed_worktree_derived_data "$dd" "$WT1" MuesliDev-debug 2>"$ERR"
  if [[ "$EXPECT_CLONE" == "1" ]]; then
    expect_self_contained "$dd/SourcePackages" "$main_dd/SourcePackages"
    mv "$main_dd" "$TEST_ROOT/dd-donor-removed-by-gc"
    expect_checkout_survives_donor "$dd/SourcePackages/checkouts/dep" main-dd
  else
    [[ ! -e "$dd" ]] || fail "DerivedData seeded without clonefile"
  fi
)
pass "seeded DerivedData does not depend on its donor"

# --- explicit SwiftPM overrides turn DerivedData seeding off too --------------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/dev/xcodebuild/MuesliDev-debug" main-dd
(
  source "$WT1/scripts/muesli_spm_cache.sh"
  dd="$(wt_cache_dir "$WT1")/dev/xcodebuild/MuesliDev-debug"
  MUESLI_SWIFTPM_SCRATCH_PATH="$TEST_ROOT/explicit" muesli_seed_worktree_derived_data "$dd" "$WT1" MuesliDev-debug 2>"$ERR"
  [[ ! -e "$dd" ]] || fail "DerivedData seeded with an explicit MUESLI_SWIFTPM_SCRATCH_PATH"
  MUESLI_SWIFTPM_SCRATCH_CHANNEL=agent-1 muesli_seed_worktree_derived_data "$dd" "$WT1" MuesliDev-debug 2>"$ERR"
  [[ ! -e "$dd" ]] || fail "DerivedData seeded with an explicit MUESLI_SWIFTPM_SCRATCH_CHANNEL"
  [[ ! -e "$(wt_cache_dir "$WT1")/.muesli-worktree-root" ]] || fail "explicit override still wrote a root marker"
)
pass "explicit overrides skip DerivedData seeding"

# --- an unreadable donor counts as busy, never as idle ------------------------
if [[ "$EXPECT_CLONE" == "1" ]]; then
  reset_cache
  make_scratch "$(wt_cache_dir "$MAIN")/test" main
  make_scratch "$(wt_cache_dir "$WT2")/test" sibling
  mkdir -p "$(wt_cache_dir "$MAIN")/test/out/locked"
  backdate "$(wt_cache_dir "$MAIN")/test"
  chmod 000 "$(wt_cache_dir "$MAIN")/test/out/locked"
  out="$(scratch_path "$WT1" test)"
  chmod 755 "$(wt_cache_dir "$MAIN")/test/out/locked"
  grep -q "busy" "$ERR" || fail "unreadable donor not treated as busy"
  [[ "$(origin_of "$out")" == "sibling" ]] || fail "unreadable donor used: $(origin_of "$out")"
  pass "unreadable donor skipped"
fi

# --- dev channel: donor DerivedData is pruned, then seeded per app -----------
reset_cache
main_dev="$(wt_cache_dir "$MAIN")/dev"
make_scratch "$main_dev" main-dev
mkdir -p "$main_dev/xcodebuild/MuesliDev-debug" "$main_dev/xcodebuild/MuesliDevA-debug"
printf 'dev\n' > "$main_dev/xcodebuild/MuesliDev-debug/origin.txt"
printf 'lane-a\n' > "$main_dev/xcodebuild/MuesliDevA-debug/origin.txt"
backdate "$main_dev"
# A lane building into the donor's DerivedData (recent writes, and an xcodebuild
# naming it) does not make the donor's dev scratch busy.
mkdir -p "$main_dev/xcodebuild/MuesliDevC-debug"
printf 'building\n' > "$main_dev/xcodebuild/MuesliDevC-debug/build.db"
bash -c 'sleep 60; :' -derivedDataPath "$main_dev/xcodebuild/MuesliDevC-debug" >/dev/null 2>&1 &
lane_pid="$!"
BG_PIDS+=("$lane_pid")
sleep 0.5
out="$(scratch_path "$WT1" dev)"
stop_bg "$lane_pid"
expect_seeded "$out" main-dev "dev channel"
[[ ! -e "$out/xcodebuild" ]] || fail "donor DerivedData copied with the dev scratch"
(
  source "$WT1/scripts/muesli_spm_cache.sh"
  dd="$out/xcodebuild/MuesliDevA-debug"
  muesli_seed_worktree_derived_data "$dd" "$WT1" MuesliDevA-debug 2>"$ERR"
  if [[ "$EXPECT_CLONE" == "1" ]]; then
    [[ "$(cat "$dd/origin.txt")" == "lane-a" ]] || fail "DerivedData should prefer the same app name"
  else
    [[ ! -e "$dd" ]] || fail "DerivedData seeded without clonefile"
  fi
  dd="$out/xcodebuild/MuesliDevB-debug"
  muesli_seed_worktree_derived_data "$dd" "$WT1" MuesliDevB-debug 2>"$ERR"
  if [[ "$EXPECT_CLONE" == "1" ]]; then
    [[ -f "$dd/origin.txt" ]] || fail "DerivedData should fall back to any debug DerivedData"
  fi
  dd="$out/xcodebuild/MuesliDevC-debug"
  MUESLI_XCODEBUILD_DERIVED_DATA="$dd" muesli_seed_worktree_derived_data "$dd" "$WT1" MuesliDevC-debug 2>"$ERR"
  [[ ! -e "$dd" ]] || fail "explicit MUESLI_XCODEBUILD_DERIVED_DATA was seeded"
)
pass "dev channel + DerivedData seeding"

# --- two seeders of one path at once: exactly one clone is published ---------
reset_cache
make_scratch "$(wt_cache_dir "$MAIN")/test" main
(cd "$WT1" && ./scripts/muesli_spm_scratch_path.sh test >/dev/null 2>"$TEST_ROOT/seed-a.log") &
seeder_a="$!"
(cd "$WT1" && ./scripts/muesli_spm_scratch_path.sh test >/dev/null 2>"$TEST_ROOT/seed-b.log") &
seeder_b="$!"
wait "$seeder_a" || fail "first concurrent seeder failed"
wait "$seeder_b" || fail "second concurrent seeder failed"
dest="$(wt_cache_dir "$WT1")/test"
if [[ "$EXPECT_CLONE" == "1" ]]; then
  [[ "$(origin_of "$dest")" == "main" ]] || fail "concurrent seeders: dest not seeded from main"
  [[ "$(ls -A "$dest" | LC_ALL=C sort | tr '\n' ' ')" == "checkouts out " ]] ||
    fail "concurrent seeders nested a clone: $(ls -A "$dest")"
else
  [[ ! -e "$dest" ]] || fail "concurrent seeders created a dest without clonefile"
fi
no_seed_leftovers "$(wt_cache_dir "$WT1")"
pass "concurrent seeders publish one clone"

# --- clone-path failures (only reachable where clonefile exists) -------------
if [[ "$EXPECT_CLONE" == "1" ]]; then
  # Donor written during the clone: discard the seed.
  reset_cache
  make_scratch "$(wt_cache_dir "$MAIN")/test" main
  cat > "$FAKE_BIN/cp" <<FAKE
#!/usr/bin/env bash
"$REAL_CP" "\$@" || exit \$?
touch "$(wt_cache_dir "$MAIN")/test/out/build.db"
FAKE
  chmod +x "$FAKE_BIN/cp"
  out="$(PATH="$FAKE_BIN:$PATH" scratch_path "$WT1" test)"
  [[ ! -e "$out" ]] || fail "kept a clone of a donor that changed mid-clone"
  grep -q "changed during" "$ERR" || fail "mid-clone change not reported"
  no_seed_leftovers "$(wt_cache_dir "$WT1")"
  pass "donor changed during clone -> cold"

  # Clone fails part way: no partial dir survives.
  reset_cache
  make_scratch "$(wt_cache_dir "$MAIN")/test" main
  cat > "$FAKE_BIN/cp" <<'FAKE'
#!/usr/bin/env bash
dest="${@: -1}"
mkdir -p "$dest/partial"
exit 1
FAKE
  chmod +x "$FAKE_BIN/cp"
  out="$(PATH="$FAKE_BIN:$PATH" scratch_path "$WT1" test)"
  [[ ! -e "$out" ]] || fail "failed clone left a dest"
  grep -q "cold build" "$ERR" || fail "failed clone not reported"
  no_seed_leftovers "$(wt_cache_dir "$WT1")"
  pass "failed clone -> cold, no leftovers"

  # Dest appears during the clone (a direct swift build): never nest into it.
  reset_cache
  make_scratch "$(wt_cache_dir "$MAIN")/test" main
  dest="$(wt_cache_dir "$WT1")/test"
  cat > "$FAKE_BIN/cp" <<FAKE
#!/usr/bin/env bash
"$REAL_CP" "\$@" || exit \$?
mkdir -p "$dest"
printf 'appeared\n' > "$dest/appeared.txt"
FAKE
  chmod +x "$FAKE_BIN/cp"
  out="$(PATH="$FAKE_BIN:$PATH" scratch_path "$WT1" test)"
  [[ "$(ls -A "$dest")" == "appeared.txt" ]] || fail "seed nested into or replaced a dest that appeared: $(ls -A "$dest")"
  grep -q "appeared" "$ERR" || fail "appearing dest not reported"
  no_seed_leftovers "$(wt_cache_dir "$WT1")"
  pass "dest appearing mid-clone is left alone"
fi

# --- GC ------------------------------------------------------------------------
gc() {
  (cd "$MAIN" && ./scripts/muesli_spm_gc.sh "$@") 2>"$ERR"
}

tree_state() {
  # Paths only: mtimes would differ if anything were written.
  (cd "$CACHE" && find . -print | LC_ALL=C sort) 2>/dev/null || true
}

setup_gc_fixture() {
  reset_cache
  local wts="$CACHE/worktrees"
  mkdir -p "$wts"
  make_scratch "$wts/live-entry/test" live
  printf '%s\n' "$WT1" > "$wts/live-entry/.muesli-worktree-root"
  make_scratch "$wts/orphan-entry/test" orphan
  printf '%s\n' "$TEST_ROOT/gone-worktree" > "$wts/orphan-entry/.muesli-worktree-root"
  make_scratch "$wts/$(wt_dir_name "$WT2")/test" hash-live
  make_scratch "$wts/legacy-entry/test" legacy
  make_scratch "$wts/empty-marker-entry/test" empty-marker
  : > "$wts/empty-marker-entry/.muesli-worktree-root"
  make_scratch "$wts/recent-orphan/test" recent
  printf '%s\n' "$TEST_ROOT/gone-too" > "$wts/recent-orphan/.muesli-worktree-root"
  make_scratch "$wts/proc-orphan/test" proc
  printf '%s\n' "$TEST_ROOT/gone-three" > "$wts/proc-orphan/.muesli-worktree-root"
  make_scratch "$wts/seeding-orphan/test" seeding
  printf '%s\n' "$TEST_ROOT/gone-four" > "$wts/seeding-orphan/.muesli-worktree-root"
  mkdir -p "$TEST_ROOT/outside"
  printf 'keep\n' > "$TEST_ROOT/outside/keep.txt"
  ln -s "$TEST_ROOT/outside" "$wts/link-entry"
  # Seed leftovers inside a live entry: one from a dead process, one live.
  true &
  local dead="$!"
  wait "$dead" || true
  dead_seed="$dead"
  mkdir -p "$wts/live-entry/test.seed-tmp.$dead"
  : > "$wts/live-entry/test.seed-stamp.$dead"
  sleep 60 >/dev/null 2>&1 &
  BG_PIDS+=("$!")
  GC_LIVE_SEEDER="$!"
  mkdir -p "$wts/live-entry/dev.seed-tmp.$GC_LIVE_SEEDER"
  local entry
  for entry in "$wts"/*; do
    [[ "$(basename "$entry")" == "recent-orphan" ]] && continue
    backdate "$entry"
  done
  touch "$wts/recent-orphan/test/out/build.db"
}

setup_gc_fixture
bash -c 'sleep 60; :' "$CACHE/worktrees/proc-orphan" >/dev/null 2>&1 &
BG_PIDS+=("$!")
proc_pid="$!"
sleep 0.5
before="$(tree_state)"
report="$(gc)" || fail "dry run failed"
[[ "$(tree_state)" == "$before" ]] || fail "dry run changed the cache"
grep -Eq '^live +.*live-entry' <<<"$report" || fail "live entry not reported live: $report"
grep -Eq '^live +.*'"$(wt_dir_name "$WT2")" <<<"$report" || fail "hash-matched entry not live: $report"
grep -Eq '^orphaned +.*orphan-entry' <<<"$report" || fail "orphan not reported: $report"
grep -Eq '^unowned +.*legacy-entry' <<<"$report" || fail "legacy entry not unowned: $report"
grep -Eq '^unowned +.*empty-marker-entry' <<<"$report" || fail "empty marker not unowned: $report"
grep -Eq '^in-use +.*recent-orphan' <<<"$report" || fail "recently written orphan not in-use: $report"
grep -Eq '^in-use +.*proc-orphan' <<<"$report" || fail "process-held orphan not in-use: $report"
grep -Eq '^skipped +.*link-entry' <<<"$report" || fail "symlink entry not skipped: $report"
pass "GC dry run classifies and writes nothing"

bash -c 'sleep 60; :' cp -c -R "$CACHE/worktrees/seeding-orphan/test" "$CACHE/worktrees/x/test.seed-tmp.1" >/dev/null 2>&1 &
seeder_pid="$!"
BG_PIDS+=("$seeder_pid")
sleep 0.5
report="$(gc --apply)" || fail "apply failed"
stop_bg "$seeder_pid"
[[ -d "$CACHE/worktrees/seeding-orphan" ]] || fail "GC removed a donor that a seed was cloning"
[[ ! -e "$CACHE/worktrees/orphan-entry" ]] || fail "orphan not removed"
[[ -d "$CACHE/worktrees/legacy-entry" ]] || fail "unowned removed without --include-unowned"
[[ -d "$CACHE/worktrees/live-entry/test" ]] || fail "live entry removed"
[[ -d "$CACHE/worktrees/$(wt_dir_name "$WT2")" ]] || fail "hash-live entry removed"
[[ -d "$CACHE/worktrees/recent-orphan" ]] || fail "in-use orphan removed"
[[ -d "$CACHE/worktrees/proc-orphan" ]] || fail "process-held orphan removed"
[[ -f "$TEST_ROOT/outside/keep.txt" && -L "$CACHE/worktrees/link-entry" ]] || fail "symlink followed or removed"
[[ -z "$(find "$CACHE/worktrees/live-entry" -maxdepth 1 -name "test.seed-tmp.*" -print)" ]] || fail "dead seed temp not swept"
[[ ! -e "$CACHE/worktrees/live-entry/test.seed-stamp.$dead_seed" ]] || fail "dead seed stamp not swept"
[[ -d "$CACHE/worktrees/live-entry/dev.seed-tmp.$GC_LIVE_SEEDER" ]] || fail "live seeder's temp swept"
pass "GC --apply removes only orphans and dead seed leftovers"

report="$(gc --apply --include-unowned)" || fail "apply --include-unowned failed"
[[ ! -e "$CACHE/worktrees/legacy-entry" ]] || fail "unowned not removed with --include-unowned"
[[ ! -e "$CACHE/worktrees/empty-marker-entry" ]] || fail "empty-marker entry not removed"
[[ -d "$CACHE/worktrees/live-entry/test" ]] || fail "live entry removed by --include-unowned"
[[ -d "$CACHE/worktrees/$(wt_dir_name "$WT2")" ]] || fail "hash-live removed by --include-unowned"
[[ -d "$CACHE/worktrees/proc-orphan" ]] || fail "process-held entry removed by --include-unowned"
stop_bg "$proc_pid"
pass "GC --include-unowned"

# A failed worktree listing must not turn live hash-named caches into deletions.
setup_gc_fixture
cat > "$FAKE_BIN/git" <<'FAKE'
#!/usr/bin/env bash
exit 128
FAKE
chmod +x "$FAKE_BIN/git"
if (cd "$MAIN" && PATH="$FAKE_BIN:$PATH" ./scripts/muesli_spm_gc.sh --apply --include-unowned) >/dev/null 2>"$ERR"; then
  fail "GC deleted unowned caches without a worktree listing"
fi
[[ -d "$CACHE/worktrees/$(wt_dir_name "$WT2")" ]] || fail "hash-live entry deleted after git failure"
[[ -d "$CACHE/worktrees/legacy-entry" ]] || fail "unowned deleted after git failure"
pass "GC refuses --include-unowned when worktrees cannot be listed"

reset_cache
report="$(gc)" || fail "GC with no cache root should succeed"
grep -q "nothing to do" <<<"$report" || fail "missing cache root not reported: $report"
pass "GC with no cache root"

echo "All SwiftPM cache tests passed."
