# Migration Plan: Nanobrew/Zig → Universal Brew (ubrew)

## Context

The project was originally **nanobrew** (a Zig-based package manager, binary `nb`). It has been **fully rewritten in Odin** and renamed to **ubrew** (Universal Brew). The source code, build system, and binary name are already Odin/ubrew. However, Zig build artifacts, nanobrew branding in CI/docs/infrastructure, and the Cloudflare worker remain as leftovers.

**Already migrated:** Source code (`src/*.odin`), build config (`mise.toml`), binary name (`ubrew`), install path (`/opt/ubrew`), git remote (`github.com:rjallais/ubrew.git`).

---

## Phase 1: Delete Zig build artifacts and stale files

Remove all leftover Zig compilation artifacts and temporary files from the repo root:

| File/Dir | Reason |
|----------|--------|
| `zig-out/` | Zig build output directory (contains stale `nb` binary) |
| `.zig-cache/` | Zig compiler cache |
| `.zigrep_archive` | Zig-specific file |
| `check_win.o` | Stale object file |
| `test_exec_iso` | Stale test artifact |
| `test_fchmod.bin` | Stale test artifact |
| `test_iso` | Stale test artifact |
| `ubrew-debug` | Stale debug binary |
| `ubrew_baseline` | Stale build variant |
| `ubrew_new` | Stale build variant |
| `test_temp` | Stale test artifact |
| `nb-linux` | Stale Linux binary (Zig-era) |

**Action:** `git rm` each file/directory.

---

## Phase 2: Delete Zig-specific CI, worker, and install script

| Item | Reason |
|------|--------|
| `.github/workflows/release.yml.disabled` | Entirely Zig-based release pipeline (dead code) |
| `worker/` (entire directory) | Cloudflare worker for `nanobrew.trilok.ai` — domain not maintained |
| `install.sh` | Zig-based build-from-source installer |
| `bench/nb` | Stale Zig-era binary used for benchmarks |

**Action:** `git rm -r` each item.

---

## Phase 3: Update CI workflows to use Odin

### 3a. `.github/workflows/ci.yml`

- Remove backward-compat symlink: `sudo ln -sfn /opt/ubrew /opt/nanobrew`
- Remove `justrach/nanobrew` tap trust (replace with a working tap if needed for tests)
- Remove `/opt/nanobrew/prefix/bin` from PATH
- Keep `feat/clean-downloads` branch trigger or remove if merged
- Build step already uses `odin build src -out:ubrew -o:speed` (no changes needed)

### 3b. `.github/workflows/benchmark.yml`

- Replace `zig build -Doptimize=ReleaseFast` → `odin build src -out:ubrew -o:speed` (or use `mise run build`)
- Replace `./zig-out/bin/nb` → `./ubrew`
- Replace `sudo mkdir -p /opt/nanobrew` → `sudo mkdir -p /opt/ubrew`
- Replace `/opt/nanobrew` → `/opt/ubrew` in all benchmark steps
- Replace `./zig-out/bin/nb init` → `./ubrew init`
- Update README template to use "ubrew" instead of "nanobrew"
- Replace `zig build linux` → `odin build src -out:ubrew -o:speed -target:linux_amd64` (or appropriate Odin cross-compile)
- Add `odin` setup step (via `jdx/mise-action` or manual install)

### 3c. `.github/workflows/upstream-tooling.yml`

- Replace `zig build` commands → `odin build src -out:ubrew -o:speed` (or use `mise run build`)
- Replace `zig-out/bin/nb` → `./ubrew`
- Replace `sudo mkdir -p /opt/nanobrew` → `sudo mkdir -p /opt/ubrew`
- Replace `./zig-out/bin/nb init` → `./ubrew init`
- Replace `NANOBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE` → `UBREW_DISABLE_UPSTREAM_REGISTRY_REMOTE` (or keep as-is if env var name is stable in source)
- **Delete Zig test steps** (`zig build test-upstream-registry`, `zig build test-upstream-github`, `zig build test`) — these tested Zig code that no longer exists
- **Add Odin test step** (see Phase 6)
- Remove `build.zig` from paths trigger
- Replace `Install Zig` step → `Set up mise` (installs Odin)
- Keep Node.js steps and `scripts/test-upstream-tooling.mjs` — these are pure Node.js and don't depend on Zig
- Update `Initialize disposable nanobrew root` → `Initialize disposable ubrew root`

### 3d. `.github/workflows/update-formula.yml`

