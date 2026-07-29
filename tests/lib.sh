#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Clear the ambient harness identity. bin/fm-harness.sh checks environment
# markers BEFORE walking the process ancestry, by design, so a suite run from
# inside a real harness session inherits that harness and every fixture that
# stubs `ps` to stage a different one is silently overruled - the stub is never
# consulted.
#
# Measured: run from a Claude Code session, tests/fm-secondmate-harness.test.sh
# stages a Pi signed-wrapper ancestry and asserts "pi", but CLAUDECODE=1 in the
# developer's environment makes fm-harness.sh return "claude" and short-circuit.
# CI never sees this because its runners have no harness markers, which is
# exactly what makes it worth clearing here rather than leaving to chance.
#
# Fixtures that need a marker set it explicitly on the command they run, so
# clearing it at source time takes nothing away.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT

# Exempt fixtures from the Windows pane setup (bin/fm-spawn.sh). That step types
# into the crewmate's pane and reads the answer back, which a fake backend cannot
# provide: it discards what is sent and has nothing to capture. The safety
# property it protects - never launch an agent into an unknown directory - is
# vacuous in a fixture, because no agent is launched.
#
# Exported suite-wide rather than per-file because the fakes are diverse (one
# models an entire Kimi TUI) and 15 of them predate the pane setup. A fixture
# that DOES model a pane unsets this and exercises the real probes; see
# "spawn fixtures" below.
export FM_SPAWN_NO_PANE_SETUP=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# --- substrate-scaled time budgets ------------------------------------------
#
# fm_test_wait_scale -> the multiplier a wall-clock budget needs on this host.
#
# Windows pays a much higher price for process creation, and firstmate's scripts
# source many libraries and shell out constantly, so a budget calibrated on
# POSIX is not a like-for-like bound there. Scaling one knob keeps POSIX
# behaviour byte-identical while stopping a Windows run from failing on the
# clock rather than on behaviour.
#
# FM_TEST_WAIT_SCALE overrides it, so a slow CI runner can be compensated
# without a code change.
#
# Lives here rather than in tests/wake-helpers.sh because it is not specific to
# wakes: any assertion with a wall-clock bound needs it. wake-helpers.sh sources
# this library, so its own use keeps working unchanged.
fm_test_wait_scale() {
  if [ -n "${FM_TEST_WAIT_SCALE:-}" ]; then
    printf '%s\n' "$FM_TEST_WAIT_SCALE"
    return 0
  fi
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-platform-lib.sh"
  if fm_platform_is_windows; then printf '6\n'; else printf '1\n'; fi
}

# --- recorded session-owner identity ----------------------------------------
#
# fm_owner_pid_of <msys-pid> -> the pid firstmate would RECORD for that process.
#
# Session ownership is stored in the platform's pid space, which on Windows is
# the Windows pid rather than the MSYS one: a native harness such as claude.exe
# has no MSYS pid at all, so only Windows pids can identify every harness. Job
# control still speaks MSYS pids, so a fixture keeps using $! for kill and wait
# while converting the pid it WRITES into state/.lock.
#
# A fixture that skips this writes an MSYS pid that firstmate then cannot match
# against any live harness, and the lock reads as stale on Windows while passing
# everywhere else.
fm_owner_pid_of() {  # <msys-pid>
  local p=$1
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-platform-lib.sh"
  if fm_platform_is_windows; then
    fm_platform_winpid "$p" 2>/dev/null || printf '%s\n' "$p"
  else
    printf '%s\n' "$p"
  fi
}

# --- spawn fixtures ---------------------------------------------------------
#
# fm-spawn learns the crew worktree through a different channel on each
# platform, so a spawn fixture has to feed both or it only tests one of them:
#
#   POSIX    types `treehouse get` into the pane, then polls the backend for the
#            pane's cwd - modelled by the fake tmux's #{pane_current_path}.
#   Windows  runs `treehouse get --lease` itself and reads the path from stdout,
#            because no Windows backend reports a pane's live directory
#            (docs/windows-gitbash.md).
#
# Both helpers below key off the same FM_FAKE_PANE_PATH, so one fixture value
# injects the same worktree whichever branch the host takes.

# A treehouse stub that exits 0 for everything, and additionally prints
# FM_FAKE_PANE_PATH for `get --lease`.
fm_fake_treehouse() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
lease=0
for arg in "$@"; do
  [ "$arg" = --lease ] && lease=1
done
if [ "${1:-}" = get ] && [ "$lease" = 1 ]; then
  printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
}

# A fake tmux for spawn fixtures: reports FM_FAKE_PANE_PATH as the pane cwd,
# names the session on '#S', optionally reports a stable new-window id, and
# swallows every other window op.
#
# It also models the pane as a POSIX shell, which the Windows branch needs: that
# branch verifies it has a POSIX shell and that the pane actually entered the
# worktree, by sending a line and reading the answer back. Only lines beginning
# `echo ` or `cd ` are evaluated, so the probes are answered while a launch
# command sent through this fixture can never be executed by it.
#
# Every invocation is appended to FM_TMUX_REC when that is set, so a caller that
# needs to pin command construction uses the same fake as everyone else.
fm_fake_spawn_tmux() {  # <fakebin> [new-window-id]
  local fakebin=$1 new_window_id=${2:-}
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
NEW_WINDOW_ID='$new_window_id'
SH
  cat >> "$fakebin/tmux" <<'SH'
TRANSCRIPT="${0%/*}/pane-transcript.log"
[ -n "${FM_TMUX_REC:-}" ] && printf 'tmux %s\n' "$*" >> "$FM_TMUX_REC"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  new-window) [ -z "$NEW_WINDOW_ID" ] || printf '%s\n' "$NEW_WINDOW_ID"; exit 0 ;;
  capture-pane) [ -f "$TRANSCRIPT" ] && cat "$TRANSCRIPT"; exit 0 ;;
  send-keys)
    # `send-keys -t <target> <text> Enter` is the submitted-line form. Record the
    # line as a real pane would echo it, then answer the probes.
    if [ "${!#}" = Enter ] && [ "$#" -ge 4 ]; then
      line=${*:$(($# - 1)):1}
      printf '%s\n' "$line" >> "$TRANSCRIPT"
      case "$line" in
        echo\ *|cd\ *) bash -c "$line" >> "$TRANSCRIPT" 2>/dev/null || true ;;
      esac
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects] [harness]: write the
# standard kind=secondmate meta block used across the secondmate suites. Window
# defaults to firstmate:fm-<id>, projects defaults to alpha, and harness defaults
# to echo to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 id window projects=${4:-alpha} harness=${5:-echo}
  id=$(basename "$file" .meta)
  window=${3:-firstmate:fm-$id}
  fm_write_meta "$file" \
    "window=$window" \
    "endpoint_task_id=$id" \
    "worktree=$home" \
    "project=$home" \
    "harness=$harness" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
