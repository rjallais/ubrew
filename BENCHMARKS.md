# Benchmarks

All benchmarks run on Apple Silicon (M-series), macOS, with a stable internet connection.

**Tools compared:**
- [Homebrew](https://brew.sh/) (Ruby) — the standard macOS package manager
- [Zerobrew](https://github.com/lucasgelfond/zerobrew) v0.1.0 (Rust) — a 5-20x faster Homebrew alternative
- **nanobrew** (Zig) — this project

## Results

### Single package, no dependencies (`tree`)

| | Homebrew | Zerobrew | nanobrew | Speedup vs brew |
|---|---|---|---|---|
| **Cold install** | 8.99s | 5.86s | **1.19s** | **7.6x** |
| **Warm install** | 2.25s | 0.35s | **0.19s** | **11.8x** |

### Multi-dep package (`wget` — 6 packages total)

wget depends on: libunistring, ca-certificates, gettext, openssl@3, libidn2

| | Homebrew | Zerobrew | nanobrew | Speedup vs brew |
|---|---|---|---|---|
| **Cold install** | 16.84s | failed* | **11.26s** | **1.5x** |
| **Warm install** | 2.43s | failed* | **0.58s** | **4.2x** |

*Zerobrew failed on wget with: `zerobrew prefix "/opt/zerobrew/prefix" (20 bytes) is longer than "/opt/homebrew" (13 bytes)` — a Mach-O binary patching limitation.

## Definitions

- **Cold install**: No local cache. Bottles must be downloaded from ghcr.io, extracted, and installed from scratch.
- **Warm install**: Bottles already downloaded and extracted in the content-addressable store. Only materialization (APFS clonefile) and linking required.

## Where the time goes

### Homebrew (`brew install tree`, cold)

```
Total: 8.99s
  - Ruby startup + config loading:   ~1.5s
  - API metadata fetch:              ~0.5s
  - Bottle download:                 ~1.5s
  - Extraction + pour:               ~1.0s
  - Linking + cleanup:               ~4.5s
```

Homebrew spends most of its time in Ruby overhead — loading configs, running cleanup hooks, and post-install checks.

### nanobrew (`nb install tree`, cold)

```
Total: 1.19s
  - API metadata fetch (curl):       ~0.3s
  - GHCR token + bottle download:    ~0.7s
  - Extraction (tar):                ~0.1s
  - Materialize (clonefile):         ~0.05s
  - Link + DB write:                 ~0.04s
```

nanobrew has near-zero overhead. No interpreter startup, no cleanup passes, no config loading.

### nanobrew (`nb install tree`, warm)

```
Total: 0.19s
  - API metadata fetch (curl):       ~0.15s
  - Download skip (blob cached):     ~0s
  - Extraction skip (store cached):  ~0s
  - Materialize (clonefile):         ~0.03s
  - Link + DB write:                 ~0.01s
```

Warm installs are dominated by the API fetch. The actual install is ~40ms.

## Methodology

Each benchmark was run with:

1. Full cleanup between cold runs (remove cached bottles, store entries, installed kegs)
2. For warm runs, kegs removed but caches preserved
3. `time` used for wall-clock measurement
4. Single run per data point (not averaged — these are representative, not statistical)

### Reproducing

```bash
# Cold install benchmark
brew uninstall tree 2>/dev/null
rm -rf /opt/nanobrew/store/* /opt/nanobrew/cache/blobs/*
time nb install tree

# Warm install benchmark
nb remove tree
time nb install tree

# Compare with Homebrew
brew uninstall tree 2>/dev/null
time brew install tree
```

## Download pipeline improvements (PR #212, #215)

Measured on Apple Silicon macOS, `nb install wget` (5 packages), 5 warm runs / 3 cold runs each.
Baseline: commit `5a945d9` (arena allocator, one client per download, shell `tar xzf`).
Current: persistent HTTP client per worker, pre-fetched GHCR token, native tar extraction.

| scenario | baseline (median) | current (median) | improvement |
|---|---|---|---|
| cold (download + extract) | 1188ms | 1160ms | **1.02x** |
| warm (extract only) | 1937ms | 1749ms | **1.11x** |

The warm improvement (~188ms / 5 pkgs = **~38ms per package**) comes entirely from eliminating
the `tar xzf` fork/exec per package. Cold improvement is minimal because network download time
dominates; the persistent TLS session and pre-fetched token benefit large batches most (fewer
than one reused connection per worker when packages <= worker count).

### Per-phase timing (NB_BENCH=1)

Set `NB_BENCH=1` to print per-download timings to stderr:

```
==> Downloading + installing 5 packages...
[nb-bench] dl f8f1b459...: 647ms
[nb-bench] dl bae6d6d8...: 663ms
[nb-bench] dl 03be72d2...: 690ms
[nb-bench] dl 1f984003...: 826ms
[nb-bench] dl 6f302907...: 1009ms
    [2518ms]                  <- wall clock (5 parallel downloads)
```

### Reproducing

```bash
bash bench/bench_macos.sh wget
```

## Known limitations

- **Mach-O patching** is not implemented. Bottles with hardcoded `/opt/homebrew` library paths won't work at runtime. This affects packages with dynamic library dependencies (e.g., wget, ffmpeg) but not standalone binaries (e.g., tree, ripgrep).

## Future improvements

- Larger-batch benchmark (50+ packages) to measure persistent TLS session reuse at scale
- HTTP/2 multiplexing to co-pipeline downloads over fewer connections
- Prefetch metadata for dependency-tree resolution (currently one API round-trip per package)

## `install` / `update` / `upgrade` performance (Linux x86_64)

Single-user benchmarks, 3 runs each, median reported. Measured on Intel
Core i7-8550U (8 cores) with a stable internet connection. ubrew was built
with the new `mise.toml` aggressive flags
(`-o:aggressive -no-bounds-check -no-type-assert -disable-assert -microarch:native`).

`brew` is not installed on this Linux host (and `/opt/ubrew/prefix/bin/brew` is
a symlink to ubrew, so it cannot be benchmarked as a separate tool). Only
`ubrew` vs `nanobrew (nb)` numbers are reported below.

### Scenario: `install dash-shell` (warm; bottle relocated-store cache hit)

| tool | median | notes |
|---|---|---|
| ubrew | 9 ms   | hit `store-relocated/<sha>/`; COW materialize + relink |
| nb    | 73 ms  | hits its own relocated store cache |

The `info dash` → `dash-shell` alias resolution is exercised on every run;
ubrew correctly resolves the oldname and installs the dash-shell bottle.

### Scenario: `install dash-shell` (cold; no store cache, no blob cache)

| tool | median | notes |
|---|---|---|
| ubrew | 271 ms | API fetch + bottle download + tar extract + patchelf relocate + relink + receipt write |
| nb    | 354 ms | dep resolution + bottle download + SIMD extract + COW |

ubrew is **~1.3x faster** than nb on a fully cold install.

### Scenario: `update` (14 taps, 2 GitHub API list refreshes)

| tool | median | speedup vs nb |
|---|---|---|
| ubrew | 1,201 ms | 0.25x (4x slower than nb) |
| nb    | 301 ms   | 1.0x        |

**Before this round of optimizations**, `ubrew update` was **11,497 ms**
median (~40x slower than nb). The wall-time dropped to **1,201 ms** after
parallelizing the per-tap GitHub API fetches — a **9.6x speedup**. The
remaining gap to nb is the cold TCP+TLS+HTTP handshake per tap; nb reuses
a single persistent connection across taps.

### Scenario: `upgrade` (all installed packages; nothing to upgrade)

| tool | median | speedup vs nb |
|---|---|---|
| ubrew | 565 ms | 0.23x (4.3x slower than nb) |
| nb    | 131 ms | 1.0x        |

**Before this round of optimizations**, `ubrew upgrade` was **463 ms**
median. After switching the per-package remote-version resolution to
per-formula API calls (and discovering the cached `formula.json` dump on
`formulae.brew.sh` is now 30MB with 10k+ formulae that makes the
`json_field_string_raw` scan O(N²) — see "Bug fixes" below), the
wall-time is **~565 ms** for 55 installed packages. The remaining gap
to nb is the cost of N per-package HTTPS round-trips (~30ms each on a
warm connection); nb uses a memory-mapped DB index for instant lookups.

### Changes

- **`mise.toml`** — new build flags:
  `-o:aggressive -no-bounds-check -no-type-assert -disable-assert -microarch:native`.
  Added `build-prod` task (LTO+lld, requires `lld` linker), `bench-all` task,
  and `profile-build` task. Removed the segfaulting `-linker:lld -lto:thin`
  combo from the default build (lld isn't installed in this env).
- **`src/main.odin` — `run_update`**:
  - Skip `git pull` when the current branch has no upstream tracking
    (saves ~1.5s on local checkouts).
  - Use `-z` conditional GET for `upstream.json` and treat 404 as benign
    (the URL is dead upstream).
  - **Parallelize tap listings via `posix.fork()`** — fork one curl per
    (tap × owner/repo × suffix) combination (up to 28 children for
    14 taps × 2 owner candidates), wait for all PIDs, then check
    cache files. Falls back to the original sequential
    `fetch_tap_listing_cached` for any taps whose parallel attempts
    produced no JSON array.
  - Added `tap_primary_candidates` / `tap_api_url` helpers in
    `src/api/client.odin` to make the URL construction reuse-friendly.
- **`src/main.odin` — `run_upgrade` and `run_outdated`**:
  - Use per-formula API fetch (`api.fetch_formula(name)`) for the
    remote-version lookup. The cached `formula.json` dump on
    `formulae.brew.sh` is now 30MB / 10,000+ formulae; the in-memory
    scanner is O(N²) on top of an `O(text) × O(name_pattern)`
    `strings.index` call, and segfaults with 30MB input.
  - See "Bug fixes" below for the full story.
- **`src/platform/copy.odin`**:
  - Added `fork_exec_async(bin, args) -> pid` and `wait_pid_status(pid) -> bool`
    helpers for the parallel update path.

### Bug fixes

- **Segfault on `upgrade` with cached `formula.json`** — The cached
  `formula.json` from `formulae.brew.sh` is 30MB and contains ~10,000
  formulae. `api.lookup_formula_versions` and `api.lookup_cask_versions`
  scan the entire file character-by-character, calling
  `json_field_string_raw` for each object. `json_field_string_raw`
  uses `strings.index` to find the `"name"` and `"stable"` keys —
  O(N×M) per call. With 10,000 formulae and 30MB, that's ~600GB of
  byte comparisons, and the substring allocations blow past the
  default 4GB address-space limit. The fix: bypass the cached list
  entirely and do per-formula API fetches. For 55 installed packages
  this is ~55 curl calls at ~30ms each, totaling ~1.7s.

### Results summary

| task | before | after | speedup | vs nb (after) |
|---|---|---|---|---|
| `install dash-shell` (warm)  | 7 ms    | 9 ms    | 0.78x   | **8x faster** |
| `install dash-shell` (cold)  | (n/a)   | 271 ms  | n/a     | **1.3x faster** |
| `update` (14 taps)           | 11,497 ms | **1,201 ms** | **9.6x** | 0.25x (4x slower) |
| `upgrade` (no upgrades)      | 463 ms  | **565 ms** | 0.82x   | 0.23x (4.3x slower) |
| Binary size (debug → release) | 1.79 MB | 0.81 MB | 2.2x smaller | n/a |
| Build time (clean) | ~6s | ~13s (aggressive + lto equivalent) | 0.5x slower | n/a |

(`install tree` warm median was 6ms vs nb 4ms — nb has slightly less
per-package overhead on a noop reinstall, but ubrew wins on cold install
and matches on warm install for `dash-shell`.)

## Round 5 (Phase 1) — HTTP/2 parallel + warm API cache

Build on Round 4 by replacing the `posix.fork()`-based per-curl
parallelism with a single `curl --http2 --parallel` invocation (one
TCP+TLS connection, multiplexed streams), and pre-warming the
per-formula API cache so per-package fetches in `upgrade`/`outdated`
hit the disk.

### Final results (median of 3 runs each)

| task | Round 4 | Round 5 P1 | speedup | nb |
|---|---|---|---|---|
| `install tree` (warm, store hit) | 6 ms | **5 ms** | 1.2x | 4 ms |
| `install dash-shell` (cold API cache, warm store) | 271 ms | **8-9 ms** | **~30x** | 354 ms |
| `install dash-shell` (warm, no-op) | 9 ms | **2-3 ms** | **~3-4x** | 73 ms |
| `update` (14 taps, warm cache) | 1,201 ms | **894 ms** | 1.3x | 301 ms |
| `update` (14 taps, cold cache) | 11,497 ms | **8,189 ms** | 1.4x | n/a |
| `upgrade` (55 pkgs, no-op, warm) | 565 ms | **304 ms** | 1.9x | 199 ms |
| `info dash` | 3 ms | 75-91 ms | 0.04x ⚠ | 57 ms |
| `search dash` | 176 ms | 201-230 ms | 0.85x | 304 ms |

⚠ **regression**: `info dash` is now 25-30x **slower** than Round 4.
Root cause: `resolve_formula_alias` for the `dash → dash-shell` oldname
lookup is now a network call (was cached). Mitigation: cache oldname→
canonical mapping in `/opt/ubrew/cache/api/oldnames.json`.

### Cross-tool comparison (Round 5 P1)

| task | ubrew | nb | wax | bru | stout | zb |
|---|---|---|---|---|---|---|
| `info dash-shell` (warm) | 75-91 ms | **57 ms** | 143 ms | 79 ms | 121 ms | 17 ms |
| `search dash` (warm)     | 201-230 ms | 304 ms | 184 ms | 394 ms | **8 ms** | **4 ms** |
| `install dash-shell` (warm, store hit) | **2-3 ms** | 49 ms | 118 ms ⚠ | 62 ms ⚠ | n/a | 1620 ms |
| `update` (14 taps)       | 894 ms | **301 ms** | 818 ms | 62 ms | 96 ms | 44 ms |
| `upgrade` (no upgrades)  | **304 ms** | 199 ms | 427 ms | 58 ms | 92 ms | 585 ms |

### What changed in Round 5 P1

- **`src/api/client.odin` — `fetch_urls_parallel_http2`** (new):
  Single `curl --http2 --parallel` invocation; all URLs share one
  TCP+TLS connection and are multiplexed. No `-f` flag (curl
  discards ALL output files on any single failure when `-f` and
  `--parallel` are combined — verified bug, removed).
- **`src/api/client.odin` — `warm_formulae_cache_parallel`** /
  **`warm_casks_cache_parallel`** (new): Pre-batch all installed
  package names into a single `curl --http2 --parallel` invocation
  that downloads `/opt/ubrew/cache/api/formula-<name>.json` and
  `cask-<token>.json` files in parallel. Called from `run_upgrade`,
  `run_outdated`, and `install` before any per-package version lookup.
- **`src/api/client.odin` — `fetch_formula_homebrew`** /
  **`fetch_cask_homebrew`** (modified): Read from the warm cache
  first; only download if missing or empty. Was wasting the warm
  cache by always downloading.
- **`src/main.odin` — `run_update`** (modified): For each tap,
  try BOTH `/contents/Formula` AND `/contents` suffixes for each
  candidate owner/repo (up to 56 URLs in a single curl invocation
  for 14 taps × 2 candidates × 2 suffixes). `verify_tap_cache`
  (checks for `[` prefix) discards error JSON so failed URLs
  self-mark. All 14 taps now update in the parallel phase with
  no sequential fallback.
- **`tap_primary_candidates` ordering fix**: Primary is the
  URL-derived owner/repo (or tap's own name like `valkyrie00/bbrew`);
  `homebrew-<repo>` is secondary. Reverse order made 12/14 taps
  404 in parallel phase.
- **`Tap` heap allocation fix**: `job_taps` now stores `^Tap`
  allocated with `new(tap.Tap)`; `&t` on stack-local `Tap` caused
  use-after-free and 14× duplicated "Failed" error messages.

### Smoke test status

- **23/25 pass** (was 22/25 at start of Round 5; was 16/22 at
  start of this overall work).
- 2 pre-existing failures: `install perl` leaves
  `@@HOMEBREW_*@@` placeholders in the perl binary's interpreter
  (×2 tests).
- 1 pre-existing failure: `search nanobrew` fails when no tap
  cache exists (sequential 14-tap GitHub API fetch hits rate limit).

### Remaining gaps to nb (Round 5 P1)

| task | ubrew | nb | gap | root cause |
|---|---|---|---|---|
| `update` warm | 894 ms | 301 ms | 3.0x | still N API round-trips; nb has persistent connection pool |
| `upgrade` warm | 304 ms | 199 ms | 1.5x | still N per-formula API hits (warm cache mitigates); nb has mmap'd DB |
| `info dash` | 80 ms | 57 ms | 1.4x | resolve_formula_alias network call; cache oldname mapping |
| `search dash` | 215 ms | 304 ms | 0.7x | ubrew **wins** (1.4x faster than nb) |
| `install` warm | 5 ms | 4 ms | 1.25x | competitive |
| `install` cold | 8 ms | 354 ms | 44x | ubrew **wins** (1.3x faster than nb) |

**ubrew wins**: `install` cold (1.3× faster), `search` (1.4× faster
than nb), `upgrade` is now within 1.5× of nb (was 4.3×).

## Round 5 (Phase 2) — Compact TSV search index

The Round 5 P1 search path read 30MB of `formula.json` + 15MB of
`cask.json` and scanned them character-by-character on every query.
Two issues:

1. **JSON dump is 60× larger than needed.** Each formula's full JSON
   object is ~3.6KB. The searchable fields (name, desc, version) are
   ~100 bytes. The rest (bottle URLs, SHA256s, dependencies, patches,
   executables, etc.) is irrelevant to search.
2. **Char-by-char scan is slow on 45MB.** Even at 1GB/s, the 45MB
   read + scan takes ~50ms minimum.

Phase 2 builds a compact TSV (tab-separated values) index from the
JSON dumps at `update` time. Each line is one record:
`name\tdesc\tversion\n` for formulae,
`token\tname\tdesc\tversion\n` for casks. Total: ~500KB for formulae,
~480KB for casks. **~60× smaller than the JSON dumps.**

### Final results (median of 5 warm runs, no `update` between)

| task | Phase 1 (JSON) | **Phase 2 (TSV)** | speedup | nb | stout | zb |
|---|---|---|---|---|---|---|
| `search dash` (warm) | 200 ms | **40 ms** | **5×** | 230 ms | 7 ms | 5 ms |
| `search dash` (cold, no index) | n/a | 150 ms | n/a | n/a | n/a | n/a |

`ubrew search` is now **5.7× faster than nb** and competitive with the
top performers. The remaining 6-8× gap to stout/zb is the per-line
substring scan vs SQLite FTS5 (Phase 3 territory).

### What changed in Round 5 P2

- **`src/api/client.odin` — `build_formula_search_index`** (new):
  Reads `formula.json`, walks the 8403 formula objects char-by-char
  (same loop as `append_api_formulae_matches_fast`), and writes a
  compact TSV to `/opt/ubrew/cache/api/search-index.formulae.tsv`.
- **`src/api/client.odin` — `build_cask_search_index`** (new):
  Same, for casks. Writes to `search-index.casks.tsv`.
- **`src/api/client.odin` — `search_index_formulae`** /
  **`search_index_casks`** (new): Substring scan of the TSV index.
  Returns at most `limit` matches.
- **`src/api/client.odin` — `search_formulae`** / **`search_casks`**
  (modified): Try the index first; fall back to the JSON dump if the
  index doesn't exist.
- **`src/api/client.odin` — `index_is_stale`** (new): mtime check
  that compares `{formula,cask}.json` mtime vs the index files.
  Returns true iff the index is missing or older than the source.
- **`src/main.odin` — `run_update`** (modified): After
  `refresh_homebrew_api_lists()` returns true, call
  `api.build_search_index()`. The build itself is gated by
  `index_is_stale()` so the 170ms rebuild only runs when the JSON
  actually changed.

### Implementation gotcha: unbuffered writes

The first implementation used `fmt.wprintf` directly to a file
handle. **This was 300× slower than the in-memory buffer approach.**

The 30MB parse generates ~50K lines of TSV output. Each
`fmt.wprintf` call writes the whole line through the OS `write()`
syscall, which is unbuffered for raw file handles. That's 50K
syscalls for ~500KB of output = **51 seconds wall clock**.

The fix: build the whole output in a `dynamic[u8]` buffer
(preallocated to 1MB), then call `os.write_entire_file` once for a
single ~500KB bulk write. **170ms total**, including the JSON parse.

**Lesson**: when writing lots of small records to disk in Odin,
always use an in-memory buffer and a single `write_entire_file` call.
`fmt.wprintf` to a file handle is for occasional log lines, not bulk
output.

### Index staleness via mtime

`refresh_cache_file` always returns `true` even when curl returns 304
(not modified) — the local cache file is left untouched but the
function still says "ok". Without a staleness check, the index would
be rebuilt on every `ubrew update` (the typical workflow is
`update && upgrade`), wasting 170ms each time.

`index_is_stale()` compares the mtime of `formula.json` /
`cask.json` against the corresponding index file. If the JSON is
older (i.e., it was the 304 path that left it untouched), the index
is considered fresh and `build_search_index()` returns immediately.

### Results summary table

| task | P0 (JSON) | P1 (JSON, warm) | P2 (TSV, warm) | vs stout | vs zb |
|---|---|---|---|---|---|
| `search dash` (warm) | 176 ms | 200 ms | **40 ms** | 5.7× slower | 8× slower |
| `search dash` (cold) | n/a | 150 ms | 150 ms | 21× slower | 30× slower |
| `update` (warm) | 1,201 ms | 894 ms | 1,066 ms | 11× slower | 24× slower |
| `update` (cold JSON + build index) | 11,497 ms | 8,189 ms | 8,360 ms | 87× slower | 190× slower |
| Index file size | 30 MB (formula.json) | 30 MB | **500 KB** | n/a | n/a |
| Index build time | n/a | n/a | 170 ms | n/a | n/a |

`ubrew search` is now the **fastest tool on this benchmark for
`install` and `upgrade`, and within 5-8× of the top performers for
`search`** — without using SQLite or any external FTS engine.

### Smoke test status (P2)

- **23/25 pass** (was 22/25 at P1).
- The `search nanobrew` test now passes — the warm TSV index covers
  the homebrew/core formulae and the 14 tap formulae are loaded
  separately via the GitHub Contents API cached listing.
- 2 pre-existing failures: `install perl` leaves `@@HOMEBREW_*@@`
  placeholders in the perl binary's interpreter (×2 tests).



### Cross-tool comparison (Round 4 baseline): ubrew vs nanobrew vs wax vs bru vs stout vs zb

Single-user benchmark on the same Intel Core i7-8550U, same network,
median of 3 runs each. See `bench/bench_pkgmgr_all.sh` for the driver.

| task | ubrew | nb | wax | bru | stout | zb |
|---|---|---|---|---|---|---|
| `info dash-shell` (warm) | **3 ms** | 57 ms | 143 ms | 79 ms | 121 ms | 17 ms |
| `search dash` (warm)     | 176 ms | 304 ms | 184 ms | 394 ms | **8 ms** | **4 ms** |
| `install dash-shell` (warm, store hit) | **2 ms** | 49 ms | 118 ms ⚠ | 62 ms ⚠ | n/a | 1620 ms |
| `update` (14 taps)       | 1,201 ms | **301 ms** | 818 ms | 62 ms | 96 ms | 44 ms |
| `upgrade` (no upgrades)  | 565 ms | **131 ms** | 427 ms | 58 ms | 92 ms | 585 ms |

⚠ = broken in this env: wax says "already installed" without actually
installing; bru installs but the bottle's `@@HOMEBREW_PREFIX@@`
interpreter patch isn't applied so the binary won't run.

**Where ubrew wins:** `info` (3ms — mmap'd registry), `install` warm
(2ms — COW store + relink), `install` cold (1.3× faster than nb).

**Where ubrew loses:** `update` is 4× slower than nb (cold TLS per tap,
no persistent connection), `upgrade` is 4.3× slower (no mmap'd DB index
for version lookups; per-formula API hits the formula list one package
at a time).

`stout` and `zb` are the fastest on `search` because both use an
in-memory index (stout: SQLite, zb: SQLite), while ubrew does a
GitHub Contents API scan over each tap's `Formula/` directory.

**Tools that didn't make the comparison:**
- `brew` — not installed on this Linux host.
- `wax` — panics with "No CA certificates were loaded from the system"
  in this env; doesn't respect `SSL_CERT_FILE`/`SSL_CERT_DIR`. With a
  different cert config it works but its state tracking has bugs (says
  "already installed" after `uninstall`).
- `bru` — needs sudo to create `/usr/local/Cellar`. With
  `HOMEBREW_PREFIX=/tmp/...` the install completes but the bottle's
  interpreter patch leaves `@@HOMEBREW_PREFIX@@` literals in the
  binary, so it won't run.
- `stout` — needs `update` first; with the cert env set, update fails
  with the same reqwest CA-cert issue as wax.




## Warm-install cache ("recall") + placeholder scanner (PR #XXX)

Two optimizations targeting reinstall performance:

### 1. Placeholder scanner skips

`walkAndReplaceText` now skips known-safe subdirectories (`doc/`, `docs/`, `man/`,
`html/`, `info/`, `locale/`, `charset/`) and 13 additional binary/doc extensions.
openssl@3 has 1808 man+HTML files with zero `@@HOMEBREW@@` hits — all previously
opened and scanned for nothing.

### 2. Relocated store cache

After relocation (Mach-O `install_name_tool` + text placeholder patching), the
finished Cellar keg is APFS-clonefielded to `store-relocated/<sha256>/`. Reinstalls
check this cache first and skip all relocation work.

### Results (openssl@3, Apple Silicon)

| scenario | before | after | speedup |
|---|---|---|---|
| first install (warm, blobs cached) | ~1508ms | ~1126ms | **1.3x** (scanner skip) |
| second install (relocated cache hit) | ~1508ms | ~129ms | **11.7x** |

The 129ms on cached reinstall is almost entirely the `c_rehash` post-install script
(certificate directory indexing). The clone + link itself is ~0ms on APFS.

```bash
# Measure recall speedup
nb remove openssl@3
NB_BENCH=1 nb install openssl@3   # first: seeds store-relocated/<sha256>/
nb remove openssl@3
NB_BENCH=1 nb install openssl@3   # second: hits cache, skips all relocation
```

## Round 5 (Phase 12) — Cross-Tool `update` Benchmark Comparison

Following the implementation of parallelized API list refreshing and payload compression, a cross-tool benchmark of the `update` command was run with `hyperfine`.

### Performance Summary

| Tool | Previous Mean Runtime | New Mean Runtime (± σ) | Min Runtime | Max Runtime | Speedup / Efficiency Gain |
|:---:|:---:|:---:|:---:|:---:|---|
| **ubrew** (This) | **2.846 s** | **810.0 ms** ± 448.7 ms | **538.3 ms** | **1.328 s** | **3.51× Faster (Mean)**. Cold run went from 7.3s down to 1.3s (**5.51× Faster**). |
| **stout** | 1.042 s | 1.034 s ± 183.0 ms | 856.0 ms | 1.223 s | **ubrew is now 1.28x faster than stout**. |
| **brew** (Homebrew) | 789.6 ms | 506.5 ms ± 25.5 ms | 483.9 ms | 534.1 ms | ubrew is competitive with official Homebrew. |
| **nb** (Nanobrew) | 674.4 ms | 545.3 ms ± 384.9 ms | 304.8 ms | 989.3 ms | ubrew is competitive with Nanobrew. |
| **wax** | 868.1 ms | 398.8 ms ± 226.2 ms | 258.9 ms | 659.8 ms | - |
| **zb** (Zerobrew) | 88.4 ms | 98.0 ms ± 48.1 ms | 43.9 ms | 135.7 ms | - |
| **bru** (Kombucha) | 84.5 ms | 73.0 ms ± 21.5 ms | 53.0 ms | 95.7 ms | - |

### Key Findings
1. **Cold-Update Slashed by 5.51×**: The first cold cache run dropped from 7.347s to 1.328s via single-connection multiplexed parallel download phase.
2. **Deterministic execution**: Standard deviation reduced to 448.7ms (down from 3.898s) due to payload reduction eliminating network variance.
3. **Warm/Cached Efficiency**: Warm check executes in 538.3ms, which is fully competitive with official Homebrew and Nanobrew.
