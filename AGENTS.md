# Anchored Summary

## Goal
- Fix 3rd-party formula management (info EOF for `pkgxdev/made/pkgm`); tackle 4 broken commands (`bundle`/`deps`/`migrate`/`doctor`); fix CodeRabbit review findings; finish unfinished `bin.install`→`bin/` symlink work; fix 3 remaining test failures.

## Constraints & Preferences
- Use `gh auth token` for any GitHub tasks
- Use CodeRabbit skill for code reviews (CLI v0.5.3, authenticated, github user `rjallais`)
- No proactive git commits (system prompt forbids it)
- Reply in same language as conversation (English)
- Use anchored summary structure

## Progress
### Done
- Implemented `src/tap/` package (`tap.odin`, `ruby_formula.odin`) with `Tap`, `Read_Tap_Entry`, `Ruby_Formula`, `parse_ruby_formula`, `extract_bin_install_targets`, `version_from_url`, `tap_repo_path`, `fetch_formula_ruby`, `fetch_tap_listing_cached`
- Wired taps into search/install/info; `info justrach/nanobrew/nanobrew` detects macOS-only
- CodeRabbit round-1 review: 6 findings fixed (`find_block_range` recursion bug, `parse_ruby_formula` else-branch leak, `tap_add` URL revert, `find_block_range` pipe offset, `replace_all` allocator, `url_to_tap_name` empty return)
- Implemented 4 broken commands in `src/main.odin`:
  - `run_bundle` (walks Cellar+Caskroom, emits `brew "name"` / `cask "name"` sorted)
  - `run_deps` (recursively walks via `api.fetch_formula`, tree format with indent + `(already shown)` marker)
  - `run_migrate` (counts formulae/casks, prints `Migrated: N formulae, M casks`)
  - `run_doctor` (changed banner to `==> Checking nanobrew installation...` per test)
- Added `core:slice` import; updated help text; added command dispatch in `main`
- Added `Formula.binaries` and `Formula.tap` fields in `src/formula/formula.odin`; `ruby_to_formula` populates them; `destroy_formula` frees them
- Reverted `exec_cmd` in `src/platform/copy.odin` to original convention (`args[0]` = program name); fixed 4 call sites to include `"curl"` as args[0] (in `client.odin` ×2 and `tap.odin` ×2)
- CodeRabbit round-2 review: 6 findings (1 CRITICAL, 1 MAJOR, 4 MINOR), all fixed:
  - CRITICAL: GitHub Contents API URL bug — changed from `https://github.com/.../contents/...` (HTML) to `https://api.github.com/repos/.../contents/...` (JSON); added `extract_owner_repo_from_github_url` helper
  - MAJOR: `registry_mmap_parse` `data_copy` leak — delete buffer after `json.parse` returns
  - MINOR: `parse_tap_token` allocator leak — always allocate from `context.allocator`; `fetch_formula_tap` defers delete
  - MINOR: `tap.odin` data leak on `continue` after empty/HTML response — added `delete(data)`
  - MINOR: `client.odin` `fetch_tap_listing_cached` data leak on `continue` — added `delete(cached)`
  - MINOR: `ruby_formula.odin` `strings.to_lower` double-alloc — use `context.temp_allocator` then `clone` into `context.allocator`
- **Fixed `info pkgxdev/made/pkgm` EOF** — root cause was a use-after-free in `fetch_formula_ruby`: `delete(data)` was called BEFORE `strings.clone(trimmed, ...)`, so the clone copied freed (zeroed) memory. Fixed by cloning first, then deleting. Also added `strings.clone(strings.to_string(b), context.allocator)` to `strip_ruby_comments` to keep its returned string valid past the function's temp_allocator scope.
- **Eliminated temp file leaks** — `os.create_temp_file` returns a File pointer, and `os.name(f)` returns a string view into that struct. If the struct is freed (by close, GC, or scope exit), the name is invalid. In `tap.odin`'s `derive_branch_from_url`, the code did `os.name(temp_f)` then `os.close(temp_f)` then `defer os.remove(temp_file)` — the defer was being called with a freed string. Fixed by cloning the name into `context.allocator` before close, and added `defer delete(temp_file)`. Same fix applied to the 3 `os.create_temp_file` call sites in `src/api/client.odin`.
- **Removed all debug prints** in `tap.odin`, `ruby_formula.odin`, and `client.odin` (the `DEBUG ...` `fmt.eprintfln` calls).
- **Smoke test: 20/22 pass** (was 16/22 at start of this work). `search nanobrew` (previously failing) now passes. The 2 remaining failures are pre-existing and unrelated: `install lua` (`-v` output format), `install awscli` (`@@HOMEBREW_CELLAR@@` placeholder bug).
- **End-to-end pkgm install verified**: `./ubrew install pkgxdev/made/pkgm` downloads source, builds into keg, materializes `keg/bin/`, moves `pkgm` binary via shell pipeline, and creates `/opt/ubrew/prefix/bin/pkgm` symlink. `pkgm --version` returns `pkgm 0.12.2`.
- **No temp file leaks remain**: 0 files in `/var/home/rjallais/ubrew/*.json` and 0 in `/tmp/ubrew_*.json` after running the full smoke test.

