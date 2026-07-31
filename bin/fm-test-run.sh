#!/usr/bin/env bash
# fm-test-run.sh - single owner of Firstmate's behavior-test runner, lane
# composition for portable CI shards, local --jobs for the proven-isolated set,
# timing markers, and the complete-regression coverage guard.
#
# Selection modes (exactly one of: --all, --family, --changed, --lane,
# --proven-isolated, or script paths):
#   fm-test-run.sh --all
#   fm-test-run.sh --family <name>
#   fm-test-run.sh --changed [--base <git-ref>]
#   fm-test-run.sh --lane portable-parallel-1|portable-parallel-2|portable-serial
#   fm-test-run.sh --lane windows-gitbash
#   fm-test-run.sh --lane windows-gitbash-parallel --jobs 6   # then:
#   fm-test-run.sh --lane windows-gitbash-serial
#   fm-test-run.sh --proven-isolated
#   fm-test-run.sh tests/<name>.test.sh [more scripts...]
#
# Inspection (no execution):
#   fm-test-run.sh --list --all
#   fm-test-run.sh --list --family <name>
#   fm-test-run.sh --list --lane portable-parallel-1
#   fm-test-run.sh --list-families
#   fm-test-run.sh --list-lanes
#   fm-test-run.sh --check-coverage
#
# Aggregation (no suite execution):
#   fm-test-run.sh --aggregate-json <out.json> <lane.json> [more lane.json...]
#
# Options:
#   --json <path>   write a deterministic timing artifact after the run
#   --list          print selected script paths (one per line) and exit 0
#   --base <ref>    with --changed, compare against this ref (default: origin/main)
#   --exclude-family <name>
#                   drop scripts whose primary family matches <name> after selection
#                   (repeatable; portable CI lanes exclude real-herdr-gated so the
#                   dedicated required Herdr lane owns that coverage)
#   --fail-on-gate-skip <token>
#                   after each script, fail the run if any output line contains
#                   "skip: <token>" (e.g. --fail-on-gate-skip 'herdr not found').
#                   The required Herdr CI lane uses this so a missing pin cannot
#                   silently pass as a gate skip.
#   --jobs N        run the selected scripts with up to N concurrent workers.
#                   Default is 1 (serial). N>1 is allowed only when every
#                   selected script is in the Phase 2 proven-isolated set
#                   (bin/fm-test-isolation-proof.sh --list). Cap is 8. Stateful
#                   families never schedule under --jobs.
#   -h, --help      print this header
#
# Per-script machine-parseable markers (stdout):
#   FM_TEST_BEGIN <iso8601> <script> family=<family> expected_gate_skip=<class>
#   FM_TEST_END <iso8601> <script> exit=<code> duration_ms=<n> gate_skip=<true|false>
#
# After all scripts (stdout):
#   FM_TEST_SUMMARY total=<n> failed=<n> skipped_gate=<n> duration_ms=<n>
#   FM_TEST_SUMMARY_FAMILY family=<name> count=<n> duration_ms=<n> failed=<n>
#   FM_TEST_SLOWEST rank=<k> script=<path> duration_ms=<n>
#
# Exit status is non-zero if any selected script exits non-zero or a configured
# --fail-on-gate-skip token appears. Other gate skips (first meaningful line
# matching ^skip:) remain successful and are counted as skipped_gate.
#
# Family labels, the changed-file map, and production portable-shard composition
# live in this script only (one owner). The proven-isolated candidate set remains
# owned by bin/fm-test-isolation-proof.sh; portable parallel shards are a
# duration-balanced partition of that exact set (see docs/fm-test-portable-shards.md).
# --changed is conservative: it over-selects related families rather than
# under-selecting, and never expands to the complete suite unless --all.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

# Used by the parallel worker isolation check, which must distinguish a real
# permission failure from a platform that cannot express one.
# shellcheck source=bin/fm-platform-lib.sh
. "$ROOT/bin/fm-platform-lib.sh"

MODE=
LIST_ONLY=0
LIST_FAMILIES=0
LIST_LANES=0
CHECK_COVERAGE=0
AGGREGATE_OUT=
FAMILY=
LANE=
BASE_REF=origin/main
JSON_PATH=
SCRIPTS=()
EXCLUDE_FAMILIES=()
FAIL_ON_GATE_SKIP=
JOBS=1
JOBS_MAX=8

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
}

die() {
  printf 'fm-test-run: %s\n' "$*" >&2
  exit 2
}

log() {
  printf 'fm-test-run: %s\n' "$*" >&2
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# Probed exactly once at load, not per call: every caller uses $(now_ms), so a
# lazy in-function cache would live and die inside that subshell and re-probe
# every time. Resolving here means subshells inherit the answer.
#
# Whether python3 is usable is decided by fm_platform_python3_works, not by
# looking for it on PATH - the old probe here trusted presence and got a
# non-numeric string back, failing every caller's arithmetic.
#
# GNU date's %3N is the next-best source (Linux and Git Bash have it; stock
# macOS date does not, where it yields a literal "N" and is rejected here).
# Thin alias so this file's call sites stay readable. The single owner of "does
# python3 actually run" is fm_platform_python3_works in bin/fm-platform-lib.sh,
# sourced above - this bug reappeared three times from per-file copies, so there
# is exactly one implementation now.
python3_works() { fm_platform_python3_works; }

fm_probe_now_ms_mode() {
  local probe
  if python3_works; then
    printf 'python\n'
    return 0
  fi
  probe=$(date +%s%3N 2>/dev/null || true)
  case "$probe" in
    ''|*[!0-9]*) printf 'seconds\n' ;;
    *) printf 'gnudate\n' ;;
  esac
}
FM_NOW_MS_MODE=${FM_NOW_MS_MODE:-$(fm_probe_now_ms_mode)}

now_ms() {
  case "$FM_NOW_MS_MODE" in
    python) python3 -c 'import time; print(int(time.time() * 1000))' ;;
    gnudate) date +%s%3N ;;
    # Second precision only when no millisecond source works.
    *) echo $(($(date +%s) * 1000)) ;;
  esac
}

