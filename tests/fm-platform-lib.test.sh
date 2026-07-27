#!/usr/bin/env bash
# tests/fm-platform-lib.test.sh - unit tests for the platform seam
# (bin/fm-platform-lib.sh): OS classification and the Windows native-symlink
# guarantee. Pure functions plus one environment mutation, no backend required.
#
# Both branches are exercised on every host by overriding FM_PLATFORM_UNAME, so
# Linux CI proves the Windows classification and a Windows run proves the POSIX
# one. The real-symlink assertion is necessarily host-conditional and is
# reported as a gate skip off Windows.
#
# SC2030/SC2031 are disabled for the whole file: every case deliberately sets
# FM_PLATFORM_UNAME and MSYS inside a subshell so the library's cached uname and
# its exported MSYS cannot leak between assertions. "The change might be lost"
# is precisely the isolation being relied on here, not a mistake.
# shellcheck disable=SC2030,SC2031
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLATFORM_LIB="$ROOT/bin/fm-platform-lib.sh"

# Each case runs in its own subshell: the library caches uname and exports MSYS,
# so a shared shell would leak state between assertions.
classify() { # <uname> -> "windows|macos|other"
  (
    unset MSYS
    export FM_PLATFORM_UNAME=$1
    # shellcheck source=/dev/null
    . "$PLATFORM_LIB"
    if fm_platform_is_windows; then printf 'windows\n'
    elif fm_platform_is_macos; then printf 'macos\n'
    else printf 'other\n'
    fi
  )
}

# --- OS classification -------------------------------------------------------

for u in MINGW64_NT-10.0-26200 MINGW32_NT-6.2 MSYS_NT-10.0 CYGWIN_NT-10.0; do
  [ "$(classify "$u")" = windows ] || fail "$u must classify as windows"
done
pass "MINGW/MSYS/CYGWIN uname values all classify as windows"

[ "$(classify Darwin)" = macos ] || fail "Darwin must classify as macos"
pass "Darwin classifies as macos and not windows"

[ "$(classify Linux)" = other ] || fail "Linux must classify as neither windows nor macos"
pass "Linux classifies as neither windows nor macos"

# WSL reports Linux and IS Linux: it must not take any Windows branch, or it
# would inherit MSYS-only workarounds that do not apply to it.
[ "$(classify Linux)" != windows ] || fail "WSL (uname Linux) must never classify as windows"
pass "WSL is not treated as Windows because it reports and behaves as Linux"

# --- the native-symlink guarantee -------------------------------------------

# On Windows the library must add winsymlinks:nativestrict to MSYS...
MSYS_WIN=$(
  unset MSYS
  export FM_PLATFORM_UNAME=MINGW64_NT-10.0
  # shellcheck source=/dev/null
  . "$PLATFORM_LIB"
  printf '%s\n' "${MSYS:-}"
)
case "$MSYS_WIN" in
  *winsymlinks:nativestrict*) ;;
  *) fail "windows must gain winsymlinks:nativestrict, got '$MSYS_WIN'" ;;
esac
pass "sourcing on Windows exports MSYS=winsymlinks:nativestrict"

# ...must preserve any pre-existing MSYS settings rather than clobbering them...
MSYS_KEPT=$(
  export MSYS=disable_pcon FM_PLATFORM_UNAME=MINGW64_NT-10.0
  # shellcheck source=/dev/null
  . "$PLATFORM_LIB"
  printf '%s\n' "${MSYS:-}"
)
case "$MSYS_KEPT" in
  *disable_pcon*winsymlinks:nativestrict*) ;;
  *) fail "pre-existing MSYS settings must be preserved, got '$MSYS_KEPT'" ;;
esac
pass "an existing MSYS value is extended, not overwritten"

# ...must be idempotent, so repeated sourcing cannot grow MSYS without bound...
MSYS_TWICE=$(
  export MSYS=winsymlinks:nativestrict FM_PLATFORM_UNAME=MINGW64_NT-10.0
  # shellcheck source=/dev/null
  . "$PLATFORM_LIB"
  fm_platform_enable_native_symlinks
  printf '%s\n' "${MSYS:-}"
)
COUNT=$(printf '%s\n' "$MSYS_TWICE" | grep -o 'winsymlinks:nativestrict' | wc -l | tr -d '[:space:]')
[ "$COUNT" = 1 ] || fail "enable_native_symlinks must be idempotent, found $COUNT copies"
pass "repeated application adds winsymlinks:nativestrict exactly once"

