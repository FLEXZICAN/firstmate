# shellcheck shell=bash
# Platform seam: OS identification, plus the substrate quirks that must be
# settled before any script relies on POSIX filesystem semantics.
# Usage: . bin/fm-platform-lib.sh
#
# Every Windows-specific behavior in firstmate sits behind this file. Linux and
# macOS paths are unchanged: fm_platform_is_windows is false there, and sourcing
# this library has no effect beyond defining functions.
#
# Why the symlink handling below is not optional:
#
# Git for Windows ships MSYS2, whose default `ln -s` does NOT create a symlink.
# It silently COPIES the target instead. That is not a cosmetic difference - it
# breaks any algorithm that uses symlink creation as an atomic mutex, because a
# copy always "succeeds" and readlink then fails on the result.
#
# The concrete casualty is the wake-queue watcher lock (bin/fm-wake-lib.sh),
# which claims ownership with `ln -s <ownerdir> <lockdir>` and verifies with
# readlink. On stock Git Bash that call copies the owner directory onto the lock
# path, readlink fails, the claim is correctly refused - and a real directory is
# left behind at the lock path forever. Every later attempt then short-circuits
# on `[ -e "$lockdir" ]`, so the watcher can never start again until someone
# deletes it by hand. Measured: three consecutive claims all refused, with a
# stray .watch.lock/ directory persisting after the first.
#
# MSYS=winsymlinks:nativestrict makes `ln -s` emit a real NTFS symlink, or fail
# outright when the OS refuses. Both outcomes are correct; the silent copy is
# the only unacceptable one. Native symlink creation needs either Developer Mode
# (Windows 10+) or elevation, so on a machine with neither, lock claims fail
# loudly instead of corrupting state.

# Cached `uname -s`. Override FM_PLATFORM_UNAME to exercise either branch in
# tests without needing the matching host.
FM_PLATFORM_UNAME="${FM_PLATFORM_UNAME:-}"
fm_platform_uname() {
  if [ -z "$FM_PLATFORM_UNAME" ]; then
    FM_PLATFORM_UNAME=$(uname -s 2>/dev/null || echo unknown)
  fi
  printf '%s\n' "$FM_PLATFORM_UNAME"
}

# True on native Windows bash substrates: Git Bash / MSYS2 (MINGW*, MSYS*) and
# Cygwin. Deliberately FALSE under WSL, which reports Linux and genuinely is
# Linux - it needs no Windows special-casing.
fm_platform_is_windows() {
  case "$(fm_platform_uname)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_platform_is_macos() {
  [ "$(fm_platform_uname)" = Darwin ]
}

# True only when python3 both RESOLVES and RUNS.
#
# `command -v python3` is not proof of an interpreter. Windows ships a Microsoft
# Store "app execution alias" at python3 that resolves on PATH and then prints an
# install advertisement instead of executing - and exits 0 while doing it. Every
# caller that trusted presence therefore either produced no output and failed its
# caller, or worse, passed silently: bin/fm-doc-audience-check.sh execs python3
# directly, so the entire documentation audience check reported success while
# validating nothing.
#
# This is not a Windows-only correctness rule; a broken interpreter anywhere
# should be treated the same way. On a host where python3 genuinely works the
# answer is unchanged, so POSIX behavior is identical.
#
# Probed once and cached. Callers should treat a false result as "no python3"
# and fail loudly rather than continuing with a silent gap.
FM_PLATFORM_PYTHON3_OK=""
fm_platform_python3_works() {
  if [ -z "$FM_PLATFORM_PYTHON3_OK" ]; then
    if command -v python3 >/dev/null 2>&1 \
      && [ "$(python3 -c 'print(1)' 2>/dev/null)" = 1 ]; then
      FM_PLATFORM_PYTHON3_OK=yes
    else
      FM_PLATFORM_PYTHON3_OK=no
    fi
  fi
  [ "$FM_PLATFORM_PYTHON3_OK" = yes ]
}

# Ensure `ln -s` creates real symlinks rather than silently copying. Idempotent,
# and a no-op everywhere except Windows. Exporting MSYS is enough for child
# processes: the MSYS runtime reads it at process start, so every later `ln`,
# `readlink`, and nested bash inherits the setting.
fm_platform_enable_native_symlinks() {
  fm_platform_is_windows || return 0
  case "${MSYS:-}" in
    *winsymlinks:nativestrict*) return 0 ;;
  esac
  MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict"
  export MSYS
}

