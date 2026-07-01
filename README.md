<p align="center">
  <img src="assets/logo.png" alt="ubrew logo" width="200">
</p>

<p align="center">
  <a href="https://github.com/rjallais/ubrew" target="_blank">github.com/rjallais/ubrew</a>
</p>

# ubrew

A fast package manager for macOS and Linux. Written in Odin. Native install pipeline for the top 100 Homebrew formulae and top 100 casks (no `brew`, no Ruby), with verified Homebrew fallback for everything else and native `.deb` support for Linux/Docker.

## Why ubrew?

- **Fast warm installs** — already-installed no-ops return in milliseconds (5.8ms on the v0.1.192 sandboxed `yt-dlp` benchmark)
- **Parallel downloads** — all dependencies download and extract at the same time
- **No Ruby runtime** — single static binary, instant startup
- **No auto-update** — `ubrew install` just installs; self-update is explicit via `ubrew update`
- **No quarantine** — cask installs skip `com.apple.quarantine`, so apps open without Gatekeeper prompts
- **Native installs** — top 100 formulae and top 100 casks install without Homebrew, Ruby, or `brew` subprocess (v0.1.192)
- **Third-party taps** — `ubrew install user/tap/formula` just works. The only fast Homebrew client with tap support
- **Drop-in Homebrew replacement** — same formulas, same bottles, same casks
- **Linux + Docker** — native .deb support, **up to 13x faster** than apt-get on warm installs

## ubrew vs Homebrew

Homebrew is great software and powers millions of dev machines. ubrew makes different tradeoffs:

| | Homebrew | ubrew |
|---|---------|----------|
| **Auto-update** | `brew install` runs `brew update` first (can take minutes) | `ubrew install` just installs. Self-update is explicit via `ubrew update`. |
| **Gatekeeper quarantine** | Casks get `com.apple.quarantine` — triggers "Are you sure?" dialog | No quarantine flag — apps open immediately |
| **Parallel downloads** | Sequential by default; set `HOMEBREW_DOWNLOAD_CONCURRENCY` to change | All dependencies download simultaneously out of the box |
| **Runtime** | Ruby (~57 MB) | Single 1.2 MB static binary. Instant startup, no bootstrapping. |
| **Brewfile no-ops** | `brew bundle` rechecks everything (~10s even when satisfied) | `ubrew bundle install` returns instantly when nothing to do |

If you rely on `post_install` hooks, build-from-source options, or Mac App Store integration, Homebrew is still the right choice. ubrew covers the fast path: bottles, casks, and bundles.

| Package | Homebrew | zerobrew (cold) | zerobrew (warm) | ubrew (cold) | ubrew (warm) |
|---------|----------|-----------------|-----------------|--------------|--------------|
| **tree** (0 deps) | 3.554s | 2.260s | 0.311s | **1.288s** | **0.003s** |
| **ffmpeg** (11 deps) | 8.007s | 5.335s | 2.860s | **1.751s** | **0.014s** |
| **wget** (6 deps) | 3.958s | 6.425s | 0.841s | **3.876s** | **0.010s** |

> Benchmarks on Apple Silicon (GitHub Actions macos-14), 2026-06-22. Auto-updated weekly.

| | ubrew | zerobrew | Homebrew |
|---|---------|----------|----------|
| **Binary size** | **1.2 MB** | 7.9 MB | 57 MB (Ruby runtime) |

> ubrew is **6.8x smaller** than zerobrew and **47x smaller** than Homebrew. See how these are measured in the [benchmark workflow](.github/workflows/benchmark.yml).

### Linux / Docker — ubrew vs apt-get

ubrew's `--deb` mode is a full apt-get replacement: fetches APT package indices, resolves dependencies, downloads and extracts `.deb` files — all in pure Odin with no subprocess calls.

| Package set | Deps | apt-get | ubrew (warm) | Speedup |
|-------------|------|---------|-----------------|---------|
| **curl wget** | 35 | 3,426ms | **448ms** | **7.6x** |
| **curl wget tree jq htop tmux** | 53 | 3,584ms | **521ms** | **6.9x** |
| **git vim build-essential** | 116 | 43,833ms | **3,402ms** | **12.9x** |
| **nginx redis-server postgresql-client** | 78 | 5,501ms | **1,402ms** | **3.9x** |

> Verified benchmarks on Ubuntu 24.04.4 LTS (aarch64, Docker/Colima), median of 3 runs. Warm = NBIX binary index cache + cached .deb blobs, `--skip-postinst`. See `bench/` for reproduction.

