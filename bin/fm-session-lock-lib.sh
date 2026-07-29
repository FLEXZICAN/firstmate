#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-claude-stop-autoarm.sh uses it to prove a Stop hook fires inside the
# lock-owning primary session before it may arm or rewake.
# This file is sourced by scripts and has no side effects on source.

# shellcheck source=bin/fm-platform-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-platform-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$'

# Windows ancestry walk. Separate from the POSIX one below because MSYS ps
# cannot see the harness at all: it lists only MSYS processes and reports this
# shell's parent as pid 1. Parentage therefore comes from the Windows process
# table. See bin/fm-platform-lib.sh for the measurements behind this.
#
# Pids printed here are WINDOWS pids, which is the correct identity to persist:
# the MSYS pid belongs to a transient tool shell, while the Windows pid is the
# harness process that outlives the whole session.
fm_harness_ancestry_pid_windows() {
  local pid name base
  # Build both snapshots ONCE in this shell. Called directly, never in a command
  # substitution, or every hop would respawn ps and wmic.
  fm_platform_msys_snapshot_ensure || return 1
  fm_platform_win_snapshot_ensure || return 1
  # Start from the MSYS ancestry ROOT, not from this process. A spawned bash
  # records an already-exited Windows parent (MSYS fork emulation), so walking
  # Windows parents from here dead-ends at the first hop.
  # Stage 1: the MSYS side. A harness that is a script or a symlink appears only
  # here - the Win32 table shows bash.exe for all of them - so this must run
  # before the bridge or those harnesses are skipped entirely. The WINPID is what
  # gets returned, so stored identity stays in one pid space either way.
  local msys_chain mwin mcmd mbase
  msys_chain=$(fm_platform_msys_chain $$ 16) || msys_chain=""
  if [ -n "$msys_chain" ]; then
    # The MSYS pid is discarded: what gets recorded is always the WINPID.
    while IFS=$'\t' read -r _ mwin mcmd; do
      [ -n "$mwin" ] || continue
      mbase=${mcmd##*/}
      mbase=${mbase%% *}
      mbase=${mbase%.[Ee][Xx][Ee]}
      if printf '%s' "$mbase" | grep -qE "$FM_HARNESS_RE"; then
        printf '%s\n' "$mwin"
        return 0
      fi
    done <<EOF
$msys_chain
EOF
  fi

  # Stage 2: bridge to the Win32 table for a native harness such as claude.exe.
  pid=$(fm_platform_msys_root_winpid $$) || return 1

  # One awk pass for the whole chain, then loop in-process. Deliberately avoids
  # a command substitution per hop, which dominates cost on Windows.
  local chain deferred=""
  chain=$(fm_platform_win_ancestry_chain "$pid" 8) || return 1
  [ -n "$chain" ] || return 1

  while IFS=$'\t' read -r pid name; do
    [ -n "$pid" ] || continue
    base=${name%.[Ee][Xx][Ee]}
    if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
      printf '%s\n' "$pid"
      return 0
    fi
    # Bare interpreter hosting a harness. Checking this needs a per-pid command
    # line query, so defer it: only pay for it if no direct name match is found
    # anywhere in the chain.
    case "$base" in
      *node*|*python*) deferred="$deferred $pid" ;;
    esac
  done <<EOF
$chain
EOF

  for pid in $deferred; do
    if fm_platform_win_command "$pid" 2>/dev/null | grep -qE "$FM_HARNESS_RE"; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

# Harness pid advertised by the harness itself, verified before use.
#
# A last resort for when even the MSYS-root bridge cannot reach a harness: an
# unrecognized shell topology, a harness launched outside the MSYS tree, or an
# MSYS root whose own Windows parent has also exited. Windows does not reparent
# orphans, so a broken link is permanent rather than redirected to pid 1.
#
# Claude Code exports CLAUDE_PID, which matched the walk-resolved ancestor
# exactly in every measurement. It is used ONLY after the walk has failed, and
# only after verifying the pid is live and really is a harness image, because an
# environment variable proves advertisement, not ancestry.
#
# Known limitation: bin/fm-spawn.sh does not scrub this variable, so a crewmate
# inherits it. That is safe only if each harness overwrites it for its own
# descendants. Keeping this strictly second to the walk bounds the blast radius
# to the case where the chain is already broken. No other verified harness
# advertises an equivalent, so they rely on the walk alone.
fm_harness_advertised_pid() {
  local pid=${CLAUDE_PID:-}
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# Walk the current process ancestry (up to 16 hops) and print a harness pid.
# For every harness except Claude, the first match wins (innermost pid), which
# is where e.g. Pi's shared signed-wrapper ancestry actually holds the session:
# a "pi-signed" launcher can be the direct parent of the inner "pi" engine
# pid that owns the lock, and the wrapper pid above it is not that owner.
# Claude Code's bg-spare hook worker chain is the opposite shape: it nests
# several claude-named processes directly parent-child with no non-harness
# process between them, and the lock is held by the outermost pid of that
# run. So once a claude-named match is found, this keeps walking past it
# looking for a still-more-ancestral claude-named match, and stops the
# instant a non-match follows - never walking past that gap to an unrelated
# claude-named process further up the real process tree (e.g. the live
# session that launched a test as its own subprocess). The harness pid lives
# as long as the session, unlike the transient subshell pid of any one tool
# call.
#
# Windows never reaches that loop: MSYS ps cannot see the harness at all, so
# the whole walk is replaced rather than adjusted (fm_harness_ancestry_pid_windows).
fm_harness_ancestry_pid() {
  local pid=$$ comm args best='' bc extending=0 hit=0 is_claude=0
  if fm_platform_is_windows; then
    # The walk is authoritative because it proves ancestry. The advertised pid
    # is consulted only when the chain is broken by an exited intermediate.
    fm_harness_ancestry_pid_windows && return 0
    fm_harness_advertised_pid && return 0
    return 1
  fi
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    bc=$(basename "$comm")
    hit=0; is_claude=0
    if printf '%s' "$bc" | grep -qE "$FM_HARNESS_RE"; then
      hit=1
      case "$bc" in *claude*) is_claude=1 ;; esac
    else
      # Bare interpreter (e.g. node): match the harness name in its script path.
      case "$comm" in
        *node*|*python*)
          if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
            hit=1
            case "$args" in *claude*) is_claude=1 ;; esac
          fi
          ;;
      esac
    fi
    if [ "$hit" -eq 1 ]; then
      best="$pid"
      if [ "$is_claude" -eq 1 ]; then
        extending=1
      else
        break
      fi
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ -n "$best" ] && { echo "$best"; return 0; }
  return 1
}

