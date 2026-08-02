# Tap Interop Migration: ubrew → shared git tap store (official Homebrew interop)

**Status:** Draft — 2026-08-02
**Owner:** rjallais (ubrew project, `nanobrew-src` repo)
**Goal:** Make ubrew's tap subsystem interoperate with official Homebrew's git-based tap system by sharing the *same* tap store (`$HOMEBREW_PREFIX/Homebrew/Library/Taps/<user>/homebrew-<repo>`). `brew tap` and `ubrew tap` then manage one set of taps; the parallel `cache/taps` fetch registry is retired in shared mode and kept only as a standalone fallback (no brew installed).

---

## 1. Context: what exists today

Verified by source exploration (2026-08-02):

- ubrew (Odin, v0.1.0) stores tap *intent* in `$UBREW_ROOT/db/taps.txt` (`user/repo` or `user/repo<TAB>url`), trust in `$UBREW_ROOT/db/trusted_taps.txt`, and tap *content* as fetch caches under `$UBREW_ROOT/cache/taps/<user>/<repo>/`:
  - `Formula_listing.json` — GitHub Contents API listing (1h TTL, `.hit` sidecar caches winning probe)
  - `Formula/<name>.rb` / `Casks/<name>.rb` — raw files fetched from `raw.githubusercontent.com`
- ubrew **already reads** a real brew install (one-directional): `read_taps()` discovers `$HOMEBREW_PREFIX/Homebrew/Library/Taps/<user>/<repo>` dirs (strips `homebrew-` prefix), `scan_local_tap_formulae()` reads formulae from those dirs for search, and `trusted_taps_load()` merges Homebrew's `$HOMEBREW_PREFIX/etc/homebrew/trusted_taps` (only at default prefix).
- ubrew never clones taps; the only git usage in the codebase is ubrew's own self-update (`git -C $UBREW_ROOT pull`). `fetch_formula_tap`/`fetch_cask_tap` fetch `.rb` via raw URLs at install time; homebrew/core and homebrew/cask come from the formulae.brew.sh JSON API (never git-cloned — intentional, see non-goals).
- Key seams (from exploration): tap path vars in `src/tap/tap.odin:8-18`; `tap_add` (139–194, pure DB write); `tap_remove` (195–225); `read_taps` (47–116); `fetch_formula_ruby` (469–534); `fetch_cask_ruby` (741–767); `fetch_tap_listing_cached` (`src/api/client.odin:2497–2610`); `scan_local_tap_formulae` (2268–2330); `fetch_formula_tap` (1316–1423); update probe pipeline (`src/main.odin:5464–5739`); `run_tap`/`run_untap` (4281–4381); `brew --repo` (8496–8503).

**Live machine state (this host):**
- Official brew: `/home/linuxbrew/.linuxbrew` — 10 taps in `Library/Taps`.
- ubrew: `/opt/ubrew` — `taps.txt` has 10 entries (same set as brew + `homebrew/core`); `trusted_taps.txt` has 12 entries **including a corrupted `https:/` line**; `cache/taps/` holds Contents-API listings + fetched `.rb` files.
- Repo `Brewfile` declares 15 tap lines (desired state) — includes `microsoft/inshellisense` and `ublue-os/homebrew-experimental-tap` which are **not** in either tool's current tap set.

---

## 2. Design: shared git tap store

### 2.1 Mode detection (new)

`tap.mode()` returns:

- **`Shared`** when `os.is_dir(platform.get_homebrew_prefix() + "/Homebrew/Library/Taps")` (a real brew install with a taps dir) — e.g. `/home/linuxbrew/.linuxbrew/Homebrew/Library/Taps` here. Optionally require write access to that dir (probe with `access(W_OK)`).
- **`Standalone`** otherwise → today's behavior, rooted at `$UBREW_ROOT/cache/taps`.

Both modes share one code path; the mode only selects *storage* and *fetch strategy*.

### 2.2 Storage layout (shared mode)

- Tap repo dir: `<shared>/<user>/<repo>` where `<shared>` = `$HOMEBREW_PREFIX/Homebrew/Library/Taps` and the folder name follows Homebrew's convention: `homebrew-<repo>` unless `<repo>` already starts with `homebrew-`.
  - Example: `gromgit/brewtils` → `Library/Taps/gromgit/homebrew-brewtils`; `ublue-os/experimental-tap` → `Library/Taps/ublue-os/homebrew-experimental-tap`.