**What makes it fast:**
- **NBIX binary index cache** — 70K packages deserialized in 32ms (vs 3s HTTP + 72MB gzip decompress + text parse)
- **8-thread parallel .deb downloads** with HTTP connection reuse
- **8-thread parallel extraction** — concurrent ar/gzip/tar parsing via native Zig tar
- **Arena allocator** — single `deinit()` frees all 70K parsed packages

## Install

```bash
# Or via Homebrew
brew tap rjallais/ubrew https://github.com/rjallais/ubrew
brew install ubrew

# Or build from source (needs Odin + mise)
git clone https://github.com/rjallais/ubrew.git
cd ubrew && mise run build
```

### Upgrading

```bash
ubrew update
```

## Usage

### Basics

```bash
ubrew install tree               # install a package
ubrew install ffmpeg wget curl   # install multiple at once
ubrew install --shims yt-dlp     # expose yt-dlp, keep dependency tools private
ubrew remove tree                # uninstall
ubrew list                       # see what's installed
ubrew info jq                    # show package details
ubrew search ripgrep             # search formulas and casks
```

### Shimmed Installs

```bash
ubrew install --shims yt-dlp
```

Shimmed installs are an experimental link mode for packages whose dependencies ship command-line tools you do not want exposed globally. The requested formula gets wrapper shims in `/opt/ubrew/prefix/bin`; dependency executables are kept out of `prefix/bin` and are only added to that wrapper's private `PATH`. This keeps commands like `deno` or `python` available to the requested tool without making those dependency executables first-class shell commands. You can also enable this mode for formula installs with `UBREW_SHIMS=1`.

### Third-Party Taps

```bash
ubrew install steipete/tap/sag   # install from a third-party tap
ubrew install indirect/tap/bpb   # taps with bottles work too
```

ubrew fetches the Ruby formula directly from GitHub, parses it, and installs — no `brew tap` step needed. Supports bottles, source builds, and pre-built binaries.

### macOS Apps (Casks)

```bash
ubrew install --cask firefox     # install a .dmg/.pkg/.zip app
ubrew remove --cask firefox      # uninstall it
ubrew upgrade --cask             # upgrade all casks
```

As of v0.1.192, the top 100 casks install through ubrew's native pipeline — no `brew` subprocess, no Homebrew prefix, no Ruby. Native cask support covers apps, `.pkg`, fonts, binaries, suites, copied artifacts, installer scripts, `.tar.xz`, and extensionless vendor URLs. Casks outside the top 100 still fall back to the verified Homebrew path.

### Linux / Docker (deb packages)

```bash
ubrew install --deb curl wget git    # install from Ubuntu/Debian repos
ubrew remove --deb curl              # remove a deb package
ubrew upgrade --deb                  # upgrade all installed deb packages
ubrew list                           # shows deb packages alongside brew packages
ubrew outdated                       # checks deb packages for newer versions too
```

```dockerfile
# Replace slow apt-get in Dockerfiles
COPY --from=ubrew/ubrew /ubrew /usr/local/bin/ubrew
RUN ubrew init && ubrew install --deb curl wget git
```

- Auto-detects distro and architecture (Ubuntu/Debian, amd64/arm64)
- Resolves virtual packages via `Provides:` field (e.g. `build-essential` works)
- Picks the best alternative when multiple packages satisfy a dependency
- Runs `postinst` scripts and `ldconfig` so shared libraries work out of the box
- Tracks installed files in `state.json` for clean removal
- Content-addressable cache — warm installs are instant

### Keep packages up to date

```bash
ubrew outdated                   # see what's behind
ubrew upgrade                    # upgrade everything
ubrew upgrade tree               # upgrade one package
ubrew pin tree                   # prevent a package from upgrading
ubrew unpin tree                 # allow upgrades again
```

### Undo and backup

```bash
ubrew rollback tree              # revert to the previous version
ubrew bundle dump                # export installed packages to a Brewfile
ubrew bundle install             # reinstall everything from a Brewfile
```

### Diagnostics

```bash
ubrew doctor                     # check for common problems
ubrew cleanup                    # remove old caches and orphaned files
ubrew cleanup --dry-run          # see what would be removed first
```

### Download Telemetry

```bash
ubrew telemetry status
ubrew telemetry off
ubrew telemetry on
```

ubrew sends anonymized, best-effort download timing events to `https://backend.trilok.ai/v1/telemetry/system`. This helps prioritize which packages and casks should get native ubrew support first, based on real download/install demand and slow paths.

The exact event shape is:

```json
{
  "schema": 1,
  "source": "ubrew",
  "event": "download",
  "os": "macos",
  "arch": "arm64",
  "ram_gb": 128,
  "cpu_count": 10,
  "operation": "download",
  "target_kind": "formula",
  "target_name": "uv",
  "duration_ms": 120,
  "download_bytes": 33000000,
  "success": true
}
```

