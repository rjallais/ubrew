#!/usr/bin/env bash
# Verify the release URLs/SHA256s in Formula/ubrew.rb are real and correct.
# Usage:
#   ./scripts/verify-formula-release.sh [path/to/ubrew.rb]
#   ./scripts/verify-formula-release.sh --local-dir build/release [path/to/ubrew.rb]
#
# Parses every `url` + `sha256` pair in the formula (order matters: a url
# line is followed by its sha256 line). Pairs whose SHA256 is `PLACEHOLDER`
# are skipped with a note (e.g. the macOS block until macOS assets exist).
#
# With --local-dir, assets already downloaded into that directory (e.g. by
# the release workflow) are verified offline by filename instead of
# re-downloading — this keeps the release pipeline hermetic.
# Requires: curl, shasum (macOS) or sha256sum (Linux), bash 4+/readarray.

set -euo pipefail

LOCAL_DIR=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-dir)
      LOCAL_DIR="$2"
      shift 2
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

FORMULA="${ARGS[0]:-Formula/ubrew.rb}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f "$FORMULA" ]]; then
  echo "usage: $0 [--local-dir DIR] [Formula/ubrew.rb]" >&2
  exit 1
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "no sha256 tool found" >&2
    return 1
  fi
}

# Collect url/sha256 pairs in document order.
mapfile -t URLS < <(grep -oE '^[[:space:]]*url "[^"]+"' "$FORMULA" | sed 's/.*url "//; s/"$//')
mapfile -t SHAS < <(grep -oE '^[[:space:]]*sha256 "[^"]+"' "$FORMULA" | sed 's/.*sha256 "//; s/"$//')

VERSION=$(awk '/^[[:space:]]*version[[:space:]]/ { print $2; exit }' "$FORMULA" | tr -d '"')
echo "Formula: $FORMULA"
echo "version=$VERSION"
echo "pairs=$(("${#URLS[@]}"))"

if [[ $(("${#URLS[@]}")) -ne $(("${#SHAS[@]}")) ]]; then
  echo "WARNING: url/sha256 pair counts differ; verifying min(${#URLS[@]},${#SHAS[@]}) pairs" >&2
fi

fail=0
checked=0
pairs=$((( ${#URLS[@]} < ${#SHAS[@]} )) && echo "${#URLS[@]}" || echo "${#SHAS[@]}")
for ((i = 0; i < pairs; i++)); do
  url="${URLS[$i]}"
  expected="${SHAS[$i]}"
  name="$(basename "$url")"

  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "SKIP: $name (sha256 placeholder '$expected')"
    continue
  fi

  checked=1
  tmp=""
  # Prefer a local copy matching the asset filename (release build output).
  if [[ -n "$LOCAL_DIR" && -f "$LOCAL_DIR/$name" ]]; then
    echo "CHECK: $name (local $LOCAL_DIR/$name)"
    got="$(sha256_of "$LOCAL_DIR/$name")"
  else
    echo "CHECK: $name (download $url)"
    tmp="$(mktemp)"
    if ! curl -gfsSL -o "$tmp" "$url"; then
      echo "  FAIL: could not download $url" >&2
      rm -f "$tmp"
      fail=1
      continue
    fi
    got="$(sha256_of "$tmp")"
    rm -f "$tmp"
  fi

  if [[ "$got" != "$expected" ]]; then
    echo "  FAIL: sha256 mismatch for $name" >&2
    echo "    expected: $expected" >&2
    echo "    got:      $got" >&2
    fail=1
  else
    echo "  OK ($name)"
  fi
done

if [[ "$checked" -eq 0 ]]; then
  echo "FAIL: no verifiable (non-placeholder) sha256 pairs found in $FORMULA" >&2
  exit 1
fi

if [[ "$fail" -ne 0 ]]; then
  echo "" >&2
  echo "Fix the formula or publish the GitHub Release for v$VERSION first. See docs/RELEASING.md" >&2
  exit 1
fi

echo ""
echo "All release URLs for v$VERSION look good."