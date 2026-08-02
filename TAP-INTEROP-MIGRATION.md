# Tap Interop Migration: ubrew → shared git tap store (official Homebrew interop)

**Status:** Implemented — 2026-08-02 (this document describes the design as built; phases 1–4 landed on `homebrew-parity`)
**Owner:** rjallais (ubrew project, `nanobrew-src` repo)
**Goal:** Make ubrew's tap subsystem interoperate with official Homebrew's git-based tap system by sharing the *same* tap store (`$HOMEBREW_PREFIX/Homebrew/Library/Taps/<user>/homebrew-<repo>`). `brew tap` and `ubrew tap` then manage one set of taps; the parallel `cache/taps` fetch registry is retired in shared mode and kept only as a standalone fallback (no brew installed).

---

## 1. Context: what exists today

Verified by source exploration (2026-08-02):

- ubrew (Odin, v0.1.0) stores tap *intent* in `$UBREW_ROOT/db/taps.txt` (`user/repo` or `user/repo<TAB>url`), trust in `$UBREW_ROOT/db/trusted_taps.txt`, and tap *content* as fetch caches under `$UBREW_ROOT/cache/taps/<user>/<repo>/`:
  - `Formula_listing.json` — GitHub Contents API listing (1h TTL, `.hit` sidecar caches winning probe)
  - `Formula/<name>.rb` / `Casks/<name>.rb` — raw files fetched from `raw.githubusercontent.com`
- ubrew **already reads** a real brew install (one-directional): `read_taps()` discovers `$HOMEBREW_PREFIX/Homebrew/Library/Taps/<user>/<repo>` dirs (strips `homebrew-` prefix), `scan_local_tap_formulae()` reads formulae from those dirs for search, and `trusted_taps_load()` merges Homebrew's `$HOMEBREW_PREFIX/etc/homebrew/trusted_taps` — loaded from the **runtime** prefix (the same prefix the shared taps dir is derived from), not the compiled-in default.
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

- **`Shared`** when `os.is_dir(platform.get_homebrew_prefix() + "/Homebrew/Library/Taps")` (a real brew install with a taps dir) — e.g. `/home/linuxbrew/.linuxbrew/Homebrew/Library/Taps` here.
- **`Standalone`** only when that directory does **not** exist → today's behavior, rooted at `$UBREW_ROOT/cache/taps`.

Mode detection is purely existence-based. If the Homebrew taps dir exists but is **not writable**, ubrew stays in `Shared` mode and the failing operation (clone, pull) errors out with a `brew tap` hint — it never falls back to `cache/taps` or a second tap store. That keeps `Library/Taps` the single source of truth instead of creating a divergent parallel store.

Both modes share one code path; the mode only selects *storage* and *fetch strategy*.

### 2.2 Storage layout (shared mode)

- Tap repo dir: `<shared>/<user>/<repo>` where `<shared>` = `$HOMEBREW_PREFIX/Homebrew/Library/Taps` and the folder name follows Homebrew's convention: `homebrew-<repo>` unless `<repo>` already starts with `homebrew-`.
  - Example: `gromgit/brewtils` → `Library/Taps/gromgit/homebrew-brewtils`; `ublue-os/experimental-tap` → `Library/Taps/ublue-os/homebrew-experimental-tap`.
- Source URL: explicit URL if given to `tap add`, else `https://github.com/<user>/homebrew-<repo>` (with the same prefix rule).
- `taps.txt` is **retired as source of truth in shared mode** — the directory set in `Library/Taps` is authoritative (exactly how `brew tap` works). `read_taps()` still merges `taps.txt` rows, but a row **without a backing clone** is filtered from the view: if `brew untap` removes a clone, the tap disappears from `ubrew tap` too (no phantom taps). Clone directories are tagged as *discovered* and are never written back into `taps.txt`. `ubrew tap add` in shared mode writes **no row** — the clone is the record — and `ubrew tap remove` drops the compat row. `taps.txt` stays meaningful for standalone installs and `ubrew bundle dump`.
- `homebrew/core` and `homebrew/cask` are **never cloned** — they stay on the formulae.brew.sh JSON API (unchanged; matches HOMEBREW-PARITY-PLAN.md non-goal).

### 2.3 Per-command behavior (shared mode)