# Applied at source time on purpose. Symlink semantics must be correct before a
# caller's first `ln -s`, and leaving it to each caller to remember is exactly
# the kind of omission that reintroduces silent state corruption.
fm_platform_enable_native_symlinks

# --- Windows process introspection -------------------------------------------
#
# The harness-ancestry walk cannot use MSYS ps on Windows. Measured on Git Bash
# (MINGW64), with the harness running as a native claude.exe:
#
#   * plain `ps` lists only MSYS processes - three of them - and reports this
#     shell's PPID as 1. The harness is simply absent from the table.
#   * `ps -W` does list Windows processes (408 rows here), but 407 of the 408
#     carry PPID=0. It offers visibility without parentage.
#   * four separate claude.exe processes were running at measurement time. Only
#     one was this session's. Matching on name alone cannot tell them apart, and
#     AGENTS.md section 5 forbids claiming ownership by name sweep.
#   * `kill -0 <winpid>` fails for a Windows pid, because MSYS kill speaks MSYS
#     pids. Liveness needs its own Windows-aware path.
#
# So parentage comes from the Windows process table (one bulk snapshot, walked
# locally), while liveness and image name come from `ps -W`, which is cheaper and
# sufficient once the pid is already known.
#
# Cost, measured: one bulk snapshot is 346ms via wmic and 633ms via PowerShell
# CIM, against 1166ms for a per-hop PowerShell walk. wmic is preferred for speed
# and PowerShell is the durable fallback, because Microsoft is removing wmic.
#
# NOT cached across process invocations, deliberately. The snapshot is cached for
# the lifetime of one shell, which is what the multi-hop walk needs. Persisting a
# resolved harness pid to disk would invite pid-reuse staleness in the code path
# that decides session-lock ownership, and that risk is not worth paying before
# measurement shows the per-invocation cost actually hurts.

# Windows pid of an MSYS pid. MSYS `ps` is authoritative here: it is the only
# thing that knows the mapping between its own pid space and Windows'.
fm_platform_winpid() { # <msys-pid>
  local pid=${1:-$$} out
  fm_platform_is_windows || { printf '%s\n' "$pid"; return 0; }
  out=$(fm_platform_msys_snapshot | awk -v p="$pid" '$1 == p { print $4; exit }')
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$out" ;;
  esac
}

# Path to a usable PowerShell, or non-zero if there is none.
#
# `command -v powershell.exe` is not sufficient: Windows keeps it in
# System32\WindowsPowerShell\v1.0, NOT in System32 itself, so a PATH carrying
# only the usual Windows directories resolves nothing. That is not hypothetical -
# it silently downgraded the git-lock staleness proof to "cannot tell" under a
# minimal PATH, which fails safe but means an abandoned lock is never cleared.
# pwsh (PowerShell 7+) is preferred when present, then the classic location.
FM_PLATFORM_POWERSHELL=""
fm_platform_powershell() {
  local candidate
  if [ -n "$FM_PLATFORM_POWERSHELL" ]; then
    printf '%s\n' "$FM_PLATFORM_POWERSHELL"
    return 0
  fi
  for candidate in pwsh.exe pwsh powershell.exe powershell; do
    if command -v "$candidate" >/dev/null 2>&1; then
      FM_PLATFORM_POWERSHELL=$candidate
      printf '%s\n' "$FM_PLATFORM_POWERSHELL"
      return 0
    fi
  done
  candidate="${SYSTEMROOT:-/c/Windows}/System32/WindowsPowerShell/v1.0/powershell.exe"
  case "$candidate" in
    [A-Za-z]:\\*) candidate=$(fm_platform_userprofile_to_posix "$candidate") ;;
  esac
  if [ -x "$candidate" ]; then
    FM_PLATFORM_POWERSHELL=$candidate
    printf '%s\n' "$FM_PLATFORM_POWERSHELL"
    return 0
  fi
  return 1
}

# Convert a Windows path to a POSIX one. cygpath when available, otherwise a
# drive-letter rewrite good enough for the fixed system paths this file uses.
fm_platform_userprofile_to_posix() {
  local p=$1 drive rest
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$p" 2>/dev/null && return 0
  fi
  case "$p" in
    [A-Za-z]:\\*)
      drive=$(printf '%s' "${p%%:*}" | tr '[:upper:]' '[:lower:]')
      rest=${p#?:\\}
      rest=${rest//\\//}
      printf '/%s/%s\n' "$drive" "$rest"
      ;;
    *) printf '%s\n' "$p" ;;
  esac
}

