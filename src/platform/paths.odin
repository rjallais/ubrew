package platform

// Shared Homebrew directory paths. These live in the lowest-level package
// so that both `store` and `installer` can reference a single source of
// truth instead of each hardcoding their own copy.
CELLAR_DIR   :: "/home/linuxbrew/.linuxbrew/Cellar"
CASKROOM_DIR :: "/home/linuxbrew/.linuxbrew/Caskroom"