# ...and must never touch MSYS on a POSIX host.
MSYS_POSIX=$(
  unset MSYS
  export FM_PLATFORM_UNAME=Linux
  # shellcheck source=/dev/null
  . "$PLATFORM_LIB"
  printf '%s\n' "${MSYS:-unset}"
)
[ "$MSYS_POSIX" = unset ] || fail "POSIX hosts must not gain an MSYS value, got '$MSYS_POSIX'"
pass "sourcing on Linux leaves MSYS untouched"

# --- ancestry algorithms, exercised on every platform ------------------------
#
# Both walks are pure functions over a process-table snapshot, so injecting
# FM_PLATFORM_WIN_SNAPSHOT / FM_PLATFORM_MSYS_SNAPSHOT exercises them fully on
# Linux CI. The fixtures encode the topology actually measured on Git Bash,
# including the failure that makes the naive approach unusable.

# Windows table: "<pid>\t<ppid>\t<name>". Mirrors a real measured chain,
# 36676 bash -> 38468 bash -> 32320 claude.exe -> 1968 pwsh -> 11768 herdr.
WIN_FIXTURE=$(printf '%s\n' \
  "36676	38468	bash.exe" \
  "38468	32320	bash.exe" \
  "32320	1968	claude.exe" \
  "1968	11768	pwsh.exe" \
  "11768	4128	herdr.exe")