# Primary family for one tests/*.test.sh basename. Unmapped scripts are
# unclassified so new tests are still runnable and visible in summaries.
family_for_basename() {
  case "$1" in
    fm-arm-pretool-check.test.sh|fm-ask-user-authority.test.sh|fm-brief.test.sh|\
    fm-calm-pi-extension.test.sh|fm-captain-translation-contract.test.sh|fm-cd-pretool-check.test.sh|\
    fm-composer-ghost.test.sh|fm-composer-lib.test.sh|\
    fm-crew-state.test.sh|fm-decision-hold-lifecycle.test.sh|\
    fm-documentation-audiences.test.sh|fm-ensure-agents-md.test.sh|fm-grok-harness.test.sh|\
    fm-kimi-harness.test.sh|fm-herdr-lab.test.sh|fm-instruction-owners.test.sh|fm-lint.test.sh|\
    fm-install-herdr.test.sh|fm-nm-test-contract.test.sh|fm-no-mistakes-ownership.test.sh|\
    fm-operational-input.test.sh|fm-pi-primary-types.test.sh|\
    fm-send-popup-settle.test.sh|fm-send-settle.test.sh|fm-stow-contract.test.sh|\
    fm-subagent-pretool-check.test.sh|\
    fm-supervision-instructions.test.sh|fm-tmux-submit-busy.test.sh|fm-transition-lib.test.sh|\
    fm-test-run.test.sh|fm-test-isolation-proof.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-daemon.test.sh|fm-guard-stale-banner.test.sh|fm-pi-watch-extension.test.sh|\
    fm-supervision-events.test.sh|fm-turnend-guard.test.sh|fm-wake-daemon-lifecycle-e2e.test.sh|\
    fm-wake-queue.test.sh|fm-watch-checkpoint.test.sh|fm-watch-triage.test.sh|\
    fm-watcher-lock.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    fm-afk-inject-herdr-e2e.test.sh|fm-afk-launch.test.sh|fm-backend-autodetect-smoke.test.sh|\
    fm-backend-herdr-eventwait-smoke.test.sh|fm-backend-herdr-presentation-e2e.test.sh|\
    fm-backend-herdr-prune-safety-e2e.test.sh|fm-backend-herdr-respawn-idem-e2e.test.sh|\
    fm-herdr-session-cleanup-e2e.test.sh|\
    fm-backend-herdr-smoke.test.sh|fm-backend-herdr-workspace-per-home-e2e.test.sh)
      printf '%s\n' real-herdr-gated
      ;;
    fm-backlog-handoff.test.sh|fm-secondmate-harness.test.sh|fm-secondmate-lifecycle-e2e.test.sh|\
    fm-secondmate-liveness.test.sh|fm-secondmate-safety.test.sh|fm-secondmate-sync.test.sh|\
    fm-send-secondmate-marker.test.sh|fm-shared-captain-inheritance.test.sh)
      printf '%s\n' secondmate
      ;;
    fm-bootstrap.test.sh|fm-fleet-sync.test.sh|fm-gate-refuse.test.sh|fm-gotmp.test.sh|\
    fm-session-start.test.sh|fm-sessionstart-nudge.test.sh|fm-tangle-guard.test.sh|\
    fm-update.test.sh)
      printf '%s\n' session-bootstrap
      ;;
    fm-afk-pi-herdr-return-e2e.test.sh|\
    fm-codex-continuity-live-e2e.test.sh|fm-grok-continuity-live-e2e.test.sh|\
    fm-grok-stop-live-e2e.test.sh|fm-opencode-primary-live-e2e.test.sh|fm-pi-primary-live-e2e.test.sh|\
    fm-send-secondmate-marker-herdr-e2e.test.sh)
      printf '%s\n' live-harness-optin
      ;;
    fm-backend-herdr.test.sh|fm-backend-tmux-smoke.test.sh|fm-backend.test.sh|\
    fm-herdr-session-cleanup.test.sh|fm-send-strict.test.sh|fm-spawn-batch.test.sh|\
    fm-spawn-dispatch-profile.test.sh|fm-spawn-worktree-settle.test.sh|\
    fm-teardown-endpoint-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-pr-check-security.test.sh|fm-pr-merge.test.sh|fm-review-diff.test.sh|\
    fm-teardown.test.sh|fm-x-mode.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-afk-inject-e2e.test.sh|fm-afk-return.test.sh)
      printf '%s\n' afk
      ;;
    fm-bearings-snapshot.test.sh|fm-fleet-snapshot-view.test.sh)
      printf '%s\n' snapshot-bearings
      ;;
    fm-backend-cmux.test.sh|fm-backend-cmux-smoke.test.sh)
      printf '%s\n' cmux
      ;;
    fm-backend-zellij.test.sh|fm-backend-zellij-smoke.test.sh)
      printf '%s\n' zellij
      ;;
    fm-backend-orca.test.sh)
      printf '%s\n' orca
      ;;
    *)
      printf '%s\n' unclassified
      ;;
  esac
}

expected_gate_skip_for_family() {
  case "$1" in
    real-herdr-gated) printf '%s\n' herdr ;;
    live-harness-optin) printf '%s\n' optin-env ;;
    cmux|zellij|orca) printf '%s\n' optional-binary ;;
    snapshot-bearings) printf '%s\n' optional-binary ;;
    *) printf '%s\n' none ;;
  esac
}

list_known_families() {
  cat <<'EOF'
pure-contract-unit
watcher-wake-lock
real-herdr-gated
secondmate
session-bootstrap
live-harness-optin
backend-dispatch
pr-forge
afk
snapshot-bearings
cmux
zellij
orca
unclassified
EOF
}

list_known_lanes() {
  cat <<'EOF'
portable-parallel-1
portable-parallel-2
portable-serial
real-herdr-gated
windows-gitbash
windows-gitbash-parallel
windows-gitbash-serial
EOF
}

# Scripts measured green on native Windows Git Bash (MINGW64), one script per
# line. Unlike the portable shards and the serial remainder, this lane is a
# SELECTOR, not a member of the complete-regression partition: it deliberately
# overlaps the other lanes and is not enumerated by run_coverage_guard, so
# adding to it can never break the partition proof.
#
# Membership rule: the script must exit 0, report at least one "ok - "
# assertion, and report no "not ok" on Windows Git Bash. A script that exits 0
# only because it gate-skipped (missing tasks-axi, tsc, tmux, ...) is NOT
# eligible - a skip is absence of coverage, not evidence of a pass.
#
# This list is expected to GROW as the Windows layer lands. Anything absent is
# either blocked on a known gap (lsof/flock/setsid, tmux) or simply not measured
# yet. Re-measure with a full run before adding entries; do not add from
# intuition.
#
# A flaky script is as disqualifying as a failing one, because a lane nobody
# trusts is worse than no lane. Two scripts were held out under that rule and
# have since been repaired rather than waived:
#
#   fm-wake-daemon-lifecycle-e2e.test.sh failed 2 of 3 runs on timing alone.
#   tests/wake-helpers.sh's wait_for_exit budget is now substrate-scaled.
#
#   fm-claude-stop-autoarm.test.sh failed once with exit 127 and hung once in a
#   full lane. Its background fake harness held the test's stdout pipe, so the
#   orphaned child blocked whoever was reading it; that output is now redirected.
#
# Neither was added back on the strength of a standalone pass - each had to
# survive the context that exposed it.
list_windows_gitbash() {
  cat <<'EOF'
tests/fm-afk-return.test.sh
tests/fm-ask-user-authority.test.sh
tests/fm-backend-herdr-respawn-idem-e2e.test.sh
tests/fm-backlog-handoff.test.sh
tests/fm-brief.test.sh
tests/fm-calm-pi-extension.test.sh
tests/fm-captain-translation-contract.test.sh
tests/fm-claude-stop-autoarm.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-gate-refuse.test.sh
tests/fm-gotmp.test.sh
tests/fm-guard-stale-banner.test.sh
tests/fm-install-herdr.test.sh
tests/fm-instruction-owners.test.sh
tests/fm-lint.test.sh
tests/fm-nm-test-contract.test.sh
tests/fm-no-mistakes-ownership.test.sh
tests/fm-platform-lib.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-secondmate-marker.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-stow-contract.test.sh
tests/fm-supervision-events.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-tangle-guard.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-update.test.sh
tests/fm-wake-daemon-lifecycle-e2e.test.sh
tests/no-mistakes-required-workflow.test.sh
EOF
}