# The pid identifying THIS process in the space firstmate records for session
# ownership. Windows pids are the only universal space here: a native harness
# such as claude.exe has no MSYS pid at all, so MSYS pids cannot identify every
# harness while Windows pids can identify all of them. Off Windows this is just
# $$, unchanged.
#
# $$ is deliberate rather than BASHPID: it stays the shell's own pid inside a
# command substitution, so $(fm_platform_self_pid) reports the caller, not a
# transient subshell.
fm_platform_self_pid() {
  if fm_platform_is_windows; then
    fm_platform_winpid $$ || return 1
  else
    printf '%s\n' $$
  fi
}

# One capture of MSYS `ps` (PID PPID PGID WINPID ...), cached for this shell.
FM_PLATFORM_MSYS_SNAPSHOT=""
fm_platform_msys_snapshot() {
  if [ -n "$FM_PLATFORM_MSYS_SNAPSHOT" ]; then
    printf '%s\n' "$FM_PLATFORM_MSYS_SNAPSHOT"
    return 0
  fi
  ps 2>/dev/null
}

# Populate the MSYS snapshot in the CALLER'S shell. Same subshell caveat as
# fm_platform_win_snapshot_ensure: never call this in a command substitution.
fm_platform_msys_snapshot_ensure() {
  [ -z "$FM_PLATFORM_MSYS_SNAPSHOT" ] || return 0
  FM_PLATFORM_MSYS_SNAPSHOT=$(ps 2>/dev/null) || return 1
  [ -n "$FM_PLATFORM_MSYS_SNAPSHOT" ]
}

# Windows pid of the ROOT of this process's MSYS ancestry - the bridge between
# the two pid spaces, and the crux of making ancestry work at all on Git Bash.
#
# MSYS emulates fork() with CreateProcess plus a transient helper, so a spawned
# bash records a WINDOWS parent that has already exited. Measured: a script's
# bash reported a Windows parent that was absent from both the process table and
# ps -W, on every one of five consecutive runs. Walking Windows parents from a
# script therefore dead-ends immediately, which is why an approach built only on
# the Windows process table cannot work.
#
# MSYS ps, however, tracks its own pid space correctly, and the ROOT MSYS process
# (the one whose MSYS ppid is 1) does retain a valid Windows parent link. So walk
# MSYS parents to that root, then hand its WINPID to the Windows walk. Measured
# end to end: msys 1771 -> 1513 (root, winpid 39548), then Windows 39548 ->
# 39444 -> 32320 claude.exe, agreeing with CLAUDE_PID.
# The MSYS ancestry chain from <msys-pid> as "<msyspid>\t<winpid>\t<command>"
# lines, nearest first. One awk pass over the cached MSYS ps capture.
#
# Needed because a harness is not always a native .exe. MSYS ps preserves the
# executed path (argv[0]), so a harness that is a script or a symlink - which is
# how several verified adapters arrive on Git Bash, and how the test fixtures
# build a fake harness - is visible HERE and nowhere else. The Win32 table only
# ever shows bash.exe for those, so a walk that jumps straight to Win32 would
# skip right past them. MSYS ps columns: PID PPID PGID WINPID TTY UID STIME
# COMMAND, with COMMAND running to end of line.
fm_platform_msys_chain() { # <msys-pid> [max-hops]
  local pid=${1:-$$} hops=${2:-16}
  fm_platform_is_windows || return 1
  fm_platform_msys_snapshot_ensure || return 1
  printf '%s\n' "$FM_PLATFORM_MSYS_SNAPSHOT" | awk -v start="$pid" -v maxhops="$hops" '
    NR > 1 && $1 ~ /^[0-9]+$/ {
      ppid[$1] = $2
      winpid[$1] = $4
      cmd = $8
      for (i = 9; i <= NF; i++) cmd = cmd " " $i
      command[$1] = cmd
    }
    END {
      cur = start
      for (i = 0; i < maxhops; i++) {
        if (!(cur in ppid)) break
        print cur "\t" winpid[cur] "\t" command[cur]
        nxt = ppid[cur]
        if (nxt == "" || nxt + 0 <= 1 || nxt == cur) break
        cur = nxt
      }
    }
  '
}