- Source URL: explicit URL if given to `tap add`, else `https://github.com/<user>/homebrew-<repo>` (with the same prefix rule).
- `taps.txt` is **retired as source of truth in shared mode** — the directory set in `Library/Taps` is authoritative (exactly how `brew tap` works). `taps.txt` entries are still honored (merge + dedupe, as `read_taps()` already does) so standalone entries and `ubrew bundle dump` keep working, but `tap add`/`tap remove` in shared mode operate on the filesystem.
- `homebrew/core` and `homebrew/cask` are **never cloned** — they stay on the formulae.brew.sh JSON API (unchanged; matches HOMEBREW-PARITY-PLAN.md non-goal).

### 2.3 Per-command behavior (shared mode)

| Command | New behavior | Fallback |
|---|---|---|
| `ubrew tap add <user>/<repo> [url]` | `git clone <url> <shared>/<user>/<repo>` (no clone if dir exists with `.git` → "Already tapped"). Records in `taps.txt` for compatibility. Honors `UBREW_TAP_SHALLOW=1` → `--depth=1`. | Clone failure + standalone → today's DB-only entry; clone failure + shared → error with hint `brew tap <user>/<repo>` |
| `ubrew tap remove / untap <tap>` | `rm -rf <shared>/<user>/<repo>` (remove dir) + drop `taps.txt` row | Standalone → today's row removal |
| `ubrew tap` (list) | Enumerate `Library/Taps` dirs (via `read_taps()`, already implemented) | — |
| `ubrew install user/tap/formula` | Read `Formula/<name>.rb` from the local clone (letter-nested `Formula/<c>/<name>.rb` supported); parse + install as today | Standalone → current raw.githubusercontent fetch |
| `ubrew update` | Per cloned tap: `git -C <dir> pull --ff-only` (untrusted taps still skipped; keep aggregate "Updated N taps" + untrusted warning). Drop Contents-API probes/`.hit` for shared taps. | Standalone → current probe pipeline |
| `ubrew search` | `scan_local_tap_formulae` becomes primary (already reads Library/Taps); extend for letter nesting | Standalone → cached listings |
| `ubrew --repo <tap>` | Report `<shared>/<user>/<repo>` path | Current cache dir path |

Trust model unchanged: `homebrew/*` always trusted, `HOMEBREW_NO_REQUIRE_TAP_TRUST` bypass, `trusted_taps.txt` + merged Homebrew `trusted_taps` file.

### 2.4 Standalone mode

All current fetch code (Contents API probes, raw.githubusercontent, `.hit` sidecars, `cache/taps`) stays intact behind `mode() == .Standalone`. ubrew keeps its "no brew, no Ruby, single binary" property when installed alone. Git is only required in shared mode (brew already requires git, so this is free).

---

## 3. Code changes (implementation phases)

### Phase 1 — Tap storage layer (`src/tap/tap.odin`)

- Add `mode()` (shared/standalone detection) + `shared_taps_dir()`, `shared_tap_dir(name, url)` (folder-name + URL derivation per §2.2), `shared_tap_clone(name, url)`.
- `tap_add`: branch on mode → git clone (shared) vs DB-only (standalone). Keep validation.
- `tap_remove`: branch on mode → remove clone dir (shared) vs row-only (standalone).
- `read_taps()`: in shared mode, treat `Library/Taps` enumeration as primary (already the merge behavior); no functional change needed beyond ordering.
- `fetch_formula_ruby` / `fetch_cask_ruby`: add local-clone-first resolution (shared): `Formula/<name>.rb` → `Formula/<c>/<name>.rb` → root `<name>.rb`; keep raw fetch for standalone. `derive_branch_*` becomes standalone-only (guard calls).
- `tap_cache_path` / `tap_cask_cache_path`: in shared mode point at the clone dir (or keep cache as write-through working copy — decide during impl; prefer reading straight from clone to avoid dual state).
- New `tap_test.odin` unit tests (see §5).

### Phase 2 — Listing / search / install reads (`src/api/client.odin`)

- `fetch_tap_listing_cached`: shared mode → synthesize listing by walking the clone (`Formula/*.rb` + `Casks/*.rb`, letter-nested) — reuse/extract `scan_local_tap_formulae` walker; skip Contents API + `.hit`.
- `scan_local_tap_formulae`: add letter-nested `Formula/<c>/<name>.rb` handling (homebrew/core layout) so shared clones of core-style taps search correctly.
- `fetch_formula_tap` / `fetch_cask_tap`: route through local clone reads in shared mode (trust checks unchanged).
- `append_tap_formulae_matches`: read from clones in shared mode.

### Phase 3 — Update pipeline & CLI (`src/main.odin`)

- `run_update` tap-refresh block (5464–5739): shared mode → `git pull --ff-only` per cloned tap (keep untrusted-skip, aggregate summary, `print_untrusted_taps_warning`); standalone keeps the probe loop.
- `run_tap` / `run_untap` / `run_trust` / `run_untrust`: wire new semantics; `ubrew tap` list shows shared set.
- `brew --repo` handler (8496–8503): shared mode → clone dir path.
- `maybe_auto_update`: unchanged.