# Windows ledger: every tests/*.test.sh that is NOT in list_windows_gitbash,
# with the reason it is not, as "<path><TAB><reason>".
#
# The lane above is an allow-list and is deliberately outside the partition
# proof, so nothing there can fail because a script is missing from it. This
# list is what makes the gap countable: run_coverage_guard requires every test
# to be in exactly one of the two, so a new test cannot land silently uncovered.
# An upstream sync added two test scripts that landed outside the lane and
# nothing reported it - "never measured" then looks exactly like "covered".
#
# A permanent reason is fine and stays: there is no tmux on Windows and there
# never will be. What is not fine is an entry with no reason, or a reason that
# says only "not measured". The reasons ARE the burn-down list; the ledger is
# expected to shrink.
#
# Every reason below was measured, not assumed. Where a cause was checked rather
# than guessed it says so - bootstrap really does find git outside the fixture,
# so those entries name the fixture PATH rather than blaming the product.
list_windows_excluded() {
  cat <<'EOF'
tests/fm-afk-inject-e2e.test.sh	gate-skips here: tmux not found
tests/fm-afk-inject-herdr-e2e.test.sh	fails on Windows:  Scenario A: human text not in log after submit
tests/fm-afk-launch.test.sh	fails on Windows:  launcher signal: interrupted lifecycle resumed or retained its lock
tests/fm-afk-pi-herdr-return-e2e.test.sh	gate-skips here: set FM_AFK_PI_HERDR_E2E=1 to run the real Pi/Herdr away-return regression
tests/fm-arm-pretool-check.test.sh	fails on Windows:  D01 via codex must deny, got exit 0
tests/fm-backend-autodetect-smoke.test.sh	fails on Windows:  fm-spawn.sh did not succeed auto-detecting herdr
tests/fm-backend-cmux-smoke.test.sh	gate-skips here: cmux CLI not found on PATH or at the bundle path
tests/fm-backend-cmux.test.sh	fails on Windows:  capture should trim to the last N lines locally, got 'line three
tests/fm-backend-herdr-eventwait-smoke.test.sh	gate-skips here: this herdr build is below the events.subscribe capability (protocol < 16 or events surface absent)
tests/fm-backend-herdr-presentation-e2e.test.sh	fails on Windows:  flag-off anchor spawn failed: 🌳 Setting up worktree...
tests/fm-backend-herdr-prune-safety-e2e.test.sh	fails on Windows:  the live heartbeat process did not start writing its marker file
tests/fm-backend-herdr-smoke.test.sh	herdr does not report foreground_cwd on Windows (docs/windows-gitbash.md)
tests/fm-backend-herdr-workspace-per-home-e2e.test.sh	fails on Windows:  primary-shaped crewmate spawn failed
tests/fm-backend-herdr.test.sh	fails on Windows:  create_task should close-and-replace all same-labeled husks after cre
tests/fm-backend-tmux-smoke.test.sh	gate-skips here: tmux not found
tests/fm-backend-zellij-smoke.test.sh	gate-skips here: zellij not found
tests/fm-backend-orca.test.sh	passes on a developer Windows box but fails Orca scout teardown on the CI windows runner; promote only once both agree
tests/fm-backend-zellij.test.sh	passes on a developer Windows box but fails zellij scout teardown on the CI windows runner; promote only once both agree
tests/fm-backend.test.sh	known pre-existing symlinked-prefix gap; green on ubuntu
tests/fm-bearings-snapshot.test.sh	fails on Windows:  stale parent Phase 7 event overrode authoritative Domain Alpha state:
tests/fm-bootstrap.test.sh	fixture PATH lacks git; bootstrap itself finds git correctly outside the fixture
tests/fm-cd-pretool-check.test.sh	fails on Windows:  transport must fail open when node is unavailable: expected exit 0, g
tests/fm-claude-stop-autoarm-live-e2e.test.sh	gate-skips here: set FM_CLAUDE_LIVE_E2E=1 to run the Claude Stop auto-arm regression
tests/fm-codex-continuity-live-e2e.test.sh	gate-skips here: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression
tests/fm-composer-lib.test.sh	fails on Windows:  the idle placeholder after a glyph should read empty, got 'pending'
tests/fm-crew-state.test.sh	fails on Windows:  timed-out no-mistakes falls back to pane (missing: 'state: working')
tests/fm-daemon.test.sh	asserts on a chmod-unwritable directory; NTFS does not honour that
tests/fm-decision-hold-lifecycle.test.sh	FAILS consistently on a quiet machine; its earlier pass was measured under load
tests/fm-documentation-audiences.test.sh	fails on Windows:  repository documentation audience check failed
tests/fm-ensure-agents-md.test.sh	fails on Windows:  CRLF AGENTS.md injection did not preserve CRLF line endings
tests/fm-fleet-snapshot-view.test.sh	needs a real tmux, which does not exist on Windows
tests/fm-fleet-sync.test.sh	fails on Windows:  bootstrap relays the STUCK outcome (missing: 'FLEET_SYNC: stuck-clone
tests/fm-grok-continuity-live-e2e.test.sh	gate-skips here: set FM_GROK_LIVE_E2E=1 to run the interactive Grok continuity regression
tests/fm-grok-harness.test.sh	stubs ps to stage a harness; the Windows paths read the process table instead (FM_PLATFORM_*_SNAPSHOT can stage it)
tests/fm-grok-stop-live-e2e.test.sh	gate-skips here: set FM_GROK_STOP_LIVE_E2E=1 with FM_GROK_NATIVE_BIN and FM_GROK_LEGACY_BIN
tests/fm-herdr-lab.test.sh	fails on Windows:  timed-out provision must fail: expected exit 1, got 0
tests/fm-herdr-session-cleanup-e2e.test.sh	fails on Windows:  restored child did not converge to the exact childless idle-shell pro
tests/fm-herdr-session-cleanup.test.sh	FLAKY here: passed one clean round and failed the next
tests/fm-kimi-harness.test.sh	fails on Windows:  Kimi hook install refused a realistic config
tests/fm-opencode-primary-live-e2e.test.sh	gate-skips here: set FM_OPENCODE_LIVE_E2E=1 to run the interactive OpenCode continuity regression
tests/fm-operational-input.test.sh	fails on Windows:  OpenCode cross-language adapter could not invoke the canonical owner
tests/fm-pending-reply.test.sh	fails on Windows:  recovery should send after completed turn + grace
tests/fm-pi-primary-live-e2e.test.sh	gate-skips here: set FM_PI_LIVE_E2E=1 to run the isolated interactive Pi regression
tests/fm-pi-primary-types.test.sh	gate-skips here: tsc not found for Pi extension typecheck
tests/fm-pi-watch-extension.test.sh	fails on Windows:  Pi extension must surface an external healthy watcher as an owned-wak
tests/fm-pr-check-security.test.sh	fails on Windows:  parser accepted a rejected raw-byte URL class
tests/fm-pr-merge.test.sh	fails on Windows:  records-before-merge: fm-pr-merge should succeed: expected exit 0, go
tests/fm-quota-array-dispatch.test.sh	fails on Windows:  schema v3 shape fixture is invalid
tests/fm-secondmate-harness.test.sh	stubs ps to stage a harness; the Windows paths read the process table instead (FM_PLATFORM_*_SNAPSHOT can stage it)
tests/fm-secondmate-lifecycle-e2e.test.sh	fails on Windows:  secondmate spawn failed
tests/fm-secondmate-liveness.test.sh	fails on Windows:  a successful missing-window recovery should stay silent by default (u
tests/fm-secondmate-safety.test.sh	fails on Windows:  fm-pr-check failed under FM_HOME
tests/fm-secondmate-sync.test.sh	fixture PATH lacks git; bootstrap itself finds git correctly outside the fixture
tests/fm-send-popup-settle.test.sh	HANGS intermittently: 145s in one clean round, still running after 2h in the next
tests/fm-send-secondmate-marker-herdr-e2e.test.sh	gate-skips here: set FM_SEND_MARKER_HERDR_E2E=1 to run the real Pi/Herdr secondmate-marker regression
tests/fm-session-start.test.sh	fails on Windows:  read-only banner did not surface fm-lock.sh's own error text (missing
tests/fm-sessionstart-nudge.test.sh	fails on Windows:  owned lock nudge must be silent, got: ⁣FIRSTMATE_OP: v1 session-sta
tests/fm-shared-captain-inheritance.test.sh	asserts on a chmod-unwritable directory; NTFS does not honour that
tests/fm-spawn-dispatch-profile.test.sh	fails on Windows:  claude spawn without profile flags should succeed: expected exit 0, g
tests/fm-spawn-worktree-settle.test.sh	fails on Windows:  already-settled pane took 18s to confirm - expected close to the sing
tests/fm-subagent-pretool-check.test.sh	fails on Windows: the missing-jq transport should fail open but exits 127
tests/fm-teardown-endpoint-safety.test.sh	fails on Windows:  recorded target pid no longer belongs to the expected child
tests/fm-teardown.test.sh	fails on Windows:  confirmed exact-pane close did not retire the presentation journal
tests/fm-test-isolation-proof.test.sh	fails on Windows:  candidate set must exactly match the archived isolation proof
tests/fm-test-run.test.sh	fails on Windows:  empty valid changed selection must pass
tests/fm-turnend-guard.test.sh	fails on Windows:  hook must fail open (exit 0) when jq is unavailable: expected exit 0,
tests/fm-wake-queue.test.sh	fails on Windows:  could not register queue custom check
tests/fm-watch-checkpoint.test.sh	fails on Windows:  signal checkpoint exit: expected exit 0, got 124
tests/fm-watch-triage.test.sh	NOT YET MEASURED on Windows
tests/fm-watcher-lock.test.sh	NOT YET MEASURED on Windows
tests/fm-x-mode.test.sh	NOT YET MEASURED on Windows
EOF
}

# Exact Phase 2 proven-isolated candidate set (same paths as
# bin/fm-test-isolation-proof.sh --list). Do not expand without a new concurrent
# isolation proof archive.
list_proven_isolated() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-brief.test.sh
tests/fm-captain-translation-contract.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-composer-lib.test.sh
tests/fm-crew-state.test.sh
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-grok-harness.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-instruction-owners.test.sh
tests/fm-lint.test.sh
tests/fm-nm-test-contract.test.sh
tests/fm-no-mistakes-ownership.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-pr-merge.test.sh
tests/fm-review-diff.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-send-settle.test.sh
tests/fm-send-strict.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-stow-contract.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-test-run.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-transition-lib.test.sh
tests/fm-x-mode.test.sh
EOF
}

# Portable parallel shard 1: LPT balance of the proven-isolated set using
# Phase 1 serial duration averages from CI timing artifacts on main after
# #825/#832/#834 (docs/fm-test-portable-shards.md). Execution order is longest
# first so wall-clock stays near the balanced sum.
list_portable_parallel_1() {
  cat <<'EOF'
tests/fm-arm-pretool-check.test.sh
tests/fm-cd-pretool-check.test.sh
tests/fm-backend-herdr.test.sh
tests/fm-pr-merge.test.sh
tests/fm-test-run.test.sh
tests/fm-send-popup-settle.test.sh
tests/fm-review-diff.test.sh
tests/fm-brief.test.sh
tests/fm-ensure-agents-md.test.sh
tests/fm-instruction-owners.test.sh
tests/fm-pi-primary-types.test.sh
tests/fm-transition-lib.test.sh
tests/fm-composer-lib.test.sh
tests/fm-stow-contract.test.sh
EOF
}

# Portable parallel shard 2: the complementary LPT half of the proven set.
list_portable_parallel_2() {
  cat <<'EOF'
tests/fm-decision-hold-lifecycle.test.sh
tests/fm-x-mode.test.sh
tests/fm-herdr-lab.test.sh
tests/fm-crew-state.test.sh
tests/fm-grok-harness.test.sh
tests/fm-spawn-batch.test.sh
tests/fm-send-strict.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-send-settle.test.sh
tests/fm-supervision-instructions.test.sh
tests/fm-lint.test.sh
tests/fm-nm-test-contract.test.sh
tests/fm-captain-translation-contract.test.sh
tests/fm-no-mistakes-ownership.test.sh
EOF
}

is_proven_isolated_script() {
  local want=$1 line
  while IFS= read -r line; do
    [ "$line" = "$want" ] && return 0
  done < <(list_proven_isolated)
  return 1
}

select_proven_isolated() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(list_proven_isolated)
}