# COMMAND recorded by MSYS ps for a WINDOWS pid, when that pid is an MSYS
# process. Lets liveness recognize a script harness the Win32 image name reports
# only as bash.exe.
fm_platform_msys_command_for_winpid() { # <winpid>
  local pid=$1 out
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_platform_is_windows || return 1
  out=$(fm_platform_msys_snapshot | awk -v p="$pid" '
    NR > 1 && $4 == p {
      cmd = $8
      for (i = 9; i <= NF; i++) cmd = cmd " " $i
      print cmd
      exit
    }')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

fm_platform_msys_root_winpid() {
  # Declared before assignment on purpose: `local a=$1 b=$a` does not see `a`
  # within the same declaration, which trips set -u.
  local start out
  start=${1:-$$}
  fm_platform_is_windows || return 1
  fm_platform_msys_snapshot_ensure || return 1
  # One awk pass. Walking hop by hop cost ~306ms for a two-hop chain, because
  # each awk is its own process and process spawns are the dominant cost here.
  # MSYS ps columns: PID PPID PGID WINPID TTY UID STIME COMMAND.
  out=$(printf '%s\n' "$FM_PLATFORM_MSYS_SNAPSHOT" | awk -v start="$start" '
    NR > 1 && $1 ~ /^[0-9]+$/ { ppid[$1] = $2; winpid[$1] = $4 }
    END {
      cur = start
      # 16 hops is generous: real MSYS chains here are two or three deep.
      for (i = 0; i < 16; i++) {
        if (!(cur in ppid)) break
        nxt = ppid[cur]
        # ppid 1 (or missing) means cur is already the MSYS root.
        if (nxt == "" || nxt + 0 <= 1 || nxt == cur) break
        cur = nxt
      }
      if (cur in winpid) print winpid[cur]
    }
  ')
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$out" ;;
  esac
}

# Build the snapshot into FM_PLATFORM_WIN_SNAPSHOT in the CALLER'S shell.
#
# This must be called directly, never as $(fm_platform_win_snapshot_ensure): a
# command substitution would populate the cache inside a subshell that then
# exits, so every later lookup would rebuild it and respawn wmic. A multi-hop
# ancestry walk did exactly that and cost 1111ms instead of one 346ms snapshot.
fm_platform_win_snapshot_ensure() {
  [ -z "$FM_PLATFORM_WIN_SNAPSHOT" ] || return 0
  FM_PLATFORM_WIN_SNAPSHOT=$(fm_platform_win_snapshot_build) || return 1
  [ -n "$FM_PLATFORM_WIN_SNAPSHOT" ]
}

# One snapshot of the Windows process table as "<pid>\t<ppid>\t<name>" lines,
# cached for this shell. Prefers wmic for speed, falls back to PowerShell CIM.
FM_PLATFORM_WIN_SNAPSHOT=""
fm_platform_win_snapshot() {
  if [ -n "$FM_PLATFORM_WIN_SNAPSHOT" ]; then
    printf '%s\n' "$FM_PLATFORM_WIN_SNAPSHOT"
    return 0
  fi
  fm_platform_win_snapshot_build
}

fm_platform_win_snapshot_build() {
  local raw ps_bin
  fm_platform_is_windows || return 1

  # wmic CSV columns are alphabetical: Node,Name,ParentProcessId,ProcessId.
  if command -v wmic >/dev/null 2>&1; then
    raw=$(wmic process get ProcessId,ParentProcessId,Name /format:csv 2>/dev/null \
      | tr -d '\r' \
      | awk -F, 'NF >= 4 && $4 ~ /^[0-9]+$/ { print $4 "\t" $3 "\t" $2 }')
  fi
  if [ -z "${raw:-}" ] && ps_bin=$(fm_platform_powershell); then
    # shellcheck disable=SC2016 # $_ and `t are PowerShell syntax; bash must not expand them.
    raw=$("$ps_bin" -NoProfile -NonInteractive -Command \
      'Get-CimInstance Win32_Process | ForEach-Object { "{0}`t{1}`t{2}" -f $_.ProcessId, $_.ParentProcessId, $_.Name }' \
      2>/dev/null | tr -d '\r')
  fi
  [ -n "${raw:-}" ] || return 1
  printf '%s\n' "$raw"
}

# The whole Windows ancestry chain from <winpid> as "<pid>\t<name>" lines, most
# recent first. One awk pass over the cached snapshot.
#
# This exists for cost, not elegance. Walking hop by hop through
# fm_platform_win_ppid / fm_platform_win_name means two command substitutions per
# hop, and process spawns are the dominant cost on Windows - measured elsewhere
# in this port at 27x to 271x the Linux figure for spawn-heavy work. Resolving
# the chain hop by hop took ~1376ms; one pass brings it near the cost of the two
# snapshots alone. That matters because bin/fm-claude-stop-autoarm.sh resolves
# harness identity on every turn-end hook, not once per session.
fm_platform_win_ancestry_chain() { # <winpid> [max-hops]
  local pid=$1 hops=${2:-8}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  fm_platform_win_snapshot | awk -F'\t' -v start="$pid" -v maxhops="$hops" '
    { ppid[$1] = $2; name[$1] = $3 }
    END {
      cur = start
      for (i = 0; i < maxhops; i++) {
        if (!(cur in name)) break
        print cur "\t" name[cur]
        nxt = ppid[cur]
        if (nxt == "" || nxt + 0 <= 0 || nxt == cur) break
        cur = nxt
      }
    }
  '
}

# Parent Windows pid of a Windows pid, read from the cached snapshot.
fm_platform_win_ppid() { # <winpid>
  local pid=$1 out
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  out=$(fm_platform_win_snapshot | awk -F'\t' -v p="$pid" '$1 == p { print $2; exit }')
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$out" ;;
  esac
}

# Image name of a Windows pid. Reads the snapshot when one is already cached,
# otherwise `ps -W`, which is cheaper than building a snapshot for one lookup.
#
# ps -W columns are PID PPID PGID WINPID TTY UID STIME COMMAND, and COMMAND is a
# full path that frequently contains spaces ("C:\Program Files\..."). Taking $NF
# would return a path fragment, so the command is rebuilt from field 8 onward
# before the basename is stripped.
fm_platform_win_name() { # <winpid>
  local pid=$1 out
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -n "$FM_PLATFORM_WIN_SNAPSHOT" ]; then
    out=$(printf '%s\n' "$FM_PLATFORM_WIN_SNAPSHOT" | awk -F'\t' -v p="$pid" '$1 == p { print $3; exit }')
  else
    out=$(ps -W 2>/dev/null | awk -v p="$pid" '
      $4 == p {
        cmd = $8
        for (i = 9; i <= NF; i++) cmd = cmd " " $i
        print cmd
        exit
      }')
    out=${out##*[\\/]}
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Full command line of a Windows pid. Only needed to recognize a harness hosted
# by a bare interpreter (node, python), so it stays a targeted per-pid query
# rather than bloating the bulk snapshot.
fm_platform_win_command() { # <winpid>
  local pid=$1 out ps_bin
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  ps_bin=$(fm_platform_powershell) || return 1
  out=$("$ps_bin" -NoProfile -NonInteractive -Command \
    "(Get-CimInstance Win32_Process -Filter 'ProcessId=$pid').CommandLine" 2>/dev/null | tr -d '\r')
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# Does any process hold <file> open? 0 held, 1 provably none, 2 cannot tell.
# Deliberately the same three-state contract as fm_lock_lsof_holder, so the
# staleness proof keeps its "uncertainty is not proof of death" property.
#
# lsof does not exist on Git Bash. Windows does not need it: file locking there
# is mandatory rather than advisory, so asking to open the file with no sharing
# is a direct test of whether anyone else holds a handle. Verified against a
# holder opened with FILE_SHARE_NONE and against one opened with shared
# read/write - both are detected, which makes this at least as strong a signal
# as an lsof scan.
#
# Only IOException means "held". Anything else (missing file, permission denied,
# an unusable interpreter) is reported as cannot-tell rather than guessed at.
fm_platform_win_file_holder() { # <file>
  local file=$1 winpath out ps_bin
  case "$file" in '') return 2 ;; esac
  fm_platform_is_windows || return 2
  ps_bin=$(fm_platform_powershell) || return 2
  if command -v cygpath >/dev/null 2>&1; then
    winpath=$(cygpath -w -- "$file" 2>/dev/null) || return 2
  else
    winpath=$file
  fi
  [ -n "$winpath" ] || return 2
  # The path is handed over through the environment rather than interpolated
  # into the command text, so a path containing quotes cannot break out of it.
  # shellcheck disable=SC2016 # $env: and $p are PowerShell syntax; bash must not expand them.
  out=$(FM_PROBE_PATH="$winpath" "$ps_bin" -NoProfile -NonInteractive -Command '
    $p = $env:FM_PROBE_PATH
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Write-Output "GONE"; exit }
    try {
      $fs = [System.IO.File]::Open($p, "Open", "ReadWrite", "None")
      $fs.Close(); $fs.Dispose()
      Write-Output "NO-HOLDER"
    } catch [System.IO.IOException] {
      Write-Output "HELD"
    } catch {
      Write-Output "UNKNOWN"
    }' 2>/dev/null | tr -d '\r')
  case "$out" in
    HELD) return 0 ;;
    NO-HOLDER|GONE) return 1 ;;
    *) return 2 ;;
  esac
}

# True when a Windows pid is live. `ps -W` is the cheap path; kill -0 is wrong
# here because MSYS kill does not speak Windows pids.
fm_platform_win_pid_alive() { # <winpid>
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  ps -W 2>/dev/null | awk -v p="$pid" '$4 == p { found = 1; exit } END { exit !found }'
}

# --- Getting a POSIX shell into a Windows crewmate pane -----------------------
#
# Every command firstmate types into a crewmate pane is POSIX, and not
# incidentally so. The harness launch line carries `VAR=value cmd` env prefixes
# (bin/fm-spawn.sh builds `FM_PI_HARNESS=... <cmd>` and the secondmate's
# `FM_HOME=... <cmd>`), which is shell syntax no Windows-native shell accepts.
# The pane's own shell is whatever the terminal launched, and on Windows that is
# PowerShell or cmd, never bash: herdr picks it from `default_shell` in the
# user's global config.toml, and `tab create` exposes no per-tab override.
#
# So the pane is switched to the same MINGW64 Git Bash firstmate itself runs in,
# once, before any POSIX text is sent. The alternative - teaching fm-spawn and
# every harness adapter to emit both POSIX and PowerShell forms of every command
# - would spread Windows into code that is otherwise platform-neutral, and would
# have to be maintained in step forever.
#
# Two verified traps this returns command lines for rather than guessing at:
#
#   * The launcher must be named by ABSOLUTE PATH. A bare `bash` from PowerShell
#     resolves to C:\Windows\System32\bash.exe - the WSL entry point - not to Git
#     Bash. On a machine with no WSL distro installed that fails with
#     "CreateProcessEntryCommon:502: execvpe /bin/bash failed 2"; on a machine
#     WITH one it would silently land the crewmate in an entirely different OS.
#   * <root>\bin\bash.exe and <root>\usr\bin\bash.exe are NOT interchangeable.
#     The first is Git for Windows' launcher and sets MSYSTEM=MINGW64; the second
#     is the raw MSYS binary and yields MSYSTEM=MSYS, a different PATH and a
#     different runtime from the one firstmate resolved its own tools against.
#     The launcher is therefore preferred and the raw binary is only a fallback.
#
# The two quoting forms are mutually safe, which is what makes trying them in
# order acceptable: `& '<path>' ...` runs the launcher in PowerShell and is a
# syntax error in cmd, while `"<path>" ...` runs it in cmd and merely echoes the
# string in PowerShell. Neither can do damage in the shell it is not meant for.
# The caller settles which one worked by probing the pane, so nothing here
# depends on knowing the pane's shell in advance.
fm_platform_windows_pane_bash_commands() {
  fm_platform_is_windows || return 1
  command -v cygpath >/dev/null 2>&1 || return 1
  local root launcher raw emitted=0
  if root=$(cygpath -w / 2>/dev/null) && [ -n "$root" ]; then
    root=${root%\\}
    launcher="$root\\bin\\bash.exe"
    printf "& '%s' --login -i\\n" "$launcher"
    printf '"%s" --login -i\n' "$launcher"
    emitted=1
  fi
  if raw=$(cygpath -w "${BASH:-/usr/bin/bash}" 2>/dev/null) && [ -n "$raw" ] \
    && [ "$raw" != "${launcher:-}" ]; then
    printf "& '%s' --login -i\\n" "$raw"
    printf '"%s" --login -i\n' "$raw"
    emitted=1
  fi
  [ "$emitted" = 1 ]
}
