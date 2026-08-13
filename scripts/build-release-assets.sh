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
# What this does:
#   1. Builds `ubrew` (+ the FTS5 SQLite library) with `-define:UBREW_VERSION`.
#   2. Makes the artifact self-contained and relocatable:
#      - Linux: rewrites the binary's DT_NEEDED to the bare `libsqlite3-fts5.so`
#        and sets RUNPATH `$ORIGIN/../lib` (the formula's install() no longer
#        needs `patchelf`).
#      - macOS: points the dylib's install name at `@rpath/libsqlite3-fts5.dylib`
#        and adds LC_RPATH `@loader_path/../lib` so the binary finds the dylib
#        next to it in a Homebrew `{bin,lib}` layout.
#   3. Smoke-tests the patched binary from a `{bin,lib}` Homebrew-style layout.
#   4. Writes `build/release/ubrew-<target>.tar.gz` + `.sha256` sidecar.
#
# Targets: `linux-x86_64`, `arm64-apple-darwin`, `x86_64-apple-darwin`. macOS
# binaries are unsigned for now (codesigning + notarization is planned but
# requires Apple Developer ID credentials; see docs/RELEASING.md).
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
  Darwin-arm64|Darwin-aarch64)
    TARGET="arm64-apple-darwin"
    LIBEXT="dylib"
    PATCH_ELF=""
    ;;
  Darwin-x86_64)
    TARGET="x86_64-apple-darwin"
    LIBEXT="dylib"
    PATCH_ELF=""
    ;;
  *)
    echo "ERROR: unsupported platform: $OS-$ARCH" >&2
    exit 2
    ;;
esac

LIB="src/vendor/odin-sqlite3/libsqlite3-fts5.${LIBEXT}"
LIB_BASENAME="$(basename "$LIB")"
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

# 2. Stage the flat tarball contents (root: ubrew + libsqlite3-fts5.{so,dylib}).
rm -rf "$STAGING"
mkdir -p "$STAGING/root"
cp ubrew "$STAGING/root/ubrew"
cp "$LIB" "$STAGING/root/${LIB_BASENAME}"

# 3. Make the artifact self-contained and relocatable.
if [[ "${PATCH_ELF:-}" == "1" ]]; then
  # Linux: rewrite DT_NEEDED to the bare .so and add RUNPATH so the binary
  # finds libsqlite3-fts5.so in a Homebrew {bin,lib} layout.
  LIB_ABS="$(readlink -f "$LIB")"
  echo "==> patching: NEEDED ${LIB_ABS} -> libsqlite3-fts5.so, RUNPATH \$ORIGIN/../lib"
  patchelf --replace-needed "$LIB_ABS" libsqlite3-fts5.so "$STAGING/root/ubrew"
  patchelf --add-rpath '$ORIGIN/../lib' "$STAGING/root/ubrew"
elif [[ "$OS" == "Darwin" ]]; then
  # macOS: point the dylib's install name at @rpath and add LC_RPATH
  # @loader_path/../lib, mirroring the Linux relocation so the binary finds
  # libsqlite3-fts5.dylib in a Homebrew {bin,lib} layout.
  echo "==> patching: dylib id @rpath/${LIB_BASENAME}, LC_RPATH @loader_path/../lib"
  xcrun install_name_tool -id "@rpath/${LIB_BASENAME}" "$STAGING/root/${LIB_BASENAME}"
  DYLIB_LOAD="$(otool -L "$STAGING/root/ubrew" 2>/dev/null | awk '/libsqlite3-fts5/ {print $1; exit}')"
  if [[ -n "$DYLIB_LOAD" ]]; then
    xcrun install_name_tool -change "$DYLIB_LOAD" "@rpath/${LIB_BASENAME}" "$STAGING/root/ubrew"
  fi
  xcrun install_name_tool -add_rpath '@loader_path/../lib' "$STAGING/root/ubrew"
fi

# 4. Smoke-test from a Homebrew-style {bin,lib} layout.
mkdir -p "$STAGING/probe/bin" "$STAGING/probe/lib"
cp "$STAGING/root/ubrew" "$STAGING/probe/bin/ubrew"
cp "$STAGING/root/${LIB_BASENAME}" "$STAGING/probe/lib/${LIB_BASENAME}"
if ! "$STAGING/probe/bin/ubrew" version | grep -q "$UBREW_VERSION"; then
  echo "ERROR: staged binary reports the wrong version" >&2
  "$STAGING/probe/bin/ubrew" version >&2 || true
  exit 1
fi
echo "==> staged binary OK (ubrew $UBREW_VERSION, loads libsqlite3-fts5.${LIBEXT} via RPATH)"

# 5. Tar + checksum sidecar.
mkdir -p "$(dirname "$OUT")"
(
  cd "$STAGING/root"
  tar -czf "$ROOT/${OUT}" ubrew "${LIB_BASENAME}"
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