It does not send URLs, paths, hostnames, usernames, IPs, user IDs, full package lists, or command history. `target_name` is only a package-like token such as `uv`, `firefox`, or `owner/tap/pkg`. You can opt out with `ubrew telemetry off`, `UBREW_NO_TELEMETRY=1`, or `UBREW_TELEMETRY=0`.

### Dependencies and services

```bash
ubrew deps ffmpeg                # list all dependencies
ubrew deps --tree ffmpeg         # show dependency tree
ubrew services list              # show launchctl services from installed packages
ubrew services start postgresql  # start a service
ubrew services stop postgresql   # stop a service
```

### Shell completions

```bash
ubrew completions zsh >> ~/.zshrc
ubrew completions bash >> ~/.bashrc
ubrew completions fish > ~/.config/fish/completions/ubrew.fish
```

### Other

```bash
ubrew update                     # self-update ubrew
ubrew init                       # create directory structure (run once)
ubrew help                       # show all commands
```

## How it works

```
ubrew install ffmpeg                        # macOS: Homebrew bottles
  │
  ├─ 1. Resolve dependencies (BFS, parallel API calls)
  ├─ 2. Skip anything already installed (warm path: ~3.5ms)
  ├─ 3. Download bottles in parallel (native HTTP, streaming SHA256)
  ├─ 4. Extract into content-addressable store (/opt/ubrew/store/<sha>)
  ├─ 5. Clone into Cellar via APFS clonefile (zero-copy, instant)
  ├─ 6. Relocate Mach-O headers + batch codesign
  └─ 7. Symlink binaries into /opt/ubrew/prefix/bin/

ubrew install --deb curl                    # Linux: .deb packages
  │
  ├─ 1. Detect distro from /etc/os-release (Ubuntu/Debian, amd64/arm64)
  ├─ 2. Fetch + decompress package index (main + universe components)
  ├─ 3. Build provides map for virtual package resolution
  ├─ 4. Resolve dependencies (topological sort, index-aware alternatives)
  ├─ 5. Download .debs with streaming SHA256 verification
  ├─ 6. Parse ar archive, decompress data.tar natively (zstd/gzip)
  ├─ 7. Extract to / and track installed files in state.json
  ├─ 8. Run postinst scripts (ca-certificates, ldconfig, etc.)
  └─ 9. Run ldconfig for shared library registration

ubrew install steipete/tap/sag              # Third-party taps
  │
  ├─ 1. Detect tap syntax (user/tap/formula)
  ├─ 2. Fetch Ruby formula from GitHub (raw.githubusercontent.com)
  ├─ 3. Parse .rb file (version, url, sha256, deps, bottle blocks)
  ├─ 4. Resolve dependencies normally (they're homebrew-core names)
  └─ 5. Install via bottle or source path (same pipeline as above)
```

Dependency ordering walks the explicit formula graph and topologically sorts it in `O(V+E)`. The `O(1)` resolver improvement in v0.1.190 refers to queue dequeue during that sort, not solving arbitrary version constraints.

Key design choices:
- **Content-addressable store** — deduplicates bottles by SHA256. Reinstalls are instant because the data is already there.
- **APFS clonefile** — copy-on-write on macOS means no extra disk space when materializing from the store.
- **Streaming SHA256** — hash is verified during download, no second pass over the file.
- **Native binary parsing** — reads Mach-O (macOS) and ELF (Linux) headers directly instead of spawning `otool`/`patchelf`.
- **Native ar + decompression** — .deb extraction without `dpkg`, `ar`, or `zstd` binaries. Only needs `tar`.
- **Single static binary** — no runtime dependencies. 1.2 MB.

## Testing

```bash
# Run unit tests
odin test src
mise run test-unit

# Run integration smoke tests
mise run test

# Cross-compile and run on Linux via Colima/Docker
odin build src -out:ubrew -o:speed -target:linux_amd64
docker run --rm -v $(pwd)/ubrew:/ubrew:ro ubuntu:24.04 /ubrew help
```

## Contributing

Follow [CONTRIBUTING.md](./CONTRIBUTING.md) for all future issues and PRs.

The short version:

- every PR must be tied to an issue
- every fix must show red-to-green proof
- every non-trivial branch must be rebased onto current `main`
- PRs over 500 changed lines will usually be rejected unless they are clearly justified, tightly scoped, and good enough to survive strict review


## Directory layout