| Command | New behavior | Fallback |
|---|---|---|
| `ubrew tap add <user>/<repo> [url]` | `git clone <url>` into a temp sibling `<dest>.tmp`, then `os.rename` into `<shared>/<user>/<repo>` only on success (readers never see a partial clone; failed temp dirs are removed). An existing clone is **validated** before "Already tapped": its origin remote must match the explicit URL, or be any working origin when none was given — a stale/partial/unrelated repo is re-cloned. Symlinks and path-escaping names are rejected up front. No `taps.txt` row is written (the clone is the record). Honors `UBREW_TAP_SHALLOW=1` → `--depth=1`. | Clone failure → error with hint `brew tap <user>/<repo> <url>`; the tap is not added |
| `ubrew tap remove / untap <tap>` | `rm -rf <shared>/<user>/<repo>` (remove dir) + drop `taps.txt` row, under the inter-process lock. Names with traversal components (`.`/`..`) and symlinked clone dirs are refused before any path math. | Standalone → today's row removal |
| `ubrew tap` (list) | Enumerate `Library/Taps` dirs (via `read_taps()`, already implemented); phantom `taps.txt` rows without clones are filtered | — |
| `ubrew install user/tap/formula` | Read `Formula/<name>.rb` from the local clone (letter-nested `Formula/<c>/<name>.rb` supported); parse + install as today | Standalone → current raw.githubusercontent fetch |
| `ubrew update` | Per cloned tap: `git -C <dir> pull --ff-only` (untrusted taps still skipped; keep aggregate "Updated N taps" + untrusted warning). The pull loop is serialized against other ubrew processes by the inter-process lock on `.ubrew.lock`. Drop Contents-API probes/`.hit` for shared taps. | Standalone → current probe pipeline |
| `ubrew search` | `scan_local_tap_formulae` becomes primary (already reads Library/Taps); extend for letter nesting | Standalone → cached listings |
| `ubrew --repo <tap>` | Report `<shared>/<user>/<repo>` path | Current cache dir path |

Trust model for third-party taps (anything not under `homebrew/`): a tap must be **explicitly trusted** — `ubrew tap trust <user/repo>` — before `ubrew tap add` or formula/cask lookups will use it. `homebrew/*` is always trusted, `HOMEBREW_NO_REQUIRE_TAP_TRUST` bypasses, and the effective trust list merges ubrew's `trusted_taps.txt` with the Homebrew install's `trusted_taps` (loaded from the **runtime** prefix). The Homebrew file is a read-only overlay — mutation commands (`tap trust`/`tap untrust`) operate only on ubrew's own file and never write into Homebrew's state.

### 2.4 Standalone mode

All current fetch code (Contents API probes, raw.githubusercontent, `.hit` sidecars, `cache/taps`) stays intact behind `mode() == .Standalone`. ubrew keeps its "no brew, no Ruby, single binary" property when installed alone. Git is only required in shared mode (brew already requires git, so this is free).

---

## 3. Code changes (implementation phases)

### Phase 1 — Tap storage layer (`src/tap/tap.odin`)

- Add `mode()` (shared/standalone detection) + `shared_taps_dir()`, `shared_tap_dir(name, url)` (folder-name + URL derivation per §2.2), `shared_tap_clone(name, url)`.
- `tap_add`: branch on mode → git clone (shared, no `taps.txt` row — the clone is the record) vs DB-only (standalone). Keep validation; clone into a temp sibling and rename, validate existing clones (§2.3).
- `tap_remove`: branch on mode → remove clone dir (shared, under the lock, with traversal/symlink rejection) vs row-only (standalone).
- `read_taps()`: in shared mode, enumerate `Library/Taps` as primary; tag clone dirs as *discovered* (never written back to `taps.txt`); filter `taps.txt` rows that have no backing clone so a `brew untap`'d tap disappears from the view (`homebrew/*` pseudo-taps stay, they are API-based and legitimately never cloned).
- `fetch_formula_ruby` / `fetch_cask_ruby`: add local-clone-first resolution (shared): `Formula/<name>.rb` → `Formula/<c>/<name>.rb` → root `<name>.rb`; keep raw fetch for standalone. `derive_branch_*` becomes standalone-only (guard calls).
- `tap_cache_path` / `tap_cask_cache_path`: **unused in shared mode**. The shared-mode contract is clone-only reads and writes — formula/cask listings and `.rb` files come straight from the clone, so `cache/taps` is never a second source of truth. It remains the store for standalone mode.
- All shared tap mutations (`tap_add`, `tap_remove`) and the `ubrew update` pull loop serialize on an inter-process fcntl advisory lock file `.ubrew.lock` inside the taps dir (see §5).
- New `tap_test.odin` unit tests (see §5).

