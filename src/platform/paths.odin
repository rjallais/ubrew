package platform

import "core:fmt"
import "core:os"
import "core:strings"

// Shared Homebrew / ubrew directory paths.
//
// Defaults match the Homebrew layout on each OS/arch so both package
// managers share Cellar/Caskroom and stay in sync:
//   - Linux:                 /home/linuxbrew/.linuxbrew
//   - macOS (Apple Silicon): /opt/homebrew
//   - macOS (Intel):         /usr/local
//
// All paths are runtime-overridable via env vars so users can run brew
// and ubrew side-by-side in separate prefixes:
//
//   UBREW_ROOT       State root (cache, store, db). Default: /opt/ubrew
//   UBREW_PREFIX     Install prefix for packages/bin/opt.
//                    Default: the platform Homebrew prefix (shared).
//                    Set to e.g. /opt/ubrew/prefix for isolation.
//   UBREW_CELLAR     Override Cellar path (default: $UBREW_PREFIX/Cellar)
//   UBREW_CASKROOM   Override Caskroom path (default: $UBREW_PREFIX/Caskroom)
//   HOMEBREW_PREFIX  Honoured as fallback for UBREW_PREFIX when the
//                    UBREW-specific var is unset (script interop).

when ODIN_OS == .Linux {
	DEFAULT_HOMEBREW_PREFIX :: "/home/linuxbrew/.linuxbrew"
} else when ODIN_OS == .Darwin {
	when ODIN_ARCH == .arm64 {
		DEFAULT_HOMEBREW_PREFIX :: "/opt/homebrew"
	} else {
		DEFAULT_HOMEBREW_PREFIX :: "/usr/local"
	}
} else {
	DEFAULT_HOMEBREW_PREFIX :: "/usr/local"
}

DEFAULT_UBREW_ROOT :: "/opt/ubrew"

// Compile-time aliases kept for call sites that still use the old
// constant names. These always reflect the *default* platform layout;
// prefer the package-level variables below once init_paths() has run.
HOMEBREW_PREFIX :: DEFAULT_HOMEBREW_PREFIX
CELLAR_DIR      :: DEFAULT_HOMEBREW_PREFIX + "/Cellar"
CASKROOM_DIR    :: DEFAULT_HOMEBREW_PREFIX + "/Caskroom"
BIN_DIR         :: DEFAULT_HOMEBREW_PREFIX + "/bin"

// Runtime-resolved paths. Initialised to the compile-time defaults and
// re-bound by init_paths() when UBREW_*/HOMEBREW_* env vars are set.
// Callers that need override support should use these variables (or the
// getter procs) rather than the :: constants above.
homebrew_prefix: string = DEFAULT_HOMEBREW_PREFIX
cellar_dir:      string = DEFAULT_HOMEBREW_PREFIX + "/Cellar"
caskroom_dir:    string = DEFAULT_HOMEBREW_PREFIX + "/Caskroom"
bin_dir:         string = DEFAULT_HOMEBREW_PREFIX + "/bin"
ubrew_root:      string = DEFAULT_UBREW_ROOT
ubrew_prefix:    string = DEFAULT_UBREW_ROOT + "/prefix"
cache_dir:       string = DEFAULT_UBREW_ROOT + "/cache"

// paths_initialized guards against double-init; init_paths is idempotent.
paths_initialized: bool = false

// clone_env returns a heap-allocated copy of an env var, or "" if unset.
// Uses context.allocator so the string lives for the process lifetime.
@(private)
clone_env :: proc(key: string) -> string {
	v := os.get_env(key, context.temp_allocator)
	if v == "" {
		return ""
	}
	return strings.clone(v, context.allocator)
}

// init_paths rebinds the runtime path variables from environment variables.
// Safe to call more than once; subsequent calls are no-ops.
//
// Resolution order for the install prefix:
//   1. UBREW_PREFIX
//   2. HOMEBREW_PREFIX  (script interop)
//   3. platform default (DEFAULT_HOMEBREW_PREFIX)
//
// UBREW_ROOT controls ubrew's own state tree (cache/store/db) and is
// independent of the package install prefix — so a user can keep
// ubrew state at /opt/ubrew while installing packages into a private
// prefix, or share Homebrew's Cellar for full interop.
init_paths :: proc() {
	if paths_initialized {
		return
	}
	paths_initialized = true

	// --- ubrew state root ---
	if root := clone_env("UBREW_ROOT"); root != "" {
		ubrew_root = root
	}
	// Derived state paths always follow UBREW_ROOT.
	ubrew_prefix = fmt.aprintf("%s/prefix", ubrew_root)
	cache_dir    = fmt.aprintf("%s/cache", ubrew_root)

	// Allow explicit UBREW_PREFIX to also override the "ubrew prefix"
	// used for opt/bin links under /opt/ubrew/prefix historically.
	// When UBREW_PREFIX is set, both the package prefix AND ubrew_prefix
	// point at it so a fully-isolated install is a single env var.
	ubrew_prefix_env := clone_env("UBREW_PREFIX")
	homebrew_prefix_env := clone_env("HOMEBREW_PREFIX")

	// --- package install prefix (Cellar/Caskroom/bin) ---
	prefix := DEFAULT_HOMEBREW_PREFIX
	if ubrew_prefix_env != "" {
		prefix = ubrew_prefix_env
		// Fully isolated mode: also redirect ubrew's own prefix.
		ubrew_prefix = ubrew_prefix_env
	} else if homebrew_prefix_env != "" {
		prefix = homebrew_prefix_env
	}
	homebrew_prefix = prefix

	// Cellar / Caskroom / bin — explicit overrides win, else derive.
	if cellar := clone_env("UBREW_CELLAR"); cellar != "" {
		cellar_dir = cellar
	} else if cellar := clone_env("HOMEBREW_CELLAR"); cellar != "" {
		cellar_dir = cellar
	} else {
		cellar_dir = fmt.aprintf("%s/Cellar", prefix)
	}

	if caskroom := clone_env("UBREW_CASKROOM"); caskroom != "" {
		caskroom_dir = caskroom
	} else if caskroom := clone_env("HOMEBREW_CASKROOM"); caskroom != "" {
		caskroom_dir = caskroom
	} else {
		caskroom_dir = fmt.aprintf("%s/Caskroom", prefix)
	}

	if bin := clone_env("UBREW_BIN"); bin != "" {
		bin_dir = bin
	} else {
		bin_dir = fmt.aprintf("%s/bin", prefix)
	}
}

// Convenience getters — always return the live runtime value.
get_homebrew_prefix :: proc() -> string { return homebrew_prefix }
get_cellar_dir      :: proc() -> string { return cellar_dir }
get_caskroom_dir    :: proc() -> string { return caskroom_dir }
get_bin_dir         :: proc() -> string { return bin_dir }
get_ubrew_root      :: proc() -> string { return ubrew_root }
get_ubrew_prefix    :: proc() -> string { return ubrew_prefix }
get_cache_dir       :: proc() -> string { return cache_dir }