# True if $1 is a live process that looks like a verified harness.
#
# On Windows this cannot use kill -0: MSYS kill speaks MSYS pids, so a live
# harness reads as dead. That direction of error is the dangerous one, because a
# lock held by a healthy session would look stale and stealable.
fm_harness_pid_alive() {
  # `args` is upstream's; `name`/`base` are the Windows path's.
  local pid=$1 comm args name base
  if fm_platform_is_windows; then
    fm_platform_win_pid_alive "$pid" || return 1
    name=$(fm_platform_win_name "$pid") || return 1
    base=${name%.[Ee][Xx][Ee]}
    printf '%s' "$base" | grep -qE "$FM_HARNESS_RE" && return 0
    # A script or symlink harness shows up as bash.exe in the Win32 table, so
    # the image name alone would call a healthy session dead and invite a lock
    # steal. MSYS ps preserves the executed path, so ask it before giving up.
    local mcmd mbase
    if mcmd=$(fm_platform_msys_command_for_winpid "$pid" 2>/dev/null); then
      mbase=${mcmd##*/}
      mbase=${mbase%% *}
      mbase=${mbase%.[Ee][Xx][Ee]}
      printf '%s' "$mbase" | grep -qE "$FM_HARNESS_RE" && return 0
    fi
    case "$base" in
      *node*|*python*)
        fm_platform_win_command "$pid" 2>/dev/null | grep -qE "$FM_HARNESS_RE" && return 0
        ;;
    esac
    return 1
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
    return 0
  fi
  case "$comm" in
    *node*|*python*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"
      ;;
    *) return 1 ;;
  esac
}

# True when state dir $1 holds a session lock whose pid is the harness ancestor
# of the current process: this script runs inside the session that owns the
# home's fleet lock. A missing lock, a lock held by another live harness, or an
# ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid my_pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  my_pid=$(fm_harness_ancestry_pid) || return 1
  [ "$my_pid" = "$lock_pid" ]
}
