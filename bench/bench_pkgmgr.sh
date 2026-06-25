#!/usr/bin/env bash
set -euo pipefail

RUNS=${RUNS:-3}
scenario=${1:-install}
PKG=${2:-${PKG:-tree}}

ms() { echo $(( ($2 - $1) / 1000000 )); }
median() { echo "$@" | tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

have() { command -v "$1" >/dev/null 2>&1; }

# Prefer repo-local nb-linux if nb isn't installed.
NB_BIN=""
if have nb; then
  NB_BIN="nb"
elif [ -x "./nb-linux" ]; then
  NB_BIN="./nb-linux"
fi

# Only treat brew as "real" Homebrew if its version output contains "Homebrew".
BREW_BIN=""
if [ -x "/var/home/linuxbrew/.linuxbrew/Homebrew/bin/brew" ]; then
  BREW_BIN="/var/home/linuxbrew/.linuxbrew/Homebrew/bin/brew"
elif have brew; then
  if brew --version 2>/dev/null | head -1 | grep -qi "homebrew"; then
    BREW_BIN="brew"
  fi
fi

UBREW_BIN=${UBREW_BIN:-./ubrew}

bench() {
  local label="$1"; shift
  local cmd=("$@")

  local t=()
  for i in $(seq 1 "$RUNS"); do
    if [ "$scenario" = "install" ]; then
      if [ "$label" = "ubrew" ]; then
        rm -rf /opt/ubrew/prefix/Cellar/"$PKG" 2>/dev/null || true
      elif [ "$label" = "nb" ]; then
        rm -rf /opt/nanobrew/prefix/Cellar/"$PKG" 2>/dev/null || true
      elif [ "$label" = "brew" ] && [ -n "$BREW_BIN" ]; then
        rm -rf "$("$BREW_BIN" --prefix)"/Cellar/"$PKG" 2>/dev/null || true
      fi
    fi

    local t1 t2
    t1=$(date +%s%N)
    "${cmd[@]}" >/dev/null 2>&1
    t2=$(date +%s%N)
    t+=("$(ms "$t1" "$t2")")
  done
  echo "$(median "${t[@]}")"
}

printf "%-12s %-10s %-10s %-10s\n" "scenario" "ubrew" "nb" "brew"
printf "%-12s %-10s %-10s %-10s\n" "--------" "-----" "--" "----"

case "$scenario" in
  install)
    u_ms=$(bench ubrew "$UBREW_BIN" install "$PKG")
    nb_ms="-"
    brew_ms="-"
    if [ -n "$NB_BIN" ]; then nb_ms=$(bench nb "$NB_BIN" install "$PKG"); fi
    if [ -n "$BREW_BIN" ]; then brew_ms=$(bench brew "$BREW_BIN" install "$PKG"); fi

    printf "%-12s %8sms %8sms %8sms\n" "install($PKG)" "$u_ms" "$nb_ms" "$brew_ms"
    ;;

  update)
    u_ms=$(bench ubrew "$UBREW_BIN" update)
    nb_ms="-"
    brew_ms="-"
    if [ -n "$NB_BIN" ]; then nb_ms=$(bench nb "$NB_BIN" update); fi
    if [ -n "$BREW_BIN" ]; then brew_ms=$(bench brew "$BREW_BIN" update); fi

    printf "%-12s %8sms %8sms %8sms\n" "update" "$u_ms" "$nb_ms" "$brew_ms"
    ;;

  upgrade)
    # No-op upgrade benchmark (common case). This intentionally does not
    # attempt to force packages out-of-date.
    u_ms=$(bench ubrew "$UBREW_BIN" upgrade)
    nb_ms="-"
    brew_ms="-"
    if [ -n "$NB_BIN" ]; then nb_ms=$(bench nb "$NB_BIN" upgrade); fi
    if [ -n "$BREW_BIN" ]; then brew_ms=$(bench brew "$BREW_BIN" upgrade); fi

    printf "%-12s %8sms %8sms %8sms\n" "upgrade" "$u_ms" "$nb_ms" "$brew_ms"
    ;;

  *)
    echo "usage: $0 {install|update|upgrade} [pkg]" >&2
    exit 2
    ;;
esac

if [ -z "$BREW_BIN" ]; then
  echo "" >&2
  echo "note: 'brew' not benchmarked (Homebrew not detected in PATH)." >&2
fi
if [ -z "$NB_BIN" ]; then
  echo "" >&2
  echo "note: 'nb' not benchmarked (install nanobrew or keep ./nb-linux executable)." >&2
fi
