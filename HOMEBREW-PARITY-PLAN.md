# Homebrew Parity Plan for `ubrew`

**Goal:** Close the user-visible behavioral gaps between `ubrew` and official Homebrew's `brew update` / outdated / tap-trust / upgrade flow, as captured in the comparison below.

**Status:** Draft — 2026-07-31

---

## 1. Current-state assessment

Expected Homebrew output (reference session):

```
==> Updating Homebrew...
==> Updated Homebrew from 728bcb3eca to 3cd83aa90d.
Updated 2 taps (homebrew/core and homebrew/cask).
==> New Formulae
==> Downloading https://formulae.brew.sh/api/formula.jws.json
git-pkgs-brief: Tool that detects and reports ...
==> New Casks
==> Downloading https://formulae.brew.sh/api/cask.jws.json
spacejump: Menu bar utility ...
==> Outdated Formulae
awscli

You have 1 outdated formula installed.
You can upgrade it with brew upgrade
or list it with brew outdated.
Warning: The following taps are not trusted:
  microsoft/inshellisense
  ublue-os/experimental-tap
...
==> Downloading bottle manifests
✔︎ Bottle Manifest awscli (2.36.13)  Downloaded  89.6KB/ 89.6KB
==> Would upgrade 1 outdated package
awscli 2.36.11 -> 2.36.13 (24.2MB)
==> Do you want to proceed with the upgrade? [y/n]
```

### Gap matrix

| # | Homebrew behavior | ubrew status | Location |
|---|---|---|---|
| G1 | `==> Updated Homebrew from <old> to <new>` | ubrew git-pulls `/opt/ubrew` but omits the short-SHA range line | `run_update()` in `src/main.odin` |
| G2 | `Updated N taps (homebrew/core and homebrew/cask)` aggregate summary | Per-tap `==> Updated tap %s successfully.` only; no aggregate | `run_update()` |
| G3 | `==> New Formulae` / `==> New Casks` listings after update | Not implemented (no diffing of API JSON lists) | `src/api/client.odin` |
| G4 | Signed `formula.jws.json` / `cask.jws.json` downloads | Uses unsigned `formula.json` / `cask.json` | `src/api/client.odin:47-48` |
| G5 | `==> Outdated Formulae` header + "You have N outdated formula installed. You can upgrade it with brew upgrade or list it with brew outdated." | Missing header and summary; `run_outdated()` prints per-item lines only | `run_outdated()` in `src/main.odin` |
| G6 | Batch "Warning: The following taps are not trusted" block with remediation (`brew untap`, `brew trust`, `HOMEBREW_NO_REQUIRE_TAP_TRUST`) | Per-tap interactive prompt or single `Error:` line; untrusted taps silently skipped during `update` (verbose-only) | `src/tap/tap.odin`, `src/api/client.odin` |
| G7 | `==> Would upgrade N outdated package(s)` + size estimate + `==> Do you want to proceed with the upgrade? [y/n]` (always asked) | Wording/estimate missing; prompt only shown in developer mode (`developer_state() == .On`) | `run_upgrade()` in `src/main.odin` |
| G8 | Auto-update before `install`/`upgrade` (governed by `HOMEBREW_AUTO_UPDATE_SECS`, `HOMEBREW_NO_AUTO_UPDATE`) | `run_update` runs only via the `update`/`up` dispatch; env vars are echoed, not enforced | `src/main.odin` dispatch |
| — | `==> Downloading bottle manifests` prepass | **Intentionally skipped by design** (ubrew API JSON embeds bottle URL+SHA) | `src/installer/installer.odin` |

---

## 2. Work items (implementation plan)

### W1 — Updated-from-to SHA range line (G1)

- In `run_update()` (src/main.odin), before `git -C <root> pull`, capture `git rev-parse --short HEAD`.
- After a successful pull capture the new short SHA; if different, print:
  `==> Updated ubrew from <old> to <new>.`
- If unchanged, keep `==> Homebrew is up-to-date!` **but rename to** `==> ubrew is up-to-date.` (branding touch-up in same pass).
- Suppress under `--auto-update` full-skip path.

### W2 — Aggregate "Updated N taps" summary (G2)

