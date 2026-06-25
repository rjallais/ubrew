#!/usr/bin/env bash
# Cross-tool benchmark: ubrew vs nb vs wax vs bru vs stout vs zb
# Usage: bench/bench_pkgmgr_all.sh <scenario>
#   scenarios: install-cold | install-warm | update | upgrade | info | search
#
# Each tool uses its own prefix / store so the comparison is fair.
# Env: SSL_CERT_FILE must be set (default /etc/ssl/certs/ca-bundle.crt)
#      HOMEBREW_PREFIX must point to bru's writable Cellar (default /tmp/bench-bru-prefix)
set -u

SCENARIO="${1:-install-warm}"
RUNS=3
PKG="dash-shell"

UBREW="${UBREW:-$(dirname "$0")/../ubrew}"
NB="${NB:-/usr/local/bin/nb}"
WAX="${WAX:-${HOME}/.local/share/mise/installs/github-plyght-wax/latest/wax}"
BRU="${BRU:-${HOME}/.local/share/mise/installs/cargo-kombrucha/0.2.3/bin/bru}"
STOUT="${STOUT:-${HOME}/.local/share/mise/installs/github-neul-labs-stout/latest/stout}"
ZB="${ZB:-${HOME}/.local/share/mise/installs/github-lucasgelfond-zerobrew/latest/zb}"

export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"
export HOMEBREW_PREFIX="${HOMEBREW_PREFIX:-/tmp/bench-bru-prefix}"

