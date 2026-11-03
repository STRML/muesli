#!/usr/bin/env bash
# sync-fork-main.sh — rebuild STRML/muesli main as upstream/main plus one squashed layer per open
# upstream PR, then the fork-local commits. Ported from STRML/oh-my-pi's script of the same name.
#
# Fork main = Muesli-HQ/muesli main
#           + "layer #N: <title>" for each open $AUTHOR PR on $UPSTREAM_REPO, oldest first
#             (git merge --squash of its head)
#           + the fork-local commits carried over from the current fork main: every commit that
#             is not a layer (daily-driver tooling, features not yet sent upstream, this script).
#
# Every PR must apply to upstream alone, so GitHub sees it as mergeable. A plain run merges
# upstream/main into each $AUTHOR PR that conflicts with it (rerere replays known resolutions),
# layers the updated head, and after the build check pushes the PR branch (a fast-forward, so the
# upstream PR never sees a force-push) along with fork main. A merge that hits a new conflict stops
# the run: resolve it on the PR branch by hand, push it, rerun.
#
# Usage:
#   scripts/sync-fork-main.sh --check       # report which PRs conflict and whether rerere resolves them
#   scripts/sync-fork-main.sh               # update PRs, build, check shards, push main + PRs, install
#   scripts/sync-fork-main.sh --no-push     # same, leave the pushes to you
#   scripts/sync-fork-main.sh --no-check    # skip the build and shard check
#   scripts/sync-fork-main.sh --test        # also run the full swift test suite before pushing
#   scripts/sync-fork-main.sh --resume      # continue after resolving a layer or carry conflict by hand
#   scripts/sync-fork-main.sh --no-install  # skip rebuilding MuesliDev
#   scripts/sync-fork-main.sh --install-only  # rebuild MuesliDev from origin/main; no layering
#
# Every run that is not --check or --no-push ends by rebuilding the daily-driver MuesliDev app with
# scripts/dev-test-local.sh, even when nothing was pushed. That script refuses while MuesliDev runs:
# the run then prints "MUESLIDEV NOT UPDATED" and exits 3 after everything else is done. Quit
# MuesliDev and rerun with --install-only.
#
# A conflict between two layers, or between a layer and a carried commit, stops the build in the
# worktree it prints. Resolve the files, `git add` them, commit (layer subject, or
# `git cherry-pick --continue`), then rerun with --resume. Keep rerere on (rerere.enabled,
# rerere.autoupdate): the resolution replays on the next cycle.
#
# Talks to github.com and builds with SwiftPM, so run it outside the agent sandbox.
set -euo pipefail

UPSTREAM_REPO="Muesli-HQ/muesli"
AUTHOR="STRML"
# Other people's open PRs we also layer onto fork main. Drop a number once it merges.
EXTRA_PRS=()

CHECK_ONLY=0; RESUME=0; NO_PUSH=0; NO_CHECK=0; RUN_TESTS=0; NO_INSTALL=0; INSTALL_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--check) CHECK_ONLY=1;;
		--resume) RESUME=1;;
		--no-push) NO_PUSH=1;;
		--no-check) NO_CHECK=1;;
		--test) RUN_TESTS=1;;
		--no-install) NO_INSTALL=1;;
		--install-only) INSTALL_ONLY=1;;
		*) printf 'unknown option: %s\n' "$arg" >&2; exit 1;;
	esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# The main checkout, even when this runs from a worktree, so the build worktree never nests.
ROOT="$(dirname -- "$(git -C "$(dirname -- "${BASH_SOURCE[0]}")" rev-parse --path-format=absolute --git-common-dir)")"
WT="$ROOT/.claude/worktrees/sync-fork-main"
BRANCH="sync-fork-main"