- Update Formula path: `Formula/nanobrew.rb` → `Formula/ubrew.rb`
- Update class name: `Nanobrew` → `Ubrew`
- Update desc: "Written in Zig" → "Written in Odin"
- Update homepage: `github.com/justrach/nanobrew` → `github.com/rjallais/ubrew`
- Update binary name: `nb` → `ubrew`
- Update test assertion: `assert_match "nanobrew"` → `assert_match "ubrew"`

---

## Phase 4: Replace Homebrew formula

- Delete `Formula/nanobrew.rb`
- Create `Formula/ubrew.rb` with:

```ruby
class Ubrew < Formula
  desc "The fastest macOS package manager. Written in Odin."
  homepage "https://github.com/rjallais/ubrew"
  license "Apache-2.0"
  version "0.1.0"
  # TODO: Replace the sha256 PLACEHOLDER values below with the actual
  # SHA-256 checksums of the published release archives before publishing
  # this formula.
  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/rjallais/ubrew/releases/download/v0.1.0/ubrew-arm64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER"
    else
      url "https://github.com/rjallais/ubrew/releases/download/v0.1.0/ubrew-x86_64-apple-darwin.tar.gz"
      sha256 "PLACEHOLDER"
    end
  end
  def install
    bin.install "ubrew"
  end
  def post_install
    ohai "Run 'ubrew init' to create the ubrew directory tree"
  end
  test do
    assert_match "ubrew", shell_output("#{bin}/ubrew help")
  end
end
```

---

## Phase 5: Update documentation

| File | Changes |
|------|---------|
| `README.md` | Replace "Written in Zig" → "Written in Odin"; replace `nanobrew` → `ubrew`; replace `nb ` → `ubrew `; update install commands (`curl -fsSL https://nanobrew.trilok.ai/install` → remove or update); update GitHub URLs; update benchmark labels; update binary size references |
| `CONTRIBUTING.md` | Replace `zig build test` → `odin check src` or `mise run test`; replace "Zig runtime code" → "Odin runtime code"; update generated files list (remove `.zig-cache/`, `zig-out/`, add `.zig-cache/` if still relevant) |
| `SECURITY.md` | Update any nanobrew references |
| `BENCHMARKS.md` | Replace "nanobrew" → "ubrew" in benchmark labels; update tool references |
| `CHANGELOG.md` | Add migration entry at top |
| `docs/RELEASING.md` | Update release process for Odin-based builds |
| `docs/upstream-registry.md` | Update references if any |
| `docs/github-upstream-discovery.md` | Update references if any |
| `docs/design/native-bottle-pipeline.md` | Update references if any |
| `docs/superpowers/specs/2026-04-05-extended-keg-linking-design.md` | Update references if any |
| `socials/tweets.md` | Update references if any |

---

## Phase 6: Write Odin unit tests

Create `@(test)` unit tests for the 13 modules that had Zig tests. Odin's test framework uses `@(test)` attributes. Test procedures should accept `^testing.T` and use `testing.expect` or `testing.expect_value`.

| Zig Test Target | Odin Module to Test | New Test File | What to Test |
|---|---|---|---|
| `test-version` | Version parsing logic | `src/version_test.odin` | Version string parsing, comparison, semver logic |
| `test-tar` | Tar extraction logic | `src/tar_test.odin` | Tar extraction (USTAR, GNU long-name headers, PAX) |
| `test-api` | `src/api/client.odin` | `src/api/client_test.odin` | API response parsing, URL construction, error handling |
| `test-tap` | `src/tap/tap.odin` | `src/tap/tap_test.odin` | Tap add/remove/trust, tap name parsing |
| `test-cask` | `src/cask/cask.odin` | `src/cask/cask_test.odin` | Cask install/uninstall, cask metadata parsing |
| `test-search` | Search logic in client.odin | `src/api/search_test.odin` | Search result parsing |
| `test-security` | Security checks in installer.odin | `src/installer/security_test.odin` | Path traversal prevention, placeholder replacement, binary verification |
| `test-deb-index` | Deb index logic | `src/deb/index_test.odin` | NBIX binary index parsing |
| `test-deb-resolver` | Deb resolver logic | `src/deb/resolver_test.odin` | Deb dependency resolution |
| `test-deb-extract` | Deb extract logic | `src/deb/extract_test.odin` | Deb archive extraction |
| `test-deb-distro` | Deb distro logic | `src/deb/distro_test.odin` | Distro detection, APT source parsing |
| `test-upstream-registry` | Upstream registry logic | `src/upstream/registry_test.odin` | Registry record parsing, status computation |
| `test-upstream-github` | Upstream GitHub logic | `src/upstream/github_test.odin` | GitHub release resolution, asset matching |