select_lane() {
  local want=$1 s base fam found=0
  case "$want" in
    portable-parallel-1)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_1)
      ;;
    portable-parallel-2)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_portable_parallel_2)
      ;;
    portable-serial)
      # Everything in the complete suite that is not proven-isolated and not
      # real-herdr-gated. Watcher/lock/AFK/tmux/daemon/ambiguous/stateful work
      # stays here, serial only.
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        base=$(basename "$s")
        fam=$(family_for_basename "$base")
        if [ "$fam" = "real-herdr-gated" ]; then
          continue
        fi
        if is_proven_isolated_script "$s"; then
          continue
        fi
        add_script "$s"
        found=1
      done < <(all_repo_tests)
      ;;
    real-herdr-gated)
      select_family real-herdr-gated
      found=1
      ;;
    windows-gitbash)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        add_script "$s"
        found=1
      done < <(list_windows_gitbash)
      ;;
    # The two halves of windows-gitbash, split by --jobs eligibility. DERIVED
    # from the one list plus the proven-isolated set rather than restated, so
    # they cannot drift out of sync with it.
    windows-gitbash-parallel)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        is_proven_isolated_script "$s" || continue
        add_script "$s"
        found=1
      done < <(list_windows_gitbash)
      ;;
    windows-gitbash-serial)
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        is_proven_isolated_script "$s" && continue
        add_script "$s"
        found=1
      done < <(list_windows_gitbash)
      ;;
    *)
      die "unknown lane '$want' (see --list-lanes)"
      ;;
  esac
  [ "$found" -eq 1 ] || die "lane '$want' selected no tests"
}

