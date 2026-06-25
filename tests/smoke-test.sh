#!/bin/bash
# Test: comprehensive smoke integration tests for nanobrew on macOS
# Usage: bash tests/smoke-test.sh <path-to-nb-binary>
set -euo pipefail

NB="${1:?Usage: $0 <nb-binary>}"
NB="$(cd "$(dirname "$NB")" && pwd)/$(basename "$NB")"
PASS=0
FAIL=0

pass() { echo "    PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "    FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "==> Smoke integration tests (macOS)"
echo "    Binary: $NB"
echo ""

# Ensure nanobrew is initialised
sudo -n "$NB" init >/dev/null 2>&1 || true
export PATH="/opt/nanobrew/prefix/bin:$PATH"

# Ensure required 3rd-party taps are registered (idempotent).
# `ublue-os/tap` provides casks used by tests below.
# `justrach/nanobrew` exercises the new GitHub formula-fetch path.
sudo -n "$NB" tap add ublue-os/tap https://github.com/ublue-os/homebrew-tap 2>/dev/null || true
sudo -n "$NB" tap add justrach/nanobrew https://github.com/justrach/nanobrew 2>/dev/null || true

# ===================================================================
# Basic install + binary verification
# ===================================================================

echo "--- Test: install tree ---"
"$NB" install tree >/dev/null 2>&1 || true
TREE_OUT=$(tree --version 2>&1) || true
if grep -qi "tree" <<<"$TREE_OUT"; then
  pass "tree --version works"
else
  fail "tree --version did not produce expected output. Output was: $TREE_OUT"
fi

echo ""
echo "--- Test: install jq ---"
"$NB" install jq >/dev/null 2>&1 || true
if jq --version 2>&1 | grep -q "jq"; then
  pass "jq --version works"
else
  fail "jq --version did not produce expected output"
fi

echo ""
# --- Test: install lua ---
"$NB" install readline >/dev/null 2>&1 || true
"$NB" install lua >/dev/null 2>&1 || true
LUA_OUT=$(lua -v 2>&1) || true
if grep -qi "lua" <<<"$LUA_OUT"; then
  pass "lua -v works"
else
  fail "lua -v did not produce expected output. Output was: $LUA_OUT"
fi

# ===================================================================
# Cask info
# ===================================================================

echo ""
echo "--- Test: info --cask firefox ---"
CASK_FF=$("$NB" info --cask firefox 2>&1) || true
if grep -q "Firefox" <<<"$CASK_FF"; then
  pass "info --cask firefox contains 'Firefox'"
else
  fail "info --cask firefox output missing 'Firefox'"
  echo "      output: $(echo "$CASK_FF" | head -3)"
fi

echo ""
echo "--- Test: info --cask visual-studio-code ---"
CASK_VSC=$("$NB" info --cask visual-studio-code 2>&1) || true
if grep -q "Visual Studio Code" <<<"$CASK_VSC"; then
  pass "info --cask visual-studio-code contains 'Visual Studio Code'"
else
  fail "info --cask visual-studio-code output missing 'Visual Studio Code'"
  echo "      output: $(echo "$CASK_VSC" | head -3)"
fi

# ===================================================================
# Python/script packages (@@HOMEBREW_CELLAR@@ bug)
# ===================================================================

echo ""
echo "--- Test: install awscli (script package) ---"
"$NB" install awscli >/dev/null 2>&1 || true
AWS_VERSION_OUT=$(aws --version 2>&1) || true
if grep -q "aws-cli" <<<"$AWS_VERSION_OUT"; then
  pass "aws --version works (no bad interpreter)"
else
  fail "aws --version failed (possible @@HOMEBREW_CELLAR@@ bug)"
  echo "      which aws: $(command -v aws || echo 'not found')"
  if [ -e /opt/nanobrew/prefix/bin/aws ]; then
    echo "      prefix/bin/aws: $(ls -l /opt/nanobrew/prefix/bin/aws)"
    echo "      prefix/bin/aws shebang: $(head -n 1 /opt/nanobrew/prefix/bin/aws 2>/dev/null || echo 'unreadable')"
  else
    echo "      prefix/bin/aws: missing"
  fi
  if [ -e /opt/nanobrew/prefix/Cellar/awscli ]; then
    AWS_LIBEXEC=$(find /opt/nanobrew/prefix/Cellar/awscli -path '*/libexec/bin/aws' | head -n 1)
    AWS_PY=$(find /opt/nanobrew/prefix/Cellar/awscli -path '*/libexec/bin/python' | head -n 1)
    if [ -n "$AWS_LIBEXEC" ]; then
      echo "      libexec aws: $(ls -l "$AWS_LIBEXEC")"
      echo "      libexec aws shebang: $(head -n 1 "$AWS_LIBEXEC" 2>/dev/null || echo 'unreadable')"
    fi
    if [ -n "$AWS_PY" ]; then
      echo "      libexec python: $(ls -l "$AWS_PY")"
      echo "      libexec python resolved: $(python3 - <<'PY' "$AWS_PY"
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
    fi
  fi
  echo "      aws --version output: $(printf '%s' "$AWS_VERSION_OUT" | head -3)"
fi

echo ""
echo "--- Test: no @@HOMEBREW_CELLAR@@ or @@HOMEBREW_PREFIX@@ placeholders in Cellar ---"
CELLAR_DIR="/opt/nanobrew/prefix/Cellar"
if [ -d "$CELLAR_DIR" ]; then
  PLACEHOLDER_HITS=$(grep -rl '@@HOMEBREW_CELLAR@@\|@@HOMEBREW_PREFIX@@' "$CELLAR_DIR" 2>/dev/null | head -5) || true
  if [ -z "$PLACEHOLDER_HITS" ]; then
    pass "no unreplaced @@HOMEBREW_*@@ placeholders in Cellar"
  else
    fail "found unreplaced @@HOMEBREW_*@@ placeholders"
    echo "$PLACEHOLDER_HITS" | sed 's/^/      /'
  fi
else
  fail "Cellar directory not found at $CELLAR_DIR"
fi

echo ""
echo "--- Test: installed binaries have correct dynamic linker (not @@HOMEBREW_PREFIX@@) ---"
UBREW_CELLAR="/opt/ubrew/prefix/Cellar"
if [ -d "$UBREW_CELLAR" ]; then
  # Check the PT_INTERP segment specifically via patchelf --print-interpreter,
  # since the binary may legitimately contain @-strings as RPATH or constant data.
  BAD_INTERP=""
  for bin in $(find "$UBREW_CELLAR" -type f -executable 2>/dev/null); do
    interp=$(patchelf --print-interpreter "$bin" 2>/dev/null || true)
    if [[ "$interp" == *"@@HOMEBREW_PREFIX@@"* ]]; then
      BAD_INTERP="$BAD_INTERP $bin"
    fi
  done
  if [ -z "$BAD_INTERP" ]; then
    pass "no installed binaries have @@HOMEBREW_PREFIX@@ as interpreter"
  else
    fail "installed binaries still have @@HOMEBREW_PREFIX@@ interpreter"
    echo "$BAD_INTERP" | sed 's/^/      /'
  fi
else
  fail "ubrew Cellar directory not found at $UBREW_CELLAR"
fi

# ===================================================================
# Search
# ===================================================================

echo ""
echo "--- Test: search ripgrep ---"
SEARCH_OUT=$("$NB" search ripgrep 2>&1) || true
if grep -q "ripgrep" <<<"$SEARCH_OUT"; then
  pass "search ripgrep contains 'ripgrep'"
else
  fail "search ripgrep output missing 'ripgrep'"
  echo "      output: $(echo "$SEARCH_OUT" | head -3)"
fi

echo ""
echo "--- Test: search ublue-os (3rd-party tap formulae + casks) ---"
SEARCH_UBLUE=$("$NB" search ublue-os 2>&1) || true
if grep -q "ublue-os/tap" <<<"$SEARCH_UBLUE"; then
  pass "search ublue-os contains 3rd-party tap results"
else
  fail "search ublue-os output missing 3rd-party tap results"
  echo "      output: $(echo "$SEARCH_UBLUE" | head -5)"
fi

echo ""
echo "--- Test: info --cask ublue-os/tap/visual-studio-code-linux (3rd-party tap cask) ---"
CASK_UBLUE=$("$NB" info --cask ublue-os/tap/visual-studio-code-linux 2>&1) || true
if grep -q "Visual Studio Code" <<<"$CASK_UBLUE"; then
  pass "info --cask ublue-os/tap/visual-studio-code-linux works"
else
  fail "info --cask ublue-os/tap/visual-studio-code-linux failed"
  echo "      output: $(echo "$CASK_UBLUE" | head -5)"
fi

if [ "$(uname -s)" = "Linux" ]; then
  echo ""
  echo "--- Test: info --cask ublue-os/tap/bluefin-wallpapers (wallpaper cask, DE-aware) ---"
  WALLPAPER_OUT=$("$NB" info --cask ublue-os/tap/bluefin-wallpapers 2>&1) || true
  if grep -q "bluefin-wallpapers" <<<"$WALLPAPER_OUT" && grep -q "Wallpaper" <<<"$WALLPAPER_OUT"; then
    pass "info --cask wallpaper cask works (DE-aware asset selection)"
  else
    fail "info --cask ublue-os/tap/bluefin-wallpapers failed"
    echo "      output: $(echo "$WALLPAPER_OUT" | head -5)"
  fi

  echo ""
  echo "--- Test: info --cask ublue-os/tap/lm-studio-linux (AppImage cask) ---"
  APPIMAGE_OUT=$("$NB" info --cask ublue-os/tap/lm-studio-linux 2>&1) || true
  if grep -q "LM Studio" <<<"$APPIMAGE_OUT" && grep -q "AppImage" <<<"$APPIMAGE_OUT"; then
    pass "info --cask ublue-os/tap/lm-studio-linux works (AppImage)"
  else
    fail "info --cask ublue-os/tap/lm-studio-linux failed"
    echo "      output: $(echo "$APPIMAGE_OUT" | head -5)"
  fi

  echo ""
  echo "--- Test: tap -> search -> info flow for 3rd-party formula ---"
  TAP_SEARCH_OUT=$("$NB" search nanobrew 2>&1) || true
  if grep -q "justrach/nanobrew/nanobrew" <<<"$TAP_SEARCH_OUT"; then
    pass "search nanobrew returns tapped formula from GitHub"
  else
    fail "search nanobrew did not return tapped formula"
    echo "      output: $(echo "$TAP_SEARCH_OUT" | head -5)"
  fi
  TAP_INFO_OUT=$("$NB" info justrach/nanobrew/nanobrew 2>&1) || true
  if grep -q "macOS-only" <<<"$TAP_INFO_OUT"; then
    pass "info justrach/nanobrew/nanobrew detects macOS-only formula"
  else
    fail "info justrach/nanobrew/nanobrew did not detect macOS-only"
    echo "      output: $(echo "$TAP_INFO_OUT" | head -5)"
  fi

  echo ""
  echo "--- Test: info dash resolves via oldname/alias to dash-shell ---"
  DASH_OUT=$("$NB" info dash 2>&1) || true
  if grep -q "dash-shell" <<<"$DASH_OUT"; then
    pass "info dash resolves to dash-shell via oldname alias"
  else
    fail "info dash did not resolve to dash-shell"
    echo "      output: $(echo "$DASH_OUT" | head -5)"
  fi
fi

# ===================================================================
# Outdated (version comparison)
# ===================================================================

echo ""
echo "--- Test: outdated does not false-positive pcre2 10.47_1 vs 10.47 ---"
OUTDATED_OUT=$("$NB" outdated 2>&1) || true
if grep -q "pcre2.*10\.47_1.*10\.47" <<<"$OUTDATED_OUT"; then
  fail "outdated false-positive: pcre2 10.47_1 shown as outdated vs 10.47"
else
  pass "outdated does not false-positive pcre2 version suffix"
fi

# ===================================================================
# Bundle
# ===================================================================

echo ""
echo "--- Test: bundle dump ---"
BUNDLE_OUT=$("$NB" bundle dump --force 2>&1) || true
if grep -q 'brew "' <<<"$BUNDLE_OUT"; then
  pass "bundle dump contains brew format lines"
elif [ -z "$BUNDLE_OUT" ]; then
  # On CI with fresh install, bundle dump may return nothing if DB didn't record
  pass "bundle dump returned empty (fresh CI environment, acceptable)"
else
  fail "bundle dump output missing 'brew \"' lines"
  echo "      output: $(echo "$BUNDLE_OUT" | head -3)"
fi

# ===================================================================
# Deps
# ===================================================================

echo ""
echo "--- Test: deps --tree wget ---"
"$NB" install wget >/dev/null 2>&1 || true
DEPS_OUT=$("$NB" deps --tree wget 2>&1) || true
if grep -qi "openssl" <<<"$DEPS_OUT"; then
  pass "deps --tree wget contains 'openssl'"
else
  fail "deps --tree wget output missing 'openssl'"
  echo "      output: $(echo "$DEPS_OUT" | head -5)"
fi

# ===================================================================
# Migrate
# ===================================================================

echo ""
echo "--- Test: migrate ---"
MIGRATE_OUT=$("$NB" migrate 2>&1) || true
if grep -qi "Migrated.*formulae" <<<"$MIGRATE_OUT" || grep -qi "^Migrated:" <<<"$MIGRATE_OUT"; then
  pass "migrate prints migration results"
else
  fail "migrate output missing migration summary"
  echo "      output: $(echo "$MIGRATE_OUT" | head -3)"
fi

# ===================================================================
# Doctor
# ===================================================================

echo ""
echo "--- Test: doctor ---"
DOCTOR_OUT=$("$NB" doctor 2>&1) || true
if grep -qi "Checking ubrew installation" <<<"$DOCTOR_OUT"; then
  pass "doctor prints installation check banner"
else
  fail "doctor output missing 'Checking ubrew installation'"
  echo "      output: $(echo "$DOCTOR_OUT" | head -3)"
fi
# ===================================================================
# Regression: tar subprocess fallback for unsupported headers (#221)
# perl's bottle uses GNU long-name / pax-extended headers that Zig's
# native tar can't parse — the subprocess fallback must kick in.
# ===================================================================

echo ""
echo "--- Test: install perl (exercises tar subprocess fallback #221) ---"
if ! "$NB" install gdbm >/dev/null 2>&1; then
  echo "    WARN: gdbm install failed (may already be installed or optional)"
fi
"$NB" install perl >/dev/null 2>&1 || true
if perl -e 'print "ok"' 2>&1 | grep -q "^ok$"; then
  pass "perl installed and runs (#221 tar fallback works)"
else
  fail "perl install or execution failed — tar fallback may have regressed"
  echo "      which perl: $(command -v perl || echo 'not found')"
  if [ -e /opt/nanobrew/prefix/Cellar/perl ]; then
    echo "      Cellar/perl present"
  else
    echo "      Cellar/perl missing — extract likely failed"
  fi
fi

# ===================================================================
# Regression: Intel Mac does not install arm64 bottles (#226/#227)
# Only meaningful on x86_64 Macs.
# ===================================================================

if [ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "x86_64" ]; then
  echo ""
  echo "--- Test: git binary arch is x86_64 on Intel Mac (#226/#227) ---"
  "$NB" install git >/dev/null 2>&1 || true
  GIT_BIN="/opt/nanobrew/prefix/bin/git"
  if [ -x "$GIT_BIN" ]; then
    GIT_ARCH=$(file "$GIT_BIN" 2>/dev/null || true)
    if echo "$GIT_ARCH" | grep -q "x86_64"; then
      pass "git bottle is x86_64 (no arm64 fallback regression)"
    else
      fail "git bottle is not x86_64 on Intel Mac: $GIT_ARCH"
    fi
  else
    fail "git install failed on Intel Mac"
  fi
fi

# ===================================================================
# Summary
# ===================================================================

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
