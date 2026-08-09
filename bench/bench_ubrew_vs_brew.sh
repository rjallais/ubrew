#!/usr/bin/env bash
#
# hyperfine benchmark: ubrew 0.2.0 (Odin) vs Homebrew 6.x on Linux.
# Default Linux layouts: ubrew kegs in $PREFIX/Cellar, brew kegs in
# $PREFIX/Homebrew/Cellar; ubrew state in /opt/ubrew (API cache, blobs,
# store). Both link into $PREFIX/bin.
#
# Scenarios:
#   version    pure startup/process overhead              (no network)
#   info       metadata query, warm caches                (no network)
#   search     index search, warm                         (no network)
#   noop       "install" when package already installed   (no network)
#   update     tap/API refresh                            (network, warm)
#   warm       install after keg removal, caches kept     (no network)
#   cold       install after keg+blob/store/bottle-cache removal (network)
#
# Env overrides: UBREW, BREW, PKG, RUNS_FAST, RUNS_NET, RUNS_COLD, OUT
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UBREW="${UBREW:-$REPO/ubrew}"
BREW="${BREW:-$(command -v brew 2>/dev/null || true)}"
PKG="${PKG:-tree}"
RUNS_FAST="${RUNS_FAST:-10}"
RUNS_NET="${RUNS_NET:-5}"
RUNS_COLD="${RUNS_COLD:-3}"
OUT="${OUT:-$REPO/bench/results}"

# Deterministic env for both tools.
export UBREW_TELEMETRY=0
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_ANALYTICS=1
export HOMEBREW_NO_ENV_HINTS=1
export CI=1
export LC_ALL=C

UBREW_BIN="$(readlink -f "$UBREW")"
[ -x "$UBREW_BIN" ] || { echo "ubrew binary not found: $UBREW" >&2; exit 2; }
[ -n "$BREW" ] || { echo "brew not found in PATH" >&2; exit 2; }
BREW_BIN="$(readlink -f "$BREW")"

PREFIX="${PREFIX:-/home/linuxbrew/.linuxbrew}"
CELLAR="$PREFIX/Cellar"                    # ubrew's Cellar (default Linux layout)
BREW_CELLAR="$PREFIX/Homebrew/Cellar"      # brew/Linuxbrew's actual Cellar
BIN="$PREFIX/bin"
UBREW_BLOBS="/opt/ubrew/cache/blobs"
UBREW_STORE="/opt/ubrew/store"
UBREW_STORE_RELOCATED="/opt/ubrew/store-relocated"
BREW_CACHE="$HOME/.cache/Homebrew"

KEG="$CELLAR/$PKG"
BREW_KEG="$BREW_CELLAR/$PKG"
BINLINK="$BIN/$PKG"
RM="/usr/bin/rm"

uver() { "$UBREW_BIN" version 2>/dev/null | head -1; }
bver() { "$BREW_BIN" --version 2>/dev/null | head -1; }

# Per-run reset: remove the kegs (+ bin links) so the install is real.
PREPARE_WARM="$RM -rf '$KEG' '$BREW_KEG' '$BINLINK'"
# Per-run reset: kegs + every blob/store/bottle cache so the install is cold.
PREPARE_COLD="/usr/bin/sh -c '$RM -rf \"$KEG\" \"$BREW_KEG\" \"$BINLINK\" \"$UBREW_BLOBS\" \"$UBREW_STORE\" \"$UBREW_STORE_RELOCATED\" \"$BREW_CACHE\"'"

run_hf() {
  # run_hf <name> <runs> <warmup> <prepare> <ubrew-cmd> <brew-cmd>
  local name="$1" runs="$2" warmup="$3" prepare="$4"
  local ucmd="$5" bcmd="$6"

  echo ""; echo "── $name (${runs} runs, warmup ${warmup}) ───────────────"
  hyperfine \
    --runs "$runs" \
    --warmup "$warmup" \
    --prepare "$prepare" \
    --export-json "$OUTDIR/$name.json" \
    --export-markdown "$OUTDIR/$name.md" \
    --shell=none \
    -n "ubrew 0.2.0" "$UBREW_BIN $ucmd" \
    -n "brew 6.x"    "$BREW_BIN $bcmd"
}

OUTDIR="$OUT/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$OUTDIR"

echo "══════════════════════════════════════════════════════════════"
echo "  $(uver)  vs  $(bver)"
echo "  host=$(uname -m) Linux  pkg=$PKG  kegs: ubrew=$CELLAR brew=$BREW_CELLAR"
echo "  runs: fast=${RUNS_FAST} net=${RUNS_NET} cold=${RUNS_COLD}"
echo "  results → $OUTDIR"
echo "══════════════════════════════════════════════════════════════"

# 1. Pure startup / process overhead.
run_hf "1-version" "$RUNS_FAST" 2 "true" "version" "--version"

# 2. Metadata lookup, warm caches (no network).
run_hf "2-info" "$RUNS_FAST" 1 "true" "info $PKG" "info $PKG"

# 3. Indexed search (no network; index built by `ubrew update`).
run_hf "3-search" "$RUNS_FAST" 1 "true" "search $PKG" "search $PKG"

# 4. "Already installed" no-op install.
run_hf "4-noop" "$RUNS_FAST" 1 "true" "install $PKG" "install $PKG"

# 5. Warm update (fresh taps/API; no-op refresh).
run_hf "5-update" "$RUNS_NET" 1 "true" "update" "update"

# 6. Warm reinstall: remove the keg, keep blobs/store caches.
run_hf "6-install-warm" "$RUNS_NET" 0 "$PREPARE_WARM" "install $PKG" "install $PKG"

# 7. Cold install: remove the keg + ubrew blobs/store + brew bottle cache.
run_hf "7-install-cold" "$RUNS_COLD" 0 "$PREPARE_COLD" "install $PKG" "install $PKG"

# 8. Upgrade no-op: with both kegs removed, "nothing to upgrade" for both
#    tools (avoids brew aborting on ubrew-written keg receipts — interop quirk).
run_hf "8-upgrade-formulae" "$RUNS_NET" 1 "$PREPARE_WARM" "upgrade --formulae" "upgrade --formulae"

# 9. Upgrade casks no-op (no casks installed/outdated).
run_hf "9-upgrade-casks" "$RUNS_NET" 1 "true" "upgrade --casks" "upgrade --casks"

# 10. Autoremove no-op: same clean state; no orphaned/unused deps to remove.
run_hf "10-autoremove" "$RUNS_FAST" 1 "$PREPARE_WARM" "autoremove" "autoremove"

echo ""
echo "=== done. see $OUTDIR/*.md / *.json ==="