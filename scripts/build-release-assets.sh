#!/usr/bin/env bash
# Build and package a ubrew release asset for the current OS/arch.
#
# Usage:
#   UBREW_VERSION=2026.8.1 bash scripts/build-release-assets.sh
#   bash scripts/build-release-assets.sh v2026.8.1
#
# Version notation follows the calendar-SemVer scheme used by mise/Odin:
# `vYYYY.M.PATCH` on the git tag; UBREW_VERSION is the bare `YYYY.M.PATCH`
# that gets compiled into the binary via `-define:UBREW_VERSION=...`.
#
# What this does (Linux x86_64):
#   1. Builds `ubrew` (+ the FTS5 SQLite library) with `-define:UBREW_VERSION`.
#   2. Rewrites the binary's DT_NEEDED to the bare `libsqlite3-fts5.so` and
#      sets RUNPATH `$ORIGIN/../lib`, so the artifact is self-contained and
#      relocatable (the formula's install() no longer needs `patchelf`).
#   3. Smoke-tests the patched binary from a `{bin,lib}` Homebrew-style layout.
#   4. Writes `build/release/ubrew-<target>.tar.gz` + `.sha256` sidecar.
#
# macOS is not wired up yet; the script exits non-zero there so the CI falls
# back to the documented manual macOS release flow (see docs/RELEASING.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

UBREW_VERSION="${1:-${UBREW_VERSION:-}}"
if [[ -z "$UBREW_VERSION" ]]; then
  echo "usage: UBREW_VERSION=<YYYY.M.PATCH> bash scripts/build-release-assets.sh" >&2
  exit 1
fi
UBREW_VERSION="${UBREW_VERSION#v}" # tolerate a leading `v`

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS-$ARCH" in
  Linux-x86_64)
    TARGET="linux-x86_64"
    LIBEXT="so"
    PATCH_ELF="1"
    ;;
  Darwin-*)
    echo "ERROR: macOS release packaging is not wired up yet." >&2
    echo "Build manually and follow docs/RELEASING.md." >&2
    exit 2
    ;;
  *)
    echo "ERROR: unsupported platform: $OS-$ARCH" >&2
    exit 2
    ;;
esac

LIB="src/vendor/odin-sqlite3/libsqlite3-fts5.${LIBEXT}"
LIB_ABS="$(readlink -f "$LIB")"
ASSET="ubrew-${TARGET}.tar.gz"
STAGING="build/release/staging/${TARGET}"
OUT="build/release/${ASSET}"

echo "==> ubrew release build ${UBREW_VERSION} (${TARGET})"

# 1. Build with the release version baked in.
odin build src -out:ubrew \
  -define:SQLITE3_CUSTOM_FTS5=true \
  -define:UBREW_VERSION="$UBREW_VERSION" \
  -o:speed -no-bounds-check
cp "src/vendor/odin-sqlite3/libsqlite3-fts5.${LIBEXT}" .

# 2. Stage the flat tarball contents (root: ubrew + libsqlite3-fts5.so).
rm -rf "$STAGING"
mkdir -p "$STAGING/root"
cp ubrew "$STAGING/root/ubrew"
cp "$LIB" "$STAGING/root/libsqlite3-fts5.so"

# 3. Make the artifact self-contained on Linux.
if [[ "${PATCH_ELF:-}" == "1" ]]; then
  echo "==> patching: NEEDED ${LIB_ABS} -> libsqlite3-fts5.so, RUNPATH \$ORIGIN/../lib"
  patchelf --replace-needed "$LIB_ABS" libsqlite3-fts5.so "$STAGING/root/ubrew"
  patchelf --add-rpath '$ORIGIN/../lib' "$STAGING/root/ubrew"
fi

# 4. Smoke-test from a Homebrew-style {bin,lib} layout.
mkdir -p "$STAGING/probe/bin" "$STAGING/probe/lib"
cp "$STAGING/root/ubrew" "$STAGING/probe/bin/ubrew"
cp "$STAGING/root/libsqlite3-fts5.so" "$STAGING/probe/lib/libsqlite3-fts5.so"
if ! "$STAGING/probe/bin/ubrew" version | grep -q "$UBREW_VERSION"; then
  echo "ERROR: staged binary reports the wrong version" >&2
  "$STAGING/probe/bin/ubrew" version >&2 || true
  exit 1
fi
echo "==> staged binary OK (ubrew $UBREW_VERSION, loads libsqlite3-fts5.so via RUNPATH)"

# 5. Tar + checksum sidecar.
mkdir -p "$(dirname "$OUT")"
(
  cd "$STAGING/root"
  tar -czf "$ROOT/${OUT}" ubrew libsqlite3-fts5.so
)
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT" | awk '{print $1}' > "${OUT}.sha256"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$OUT" | awk '{print $1}' > "${OUT}.sha256"
else
  echo "ERROR: no sha256 tool found" >&2
  exit 1
fi

echo "==> artifacts:"
ls -lh "$OUT" "${OUT}.sha256"
echo "SHA256: $(cat "${OUT}.sha256")"