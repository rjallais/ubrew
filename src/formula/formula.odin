package formula

import "core:fmt"

Formula :: struct {
    name:                     string,
    desc:                     string,
    homepage:                 string,
    version:                  string,
    bottle_url:               string,
    bottle_sha256:            string,
    bottle_size:              i64,
    installed_size:           i64,
    source_url:               string,
    source_sha256:            string,
    dependencies:             []string,
    build_dependencies:       []string,
    test_dependencies:        []string,
    optional_dependencies:    []string,
    recommended_dependencies: []string,
    requirements:             []string,
    uses_from_macos:          []string,
    // binaries are the names that `bin.install "..."` would create in
    // the keg's bin/ directory. Used by 3rd-party tap formulae that
    // build from source.
    binaries:                 []string,
    // tap is the user/repo of the tap this formula came from, or "" for
    // the canonical Homebrew formula registry. Used for cache invalidation
    // and dependency display.
    tap:                      string,
    aliases:                  []string,
    keg_only:                 bool,
    keg_only_reason:          string,
}

format_bytes_human :: proc(bytes: i64, allocator := context.temp_allocator) -> string {
	if bytes <= 0 do return fmt.aprintf("%s", "N/A", allocator = allocator)
	if bytes < 1024 do return fmt.aprintf("%d B", bytes, allocator = allocator)
	kb := f64(bytes) / 1024.0
	if kb < 1024 do return fmt.aprintf("%.1f KB", kb, allocator = allocator)
	mb := kb / 1024.0
	if mb < 1024 do return fmt.aprintf("%.1f MB", mb, allocator = allocator)
	gb := mb / 1024.0
	return fmt.aprintf("%.2f GB", gb, allocator = allocator)
}