# Files left conflicted after a merge: unmerged paths plus staged files still holding markers.
# rerere.autoupdate stages its replayed resolutions, so a failed merge can leave nothing here.
unresolved() {
	{
		git diff --name-only --diff-filter=U
		git diff --cached --name-only -z | xargs -0 grep -l '^<<<<<<< ' 2>/dev/null || true
	} | sort -u
}

# Writes "<number>\t<head owner>\t<head branch>\t<title>" for every PR to layer, oldest first.
list_prs() {
	local fields='"\(.number)\t\(.headRepositoryOwner.login)\t\(.headRefName)\t\(.title)"'
	{
		gh pr list -R "$UPSTREAM_REPO" --author "$AUTHOR" --state open --limit 200 \
			--json number,headRepositoryOwner,headRefName,title --jq ".[] | $fields"
		for n in "${EXTRA_PRS[@]+"${EXTRA_PRS[@]}"}"; do
			gh pr view "$n" -R "$UPSTREAM_REPO" --json number,headRepositoryOwner,headRefName,title,state \
				--jq "select(.state == \"OPEN\") | $fields"
		done
	} | sort -n -u -k1,1
}

fetch_prs() {
	local refspecs=() n
	while IFS=$'\t' read -r -u 3 n _; do refspecs+=("+pull/$n/head:refs/pr/$n"); done 3< "$PRS"
	(( ${#refspecs[@]} )) || return 0
	git fetch -q upstream "${refspecs[@]}"
}

# GitHub's view: does the PR head merge onto upstream/main with no help from rerere?
merges_clean() {
	git merge-tree --write-tree "$UPSTREAM" "refs/pr/$1" >/dev/null 2>&1
}

# Merges upstream/main into refs/pr/N in the worktree. Leaves the merge checked out (detached) on
# success; aborts and returns 1 on a conflict rerere does not know.
update_pr() {
	local n="$1"
	git checkout -q --detach "refs/pr/$n"
	git merge -q --no-edit "$UPSTREAM" >/dev/null 2>&1 && return 0
	if [[ -n "$(unresolved)" ]]; then
		git merge --abort >/dev/null 2>&1 || true
		return 1
	fi
	git commit -q --no-verify --no-edit
}

# One line per PR. With "apply", updates the conflicting $AUTHOR PRs for real: refs/pr/N moves to
# the merge and "<number>\t<branch>\t<old head>\t<new head>" goes to $UPDATED.
check_prs() {
	local mode="${1:-report}" bad=0 n owner branch old
	while IFS=$'\t' read -r -u 3 n owner branch _; do
		if merges_clean "$n"; then say "ok        #$n"; continue; fi
		old="$(git rev-parse "refs/pr/$n")"
		if [[ "$owner" != "$AUTHOR" ]]; then
			say "CONFLICT  #$n: not ours, ask its author to update it"; bad=1; continue
		fi
		if update_pr "$n"; then
			say "updated   #$n ($branch)"
			if [[ "$mode" == apply ]]; then
				git update-ref "refs/pr/$n" HEAD
				printf '%s\t%s\t%s\t%s\n' "$n" "$branch" "$old" "$(git rev-parse HEAD)" >> "$UPDATED"
			fi
		else
			say "CONFLICT  #$n ($branch): merge upstream/main into it by hand"; bad=1
		fi
	done 3< "$PRS"
	git checkout -q --detach "$UPSTREAM"
	return "$bad"
}

# A captured list, not a `grep -q` pipe: under pipefail an early grep exit SIGPIPEs git log.
has_subject() {
	local subjects
	subjects="$(git log --format=%s "$UPSTREAM..HEAD")"
	[[ $'\n'"$subjects"$'\n' == *$'\n'"$1"$'\n'* ]]
}

layer() {
	local n="$1" title="$2" subject="layer #$1: $2"
	if has_subject "$subject"; then say "have      #$n"; return; fi
	if ! git merge --squash -q "refs/pr/$n" >/dev/null 2>&1; then
		local left; left="$(unresolved)"
		if [[ -n "$left" ]]; then
			say "CONFLICT  #$n in $WT:"; say "$left"
			die "resolve, git add, git commit -m \"$subject\", then rerun with --resume"
		fi
		say "rerere    #$n"
	fi
	if git diff --cached --quiet; then say "empty     #$n (already upstream?)"; return; fi
	git commit -q --no-verify -m "$subject"
	say "layered   #$n"
}

# Fork-local commits: everything on the old fork main past its upstream base that is not a layer,
# plus unpushed commits on the main checkout's local main when it builds on the old fork main.
# A carried commit that turns empty (its change reached upstream) is dropped.
carry_local() {
	local base sha subject
	base="$(git merge-base "$ORIGIN" "$UPSTREAM")"
	while read -r -u 3 sha subject; do
		[[ "$subject" == "layer #"* ]] && continue
		if has_subject "$subject"; then say "have      $subject"; continue; fi
		if ! git cherry-pick --allow-empty "$sha" >/dev/null 2>&1; then
			if [[ -n "$(unresolved)" ]]; then
				die "carry of $sha ($subject) conflicted in $WT; resolve, git cherry-pick --continue, rerun with --resume"
			fi
			git -c core.editor=true cherry-pick --continue >/dev/null
		fi
		if git diff --quiet HEAD^ HEAD; then
			git reset -q --hard HEAD^
			say "dropped   $subject (empty; already upstream?)"
			continue
		fi
		say "carried   $subject"
	done 3< <(git log --reverse --no-merges --format='%H %s' "$base..$CARRY")
}

build_check() {
	(( NO_CHECK )) && return
	say "== swift build =="
	local scratch
	scratch="$(scripts/muesli_spm_scratch_path.sh test)"
	swift build --build-tests --package-path native/MuesliNative --scratch-path "$scratch"
	scripts/test_ci_test_shards.sh
	if (( RUN_TESTS )); then
		say "== swift test =="
		swift test --skip-build --package-path native/MuesliNative --scratch-path "$scratch"
	fi
}

# Rebuilds the daily-driver MuesliDev app from the worktree. dev-test-local.sh keeps the signing
# identity stable so macOS permissions survive, and refuses while MuesliDev runs.
install_dev() {
	(( NO_INSTALL )) && return 0
	say "== rebuild MuesliDev =="
	if ! scripts/dev-test-local.sh; then
		say "MUESLIDEV NOT UPDATED: quit MuesliDev, then rerun: scripts/sync-fork-main.sh --install-only"
		exit 3
	fi
}

say "== fetch =="
git -C "$ROOT" fetch -q origin main
if (( INSTALL_ONLY )); then
	[[ -d "$WT" ]] || git -C "$ROOT" worktree add -q --detach "$WT" origin/main
	cd "$WT"
	git checkout -q --detach origin/main
	install_dev
	exit 0
fi
git -C "$ROOT" fetch -q upstream main
# A stale checkout runs a stale script: say so before it rebuilds main with old rules.
if ! cmp -s "${BASH_SOURCE[0]}" <(git -C "$ROOT" show origin/main:scripts/sync-fork-main.sh 2>/dev/null); then
	say "WARNING: this copy differs from origin/main:scripts/sync-fork-main.sh (stale checkout or local edit)"
fi

if [[ ! -d "$WT" ]]; then
	git -C "$ROOT" worktree add -q --detach "$WT" upstream/main
fi
cd "$WT"
STATE="$(git rev-parse --git-path sync-fork-main.state)"
PRS="$(git rev-parse --git-path sync-fork-main.prs)"
UPDATED="$(git rev-parse --git-path sync-fork-main.updated)"

if (( RESUME )); then
	[[ -f "$STATE" ]] || die "no saved run to resume"
	# shellcheck source=/dev/null
	source "$STATE"
	[[ "$(git branch --show-current)" == "$BRANCH" ]] || die "$WT is not on $BRANCH"
	[[ -z "$(unresolved)" ]] || die "unresolved files remain in $WT"
else
	# The worktree belongs to this script: drop whatever an abandoned run left behind.
	git merge --abort >/dev/null 2>&1 || true
	git cherry-pick --abort >/dev/null 2>&1 || true
	git reset -q --hard
	: > "$UPDATED"
	UPSTREAM="$(git rev-parse upstream/main)"
	ORIGIN="$(git rev-parse origin/main)"
	CARRY="$ORIGIN"
	if git -C "$ROOT" merge-base --is-ancestor "$ORIGIN" refs/heads/main; then
		CARRY="$(git -C "$ROOT" rev-parse refs/heads/main)"
	fi
	printf 'UPSTREAM=%s\nORIGIN=%s\nCARRY=%s\n' "$UPSTREAM" "$ORIGIN" "$CARRY" > "$STATE"
	list_prs > "$PRS"
	fetch_prs
fi
say "upstream/main = $UPSTREAM"
say "origin/main   = $ORIGIN"
[[ "$CARRY" == "$ORIGIN" ]] || say "local main    = $CARRY (unpushed commits carried)"
say "PRs: $(cut -f1 "$PRS" | tr '\n' ' ')"

if (( CHECK_ONLY )); then
	say "== check PRs against upstream/main =="
	check_prs || die "update the CONFLICT PRs by hand and push them, then rerun"
	exit 0
fi

if (( ! RESUME )); then
	say "== merge upstream/main into PRs that conflict with it =="
	check_prs apply || die "update the CONFLICT PRs by hand and push them, then rerun"
	say "== reset $BRANCH onto upstream/main =="
	git checkout -q -B "$BRANCH" "$UPSTREAM"
fi

say "== layers =="
while IFS=$'\t' read -r -u 3 n _ _ title; do layer "$n" "$title"; done 3< "$PRS"

say "== fork-local commits =="
carry_local

say "== result =="
git log --oneline "$UPSTREAM..HEAD" | cat

# Same base, same tree, no updated PRs: a push would only swap commit timestamps.
if [[ "$(git merge-base "$ORIGIN" "$UPSTREAM")" == "$UPSTREAM" && "$(git rev-parse "HEAD^{tree}")" == "$(git rev-parse "$ORIGIN^{tree}")" && ! -s "$UPDATED" ]]; then
	say "fork main already matches this rebuild; nothing to push"
	install_dev
	exit 0
fi

build_check

if (( NO_PUSH )); then
	say "push with:"
	say "  git -C $WT push origin HEAD:refs/heads/main --force-with-lease=refs/heads/main:$ORIGIN"
	while IFS=$'\t' read -r -u 3 n branch _ new; do
		say "  git -C $WT push origin $new:refs/heads/$branch  # #$n (fast-forward)"
	done 3< "$UPDATED"
	exit 0
fi

say "== push =="
git push origin HEAD:refs/heads/main --force-with-lease=refs/heads/main:"$ORIGIN"
say "origin/main = $(git ls-remote origin refs/heads/main | cut -f1)"
# PR branches only gain a merge commit, so these are plain fast-forward pushes.
while IFS=$'\t' read -r -u 3 n branch _ new; do
	git push origin "$new:refs/heads/$branch"
	say "#$n $branch = $new"
done 3< "$UPDATED"

# Bring the main checkout along, so its copy of this script is the one just pushed.
# Only when local main held nothing past the old fork main; reset --keep refuses to
# clobber uncommitted edits.
if [[ "$(git -C "$ROOT" branch --show-current)" == main ]] && git -C "$ROOT" merge-base --is-ancestor main "$CARRY"; then
	git -C "$ROOT" reset -q --keep "$(git rev-parse HEAD)" && say "main checkout = $(git rev-parse --short HEAD)"
else
	say "main checkout left alone; to follow: git -C $ROOT checkout -B main origin/main"
fi

install_dev