- Collect per-tap success/fallback/failure results in `run_update()` into a small array (`Updated_Tap` struct: name, result enum).
- Count **only** taps with a successful state change in the aggregate. After the loop print:
  - `Updated N tap(s) (<name> and <name>).` when N ≤ 3, else `Updated N taps (including <first>, <second>, ...)`.
  - Keep the per-tap `==> Updated tap %s successfully.` lines only under `-v/--verbose` to match Homebrew's quiet default.
- Report fallback and failure outcomes separately (a per-tap `==> <name> unchanged (fallback)` / `failed` line), so a fallback or failure is never counted as a successful update.
- On zero successful updates print `Already up-to-date.` **only** when every tap result is a clean success or a no-op. Suppress it whenever any tap fell back or failed (the per-tap fallback/failure lines are still printed) — a fallback or failed result means the update was incomplete, so the aggregate must never claim everything stayed up-to-date.

### W3 — New Formulae / New Casks diff listings (G3)

- Before overwriting `cache/formula.json` / `cache/casket.json` in `run_update()`, load the previous lists into a hash set of `name -> version` (reuse JSON loader in `src/api/client.odin`).
- After the new lists arrive, compute added names (and optionally version bumps for "Updated Formulae").
- Print sections:
  ```
  ==> New Formulae
  git-pkgs-brief: Tool that detects ...
  ==> New Casks
  spacejump: Menu bar utility ...
  ```
  with description from the API record. Cap each listing at ~50 lines (Homebrew truncates similarly); honor `--auto-update` by printing verbosely only on TTY.
- Skip sections when the previous cache is absent (first run).
- Odin gotchas to observe: no inline slice literals in `for` headers; use 4-arg `make([dynamic]T, 0, cap, allocator)`; free loaded JSON with the same allocator it was decoded with.

### W4 — Switch to JWS API JSONs (G4)

- Change `FORMULA_LIST_URL` / `CASK_LIST_URL` to `https://formulae.brew.sh/api/formula.jws.json` and `.../cask.jws.json`.
- Parsing: JWS payloads are `{"payload": "<base64 json>", "signatures": [...]}`; decode the payload to get the same JSON array as today (portable pure-Odin base64 decode lives in the stdlib `core:encoding/base64`).
- Verification (REQUIRED gate): do **not** silently trust unverified payloads. Either (a) verify signatures against pinned Homebrew public keys and only then make JWS the default source, or (b) keep the unsigned endpoints as the default and explicitly mark JWS-decoded metadata untrusted in-code. `UBREW_NO_VERIFY_JWS` is an **explicit insecure override**, never an automatic fallback; leaving it unset must fail closed. Until verification or (b) ships, do not flip JWS to the default source. **Phase 2** (optional, follow-up): vendor the Ruby bundler root cert chain / use `cosign`-style verify via an external tool — keep out of scope for the default path.
- Ensure `build_search_index()` and ETag caching work unchanged on decoded payloads.

### W5 — Outdated header + summary (G5)

- In `run_outdated()` human-output branch:
  - If any formula items: `==> Outdated Formulae`, list, blank line, then
    `You have N outdated formula(e) installed. / You can upgrade ... with ubrew upgrade / or list ... with ubrew outdated.`
  - Same for casks under `==> Outdated Casks`.
- Keep `--json=v1/v2`, `--quiet` (bare names), and piped-output behavior byte-identical — the summary appears only on TTY/verbose.
- Add `-q/--quiet` guard so the summary never pollutes script-parsible output (mirrors Homebrew).

### W6 — Batch untrusted-tap warning block (G6)

- New proc in `src/tap/tap.odin`: `format_untrusted_warning(allocator) -> (string, bool)` that collects all tapped repos failing `tap_is_trusted()` and formats:
  ```
  Warning: The following taps are not trusted:
    <user/repo>
    ...
  ubrew is currently ignoring formulae, casks and commands from these taps because tap trust is required.

  Untap them with:
    ubrew untap <a> <b>
  Trust whole taps with:
    ubrew tap trust <a> <b>
  To disable trust checks:
    export HOMEBREW_NO_REQUIRE_TAP_TRUST=1
  ```
