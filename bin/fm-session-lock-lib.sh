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
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$'

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

# Walk the current process ancestry (up to 8 hops) and print the first pid whose
# command looks like a verified harness. The harness pid lives as long as the
# session, unlike the transient subshell pid of any one tool call.
fm_harness_ancestry_pid() {
  local pid=$$ comm args
  if fm_platform_is_windows; then
    # The walk is authoritative because it proves ancestry. The advertised pid
    # is consulted only when the chain is broken by an exited intermediate.
    fm_harness_ancestry_pid_windows && return 0
    fm_harness_advertised_pid && return 0
    return 1
  fi
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$FM_HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$FM_HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

# True if $1 is a live process that looks like a verified harness.
#
# On Windows this cannot use kill -0: MSYS kill speaks MSYS pids, so a live
# harness reads as dead. That direction of error is the dangerous one, because a
# lock held by a healthy session would look stale and stealable.
fm_harness_pid_alive() {
  local pid=$1 comm name base
  if fm_platform_is_windows; then
    fm_platform_win_pid_alive "$pid" || return 1
    name=$(fm_platform_win_name "$pid") || return 1
    base=${name%.[Ee][Xx][Ee]}
    printf '%s' "$base" | grep -qE "$FM_HARNESS_RE" && return 0
    case "$base" in
      *node*|*python*)
        fm_platform_win_command "$pid" 2>/dev/null | grep -qE "$FM_HARNESS_RE" && return 0
        ;;
    esac
    return 1
  fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_HARNESS_RE"
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