reset_ubrew() {
  rm -f /opt/ubrew/prefix/bin/dash /opt/ubrew/prefix/bin/dash-shell 2>/dev/null
  rm -rf /opt/ubrew/prefix/Cellar/dash-shell
  rm -rf /opt/ubrew/store/* /opt/ubrew/store-relocated/* 2>/dev/null
}

reset_nb() {
  rm -f /opt/nanobrew/prefix/bin/dash /opt/nanobrew/prefix/bin/dash-shell 2>/dev/null
  rm -rf /opt/nanobrew/prefix/Cellar/dash-shell
  rm -rf /opt/nanobrew/store/* /opt/nanobrew/store-relocated/* 2>/dev/null
  "$NB" uninstall "$PKG" >/dev/null 2>&1
}

reset_wax() {
  rm -f "${HOME}/.local/wax/bin/dash" "${HOME}/.local/wax/bin/dash-shell" 2>/dev/null
  rm -rf "${HOME}/.local/wax/Cellar/dash-shell"
  "$WAX" uninstall -y "$PKG" >/dev/null 2>&1
}

reset_bru() {
  rm -f "$HOMEBREW_PREFIX/bin/dash" "$HOMEBREW_PREFIX/bin/dash-shell" 2>/dev/null
  rm -rf "$HOMEBREW_PREFIX/Cellar/dash-shell"
}

reset_stout() {
  rm -rf "${HOME}/.local/share/stout" "${HOME}/.stout" 2>/dev/null
  "$STOUT" uninstall "$PKG" >/dev/null 2>&1
}

reset_zb() {
  rm -f "${HOME}/.local/share/zerobrew/prefix/bin/dash" "${HOME}/.local/share/zerobrew/prefix/bin/dash-shell" 2>/dev/null
  rm -rf "${HOME}/.local/share/zerobrew/prefix/Cellar/dash-shell"
  rm -rf "${HOME}/.local/share/zerobrew/store"/* 2>/dev/null
  "$ZB" uninstall "$PKG" >/dev/null 2>&1
}

reset_all() {
  reset_ubrew ; reset_nb ; reset_wax ; reset_bru ; reset_stout ; reset_zb
}

median() {
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'
}

to_ms() {
  # $1 = "XmY.YYYs" or "X.YYYs" or "X.YYY"  ->  milliseconds
  echo "$1" | awk -F'[m,s]' '
    {
      if ($0 ~ /m/) {
        m = $1; s = $2;
      } else {
        m = 0; s = $1;
      }
      gsub(/[^0-9.]/, "", s);
      val_m = (m ~ /^[0-9.]+$/) ? m : 0;
      val_s = (s ~ /^[0-9.]+$/) ? s : 0;
      printf "%d\n", val_m*60*1000 + val_s*1000 + 0.5
    }
  '
}

bench() {
  # bench <label> <cmd...>
  local label="$1" ; shift
  local times=()
  for i in $(seq 1 $RUNS); do
    local t ms
    t=$( { TIMEFORMAT=$'real\t%3R'; time "$@" >/dev/null 2>&1; } 2>&1 | awk '/real/{print $2}')
    ms=$(to_ms "$t")
    times+=("$ms")
  done
  local med
  med=$(median "${times[@]}")
  printf "  %-7s : median=%4sms  all=%s\n" "$label" "$med" "${times[*]}"
}

# Pre-warm one install for each tool so the first run's TCP+TLS handshake
# doesn't dominate. (The first cold run is in the 200-400ms range; after
# warmup it's <100ms.)
warmup() {
  echo "[warm-up: 1 install per tool]"
  # Reset only the five tools that are benchmarked and warmed up for package installation.
  # stout is excluded because it does not support/is not included in the install benchmarks.
  reset_ubrew ; reset_nb ; reset_wax ; reset_bru ; reset_zb
  "$UBREW" install "$PKG" >/dev/null 2>&1
  "$NB" install "$PKG" >/dev/null 2>&1
  "$WAX" install -y "$PKG" >/dev/null 2>&1
  "$BRU" install "$PKG" >/dev/null 2>&1
  "$ZB" init >/dev/null 2>&1
  "$ZB" install "$PKG" >/dev/null 2>&1
  echo ""
}

case "$SCENARIO" in
  install-cold)
    echo "=== install-cold: each run wipes store + Cellar (no API cache reset) ==="
    warmup
    # Note: This outer loop controls the visual rounds/grouping of the benchmark execution
    # to show run-to-run variation. The $RUNS variable controls the sample count used by
    # the bench function internally to compute each tool's median latency.
    for i in 1 2 3; do
      echo "--- run $i ---"
      reset_ubrew ; bench "ubrew" "$UBREW" install "$PKG"
      reset_nb    ; bench "nb"    "$NB" install "$PKG"
      reset_wax   ; bench "wax"   "$WAX" install -y "$PKG"
      reset_bru   ; bench "bru"   "$BRU" install "$PKG"
      reset_zb    ; bench "zb"    "$ZB" install "$PKG"
    done
    ;;

  install-warm)
    echo "=== install-warm: store + Cellar cache hit ==="
    warmup
    # Note: This outer loop controls the visual rounds/grouping of the benchmark execution
    # to show run-to-run variation. The $RUNS variable controls the sample count used by
    # the bench function internally to compute each tool's median latency.
    for i in 1 2 3; do
      echo "--- run $i ---"
      reset_ubrew ; bench "ubrew" "$UBREW" install "$PKG"
      reset_nb    ; bench "nb"    "$NB" install "$PKG"
      reset_wax   ; bench "wax"   "$WAX" install -y "$PKG"
      reset_bru   ; bench "bru"   "$BRU" install "$PKG"
      reset_zb    ; bench "zb"    "$ZB" install "$PKG"
    done
    ;;

  update)
    echo "=== update: full index refresh (14 taps) ==="
    for i in 1 2 3; do
      echo "--- run $i ---"
      bench "ubrew" "$UBREW" update
      bench "nb"    "$NB" update
      bench "wax"   "$WAX" update
      bench "bru"   "$BRU" update
      bench "stout" "$STOUT" update
      bench "zb"    "$ZB" update
    done
    ;;

  upgrade)
    echo "=== upgrade: nothing to upgrade ==="
    for i in 1 2 3; do
      echo "--- run $i ---"
      bench "ubrew" "$UBREW" upgrade
      bench "nb"    "$NB" upgrade
      bench "wax"   "$WAX" upgrade
      bench "bru"   "$BRU" upgrade
      bench "stout" "$STOUT" upgrade
      bench "zb"    "$ZB" upgrade
    done
    ;;

  info|search)
    echo "=== $SCENARIO $PKG ==="
    for i in 1 2 3; do
      echo "--- run $i ---"
      bench "ubrew" "$UBREW" "$SCENARIO" "$PKG"
      bench "nb"    "$NB" "$SCENARIO" "$PKG"
      bench "wax"   "$WAX" "$SCENARIO" "$PKG"
      bench "bru"   "$BRU" "$SCENARIO" "$PKG"
      bench "stout" "$STOUT" "$SCENARIO" "$PKG"
      bench "zb"    "$ZB" "$SCENARIO" "$PKG"
    done
    ;;

  *)
    echo "Unknown scenario: $SCENARIO" >&2
    exit 1
    ;;
esac
