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

The [Release workflow](../.github/workflows/release.yml) then, in one
workflow run:

1. A `build-macos` matrix job builds the macOS release assets on dedicated
   runners (**`macos-14`** → arm64, **`macos-15-intel`** → x86_64) via
   `scripts/build-release-assets.sh`, packaging
   `ubrew-arm64-apple-darwin.tar.gz` and `ubrew-x86_64-apple-darwin.tar.gz`
   with their `.sha256` sidecars. They are **unsigned** for now (see
   [macOS](#macos)).
2. The `release` job on `ubuntu-latest` builds the Linux x86_64 asset, then
   publishes the GitHub Release with all three tarballs + sidecars.
3. The `release` job **bumps the formula** `Formula/ubrew.rb` via
   `scripts/update-formula.sh` (version + Linux URL/SHA256 **and** the real
   macOS URL/SHA256s now that the assets exist), verifies it against the
   release assets via `scripts/verify-formula-release.sh --local-dir`, and
   opens `release/formula-<tag>` → `main` PR.

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

macOS binaries are **built by CI** on the [Release workflow](../.github/workflows/release.yml):
`build-macos` builds `ubrew-arm64-apple-darwin.tar.gz` on `macos-14` (arm64)
and `ubrew-x86_64-apple-darwin.tar.gz` on `macos-15-intel` (x86_64), which are
uploaded to the release. The formula's `on_macos` SHA256 values are filled
from those assets automatically; the formula's `install` also stages
`libsqlite3-fts5.dylib` alongside the binary (relocated to `@rpath`).

> **Signed distribution is not wired up yet.** Behaves like the Linux flow,
> shipping an **unsigned** binary. Until Developer ID codesigning +
> notarization is added, macOS users installing from Homebrew may hit
> Gatekeeper warnings on the downloaded binary (a right-click → **Open**
> workaround or `xattr -dr com.apple.quarantine` on the tarball contents).
> See `scripts/notarize-macos.sh` for the notarization recipe once a
> codesigning identity and `notarytool` profile are available.

To rebuild the formula manually (e.g. after re-uploading assets to an
existing release), either:

- re-run the manual [`Update Formula`](../.github/workflows/update-formula.yml)
  workflow, or
- run the scripts locally:

```bash
UBREW_VERSION=2026.8.1 UBREW_LINUX_SHA256=<...> \
UBREW_MACOS_ARM_SHA256=<...> UBREW_MACOS_X86_SHA256=<...> \
bash scripts/update-formula.sh
```

On a Darwin host the same `scripts/build-release-assets.sh` (with
`UBREW_VERSION`) produces the matching macOS tarball + sidecar directly.

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