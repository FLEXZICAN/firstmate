#!/usr/bin/env bash
# fm-install-shellcheck.sh - install CI's pinned, verified ShellCheck build.
#
# Usage:
#   fm-install-shellcheck.sh <destination-directory>
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$("$ROOT/bin/fm-lint.sh" --required-version)"
# Upstream ships a single Windows zip with no arch suffix, against a
# linux.x86_64 tarball elsewhere; the layouts inside differ too, so extraction
# is selected alongside the asset rather than assumed.
case "$(uname -s 2>/dev/null || echo unknown)" in
  MINGW*|MSYS*|CYGWIN*)
    SHA256=8a4e35ab0b331c85d73567b12f2a444df187f483e5079ceffa6bda1faa2e740e
    ARCHIVE="shellcheck-v${VERSION}.zip"
    BINARY=shellcheck.exe
    EXTRACT=zip
    ;;
  *)
    SHA256=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    ARCHIVE="shellcheck-v${VERSION}.linux.x86_64.tar.xz"
    BINARY=shellcheck
    EXTRACT=tar
    ;;
esac
URL="https://github.com/koalaman/shellcheck/releases/download/v${VERSION}/${ARCHIVE}"
DESTINATION=${1:?usage: fm-install-shellcheck.sh <destination-directory>}
# RUNNER_TEMP is a NATIVE path on Windows runners (D:\a\_temp). Handing that to
# MSYS mktemp does not fail loudly - it produces a path the later download and
# checksum disagree about, which surfaces as a bogus "checksum mismatch" for an
# archive that is in fact byte-correct. Convert before use.
TMP_PARENT=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
case "$TMP_PARENT" in
  [A-Za-z]:\\*|[A-Za-z]:/*)
    if command -v cygpath >/dev/null 2>&1; then
      TMP_PARENT=$(cygpath -u "$TMP_PARENT")
    fi
    ;;
esac
TMP=$(mktemp -d "$TMP_PARENT/fm-shellcheck.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

DOWNLOAD_ATTEMPTS=3
download_attempt=1
while ! curl -fsSL "$URL" -o "$TMP/$ARCHIVE"; do
  [ "$download_attempt" -lt "$DOWNLOAD_ATTEMPTS" ] || {
    printf 'fm-install-shellcheck.sh: download failed after %s attempts\n' "$DOWNLOAD_ATTEMPTS" >&2
    exit 1
  }
  printf 'fm-install-shellcheck.sh: download attempt %s failed; retrying\n' "$download_attempt" >&2
  sleep "$download_attempt"
  download_attempt=$((download_attempt + 1))
done
ACTUAL_SHA256=$(sha256sum "$TMP/$ARCHIVE" | awk '{print $1}')
[ "$ACTUAL_SHA256" = "$SHA256" ] || {
  printf 'fm-install-shellcheck.sh: checksum mismatch for %s\n' "$ARCHIVE" >&2
  exit 1
}
if [ "$EXTRACT" = zip ]; then
  # The Windows zip puts the binary at the archive root, not under a versioned
  # directory the way the tarball does.
  command -v unzip >/dev/null 2>&1 || {
    printf 'fm-install-shellcheck.sh: unzip is required to install the Windows build\n' >&2
    exit 1
  }
  unzip -q -o "$TMP/$ARCHIVE" -d "$TMP/x"
  SOURCE="$TMP/x/$BINARY"
else
  tar -xJf "$TMP/$ARCHIVE" -C "$TMP"
  SOURCE="$TMP/shellcheck-v${VERSION}/$BINARY"
fi
mkdir -p "$DESTINATION"
install -m 0755 "$SOURCE" "$DESTINATION/$BINARY"
"$DESTINATION/$BINARY" --version
