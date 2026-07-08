package platform

// Shared Homebrew directory paths. These live in the lowest-level package
// so that both `store` and `installer` can reference a single source of
// truth instead of each hardcoding their own copy.
//
// The paths are platform-aware to match the Homebrew layout on each OS/arch:
//   - Linux:                 /home/linuxbrew/.linuxbrew
//   - macOS (Apple Silicon): /opt/homebrew
//   - macOS (Intel):         /usr/local

when ODIN_OS == .Linux {
	HOMEBREW_PREFIX :: "/home/linuxbrew/.linuxbrew"
} else when ODIN_OS == .Darwin {
	when ODIN_ARCH == .arm64 {
		HOMEBREW_PREFIX :: "/opt/homebrew"
	} else {
		HOMEBREW_PREFIX :: "/usr/local"
	}
} else {
	HOMEBREW_PREFIX :: "/usr/local"
}

CELLAR_DIR   :: HOMEBREW_PREFIX + "/Cellar"
CASKROOM_DIR :: HOMEBREW_PREFIX + "/Caskroom"