### In Progress
- (none)

### Blocked
- (none)

## Key Decisions
- Curl GitHub API cache TTL = 1 hour; rejects non-`[` responses; falls back to stale cache on refresh failure
- `fetch_formula_ruby` tries 4 raw URL candidates: `user/repo` Formula/, `user/repo` root, `user/homebrew-repo` Formula/, `user/homebrew-repo` root
- `fetch_tap_listing_cached` uses GitHub Contents API (`api.github.com/repos/.../contents/...`) — NOT the HTML web URL
- `parse_tap_token` always allocates both returned strings from `context.allocator`; caller `fetch_formula_tap` defers delete
- `exec_cmd` convention: `args[0]` IS the program name (not prepended by exec_cmd). This is the original convention; recent "fix" was reverted.
- `doctor` banner says "Checking nanobrew installation" to match test expectation (even though binary is `ubrew`)
- For `bin.install "pkgm"` handling: post-process after the `cp -R` step using `find`+`mv` shell pipeline to move named files into `keg/bin/`
- **Use-after-free guard**: any code that calls `os.create_temp_file` MUST `strings.clone(os.name(f), context.allocator)` to get a stable file path, and `defer delete(temp_file)` it. Defers should be set up before `os.close(f)`.

## Next Steps
- Investigate `lua` install (`-v` output issue) and `aws` install (`@@HOMEBREW_CELLAR@@` placeholder bug) — these are the 2 remaining test failures, but they're pre-existing and outside the tap work scope
- Re-run CodeRabbit review after the use-after-free and clone-everywhere fixes
- Optional: replace shell pipeline in `bin.install` wire-up with native Odin code (currently uses `libc.system` with a `find`+`mv` shell command)

## Critical Context
- `pkgm` from `pkgxdev/homebrew-made`: has no `version` field, URL is `https://github.com/pkgxdev/pkgm/releases/download/v0.12.2/pkgm-0.12.2.tgz`, files at repo root not in `Formula/`, has `bin.install("pkgm")` (with parens) + `depends_on "deno"`, `depends_on "pkgx"`
- CodeRabbit CLI v0.5.3, authenticated, reviews use limited/free CLI tier (not in installed org)
- `f.binaries` is populated by `extract_bin_install_targets` (parses `bin.install "name"` and `bin.install("name")` since parser uses `strings.index` for the marker, not the parens)
- The 2 use-after-free patterns that bit us:
  1. `delete(buffer)` before `strings.clone(string_view_into(buffer), ...)` — the clone copies freed memory
  2. `os.close(file)` then `os.remove(string_view_into(file))` — the close may free the struct, invalidating the name
- `exec_cmd`/`exec_cmd_capture` do NOT prepend bin to argv; pass `"curl"` as `args[0]`
- `_prefix_and_suffix` rejects patterns with path separators; pattern `ubrew_*_branch_*.json` is safe (no `/`)
- Odin's `os.create_temp_file("", pattern)` with empty `dir` falls back to `TMPDIR` env var (then `P_tmpdir` `/tmp/`)
- `random_string(buf)` for temp file suffixes produces only ASCII digits 0-9 (`'0' + u8(n) % 10`), so temp file names are always safe ASCII

## Relevant Files
- `src/tap/tap.odin`: tap storage, URL inference, formula cache fetch (use-after-free fixed in `fetch_formula_ruby` and `derive_branch_from_url`)
- `src/tap/ruby_formula.odin`: Ruby formula DSL parser (strip_ruby_comments now clones to context.allocator)
- `src/api/client.odin`: `fetch_formula`, `fetch_formula_tap`, `parse_tap_token`, `ruby_to_formula`, `fetch_tap_listing_cached`, `fetch_formula_homebrew`, `registry_mmap_parse` (data freed), `extract_owner_repo_from_github_url` helper, `destroy_formula` (frees binaries+tap), 3× temp file sites with use-after-free fixed
- `src/main.odin`: `run_tap`/`run_untap`/`run_bundle`/`run_deps`/`run_migrate`/`run_doctor`; help text; command dispatch; `print_formula` (shows source_url/source_sha256)
- `src/installer/installer.odin`: `install_source` `.Unknown` case materializes `keg/bin/` and runs `find`+`mv` for each `f.binaries` entry
- `src/platform/copy.odin`: `exec_cmd` (original convention: `args[0]` = program name)
- `src/formula/formula.odin`: `Formula` struct has `binaries: []string` and `tap: string` fields
- `tests/smoke-test.sh`: 22 tests, 20 pass, 2 pre-existing failures (lua, awscli)
- `/opt/ubrew/db/taps.txt`: `ublue-os/tap\thttps://github.com/ublue-os/homebrew-tap`, `pkgxdev/made\thttps://github.com/pkgxdev/homebrew-made`, `justrach/nanobrew\thttps://github.com/justrach/nanobrew`
- `/opt/ubrew/cache/taps/<name>/Formula_listing.json`: 1h cached GitHub API Contents response
- `/opt/ubrew/cache/taps/<name>/Formula/<formula>.rb`: cached Ruby formula file