```
/opt/ubrew/
  cache/
    blobs/      # downloaded bottles (by SHA256)
    api/        # cached formula metadata (5-min TTL)
    tokens/     # GHCR auth tokens (4-min TTL)
    tmp/        # partial downloads
  store/        # extracted bottles (by SHA256)
  prefix/
    Cellar/     # installed packages
    Caskroom/   # installed casks
    bin/        # symlinks to binaries
    opt/        # symlinks to keg dirs
  db/
    state.json  # installed package state
```

## Homebrew Compatibility

ubrew uses Homebrew's formulas, bottles, and cask definitions. It's a faster client for the same ecosystem — not a fork.

### What works

- **Bottle installs** — all pre-built Homebrew bottles install correctly
- **Cask installs** — `.dmg`, `.zip`, `.pkg`, and `.tar.gz` casks
- **Dependency resolution** — same transitive deps as Homebrew
- **Third-party taps** — `ubrew install user/tap/formula` fetches from GitHub
- **Shared Cellar** — packages install to `/opt/ubrew/prefix/Cellar/` (same layout as Homebrew)
- **Bundle/Brewfile** — `ubrew bundle dump` and `ubrew bundle install` for common `brew "pkg"` and `cask "pkg"` lines

### What doesn't work (yet)

- **Ruby `post_install` hooks** — Homebrew formulae with Ruby `post_install` blocks won't run those hooks. Most bottles don't need them.
- **Build from source with custom options** — `args: ["with-feature"]` in Brewfiles is ignored
- **`tap` command** — ubrew auto-fetches taps inline; standalone `brew tap` is not needed
- **Mac App Store (`mas`)** — not supported
- **Complex Ruby DSL in Brewfiles** — conditional blocks, custom Ruby code

### Migration from Homebrew

```bash
ubrew migrate    # scan /opt/homebrew/Cellar and Caskroom, import into ubrew's DB
```

After migration, `ubrew list`, `ubrew outdated`, and `ubrew upgrade` will see your existing packages.

### Switching back to Homebrew

Packages installed by ubrew live in `/opt/ubrew/prefix/Cellar/` — they don't interfere with Homebrew's `/opt/homebrew/Cellar/`. You can safely remove ubrew with `ubrew nuke` without affecting Homebrew.

## Project status

**Experimental** — works well for common packages. If something breaks, [open an issue](https://github.com/rjallais/ubrew/issues).

License: [Apache 2.0](./LICENSE)

## All commands

| Command | Short | What it does |
|---------|-------|-------------|
| `ubrew install <pkg>` | `ubrew i` | Install packages |
| `ubrew install --cask <app>` | | Install macOS apps |
| `ubrew install --deb <pkg>` | | Install .deb packages (Linux/Docker) |
| `ubrew install user/tap/formula` | | Install from a third-party tap |
| `ubrew remove <pkg>` | `ubrew ui` | Uninstall packages |
| `ubrew remove --deb <pkg>` | | Remove a .deb package (Linux/Docker) |
| `ubrew list` | `ubrew ls` | List installed packages (brew + deb) |
| `ubrew leaves [--tree]` | | List installed formulae with no dependents |
| `ubrew where <pattern>` | `ubrew wh` | Show installed kegs, prefix files, and index hits matching pattern |
| `ubrew info <pkg>` | | Show package details |
| `ubrew info --cask <app>` | | Show cask details |
| `ubrew search <query>` | `ubrew s` | Search formulas and casks |
| `ubrew upgrade [pkg]` | | Upgrade packages |
| `ubrew upgrade --deb` | | Upgrade all installed .deb packages |
| `ubrew outdated` | | List outdated packages (brew + deb) |
| `ubrew pin <pkg>` | | Prevent upgrades |
| `ubrew unpin <pkg>` | | Allow upgrades |
| `ubrew rollback <pkg>` | `ubrew rb` | Revert to previous version |
| `ubrew bundle dump` | | Export installed packages |
| `ubrew bundle install` | | Import from bundle file |
| `ubrew doctor` | `ubrew dr` | Health check |
| `ubrew cleanup` | `ubrew clean` | Remove old caches |
| `ubrew deps [--tree] <pkg>` | | Show dependencies |
| `ubrew services` | | Manage services (launchctl/systemd) |
| `ubrew completions <shell>` | | Print shell completions |
| `ubrew telemetry [status\|on\|off]` | | View or change telemetry opt-in |
| `ubrew nuke` | | Remove all of ubrew's state |
| `ubrew migrate` | | Import packages from Homebrew |
| `ubrew update` | | Self-update ubrew |
| `ubrew init` | | Create directory structure |
| `ubrew help` | | Show help |

See [CHANGELOG.md](./CHANGELOG.md) for version history.