### Phase 2 — Listing / search / install reads (`src/api/client.odin`)

- `fetch_tap_listing_cached`: shared mode → synthesize listing by walking the clone (`Formula/*.rb` + `Casks/*.rb`, letter-nested) — reuse/extract `scan_local_tap_formulae` walker; skip Contents API + `.hit`.
- `scan_local_tap_formulae`: add letter-nested `Formula/<c>/<name>.rb` handling (homebrew/core layout) so shared clones of core-style taps search correctly.
- `fetch_formula_tap` / `fetch_cask_tap`: route through local clone reads in shared mode (trust checks unchanged).
- `append_tap_formulae_matches`: read from clones in shared mode.

### Phase 3 — Update pipeline & CLI (`src/main.odin`)

- `run_update` tap-refresh block (5464–5739): shared mode → `git pull --ff-only` per cloned tap (keep untrusted-skip, aggregate summary, `print_untrusted_taps_warning`), wrapped in the inter-process `.ubrew.lock`; standalone keeps the probe loop.
- `run_tap` / `run_untap` / `run_trust` / `run_untrust`: wire new semantics; `ubrew tap` list shows shared set.
- `brew --repo` handler (8496–8503): shared mode → clone dir path.
- `maybe_auto_update`: unchanged.

### Phase 4 — `ubrew tap migrate` + live migration

New subcommand `ubrew tap migrate [-n|--dry-run] [--brewfile]`:

1. For each entry in `taps.txt` (excluding `homebrew/*` pseudo-taps — both `homebrew/core` and `homebrew/cask`): ensure a clone exists in shared `Library/Taps` (clone if missing), using the **stored tab-separated URL** when the row has one so non-default origins are preserved.
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
  - Shared-mode `tap_add` clones into a temp `Library/Taps` fixture (use a local `file://` origin); double-add is a no-op; `tap_remove` removes the dir; **no `taps.txt` row is written** by shared-mode add.
  - Local fetch resolution incl. letter-nested `Formula/w/wget.rb`; standalone fallback still hits raw URLs (mock by pointing at a fixture origin).
  - Mode detection: with/without a brew-like `Homebrew/Library/Taps` fixture.
  - Regression coverage for the review findings: traversal/`..` names rejected before any path math; `tap_remove` refuses symlinked clone dirs (target untouched); discovered clones are excluded from `write_taps` and phantom rows without clones are filtered from `read_taps` in shared mode; an existing clone whose origin remote mismatches the requested URL is re-cloned; a failed clone leaves no `.tmp` or destination dir behind; runtime-prefix Homebrew `trusted_taps` loading; own-file trust round-trip.
- **Integration (this box):** the §3.Phase-5 verification list; plus `brew tap <new>` then `ubrew tap` shows it without any `ubrew` action; plus external `brew untap <tap>` then `ubrew tap` no longer shows it (phantom `taps.txt` row filtered).
- **Regression:** existing `tests/smoke-test.sh` must pass unchanged (standalone paths).

**CI clean-runner setup** (required before the trust-gated and shared-path tests can run): on a fresh runner, create and own `/opt/ubrew` (`mkdir -p /opt/ubrew && chown` the build user), build the binary (`mise run build-prod` → `ubrew_prod`), pre-trust the taps the tests exercise (`ubrew tap trust ublue-os/tap` and `ubrew tap trust justrach/nanobrew`, or set `HOMEBREW_NO_REQUIRE_TAP_TRUST=1`), and add `/opt/ubrew/prefix/bin` to `GITHUB_PATH` so `ubrew` resolves. Without this setup the trust-gated and shared-path tests fail before they exercise the migration.

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Writing into `$HOMEBREW_PREFIX` needs permission | Standalone is used only when the taps dir does **not** exist. If it exists but is unwritable, ubrew stays in Shared mode and the failing operation errors with a `brew tap` hint — no `cache/taps` fallback, so no second tap store ever appears |
| Full clones of large taps (network/size) | Match Homebrew (full clone, needed for `git pull --ff-only`); opt-in `UBREW_TAP_SHALLOW=1` |
| Concurrent `brew tap` / `ubrew tap` on same dirs | ubrew serializes its own `tap add`/`tap remove`/`update` with an inter-process fcntl advisory lock on `<taps>/.ubrew.lock`. `brew` itself does not honor the lock, so mutations are kept short; "one tool at a time for add/remove" is user guidance, not enforcement |
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
