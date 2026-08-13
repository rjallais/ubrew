#!/usr/bin/env bash
# Rewrite Formula/ubrew.rb for a released version (calendar SemVer scheme).
#
# Usage:
#   UBREW_VERSION=2026.8.1 \
#   UBREW_LINUX_SHA256=<sha> \
#   [UBREW_MACOS_ARM_SHA256=<sha>] [UBREW_MACOS_X86_SHA256=<sha>] \
#   bash scripts/update-formula.sh [outfile]
#
# If UBREW_LINUX_SHA256 is omitted, it is computed from UBREW_LINUX_TAR
# (path to the just-built build/release/ubrew-linux-x86_64.tar.gz).
# macOS SHAs are optional: absent/empty leaves the PLACEHOLDER block so
# macOS installs fail loudly until a macOS asset exists. The convention is
# that a formula for a stable release must always have a real Linux SHA256.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="${1:-Formula/ubrew.rb}"
VERSION="${UBREW_VERSION:-}"
VERSION="${VERSION#v}"

if [[ -z "$VERSION" ]]; then
  echo "usage: UBREW_VERSION=<YYYY.M.PATCH> bash scripts/update-formula.sh [OUTFILE]" >&2
  exit 1
fi

LINUX_SHA="${UBREW_LINUX_SHA256:-}"
if [[ -z "$LINUX_SHA" ]]; then
  LINUX_TAR="${UBREW_LINUX_TAR:-build/release/ubrew-linux-x86_64.tar.gz}"
  if [[ ! -f "$LINUX_TAR" ]]; then
    echo "ERROR: no UBREW_LINUX_SHA256 given and $LINUX_TAR not found" >&2
    exit 1
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    LINUX_SHA="$(sha256sum "$LINUX_TAR" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    LINUX_SHA="$(shasum -a 256 "$LINUX_TAR" | awk '{print $1}')"
  else
    echo "ERROR: no sha256 tool found" >&2
    exit 1
  fi
fi

# macOS SHAs default to PLACEHOLDER until real artifacts exist.
ARM_SHA="${UBREW_MACOS_ARM_SHA256:-}"
X86_SHA="${UBREW_MACOS_X86_SHA256:-}"
[[ -n "$ARM_SHA" ]] || ARM_SHA="PLACEHOLDER"
[[ -n "$X86_SHA" ]] || X86_SHA="PLACEHOLDER"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<FORMULA
class Ubrew < Formula
  desc "The fastest package manager. Written in Odin."
  homepage "https://github.com/rjallais/ubrew"
  license "Apache-2.0"
  version "${VERSION}"

  on_macos do
    # macOS binaries are built in CI (arm64 on macos-14, x86_64 on macos-15-intel)
    # and the SHA256 values below are filled automatically from the release
    # assets. They are unsigned for now (see docs/RELEASING.md). Until the
    # assets exist for a given version these stay PLACEHOLDER so installs
    # fail loudly instead of silently downloading an invalid archive.
    if Hardware::CPU.arm?
      url "https://github.com/rjallais/ubrew/releases/download/v${VERSION}/ubrew-arm64-apple-darwin.tar.gz"
      sha256 "${ARM_SHA}" # set from the macOS arm64 release asset
    else
      url "https://github.com/rjallais/ubrew/releases/download/v${VERSION}/ubrew-x86_64-apple-darwin.tar.gz"
      sha256 "${X86_SHA}" # set from the macOS x86_64 release asset
    end
  end

  on_linux do
    # Self-contained prebuilt binary (ubrew + libsqlite3-fts5.so); the
    # tarball's binary already carries a bare libsqlite3-fts5.so DT_NEEDED.
    url "https://github.com/rjallais/ubrew/releases/download/v${VERSION}/ubrew-linux-x86_64.tar.gz"
    sha256 "${LINUX_SHA}"
  end

  def install
    if OS.linux?
      bin.install "ubrew"
      lib.install "libsqlite3-fts5.so"
    elsif OS.mac?
      bin.install "ubrew"
      lib.install "libsqlite3-fts5.dylib"
    else
      bin.install "ubrew"
    end
  end

  def post_install
    ohai "Run 'ubrew init' to create the ubrew directory tree"
  end

  test do
    assert_match "ubrew", shell_output("#{bin}/ubrew help")
  end
end
FORMULA

echo "Wrote ${OUT}"
echo "  version: ${VERSION}"
echo "  linux sha256: ${LINUX_SHA}"
echo "  macos arm64 sha256: ${ARM_SHA}"
echo "  macos x86_64 sha256: ${X86_SHA}"