### Phase 4 — `ubrew tap migrate` + live migration

New subcommand `ubrew tap migrate [-n|--dry-run] [--brewfile]`:

1. For each entry in `taps.txt` (excluding `homebrew/core`): ensure a clone exists in shared `Library/Taps` (clone if missing).
2. Remove now-stale `cache/taps/<name>/Formula_listing.json*`, `.hit`, `Formula/`, `Casks/` for migrated taps (caches rebuild on demand).
3. Repair `trusted_taps.txt`: drop the corrupted `https:/` line; report the diff.
4. `--brewfile`: reconcile the tap set against the repo `Brewfile` (desired state = its 15 tap lines) — add missing (`microsoft/inshellisense`, `ublue-os/homebrew-experimental-tap`), report anything extra.
5. `-n` prints before/after without changing anything.

Also write the doc **`TAP-INTEROP-MIGRATION.md`** in the repo (this plan, repo-formatted like `MIGRATION-PLAN.md` / `HOMEBREW-PARITY-PLAN.md`).

### Phase 5 — Live execution on this machine

1. `mise run build` (clean runner prep per AGENTS.md §4).
2. `./ubrew tap migrate -n` → review diff → `./ubrew tap migrate --brewfile`.
3. `brew tap` vs `ubrew tap` → verify identical sets.
4. `./ubrew update` → git pulls; `./ubrew search <tap-formula>` → hits from clones; `./ubrew install <user>/<tap>/<formula>` → installs from clone.

---

## 4. Testing

- **Unit (`odin test src -all-packages` / `mise run test-unit`) — new `tap_test.odin`:**
  - Folder-name derivation: `gromgit/brewtils` → `gromgit/homebrew-brewtils`; `ublue-os/experimental-tap` → `ublue-os/homebrew-experimental-tap`; explicit `homebrew-`-prefixed names pass through.
  - Shared-mode `tap_add` clones into a temp `Library/Taps` fixture (use a local `file://` origin); double-add is a no-op; `tap_remove` removes the dir.
  - Local fetch resolution incl. letter-nested `Formula/w/wget.rb`; standalone fallback still hits raw URLs (mock by pointing at a fixture origin).
  - Mode detection: with/without a brew-like `Homebrew/Library/Taps` fixture.
- **Integration (this box):** the §3.Phase-5 verification list; plus `brew tap <new>` then `ubrew tap` shows it without any `ubrew` action.
- **Regression:** existing `tests/smoke-test.sh` must pass unchanged (standalone paths); CI workflows untouched apart from adding the new unit test file.

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Writing into `$HOMEBREW_PREFIX` needs permission | Access probe in `mode()`; clear error + `brew tap` hint if unwritable; standalone fallback |
| Full clones of large taps (network/size) | Match Homebrew (full clone, needed for `git pull --ff-only`); opt-in `UBREW_TAP_SHALLOW=1` |
| Concurrent `brew tap` / `ubrew tap` on same dirs | Git handles concurrent clones/pulls; document "one tool at a time for add/remove" |
| homebrew/core letter-nested layout in local reads | Explicit `Formula/<c>/<name>.rb` resolution in Phases 1–2 |
| Removing `cache/taps` breaks search/install | Caches are derived state; clones replace them in shared mode; standalone untouched |
| `trusted_taps.txt` corruption | Repaired during `tap migrate`; add validation on write (`tap_trust` rejects names not matching `user/repo`) |
| Regression in standalone mode | Mode-gated code; existing smoke tests are the guard |

## 6. Non-goals

- Cloning `homebrew/core` / `homebrew/cask` (stay on formulae.brew.sh API; parity-plan non-goal stands).
- JWS signature verification (parity W4, separate).
- Writing trust state into Homebrew's `etc/homebrew/trusted_taps` (keep merge-only; optional follow-up).
- Qt/ArkUI/other platform work.

## 7. Execution order / PR split

1. **PR 1 — Storage layer:** `tap.odin` mode detection + git-clone `tap add/remove` + path derivation + unit tests. Also lands `TAP-INTEROP-MIGRATION.md`.
2. **PR 2 — Read paths:** `client.odin` local-clone-first fetch/listing/search (letter nesting).
3. **PR 3 — Update & CLI:** `run_update` git pulls, `run_tap`/`untap`/`brew --repo` wiring.
4. **PR 4 — Migrate command + live run:** `ubrew tap migrate`, trusted_taps repair, Brewfile reconcile; execute on this machine and verify.