CHAIN=$(FM_PLATFORM_WIN_SNAPSHOT=$WIN_FIXTURE bash -c "
  # shellcheck source=/dev/null
  . '$PLATFORM_LIB'
  FM_PLATFORM_WIN_SNAPSHOT=\"\$1\"
  fm_platform_win_ancestry_chain 36676 8
" _ "$WIN_FIXTURE")
[ "$(printf '%s\n' "$CHAIN" | wc -l | tr -d '[:space:]')" = 5 ] \
  || fail "chain should have 5 hops, got: $CHAIN"
printf '%s\n' "$CHAIN" | grep -q '^32320	claude\.exe$' \
  || fail "chain must contain the harness hop, got: $CHAIN"
pass "fm_platform_win_ancestry_chain walks a snapshot to the harness in one pass"

# A dangling parent must terminate the walk rather than loop or invent hops.
# This is the measured Git Bash reality: a spawned bash records a Windows parent
# that has already exited, so the chain ends after one hop.
ORPHAN=$(printf '%s\n' "26576	36772	bash.exe")
CHAIN2=$(bash -c "
  # shellcheck source=/dev/null
  . '$PLATFORM_LIB'
  FM_PLATFORM_WIN_SNAPSHOT=\"\$1\"
  fm_platform_win_ancestry_chain 26576 8
" _ "$ORPHAN")
[ "$(printf '%s\n' "$CHAIN2" | wc -l | tr -d '[:space:]')" = 1 ] \
  || fail "a dead parent must end the walk after one hop, got: $CHAIN2"
pass "an exited Windows parent terminates the chain instead of dead-ending mid-walk"

# A parent cycle must not hang the walk.
CYCLE=$(printf '%s\n' "10	20	a.exe" "20	10	b.exe")
CHAIN3=$(bash -c "
  # shellcheck source=/dev/null
  . '$PLATFORM_LIB'
  FM_PLATFORM_WIN_SNAPSHOT=\"\$1\"
  fm_platform_win_ancestry_chain 10 8
" _ "$CYCLE")
[ "$(printf '%s\n' "$CHAIN3" | wc -l | tr -d '[:space:]')" -le 8 ] \
  || fail "a pid cycle must stay bounded by max hops, got: $CHAIN3"
pass "a parent cycle stays bounded by the hop limit"

# MSYS table: PID PPID PGID WINPID ... The root is the entry whose PPID is 1,
# and its WINPID is the bridge into the Windows table.
MSYS_FIXTURE=$(printf '%s\n' \
  "      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND" \
  "     1771    1513    1771      10980   ?        197609 17:00:53 /usr/bin/bash" \
  "     1513       1    1513      39548   ?        197609 17:00:30 /usr/bin/bash")
ROOTWIN=$(bash -c "
  # shellcheck source=/dev/null
  . '$PLATFORM_LIB'
  FM_PLATFORM_UNAME=MINGW64_NT-10.0
  FM_PLATFORM_MSYS_SNAPSHOT=\"\$1\"
  fm_platform_msys_root_winpid 1771
" _ "$MSYS_FIXTURE")
[ "$ROOTWIN" = 39548 ] \
  || fail "MSYS root bridge must yield the root's WINPID 39548, got '$ROOTWIN'"
pass "fm_platform_msys_root_winpid walks MSYS parents to the root and returns its WINPID"

# Already at the root: the bridge must return that process's own WINPID.
ROOTWIN2=$(bash -c "
  # shellcheck source=/dev/null
  . '$PLATFORM_LIB'
  FM_PLATFORM_UNAME=MINGW64_NT-10.0
  FM_PLATFORM_MSYS_SNAPSHOT=\"\$1\"
  fm_platform_msys_root_winpid 1513
" _ "$MSYS_FIXTURE")
[ "$ROOTWIN2" = 39548 ] \
  || fail "a process already at the MSYS root must return its own WINPID, got '$ROOTWIN2'"
pass "the bridge is correct when the caller is already the MSYS root"

# --- the guarantee actually holds on a real Windows host ---------------------

if ! (
  unset FM_PLATFORM_UNAME
  # shellcheck source=/dev/null
  . "$PLATFORM_LIB"
  fm_platform_is_windows
); then
  echo "skip: native symlink round-trip requires a Windows host"
  exit 0
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-platform.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
(
  # shellcheck source=/dev/null
  . "$PLATFORM_LIB"
  cd "$TMP" || exit 1
  mkdir owner && printf 'held\n' > owner/pid
  ln -s owner lock 2>/dev/null || { echo "ln -s failed"; exit 1; }
  [ -L lock ] || { echo "not a symlink: ln -s silently copied"; exit 1; }
  [ "$(readlink lock)" = owner ] || { echo "readlink did not resolve to owner"; exit 1; }
  [ "$(cat lock/pid)" = held ] || { echo "read through the link failed"; exit 1; }
) || fail "ln -s must produce a real, readlink-resolvable symlink on Windows"
pass "on a Windows host ln -s produces a real symlink that readlink resolves"

# End-to-end: the regression this seam exists to prevent. Without it, stock Git
# Bash copies the owner directory onto the lock path, readlink fails, the claim
# is refused, and the leftover directory blocks every later attempt forever.
#
# Note this is NOT asserted as "a second ln -s fails". When the lock path is
# already a symlink to a directory, POSIX ln -s creates the link INSIDE it
# instead of failing - which is exactly why fm_lock_remove_stray_owner_link
# exists. The property under test is the lock's own mutual exclusion.
(
  LOCKHOME=$(mktemp -d "${TMPDIR:-/tmp}/fm-platform-lock.XXXXXX")
  trap 'rm -rf "$LOCKHOME"' EXIT
  mkdir -p "$LOCKHOME/state"
  export FM_HOME="$LOCKHOME" FM_STATE_OVERRIDE="$LOCKHOME/state"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-wake-lib.sh"
  LOCK="$FM_STATE_OVERRIDE/.watch.lock"

  fm_lock_try_create "$LOCK" || { echo "first claim was refused"; exit 1; }
  [ -L "$LOCK" ] || { echo "lock path is not a symlink"; exit 1; }
  [ -n "${FM_LOCK_OWNER_DIR:-}" ] || { echo "no owner dir recorded"; exit 1; }
  fm_lock_points_to_owner "$LOCK" "$FM_LOCK_OWNER_DIR" \
    || { echo "lock does not resolve to its owner"; exit 1; }

  # A second holder must be refused while the first still holds it.
  if fm_lock_try_create "$LOCK"; then
    echo "second claim succeeded: mutual exclusion is broken"
    exit 1
  fi
  exit 0
) || fail "the watcher lock must claim once and refuse a concurrent second claim"
pass "the real watcher lock claims a resolvable symlink and refuses a second holder"
