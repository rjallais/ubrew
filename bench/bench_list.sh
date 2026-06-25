#!/usr/bin/env bash
# Benchmark: ubrew list vs brew/nb/stout/wax/bru/zb list
# Requires: hyperfine ≥ 1.18
# Usage: bash bench/bench_list.sh
set -u

export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"
unset CURL_CA_BUNDLE

UBREW="${UBREW:-$(dirname "$0")/../ubrew}"
NB="${NB:-/usr/local/bin/nb}"
BREW="${BREW:-/home/linuxbrew/.linuxbrew/bin/brew}"
STOUT="${STOUT:-${HOME}/.local/share/mise/installs/github-neul-labs-stout/latest/stout}"
WAX="${WAX:-${HOME}/.local/share/mise/installs/github-plyght-wax/latest/wax}"
BRU="${BRU:-${HOME}/.local/share/mise/installs/cargo-kombrucha/0.2.3/bin/bru}"
ZB="${ZB:-${HOME}/.local/share/mise/installs/github-lucasgelfond-zerobrew/latest/zb}"

RUNS="${BENCH_RUNS:-20}"
WARMUP="${BENCH_WARMUP:-5}"
OUTDIR="${1:-/tmp}"

echo "=== list benchmark: ubrew vs brew vs nb vs stout vs wax vs bru vs zb ==="
echo "    runs=$RUNS  warmup=$WARMUP"
echo ""

cmds=()
for name_bin in \
  "ubrew list:$UBREW list" \
  "brew list:$BREW list" \
  "nb list:$NB list" \
  "stout list:$STOUT list" \
  "wax list:$WAX list" \
  "bru list:$BRU list" \
  "zb list:$ZB list"
do
  label="${name_bin%%:*}"
  cmd="${name_bin#*:}"
  bin="${cmd%% *}"
  if [ -x "$bin" ]; then
    cmds+=(--command-name "$label" "$cmd")
  else
    echo "  [skip] $label  ($bin not found)"
  fi
done

if [ ${#cmds[@]} -lt 6 ]; then
  echo "Error: fewer than 2 tools available" >&2
  exit 1
fi

hyperfine \
  --warmup "$WARMUP" \
  --runs "$RUNS" \
  --export-markdown "$OUTDIR/bench_list.md" \
  "${cmds[@]}"

echo ""
echo "=== Markdown table ==="
cat "$OUTDIR/bench_list.md"
