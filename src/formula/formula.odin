package formula

Formula :: struct {
    name:          string,
    desc:          string,
    homepage:      string,
    version:       string,
    bottle_url:    string,
    bottle_sha256: string,
    source_url:    string,
    source_sha256: string,
    dependencies:  []string,
    // binaries are the names that `bin.install "..."` would create in
    // the keg's bin/ directory. Used by 3rd-party tap formulae that
    // build from source.
    binaries:      []string,
    // tap is the user/repo of the tap this formula came from, or "" for
    // the canonical Homebrew formula registry. Used for cache invalidation
    // and dependency display.
    tap:           string,
    aliases:       []string,
}
