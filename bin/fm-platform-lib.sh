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
