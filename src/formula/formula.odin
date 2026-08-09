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

// format_bytes_human renders a byte count in a human-friendly unit. Values
// are promoted to the next unit when display rounding would cross the
// boundary (e.g. 1024*1024-1 bytes must not read "1024.0 KB").
format_bytes_human :: proc(bytes: i64, allocator := context.temp_allocator) -> string {
	if bytes <= 0 do return "N/A"
	if bytes < 1024 do return fmt.aprintf("%d B", bytes, allocator = allocator)
	kb := f64(bytes) / 1024.0
	if kb < 1024 {
		if kb >= 1023.95 { // rounds to "1024.0" — promote to MB
			return fmt.aprintf("%.2f MB", kb / 1024.0, allocator = allocator)
		}
		return fmt.aprintf("%.1f KB", kb, allocator = allocator)
	}
	mb := kb / 1024.0
	if mb < 1024 {
		if mb >= 1023.95 { // rounds to "1024.0" — promote to GB
			return fmt.aprintf("%.2f GB", mb / 1024.0, allocator = allocator)
		}
		return fmt.aprintf("%.1f MB", mb, allocator = allocator)
	}
	gb := mb / 1024.0
	return fmt.aprintf("%.2f GB", gb, allocator = allocator)
}