- Emit it exactly **once** per command invocation. Consolidate ownership in a single dedup helper (e.g. `show_untrusted_warning_once()`), called from `run_update()` after tap refresh and from `run_upgrade()`; the second caller sees it was already shown and suppresses duplicate output, preserving the existing warning content and silent-skip behavior.
- Keep the per-tap interactive `prompt_and_trust_tap()` for *install/fetch* paths (that's superior UX to Homebrew there — don't regress it).
- Replace silent skipping in the update loop with this visible warning (keep the skip itself).

### W7 — Upgrade prompt parity (G7)

- Rename pre-upgrade header to Homebrew wording for the dry/confirm stage:
  `==> Would upgrade N outdated package(s)` + `%s %s -> %s (%s)` where `(%s)` is the bottle download size (available from API JSON `bottle.stable.files.*` entry or HEAD on the bottle URL; fall back to no size suffix if unknown).
- Make the confirmation prompt **always** ask on an interactive TTY (unless `-y/--yes` or non-TTY/`CI`), not developer-mode gated:
  `==> Do you want to proceed with the upgrade? [y/n] `
- Reuse `prompt_user_yes_no()`; add `--yes/-y` flag to `upgrade` for automation; keep `-n/--dry-run` printing the list without prompting.
- Note current main.odin line ~5811 developer gate gets deleted; developer mode keeps its other behaviors.

### W8 — Auto-update hook (G8)

- Add `maybe_auto_update()` called at the top of `install` and `upgrade` dispatch:
  - Skipped when `HOMEBREW_NO_AUTO_UPDATE` is set, `CI=1` without TTY, or command was `update` itself.
  - 24h freshness gate already exists in `run_update(--auto-update)`; wire `HOMEBREW_AUTO_UPDATE_SECS` to override the 86400 default.
- Runs `run_update(auto_update = true)`. **Atomicity:** fetch/network failures stay non-fatal warnings, but an `install`/`upgrade` must never continue after a *partially applied* update. Stage the complete metadata snapshot as a versioned generation (e.g. `cache/generations/<id>/` holding every list together), then commit it with a **single atomic switch of one active manifest** (a pointer file or directory symlink flip). Never rename the individual cache files independently. Preserve the previous generation if staging or the switch fails; mark the new state indeterminate; and **stop the dependent command** (propagate the failure) instead of treating it as a warning and continuing on a half-updated cache.

---

## 3. Explicit non-goals

- **Bottle-manifest prefetch step** (`==> Downloading bottle manifests`): ubrew's API payload already contains bottle URL + SHA256, so there is nothing to prefetch. Not implemented; document the deviation in README/AGENTS.md.
- **Full JWS signature verification** (Phase 2, optional follow-up).
- Replacing the API-JSON model with real `homebrew/core` / `homebrew/cask` git clones.

## 4. Testing

1. `mise run build` (see AGENTS.md §4 for clean-runner prep); run `./ubrew update`, `./ubrew outdated`, `./ubrew upgrade -n`, `./ubrew upgrade` with a tap downgraded locally in the cache to simulate staleness.
2. Fixture-based: keep a previous `formula.json` snapshot, drop a second snapshot with 2 added entries, assert `==> New Formulae` lists exactly those entries.
3. Tap-trust: establish a deterministic untrusted state before asserting — use a dedicated third-party tap fixture or explicitly clear/revoke any pre-existing trust entry for the tap — then `ubrew update` must print the W6 warning; `HOMEBREW_NO_REQUIRE_TAP_TRUST=1 ubrew update` must not.
4. Non-TTY: run `ubrew upgrade` against a controlled fixture with outdated packages, drain its complete output, then assert it exits with status **1** (abort) and no package mutation when no approval is present (no interactive question is emitted, no prompt is awaited, and nothing is upgraded without an explicit approval). With `--yes` (or `-n/--dry-run`), assert exit status **0**; only the `--yes` case may mutate packages.
5. Do **not** binary-check `--version` after install (AGENTS.md §3) — verify upgrades by keg dir + `ubrew list --versions`.

## 5. Suggested PR split

| PR | Items | Risk |
|---|---|---|
| 1 | W1, W2 (update output polish) | Low |
| 2 | W5 (outdated summary) + W7 (upgrade prompt always-on) | Medium (UX change) |
| 3 | W6 (batch tap-trust warning) | Low |
| 4 | W3 (new formulae/casks diffing) | Medium |
| 5 | W4 (JWS API JSONs) + W8 (auto-update hook) | Higher — network path changes |
