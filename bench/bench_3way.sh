#!/usr/bin/env bash
#
# hyperfine benchmark: ubrew (Odin) vs Homebrew 6.x (Ruby) vs Nanobrew (Zig) on Linux.
#
# Scenarios:
#   1. version / startup     pure process & runtime startup overhead
#   2. info                  formula metadata query (warm cache)
#   3. search                indexed formula & cask search
#   4. noop install          install check when formula is already up to date
#   5. list                  listing installed packages
#   6. upgrade (no-op)       single-package upgrade when already up to date
#   7. warm install          reinstall after keg removal (blobs cached, COW / materialization)
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UBREW="${UBREW:-$REPO/ubrew}"
BREW="${BREW:-$(command -v brew 2>/dev/null || true)}"
NB="${NB:-$(command -v nb 2>/dev/null || true)}"
PKG="${PKG:-tree}"
RUNS_FAST="${RUNS_FAST:-15}"
RUNS_WARM="${RUNS_WARM:-5}"
OUT="${OUT:-$REPO/bench/results/round10-ubrew-vs-brew-vs-nanobrew}"

# Deterministic environment
export UBREW_TELEMETRY=0
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_PATH_SHADOW_CHECK=1
export CI=1
export LC_ALL=C

UBREW_BIN="$(readlink -f "$UBREW")"
[ -x "$UBREW_BIN" ] || { echo "ubrew binary not found: $UBREW" >&2; exit 2; }
[ -n "$BREW" ] || { echo "brew not found in PATH" >&2; exit 2; }
BREW_BIN="$(readlink -f "$BREW")"
[ -n "$NB" ] || { echo "nb not found in PATH" >&2; exit 2; }
NB_BIN="$(readlink -f "$NB")"

mkdir -p "$OUT"

uver() { "$UBREW_BIN" version 2>/dev/null | head -1; }
bver() { "$BREW_BIN" --version 2>/dev/null | head -1; }
nver() { "$NB_BIN" help 2>&1 | grep -i "nanobrew v" | head -1 | sed 's/^[[:space:]]*//'; }

echo "══════════════════════════════════════════════════════════════"
echo "  3-Way Benchmark: ubrew vs Homebrew 6.x vs Nanobrew"
echo "  ubrew:    $(uver) (Odin)"
echo "  brew:     $(bver) (Ruby)"
echo "  nanobrew: $(nver) (Zig)"
echo "  host:     $(uname -m) Linux ($(uname -r))"
echo "  package:  $PKG"
echo "  results:  $OUT"
echo "══════════════════════════════════════════════════════════════"

# Prepare tree across all managers so baseline is consistent
"$UBREW_BIN" install "$PKG" >/dev/null 2>&1 || true
"$BREW_BIN" install "$PKG" >/dev/null 2>&1 || true
"$NB_BIN" install "$PKG" >/dev/null 2>&1 || true

run_hf() {
  local name="$1" runs="$2" warmup="$3" prepare="$4"
  local ucmd="$5" bcmd="$6" ncmd="$7"

  echo ""
  echo "── $name (${runs} runs, warmup ${warmup}) ───────────────"
  hyperfine \
    --runs "$runs" \
    --warmup "$warmup" \
    --prepare "$prepare" \
    --export-json "$OUT/$name.json" \
    --export-markdown "$OUT/$name.md" \
    --shell=none \
    -n "ubrew (Odin)"    "$UBREW_BIN $ucmd" \
    -n "brew 6.x (Ruby)" "$BREW_BIN $bcmd" \
    -n "nanobrew (Zig)"  "$NB_BIN $ncmd"
}

# 1. Version / Startup overhead
run_hf "1-version" "$RUNS_FAST" 3 "true" "version" "--version" "help"

# 2. Metadata lookup (warm cache)
run_hf "2-info" "$RUNS_FAST" 2 "true" "info $PKG" "info $PKG" "info $PKG"

# 3. Indexed search
run_hf "3-search" 10 1 "true" "search $PKG" "search $PKG" "search $PKG"

# 4. Already installed (no-op install)
run_hf "4-noop-install" "$RUNS_FAST" 2 "true" "install $PKG" "install $PKG" "install $PKG"

# 5. List installed packages
run_hf "5-list" "$RUNS_FAST" 2 "true" "list" "list" "list"

# 6. Single-package upgrade check (already up to date)
run_hf "6-upgrade-tree" "$RUNS_FAST" 2 "true" "upgrade $PKG" "upgrade $PKG" "upgrade $PKG"

# 7. Warm reinstall: kegs removed, blobs cached
PREPARE_WARM="rm -rf /opt/ubrew/prefix/Cellar/$PKG /opt/ubrew/prefix/bin/$PKG /opt/ubrew/prefix/share/man/man1/$PKG.1 /opt/nanobrew/prefix/Cellar/$PKG /opt/nanobrew/prefix/bin/$PKG /opt/nanobrew/prefix/share/man/man1/$PKG.1 /home/linuxbrew/.linuxbrew/Cellar/$PKG /home/linuxbrew/.linuxbrew/bin/$PKG /home/linuxbrew/.linuxbrew/share/man/man1/$PKG.1"
run_hf "7-install-warm" "$RUNS_WARM" 0 "$PREPARE_WARM" "install $PKG" "install $PKG" "install $PKG"

# Restore state
"$UBREW_BIN" install "$PKG" >/dev/null 2>&1 || true
"$BREW_BIN" install "$PKG" >/dev/null 2>&1 || true
"$NB_BIN" install "$PKG" >/dev/null 2>&1 || true

echo ""
echo "=== Benchmark suite complete. Results written to $OUT ==="
