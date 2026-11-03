# Config for ~/.claude/scripts/fork-sync.sh (the fork-sync skill). Sourced by bash.
# Fork main = Muesli-HQ/muesli main + one layer per open STRML PR + the fork-local commits.
UPSTREAM_REPO="Muesli-HQ/muesli"
AUTHOR="STRML"
EXTRA_PRS=()
# Upstream PRs never get force-pushed: a conflicting PR gets upstream/main merged in.
PR_UPDATE="merge"

# Build with tests and check CI shard assignments; --test also runs the full suite.
fork_check() {
	local scratch
	scratch="$(scripts/muesli_spm_scratch_path.sh test)"
	swift build --build-tests --package-path native/MuesliNative --scratch-path "$scratch"
	scripts/test_ci_test_shards.sh
	if has_arg --test; then
		swift test --skip-build --package-path native/MuesliNative --scratch-path "$scratch"
	fi
}

# Rebuild the daily-driver MuesliDev. dev-test-local.sh keeps the signing identity, so macOS
# permissions survive, and refuses while MuesliDev runs (quit it, then --install-only).
fork_install() {
	scripts/dev-test-local.sh || return 3
}