run_coverage_guard() {
  local tmp missing extra a b
  local -a saved_scripts=()
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-coverage.XXXXXX")

  all_repo_tests | LC_ALL=C sort -u >"$tmp/all"
  list_proven_isolated | LC_ALL=C sort -u >"$tmp/proven"
  list_portable_parallel_1 | LC_ALL=C sort -u >"$tmp/s1"
  list_portable_parallel_2 | LC_ALL=C sort -u >"$tmp/s2"

  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort | uniq -d >"$tmp/shard_dups"
  if [ -s "$tmp/shard_dups" ]; then
    log "coverage guard: portable parallel shards share scripts:"
    cat "$tmp/shard_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  cat "$tmp/s1" "$tmp/s2" | LC_ALL=C sort -u >"$tmp/shards_union"
  missing=$(comm -23 "$tmp/proven" "$tmp/shards_union" || true)
  extra=$(comm -13 "$tmp/proven" "$tmp/shards_union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: portable shards must equal the proven-isolated set"
    [ -z "$missing" ] || { log "missing from shards:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond proven:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  # Serial + Herdr lane listings without disturbing a caller's selection.
  saved_scripts=("${SCRIPTS[@]+"${SCRIPTS[@]}"}")
  SCRIPTS=()
  select_lane portable-serial
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/serial"
  SCRIPTS=()
  select_family real-herdr-gated
  printf '%s\n' "${SCRIPTS[@]+"${SCRIPTS[@]}"}" | LC_ALL=C sort -u >"$tmp/herdr"
  SCRIPTS=("${saved_scripts[@]+"${saved_scripts[@]}"}")

  for pair in "shards_union:serial" "shards_union:herdr" "serial:herdr"; do
    a=${pair%%:*}
    b=${pair#*:}
    comm -12 "$tmp/$a" "$tmp/$b" >"$tmp/overlap"
    if [ -s "$tmp/overlap" ]; then
      log "coverage guard: overlap between $a and $b:"
      cat "$tmp/overlap" >&2
      rm -rf "$tmp"
      return 1
    fi
  done

  cat "$tmp/shards_union" "$tmp/serial" "$tmp/herdr" | LC_ALL=C sort >"$tmp/union_raw"
  uniq -d "$tmp/union_raw" >"$tmp/union_dups"
  if [ -s "$tmp/union_dups" ]; then
    log "coverage guard: duplicate scripts across lanes:"
    cat "$tmp/union_dups" >&2
    rm -rf "$tmp"
    return 1
  fi
  LC_ALL=C sort -u "$tmp/union_raw" >"$tmp/union"
  missing=$(comm -23 "$tmp/all" "$tmp/union" || true)
  extra=$(comm -13 "$tmp/all" "$tmp/union" || true)
  if [ -n "$missing" ] || [ -n "$extra" ]; then
    log "coverage guard: union of portable shards + portable serial + Herdr must equal tests/*.test.sh"
    [ -z "$missing" ] || { log "missing from union:"; printf '%s\n' "$missing" >&2; }
    [ -z "$extra" ] || { log "extra beyond inventory:"; printf '%s\n' "$extra" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  if [ -x "$ROOT/bin/fm-test-isolation-proof.sh" ]; then
    "$ROOT/bin/fm-test-isolation-proof.sh" --list | LC_ALL=C sort -u >"$tmp/proof_list"
    if ! cmp -s "$tmp/proven" "$tmp/proof_list"; then
      log "coverage guard: embedded proven-isolated set diverges from bin/fm-test-isolation-proof.sh --list"
      comm -3 "$tmp/proven" "$tmp/proof_list" >&2 || true
      rm -rf "$tmp"
      return 1
    fi
  fi

  # Windows ledger. Unlike the partition above, the windows-gitbash lane is an
  # allow-list, so on its own it can never fail because a script is missing from
  # it - which is exactly how an upstream sync added two tests that landed
  # outside it with nothing reported. Requiring every test to be in EXACTLY one
  # of the lane or list_windows_excluded makes that impossible: a new test is
  # either covered on Windows or carries a written reason it is not.
  local win_bad win_both win_unclassified win_stale
  list_windows_gitbash | LC_ALL=C sort -u >"$tmp/win_lane"
  list_windows_excluded | cut -f1 | LC_ALL=C sort -u >"$tmp/win_excl"

  # A reason is the whole point of the ledger; an entry without one is just an
  # untracked gap wearing a different hat.
  win_bad=$(list_windows_excluded | awk -F'\t' 'NF < 2 || $2 ~ /^[[:space:]]*$/ { print $1 }')
  if [ -n "$win_bad" ]; then
    log "coverage guard: Windows ledger entries missing a reason:"
    printf '%s\n' "$win_bad" >&2
    rm -rf "$tmp"
    return 1
  fi

  win_both=$(comm -12 "$tmp/win_lane" "$tmp/win_excl" || true)
  if [ -n "$win_both" ]; then
    log "coverage guard: scripts both in the Windows lane and excluded from it:"
    printf '%s\n' "$win_both" >&2
    rm -rf "$tmp"
    return 1
  fi

  cat "$tmp/win_lane" "$tmp/win_excl" | LC_ALL=C sort -u >"$tmp/win_union"
  win_unclassified=$(comm -23 "$tmp/all" "$tmp/win_union" || true)
  win_stale=$(comm -13 "$tmp/all" "$tmp/win_union" || true)
  if [ -n "$win_unclassified" ] || [ -n "$win_stale" ]; then
    log "coverage guard: every test must be in the Windows lane or the ledger, with a reason"
    [ -z "$win_unclassified" ] || { log "in neither (add to one):"; printf '%s\n' "$win_unclassified" >&2; }
    [ -z "$win_stale" ] || { log "named but no longer exists:"; printf '%s\n' "$win_stale" >&2; }
    rm -rf "$tmp"
    return 1
  fi

  printf 'FM_TEST_COVERAGE ok total=%s parallel=%s serial=%s herdr=%s windows=%s windows_excluded=%s\n' \
    "$(wc -l <"$tmp/all" | tr -d ' ')" \
    "$(wc -l <"$tmp/shards_union" | tr -d ' ')" \
    "$(wc -l <"$tmp/serial" | tr -d ' ')" \
    "$(wc -l <"$tmp/herdr" | tr -d ' ')" \
    "$(wc -l <"$tmp/win_lane" | tr -d ' ')" \
    "$(wc -l <"$tmp/win_excl" | tr -d ' ')"
  rm -rf "$tmp"
  return 0
}

aggregate_timing_json() {
  local out=$1
  shift
  [ "$#" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  python3_works || die "--aggregate-json requires a working python3"
  python3 - "$out" "$@" <<'PY'
import json, sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [Path(p) for p in sys.argv[2:]]
lanes = []
all_scripts = []
failed = 0
skipped = 0
total = 0
wall_ms = 0
for path in inputs:
    doc = json.loads(path.read_text(encoding="utf-8"))
    summary = doc.get("summary") or {}
    lane = {
        "path": str(path),
        "run_id": doc.get("run_id"),
        "selection": doc.get("selection"),
        "started_at": doc.get("started_at"),
        "finished_at": doc.get("finished_at"),
        "summary": summary,
    }
    lanes.append(lane)
    total += int(summary.get("total") or 0)
    failed += int(summary.get("failed") or 0)
    skipped += int(summary.get("skipped_gate") or 0)
    wall_ms = max(wall_ms, int(summary.get("duration_ms") or 0))
    for s in doc.get("scripts") or []:
        row = dict(s)
        row["lane_selection"] = doc.get("selection")
        row["lane_run_id"] = doc.get("run_id")
        all_scripts.append(row)

all_scripts.sort(key=lambda s: (-int(s.get("duration_ms") or 0), s.get("path") or ""))
agg = {
    "kind": "aggregate",
    "lanes": lanes,
    "summary": {
        "lanes": len(lanes),
        "total": total,
        "failed": failed,
        "skipped_gate": skipped,
        "critical_path_duration_ms": wall_ms,
    },
    "scripts": all_scripts,
    "slowest": all_scripts[:15],
}
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(agg, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"FM_TEST_AGGREGATE lanes={len(lanes)} total={total} failed={failed} skipped_gate={skipped} critical_path_duration_ms={wall_ms}")
PY
}

all_repo_tests() {
  # Deterministic lexical order (same as bash glob expansion under LC_ALL=C).
  local f
  # shellcheck disable=SC2035
  for f in tests/*.test.sh; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
  done | LC_ALL=C sort
}

normalize_script_path() {
  local p=$1
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    tests/*|./tests/*)
      p=${p#./}
      printf '%s\n' "$p"
      ;;
    *.test.sh)
      if [ -f "tests/$p" ]; then
        printf 'tests/%s\n' "$p"
      else
        printf '%s\n' "$p"
      fi
      ;;
    *)
      printf '%s\n' "$p"
      ;;
  esac
}

# Append unique relative-or-absolute script paths to SCRIPTS.
add_script() {
  local p existing
  p=$(normalize_script_path "$1")
  for existing in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    [ "$existing" = "$p" ] && return 0
  done
  SCRIPTS+=("$p")
}

select_all() {
  local s
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    add_script "$s"
  done < <(all_repo_tests)
}

select_family() {
  local want=$1 s base fam found=0
  [ -n "$want" ] || die "--family requires a name"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    base=$(basename "$s")
    fam=$(family_for_basename "$base")
    if [ "$fam" = "$want" ]; then
      add_script "$s"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ] || die "no tests mapped to family '$want'"
}

families_for_test_reference() {
  local needle=$1 s
  local found=0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -Fq "$needle" "$s"; then
      family_for_basename "$(basename "$s")"
      found=1
    fi
  done < <(all_repo_tests)
  [ "$found" -eq 1 ]
}

# Conservative path → family map. Over-selects rather than under-selects.
# Never expands to the complete suite.
families_for_changed_path() {
  local path=$1
  case "$path" in
    tests/fm-test-run.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    tests/fm-backend-herdr-eventwait.test.py)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    tests/*.test.sh)
      # A single test file change selects only that script via basename family
      # resolution in the caller; emit a marker family of __script__
      printf '%s\n' "__script__:$(basename "$path")"
      ;;
    bin/fm-test-run.sh|bin/fm-test-isolation-proof.sh)
      printf '%s\n' pure-contract-unit
      ;;
    bin/backends/herdr*|bin/fm-herdr-lab.sh|tests/herdr-test-safety.sh)
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-herdr-session-cleanup.sh)
      printf '%s\n' session-bootstrap
      printf '%s\n' real-herdr-gated
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/zellij*|tests/zellij-test-safety.sh)
      printf '%s\n' zellij
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/cmux*|tests/cmux-test-safety.sh)
      printf '%s\n' cmux
      printf '%s\n' backend-dispatch
      ;;
    bin/backends/orca*|bin/backends/tmux.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' orca
      ;;
    bin/fm-backend.sh|bin/fm-backend-hometag-lib.sh)
      printf '%s\n' backend-dispatch
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-watch*|bin/fm-wake*|\
    bin/fm-classify-lib.sh|bin/fm-daemon*|bin/fm-turnend-guard*|bin/fm-guard.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    bin/fm-afk*)
      printf '%s\n' afk
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-supervisor-target-lib.sh)
      printf '%s\n' watcher-wake-lock
      printf '%s\n' real-herdr-gated
      printf '%s\n' live-harness-optin
      printf '%s\n' afk
      ;;
    bin/fm-secondmate*|bin/fm-home-seed.sh|bin/fm-backlog-handoff.sh|\
    bin/fm-config-inherit-lib.sh|bin/fm-config-push.sh|bin/fm-shared*)
      printf '%s\n' secondmate
      ;;
    bin/fm-session-start.sh|bin/fm-bootstrap.sh|bin/fm-fleet-sync.sh|\
    bin/fm-sessionstart-nudge.sh|bin/fm-tangle*|bin/fm-update.sh|\
    bin/fm-gate-refuse*|bin/fm-lock*)
      printf '%s\n' session-bootstrap
      ;;
    bin/fm-pr-*|bin/fm-merge-local.sh|bin/fm-teardown.sh|bin/fm-review-diff.sh|\
    bin/fm-x-*|bin/fm-check*)
      printf '%s\n' pr-forge
      ;;
    bin/fm-spawn.sh|bin/fm-send.sh|bin/fm-harness.sh|\
    bin/fm-peek.sh|bin/fm-composer*)
      printf '%s\n' backend-dispatch
      printf '%s\n' pure-contract-unit
      ;;
    bin/fm-bearings-snapshot.sh|bin/fm-fleet-snapshot.sh|bin/fm-fleet-view.sh)
      printf '%s\n' snapshot-bearings
      ;;
    bin/fm-install-herdr.sh|bin/fm-install-treehouse.sh|bin/fm-herdr-ci-cleanup.sh)
      printf '%s\n' pure-contract-unit
      # Pin or cleanup changes also select the real-Herdr family so the required
      # lane's contract coverage re-runs.
      printf '%s\n' real-herdr-gated
      ;;
    bin/fm-lint.sh|bin/fm-install-shellcheck.sh|\
    bin/fm-brief.sh|bin/fm-ensure-agents-md.sh|bin/fm-crew-state.sh|\
    bin/fm-decision-hold.sh|bin/fm-supervision*|bin/fm-transition-lib.sh|\
    bin/fm-tmux-lib.sh|bin/fm-marker-lib.sh|bin/fm-operational-input.sh|bin/fm-tasks-axi-lib.sh|\
    bin/fm-primary-scope-lib.sh|bin/fm-project-mode.sh|bin/fm-promote.sh|\
    bin/fm-ff-lib.sh|bin/fm-gotmp*|bin/*pretool*)
      printf '%s\n' pure-contract-unit
      ;;
    .agents/skills/*/SKILL.md)
      printf '%s\n' pure-contract-unit
      ;;
    .github/workflows/ci.yml|.no-mistakes.yaml)
      printf '%s\n' pure-contract-unit
      printf '%s\n' real-herdr-gated
      ;;
    docs/fm-test-portable-shards.md|docs/fm-test-isolation-proof.md|\
    docs/fm-test-isolation-proof.json)
      printf '%s\n' pure-contract-unit
      ;;
    .github/*|.tasks.toml|AGENTS.md|CLAUDE.md|CONTRIBUTING.md|\
    docs/configuration.md|docs/supervision-protocols/*)
      printf '%s\n' pure-contract-unit
      ;;
    tests/lib.sh|tests/*-helpers.sh)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    bin/*)
      families_for_test_reference "$(basename "$path")" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
    tests/*)
      printf '%s\n' "__unmapped__:$path"
      ;;
    README.md|LICENSE|assets/*|docs/*|.gitignore)
      ;;
    *)
      families_for_test_reference "$path" \
        || printf '%s\n' "__unmapped__:$path"
      ;;
  esac
}

select_changed() {
  local base=$1 path entry fam script_name s
  local -a wanted_families=()
  local -a wanted_scripts=()

  if ! git -C "$ROOT" rev-parse --verify "$base" >/dev/null 2>&1; then
    die "changed-file base ref not found: $base (pass --base <ref>)"
  fi

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      case "$entry" in
        __script__:*)
          script_name=${entry#__script__:}
          wanted_scripts+=("$script_name")
          ;;
        __unmapped__:*)
          die "no changed-test mapping for source path: ${entry#__unmapped__:}"
          ;;
        *)
          wanted_families+=("$entry")
          ;;
      esac
    done < <(families_for_changed_path "$path")
  done < <(git -C "$ROOT" diff --name-only "${base}...HEAD" 2>/dev/null; \
           git -C "$ROOT" diff --name-only HEAD 2>/dev/null; \
           git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null)

  # Dedup families
  local f seen_f
  local -a unique_families=()
  for f in "${wanted_families[@]+"${wanted_families[@]}"}"; do
    seen_f=0
    for u in "${unique_families[@]+"${unique_families[@]}"}"; do
      [ "$u" = "$f" ] && { seen_f=1; break; }
    done
    [ "$seen_f" -eq 0 ] && unique_families+=("$f")
  done

  for f in "${unique_families[@]+"${unique_families[@]}"}"; do
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if [ "$(family_for_basename "$(basename "$s")")" = "$f" ]; then
        add_script "$s"
      fi
    done < <(all_repo_tests)
  done

  for script_name in "${wanted_scripts[@]+"${wanted_scripts[@]}"}"; do
    if [ -f "tests/$script_name" ]; then
      add_script "tests/$script_name"
    fi
  done

  if [ "${#SCRIPTS[@]}" -eq 0 ]; then
    log "no tests selected for changes vs $base (map is conservative; use --all for the complete suite)"
  fi
}

detect_gate_skip() {
  # True when the first non-empty output line is a skip: gate message.
  local file=$1 first
  first=$(awk 'NF { print; exit }' "$file" 2>/dev/null || true)
  case "$first" in
    skip:*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when any output line contains "skip: <token>" (token may contain spaces).
detect_gate_skip_token() {
  local file=$1 token=$2
  [ -n "$token" ] || return 1
  grep -F -q "skip: $token" "$file" 2>/dev/null
}

apply_exclude_families() {
  local s fam keep ex
  local -a kept=()
  [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ] || return 0
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    fam=$(family_for_basename "$(basename "$s")")
    keep=1
    for ex in "${EXCLUDE_FAMILIES[@]}"; do
      if [ "$fam" = "$ex" ]; then
        keep=0
        break
      fi
    done
    [ "$keep" -eq 1 ] && kept+=("$s")
  done
  SCRIPTS=("${kept[@]+"${kept[@]}"}")
}

write_json_artifact() {
  local out=$1
  local started=$2
  local finished=$3
  local run_id=$4
  local total=$5
  local failed=$6
  local skipped=$7
  local duration=$8
  local selection=$9
  local records_file=${10}
  local families_file=${11}

  if ! python3_works; then
    die "--json requires a working python3 to emit a valid timing artifact"
  fi

  python3 - "$out" "$started" "$finished" "$run_id" "$total" "$failed" "$skipped" "$duration" "$selection" "$records_file" "$families_file" <<'PY'
import json, sys

out, started, finished, run_id, total, failed, skipped, duration, selection, records_file, families_file = sys.argv[1:]

scripts = []
with open(records_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        path, family, expected, exit_s, dur_s, gate = line.split("\t")
        scripts.append({
            "path": path,
            "family": family,
            "expected_gate_skip": expected,
            "duration_ms": int(dur_s),
            "exit": int(exit_s),
            "gate_skip": gate == "true",
        })

families = []
with open(families_file, encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        name, count_s, dur_s, failed_s = line.split("\t")
        families.append({
            "name": name,
            "count": int(count_s),
            "duration_ms": int(dur_s),
            "failed": int(failed_s),
        })

doc = {
    "run_id": run_id,
    "started_at": started,
    "finished_at": finished,
    "selection": selection,
    "summary": {
        "total": int(total),
        "failed": int(failed),
        "skipped_gate": int(skipped),
        "duration_ms": int(duration),
    },
    "scripts": scripts,
    "families": families,
}
with open(out, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --all)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=all
      shift
      ;;
    --family)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--family requires a name"
      MODE=family
      FAMILY=$2
      shift 2
      ;;
    --family=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=family
      FAMILY=${1#--family=}
      shift
      ;;
    --lane)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      [ "$#" -gt 1 ] || die "--lane requires a name (see --list-lanes)"
      MODE=lane
      LANE=$2
      shift 2
      ;;
    --lane=*)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=lane
      LANE=${1#--lane=}
      shift
      ;;
    --proven-isolated)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=proven-isolated
      shift
      ;;
    --changed)
      [ -z "$MODE" ] || die "only one selection mode is allowed"
      MODE=changed
      shift
      ;;
    --base)
      [ "$#" -gt 1 ] || die "--base requires a git ref"
      BASE_REF=$2
      shift 2
      ;;
    --base=*)
      BASE_REF=${1#--base=}
      shift
      ;;
    --json)
      [ "$#" -gt 1 ] || die "--json requires a path"
      JSON_PATH=$2
      shift 2
      ;;
    --json=*)
      JSON_PATH=${1#--json=}
      shift
      ;;
    --jobs)
      [ "$#" -gt 1 ] || die "--jobs requires a positive integer"
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#--jobs=}
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    --list-families)
      LIST_FAMILIES=1
      shift
      ;;
    --list-lanes)
      LIST_LANES=1
      shift
      ;;
    --check-coverage)
      CHECK_COVERAGE=1
      shift
      ;;
    --aggregate-json)
      [ "$#" -gt 1 ] || die "--aggregate-json requires an output path"
      AGGREGATE_OUT=$2
      shift 2
      # Remaining args after options will be collected as inputs below via MODE.
      # For aggregation we accept only input JSON paths as free args after this.
      MODE=aggregate
      ;;
    --exclude-family)
      [ "$#" -gt 1 ] || die "--exclude-family requires a name"
      EXCLUDE_FAMILIES+=("$2")
      shift 2
      ;;
    --exclude-family=*)
      EXCLUDE_FAMILIES+=("${1#--exclude-family=}")
      shift
      ;;
    --fail-on-gate-skip)
      [ "$#" -gt 1 ] || die "--fail-on-gate-skip requires a token (e.g. 'herdr not found')"
      FAIL_ON_GATE_SKIP=$2
      shift 2
      ;;
    --fail-on-gate-skip=*)
      FAIL_ON_GATE_SKIP=${1#--fail-on-gate-skip=}
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        SCRIPTS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      if [ "${MODE:-}" = "aggregate" ]; then
        SCRIPTS+=("$1")
      elif [ -z "$MODE" ] || [ "$MODE" = scripts ]; then
        MODE=scripts
        SCRIPTS+=("$1")
      else
        die "script paths cannot be combined with --$MODE"
      fi
      shift
      ;;
  esac
done

if [ "$LIST_FAMILIES" -eq 1 ]; then
  list_known_families
  exit 0
fi

if [ "$LIST_LANES" -eq 1 ]; then
  list_known_lanes
  exit 0
fi

if [ "$CHECK_COVERAGE" -eq 1 ]; then
  run_coverage_guard
  exit $?
fi

if [ "${MODE:-}" = "aggregate" ]; then
  [ -n "$AGGREGATE_OUT" ] || die "--aggregate-json requires an output path"
  [ "${#SCRIPTS[@]}" -gt 0 ] || die "--aggregate-json requires at least one input timing JSON"
  for s in "${SCRIPTS[@]}"; do
    [ -f "$s" ] || die "aggregate input not found: $s"
  done
  aggregate_timing_json "$AGGREGATE_OUT" "${SCRIPTS[@]}"
  exit 0
fi

case "$JOBS" in
  ''|*[!0-9]*) die "--jobs must be a positive integer" ;;
esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
[ "$JOBS" -le "$JOBS_MAX" ] || die "--jobs is capped at $JOBS_MAX (got $JOBS)"

case "${MODE:-}" in
  all)
    select_all
    SELECTION_DESC="all"
    ;;
  family)
    select_family "$FAMILY"
    SELECTION_DESC="family=$FAMILY"
    ;;
  lane)
    select_lane "$LANE"
    SELECTION_DESC="lane=$LANE"
    ;;
  proven-isolated)
    select_proven_isolated
    SELECTION_DESC="proven-isolated"
    ;;
  changed)
    select_changed "$BASE_REF"
    SELECTION_DESC="changed:base=$BASE_REF"
    ;;
  scripts)
    # Normalize and re-add through add_script for consistent paths.
    raw=("${SCRIPTS[@]}")
    SCRIPTS=()
    for s in "${raw[@]}"; do
      add_script "$s"
    done
    SELECTION_DESC="scripts"
    ;;
  *)
    die "select with --all, --family <name>, --lane <name>, --proven-isolated, --changed, or one or more script paths (see --help)"
    ;;
esac

apply_exclude_families
if [ "${#EXCLUDE_FAMILIES[@]}" -gt 0 ]; then
  SELECTION_DESC="${SELECTION_DESC};exclude-family=$(IFS=,; printf '%s' "${EXCLUDE_FAMILIES[*]}")"
fi
if [ -n "$FAIL_ON_GATE_SKIP" ]; then
  SELECTION_DESC="${SELECTION_DESC};fail-on-gate-skip=$FAIL_ON_GATE_SKIP"
fi
if [ "$JOBS" -gt 1 ]; then
  SELECTION_DESC="${SELECTION_DESC};jobs=$JOBS"
fi

if [ "$LIST_ONLY" -eq 1 ]; then
  for s in "${SCRIPTS[@]+"${SCRIPTS[@]}"}"; do
    printf '%s\n' "$s"
  done
  exit 0
fi

if [ "${#SCRIPTS[@]}" -eq 0 ]; then
  log "nothing to run"
  printf 'FM_TEST_SUMMARY total=0 failed=0 skipped_gate=0 duration_ms=0\n'
  if [ -n "$JSON_PATH" ]; then
    empty_rec=$(mktemp)
    empty_fam=$(mktemp)
    : >"$empty_rec"
    : >"$empty_fam"
    started=$(now_iso)
    mkdir -p "$(dirname "$JSON_PATH")"
    write_json_artifact "$JSON_PATH" "$started" "$started" "empty" 0 0 0 0 "$SELECTION_DESC" "$empty_rec" "$empty_fam"
    rm -f "$empty_rec" "$empty_fam"
  fi
  exit 0
fi

# Verify selected scripts exist before starting.
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || die "test script not found: $s"
  [ -x "$s" ] || [ -r "$s" ] || die "test script not readable: $s"
done

# --jobs N>1 only for the proven-isolated set. Stateful families stay serial.
if [ "$JOBS" -gt 1 ]; then
  for s in "${SCRIPTS[@]}"; do
    if ! is_proven_isolated_script "$s"; then
      die "--jobs $JOBS refused: $s is not in the proven-isolated set (see bin/fm-test-isolation-proof.sh --list). Stateful families stay serial."
    fi
  done
fi

RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-run.XXXXXX")
RECORDS="$RUN_TMP/records.tsv"
FAMILIES_TSV="$RUN_TMP/families.tsv"
: >"$RECORDS"
trap 'rm -rf "$RUN_TMP"' EXIT

RUN_STARTED_ISO=$(now_iso)
RUN_STARTED_MS=$(now_ms)
RUN_ID="fm-test-run-${RUN_STARTED_MS}-$$"
TOTAL=0
FAILED=0
SKIPPED_GATE=0
AGG_RC=0

# Family accumulators as TSV lines updated in-memory via temp files.
# family -> count, duration_ms, failed
family_bump() {
  local fam=$1 dur=$2 failed_delta=$3
  local line name count duration failed_count rest
  local found=0
  local tmp="$RUN_TMP/families.new"
  : >"$tmp"
  if [ -s "$FAMILIES_TSV" ]; then
    while IFS= read -r line; do
      name=${line%%$'\t'*}
      rest=${line#*$'\t'}
      count=${rest%%$'\t'*}
      rest=${rest#*$'\t'}
      duration=${rest%%$'\t'*}
      failed_count=${rest#*$'\t'}
      if [ "$name" = "$fam" ]; then
        count=$((count + 1))
        duration=$((duration + dur))
        failed_count=$((failed_count + failed_delta))
        found=1
      fi
      printf '%s\t%s\t%s\t%s\n' "$name" "$count" "$duration" "$failed_count" >>"$tmp"
    done <"$FAMILIES_TSV"
  fi
  if [ "$found" -eq 0 ]; then
    printf '%s\t%s\t%s\t%s\n' "$fam" 1 "$dur" "$failed_delta" >>"$tmp"
  fi
  mv "$tmp" "$FAMILIES_TSV"
}

record_script_result() {
  local script=$1 rc=$2 duration=$3 out=$4 end_iso=$5
  local base family expected gate_skip fail_delta
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")

  if [ -n "$FAIL_ON_GATE_SKIP" ] && detect_gate_skip_token "$out" "$FAIL_ON_GATE_SKIP"; then
    log "required gate skip token seen in $script: skip: $FAIL_ON_GATE_SKIP"
    rc=1
  fi

  gate_skip=false
  if [ "$rc" -eq 0 ] && detect_gate_skip "$out"; then
    gate_skip=true
    SKIPPED_GATE=$((SKIPPED_GATE + 1))
  fi

  printf 'FM_TEST_END %s %s exit=%s duration_ms=%s gate_skip=%s\n' \
    "$end_iso" "$script" "$rc" "$duration" "$gate_skip"

  fail_delta=0
  if [ "$rc" -ne 0 ]; then
    FAILED=$((FAILED + 1))
    fail_delta=1
    AGG_RC=1
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$script" "$family" "$expected" "$rc" "$duration" "$gate_skip" >>"$RECORDS"
  family_bump "$family" "$duration" "$fail_delta"
  TOTAL=$((TOTAL + 1))
}

run_one_serial() {
  local script=$1
  local base family expected out begin_iso begin_ms end_ms end_iso duration rc
  base=$(basename "$script")
  family=$(family_for_basename "$base")
  expected=$(expected_gate_skip_for_family "$family")
  out="$RUN_TMP/out.$TOTAL"
  begin_iso=$(now_iso)
  begin_ms=$(now_ms)

  printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
    "$begin_iso" "$script" "$family" "$expected"

  set +e
  # Stream live output while retaining a copy for gate-skip detection.
  # PIPESTATUS[0] is the test script; tee's exit is ignored for aggregate.
  bash "$script" 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  set -e
  : "${rc:=1}"

  end_ms=$(now_ms)
  end_iso=$(now_iso)
  duration=$((end_ms - begin_ms))
  if [ "$duration" -lt 0 ]; then
    duration=0
  fi
  record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
}

if [ "$JOBS" -eq 1 ]; then
  for script in "${SCRIPTS[@]}"; do
    run_one_serial "$script"
  done
else
  # Bounded concurrent execution for proven-isolated scripts only. Each worker
  # gets a private mode-0700 TMPDIR so mktemp roots cannot collide. Retries are
  # never used as a green strategy.
  declare -a WORKER_PIDS=()
  declare -a WORKER_IDX=()
  declare -a WORKER_SCRIPTS=()
  worker_n=0
  active_workers=0

  wait_one_job_worker() {
    local slot=$1 pid idx work script rc duration mode out end_iso
    pid=${WORKER_PIDS[$slot]}
    idx=${WORKER_IDX[$slot]}
    script=${WORKER_SCRIPTS[$slot]}
    unset 'WORKER_PIDS[slot]'
    unset 'WORKER_IDX[slot]'
    unset 'WORKER_SCRIPTS[slot]'
    active_workers=$((active_workers - 1))
    set +e
    wait "$pid"
    set -e
    work="$RUN_TMP/w$idx"
    rc=$(cat "$work/exit" 2>/dev/null || echo 1)
    duration=$(cat "$work/duration_ms" 2>/dev/null || echo 0)
    out="$work/output"
    end_iso=$(now_iso)
    # Replay captured output after the worker finishes so markers stay ordered.
    if [ -s "$out" ]; then
      cat "$out"
    fi
    # Worker roots must be private to their worker. The mode check is the POSIX
    # way to prove that, and it cannot hold on Windows: NTFS has no faithful
    # mapping for POSIX mode bits, so a root created 0700 reads back as 755 and
    # every parallel worker fails an assertion its tests just passed. Measured:
    # 12 of 12 scripts "failed" this way with every assertion green.
    #
    # What the check is really guaranteeing - that each worker gets its OWN root,
    # created fresh by mktemp -d under a run-private parent - is unaffected by the
    # platform and still holds. Only the "no other account can read it" half is
    # unenforceable, which is the same reduction already accepted for the
    # watcher's check-trust guard (see bin/fm-check-lib.sh). The exposure is
    # another local account reading a temp dir during a test run.
    #
    # So the mode is verified where it is meaningful and reported without failing
    # the run where it is not.
    mode=$(stat -c %a "$work" 2>/dev/null || stat -f %Lp "$work" 2>/dev/null || echo unknown)
    case "$mode" in
      700|0700) ;;
      *)
        if fm_platform_is_windows; then
          # Once per run, not once per worker: it is a property of the platform,
          # and repeating it for every worker buries real output.
          if [ -z "${FM_WORKER_MODE_NOTED:-}" ] && : >"$RUN_TMP/.mode-noted" 2>/dev/null; then
            FM_WORKER_MODE_NOTED=1
            log "note: worker roots are mode $mode, not 0700; POSIX mode bits are cosmetic on this platform, so the mode half of the isolation check is advisory here. Per-worker root separation still holds."
          fi
        else
          log "isolation failure: worker root mode is $mode, expected 0700 ($work)"
          rc=1
        fi
        ;;
    esac
    record_script_result "$script" "$rc" "$duration" "$out" "$end_iso"
  }

  worker_pid_is_running() {
    local want=$1 running inventory="$RUN_TMP/running-pids"
    # Keep `jobs` in this shell. A process substitution runs it in a subshell
    # without this shell's job table on Bash 3.2/5.x, falsely reporting every
    # worker complete and making the scheduler wait for the oldest PID.
    jobs -r -p >"$inventory"
    while IFS= read -r running; do
      [ "$running" = "$want" ] && return 0
    done <"$inventory"
    return 1
  }

  wait_one_completed_job_worker() {
    local slot work
    while :; do
      for slot in "${!WORKER_PIDS[@]}"; do
        work="$RUN_TMP/w${WORKER_IDX[$slot]}"
        if [ -f "$work/exit" ] || ! worker_pid_is_running "${WORKER_PIDS[$slot]}"; then
          wait_one_job_worker "$slot"
          return
        fi
      done
      sleep 0.01
    done
  }

  for script in "${SCRIPTS[@]}"; do
    while [ "$active_workers" -ge "$JOBS" ]; do
      wait_one_completed_job_worker
    done
    worker_n=$((worker_n + 1))
    work="$RUN_TMP/w$worker_n"
    mkdir -p "$work/tmp"
    chmod 0700 "$work" "$work/tmp" || die "could not chmod 0700 worker root $work"
    base=$(basename "$script")
    family=$(family_for_basename "$base")
    expected=$(expected_gate_skip_for_family "$family")
    printf 'FM_TEST_BEGIN %s %s family=%s expected_gate_skip=%s\n' \
      "$(now_iso)" "$script" "$family" "$expected"
    (
      set +e
      export TMPDIR="$work/tmp"
      export TMP="$work/tmp"
      unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_ROOT_OVERRIDE \
        FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_BACKEND 2>/dev/null || true
      cd "$ROOT" || exit 1
      begin_ms=$(now_ms)
      bash "$script" >"$work/output" 2>&1
      rc=$?
      end_ms=$(now_ms)
      duration=$((end_ms - begin_ms))
      if [ "$duration" -lt 0 ]; then
        duration=0
      fi
      printf '%s\n' "$duration" >"$work/duration_ms"
      printf '%s\n' "$rc" >"$work/exit"
      exit 0
    ) &
    WORKER_PIDS[worker_n]=$!
    WORKER_IDX[worker_n]=$worker_n
    WORKER_SCRIPTS[worker_n]=$script
    active_workers=$((active_workers + 1))
  done
  while [ "$active_workers" -gt 0 ]; do
    wait_one_completed_job_worker
  done
fi

RUN_FINISHED_ISO=$(now_iso)
RUN_FINISHED_MS=$(now_ms)
RUN_DURATION=$((RUN_FINISHED_MS - RUN_STARTED_MS))
if [ "$RUN_DURATION" -lt 0 ]; then
  RUN_DURATION=0
fi

printf 'FM_TEST_SUMMARY total=%s failed=%s skipped_gate=%s duration_ms=%s\n' \
  "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION"

if [ -s "$FAMILIES_TSV" ]; then
  # Stable family summary order by name.
  sort -t$'\t' -k1,1 "$FAMILIES_TSV" | while IFS=$'\t' read -r name count duration failed_count; do
    printf 'FM_TEST_SUMMARY_FAMILY family=%s count=%s duration_ms=%s failed=%s\n' \
      "$name" "$count" "$duration" "$failed_count"
  done
fi

# Slowest scripts (top 15) from records.
if [ -s "$RECORDS" ]; then
  rank=1
  sort -t$'\t' -k5,5nr "$RECORDS" | head -n 15 | while IFS=$'\t' read -r path _family _expected _rc duration _gate; do
    printf 'FM_TEST_SLOWEST rank=%s script=%s duration_ms=%s\n' \
      "$rank" "$path" "$duration"
    rank=$((rank + 1))
  done
fi

if [ -n "$JSON_PATH" ]; then
  mkdir -p "$(dirname "$JSON_PATH")"
  # Families file may be unsorted; write_json reads as-is (deterministic sort in python).
  if [ -s "$FAMILIES_TSV" ]; then
    sort -t$'\t' -k1,1 "$FAMILIES_TSV" -o "$FAMILIES_TSV"
  else
    : >"$FAMILIES_TSV"
  fi
  write_json_artifact "$JSON_PATH" \
    "$RUN_STARTED_ISO" "$RUN_FINISHED_ISO" "$RUN_ID" \
    "$TOTAL" "$FAILED" "$SKIPPED_GATE" "$RUN_DURATION" \
    "$SELECTION_DESC" "$RECORDS" "$FAMILIES_TSV"
  log "wrote timing artifact: $JSON_PATH"
fi

exit "$AGG_RC"
