# Releasing ubrew

## Version notation (calendar SemVer)

Versions use the calendar-SemVer notation popularised by mise and similar
to Odin's dev builds: **`vYYYY.M.PATCH`** on the git tag (e.g.
`v2026.8.1`), where `YYYY` is the year, `M` the month, and `PATCH` a
monotonic counter within the month. The version embedded in the binary and
in the Homebrew formula is the bare `YYYY.M.PATCH` (no `v` prefix).

- `ubrew --version` / `ubrew version` print `ubrew YYYY.M.PATCH`.
- `Formula/ubrew.rb` carries `version "YYYY.M.PATCH"`.
- The binary's version is compiled in at build time via
  `-define:UBREW_VERSION=YYYY.M.PATCH` (see `src/main.odin` /
  `src/installer/installer.odin`). Local, non-release builds fall back to
  the in-source default and need no define.
- Prerelease tags append a suffix: `v2026.8.1-rc.1` (SemVer style).

## Release flow (fully automated, Linux)

Push an annotated tag and CI does the rest:

```bash
git tag -a v2026.8.1 -m "ubrew v2026.8.1"
git push origin v2026.8.1
```

The [Release workflow](../.github/workflows/release.yml) then, in one run
on `ubuntu-latest`:

1. **Builds** the release binary with `-define:UBREW_VERSION=<version>`
   (`-o:speed -no-bounds-check`, no CPU-specific microarch flags), using
   `scripts/build-release-assets.sh`.
2. **Relocates** the artifact: rewrites the binary's `DT_NEEDED` for
   `libsqlite3-fts5.so` to the bare name and sets `RUNPATH $ORIGIN/../lib`,
   so the tarball is self-contained and the formula no longer needs
   `patchelf` at install time.
3. **Smoke-tests** the staged binary from a Homebrew-style `{bin,lib}`
   layout and asserts the compiled-in version.
4. **Publishes** the GitHub Release with
   `ubrew-linux-x86_64.tar.gz` and its `.sha256` sidecar (generated notes).
5. **Bumps the formula** `Formula/ubrew.rb` via `scripts/update-formula.sh`
   (version + Linux URL/SHA256), verifies it against the release assets via
   `scripts/verify-formula-release.sh --local-dir`, and opens
   `release/formula-<tag>` → `main` PR.

### Prereleases

Tags containing a hyphen (e.g. `v2026.8.1-rc.1`) are published as GitHub
**prereleases** and the formula bump is skipped. Stable `ubrew update`
flows and `Formula/ubrew.rb` only ever point at stable releases, so
prereleases are never auto-promoted.

## Safe rollout policy

- Stable binary channel: non-prerelease GitHub Releases only. These are
  the only releases `ubrew update`, the update banner, and
  `Formula/ubrew.rb` promote.
- Beta binary channel: prerelease GitHub Releases only. Installed manually
  from the release page.
- The background update banner reads `https://ubrew.trilok.ai/version`;
  keep that endpoint pointed at the latest stable version only.

## macOS

macOS artifacts are **not** built by CI yet. The formula keeps the macOS
URL layout but with `PLACEHOLDER` SHAs (macOS installs fail loudly until a
macOS asset exists). When macOS assets are uploaded to a release, either:

- re-run the manual [`Update Formula`](../.github/workflows/update-formula.yml)
  workflow, or
- run the scripts locally:

```bash
UBREW_VERSION=2026.8.1 UBREW_LINUX_SHA256=<...> \
UBREW_MACOS_ARM_SHA256=<...> UBREW_MACOS_X86_SHA256=<...> \
bash scripts/update-formula.sh
```

## Manual formula edits

If you edit `Formula/ubrew.rb` by hand:

- Confirm the tag exists and the tarball is on the release page.
- Copy the SHA256 from the `.sha256` sidecar or `sha256sum` locally.

Do **not** bump `version` in the formula to a build that has no published
release (breaks `brew install ubrew` with HTTP 404).

## Tap repository

There is **no separate** `homebrew-ubrew` repository for the default tap.
Users install with:

```bash
brew tap rjallais/ubrew https://github.com/rjallais/ubrew
brew install ubrew
```

Homebrew reads `Formula/ubrew.rb` **from this repo**. Keeping releases and
the formula in sync here is sufficient unless you maintain a custom tap fork
elsewhere.

## Version constants

- **`src/main.odin`** and **`src/installer/installer.odin`** — compile-time
  `#config(UBREW_VERSION, default)`; release builds pass the define.
- **`Formula/ubrew.rb`** — tracks the bottled binary users download via
  Homebrew; tied to GitHub Releases, not necessarily every commit on `main`.

## Verify locally

After editing the formula, run:

```bash
# offline: verify against a local directory of release assets
bash scripts/verify-formula-release.sh --local-dir <dir> Formula/ubrew.rb

# online: download the release URLs and compare
bash scripts/verify-formula-release.sh Formula/ubrew.rb
```

To do a full local dry-run of the release pipeline:

```bash
UBREW_VERSION=2026.8.1 mise run build-libsqlite
UBREW_VERSION=2026.8.1 bash scripts/build-release-assets.sh
UBREW_VERSION=2026.8.1 bash scripts/update-formula.sh
bash scripts/verify-formula-release.sh --local-dir build/release
```