#!/usr/bin/env bash
# Shared "is this git lock file provably abandoned?" decision procedure.
#
# ONE owner for the staleness proof that fm-teardown.sh (a worktree index.lock)
# and fm-fleet-sync.sh (a clone's .git/packed-refs.lock) both rely on: a lock is
# provably stale iff ALL of the following hold -
#   1. the lock file still exists;
#   2. no live process holds the lock file open, and none holds a companion
#      directory (the worktree, or the repo's .git dir) open as cwd or an fd -
#      a live git process keeps its own lock open for the whole operation, so an
#      empty lsof result means the file was abandoned, not that no one held it;
#   3. its mtime age is at least a caller-supplied threshold - a freshly created
#      lock might belong to a process lsof has not yet reflected.
# ANY uncertainty - lsof missing, an lsof error, an unreadable mtime - returns
# non-zero (NOT stale): fail safe, never remove a lock that cannot be proven dead.
# Diagnostics print to stderr prefixed by ${FM_LOCK_LOG_PREFIX:-fm-lock} so each
# caller's output stays recognizable.

# Windows has no lsof, and its holder check is decided differently; see
# fm_lock_has_live_holder_windows. Inert off Windows.
# shellcheck source=bin/fm-platform-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-platform-lib.sh"

fm_lock_log() {
  echo "${FM_LOCK_LOG_PREFIX:-fm-lock}: $*" >&2
}

# Portable mtime in epoch seconds. Kept self-contained so this leaf lib drags in
# no wake-queue machinery when a caller only needs the staleness proof.
fm_lock_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_lock_lsof_holder <target>: 0 a process holds it, 1 provably none, 2 lsof
# errored (cannot tell). Diagnostics print on the error path only.
fm_lock_lsof_holder() {
  local target=$1 output status
  if output=$(lsof -- "$target" 2>&1); then
    return 0
  else
    status=$?
  fi
  if [ "$status" -eq 1 ] && [ -z "$output" ]; then
    return 1
  fi
  if [ -n "$output" ]; then
    while IFS= read -r line; do
      fm_lock_log "lsof check failed: $line"
    done <<< "$output"
  else
    fm_lock_log "lsof check failed for $target with exit $status"
  fi
  return 2
}

# Windows variant of the holder check. Same contract: 0 means "assume live",
# 1 means provably no holder.
#
# DELIBERATE DIFFERENCE, read before changing. The POSIX proof needs no holder on
# BOTH the lock file and a companion directory. On Windows only the file half is
# decidable: there is no lsof, and detecting "some process has this directory as
# its cwd" needs handle enumeration (Sysinternals handle.exe) that is not present
# on a stock machine. No non-mutating substitute exists - the rename trick would
# have to mutate a live worktree, which is unacceptable in a safety check.
#
# So on Windows the proof rests on the file probe plus the caller's mtime age
# threshold. That is a genuinely smaller signal, and the reasons it is still
# sound here:
#
#   1. The file probe is at least as strong as lsof. Windows file locking is
#      mandatory, so an exclusive-open attempt detects ANY open handle, including
#      one opened with shared read/write. Verified against both.
#   2. What the directory check buys is stated in fm-fleet-sync.sh: it catches
#      git in "the narrow window after it closes packed-refs.lock and before it
#      exits". That window is milliseconds. Both callers require an mtime age of
#      at least 30s, so the age threshold already covers it by three orders of
#      magnitude.
#   3. A live git holds its own lock open for the whole operation, which is the
#      primary signal the POSIX path relies on too.
#
# The alternative was returning "cannot tell" and always failing safe. That is
# not free: it makes every abandoned index.lock permanently un-clearable, so
# fm-teardown.sh returns TEARDOWN_TREEHOUSE_LOCK_REFUSED forever and task cleanup
# on Windows requires manual deletion. Trading a millisecond-wide race that the
# 30s threshold already covers against permanently broken teardown is the better
# bargain, but it IS a judgment call - revisit it if handle.exe ever becomes a
# dependency worth taking.
fm_lock_has_live_holder_windows() {
  local lock=$1 dir=$2 status
  # $dir is accepted for signature parity and intentionally unused; see above.
  : "$dir"
  # No lock path to prove anything about: fail safe.
  [ -n "$lock" ] || return 0
  fm_platform_win_file_holder "$lock"
  status=$?
  case "$status" in
    0) return 0 ;;  # held
    1) return 1 ;;  # provably no holder
    *) return 0 ;;  # cannot tell -> fail safe, same as the POSIX path
  esac
}

# fm_lock_has_live_holder <lock> <dir>: 0 if a live process holds $lock or the
# companion $dir open, OR if the answer is uncertain - a missing lsof or an lsof
# error is treated as "cannot prove no holder" (fail safe: assume live). Returns
# 1 only when lsof reports provably no holder on both.
fm_lock_has_live_holder() {
  local lock=$1 dir=$2 status
  if fm_platform_is_windows; then
    fm_lock_has_live_holder_windows "$lock" "$dir"
    return
  fi
  command -v lsof >/dev/null 2>&1 || return 0
  if [ -n "$lock" ]; then
    if fm_lock_lsof_holder "$lock"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  if [ -n "$dir" ]; then
    if fm_lock_lsof_holder "$dir"; then
      return 0
    else
      status=$?
      [ "$status" -eq 1 ] || return 0
    fi
  fi
  return 1
}

# fm_lock_age <lock>: prints the lock's mtime age in whole seconds, or fails.
fm_lock_age() {
  local lock=$1 m now
  m=$(fm_lock_path_mtime "$lock") || return 1
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s) || return 1
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$(( now - m ))"
}

# fm_lock_is_provably_stale <lock> <dir> <min_age_secs>: THE proof. Returns 0 iff
# the lock exists, has no live holder, and its mtime age is at least
# <min_age_secs>. Returns non-zero on any uncertainty - never remove a lock this
# returns non-zero for.
fm_lock_is_provably_stale() {
  local lock=$1 dir=$2 min_age=$3 age
  [ -n "$lock" ] && [ -e "$lock" ] || return 1
  fm_lock_has_live_holder "$lock" "$dir" && return 1
  if ! age=$(fm_lock_age "$lock"); then
    fm_lock_log "cannot read mtime for git lock $lock; leaving it in place"
    return 1
  fi
  [ "$age" -ge "$min_age" ]
}