**Note:** If some of these modules don't exist in the Odin codebase (e.g., deb modules may not have been ported yet), skip those tests and add a comment noting they're pending. Focus on modules that exist in `src/`.

**Add a mise task for running tests:**

```toml
[tasks.test-unit]
description = "Run Odin unit tests"
run = "odin test src -all-packages"
```

**Update `ci.yml`** to add an Odin unit test step after build:

```yaml
- name: Run unit tests
  run: odin test src -all-packages
```

---

## Phase 7: Update smoke tests

`tests/smoke-test.sh` has hardcoded `/opt/nanobrew/` paths throughout. Update all references:

- Line 2: `# Test: comprehensive smoke integration tests for nanobrew on macOS` → `...for ubrew on macOS`
- Line 20: `export PATH="/opt/nanobrew/prefix/bin:$PATH"` → `export PATH="/opt/ubrew/prefix/bin:$PATH"`
- Line 98: `/opt/nanobrew/prefix/bin/aws` → `/opt/ubrew/prefix/bin/aws`
- Line 99: `/opt/nanobrew/prefix/bin/aws` → `/opt/ubrew/prefix/bin/aws`
- Line 100: `/opt/nanobrew/prefix/bin/aws shebang` → `/opt/ubrew/prefix/bin/aws shebang`
- Line 104: `/opt/nanobrew/prefix/Cellar/awscli` → `/opt/ubrew/prefix/Cellar/awscli`
- Line 125: `CELLAR_DIR="/opt/nanobrew/prefix/Cellar"` → `CELLAR_DIR="/opt/ubrew/prefix/Cellar"`
- Line 378: `/opt/nanobrew/prefix/Cellar/perl` → `/opt/ubrew/prefix/Cellar/perl`
- Line 394: `/opt/nanobrew/prefix/bin/git` → `/opt/ubrew/prefix/bin/git`

Also update the tap references:
- Line 26: `justrach/nanobrew` tap → keep as-is (it's a real third-party tap for testing), or replace with a different test tap

---

## Phase 8: Update CONTRIBUTING.md and .gitignore

**CONTRIBUTING.md:**
- Line 26: "Zig runtime code" → "Odin runtime code"
- Lines 138-143: Replace `zig build test` / `zig build linux` examples with `odin check src` / `mise run test`
- Line 125: Remove `.zig-cache/` from generated files list (or keep if still relevant)
- Line 126: Remove `zig-out/` from generated files list

**.gitignore:**
- Add `zig-out/` and `.zig-cache/` if not already present (they may need to stay for anyone who still has Zig installed locally)

---

## Phase 9: Update AGENTS.md

Already uses "ubrew" consistently. Minor updates needed:

- Line 40: `sudo ln -sfn /opt/ubrew /opt/nanobrew` → remove this line (no more backward-compat symlink)
- Line 41: `./ubrew tap trust justrach/nanobrew` → verify this tap still works or replace

---

## Execution Order

1. **Phase 1** — Delete Zig artifacts (safe, no dependencies)
2. **Phase 2** — Delete Zig CI/worker/install script (safe, no dependencies)
3. **Phase 4** — Create new Homebrew formula (before updating workflows that reference it)
4. **Phase 3** — Update CI workflows (depends on Phase 4 for formula path)
5. **Phase 5** — Update documentation (can be done in parallel with Phase 3)
6. **Phase 6** — Write Odin unit tests (independent, can be done in parallel)
7. **Phase 7** — Update smoke tests (independent, can be done in parallel)
8. **Phase 8** — Update CONTRIBUTING.md and .gitignore (low priority)
9. **Phase 9** — Update AGENTS.md (low priority)
10. **Verify** — Run `odin check src`, `odin test src -all-packages`, and `mise run test` to ensure nothing broke

---

## Files Modified Summary

| Category | Files Modified | Files Deleted | Files Created |
|----------|---------------|---------------|---------------|
| Zig artifacts | 0 | 12 files + `zig-out/`, `.zig-cache/` | 0 |
| CI/Infra | 4 workflows | `release.yml.disabled`, `worker/`, `install.sh`, `bench/nb` | 0 |
| Formula | 0 | `Formula/nanobrew.rb` | `Formula/ubrew.rb` |
| Documentation | 8+ files | 0 | 0 |
| Tests | `tests/smoke-test.sh` | 0 | 13 `*_test.odin` files |
| Config | `CONTRIBUTING.md`, `.gitignore`, `AGENTS.md` | 0 | 0 |
