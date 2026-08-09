package store

import "core:os"
import "core:fmt"
import "core:strings"
import "../platform"

// Compile-time defaults. Runtime overrides come from init_paths().
STORE_DIR           := "/opt/ubrew/store"
STORE_RELOCATED_DIR := "/opt/ubrew/store-relocated"
CELLAR_DIR          := platform.DEFAULT_HOMEBREW_PREFIX + "/Cellar"

store_paths_initialized: bool = false

init_paths :: proc() {
	if store_paths_initialized {
		return
	}
	store_paths_initialized = true
	root := platform.get_ubrew_root()
	STORE_DIR           = fmt.aprintf("%s/store", root)
	STORE_RELOCATED_DIR = fmt.aprintf("%s/store-relocated", root)
	CELLAR_DIR          = strings.clone(platform.get_cellar_dir(), context.allocator)
	// Blob cache must follow the same runtime root; without this the
	// package-scope BLOBS_DIR stays pinned to DEFAULT_UBREW_ROOT and blob
	// cache reads/writes land in the wrong prefix under UBREW_ROOT overrides.
	init_blob_paths()
}

// bounded_path renders `format` into `buf` like fmt.bprintf, but returns ""
// instead of a silently truncated result when `buf` is too small. The build
// compiles asserts out (-disable-assert, -no-bounds-check) and fmt.bprintf
// truncates an oversized result with no error signal, so callers must treat a
// "" return as "could not render path" and bail before any os call.
bounded_path :: proc(buf: []u8, format: string, args: ..any) -> string {
	if len(buf) <= len(fmt.tprintf(format, ..args)) {
		return ""
	}
	return fmt.bprintf(buf, format, ..args)
}

store_entry_path :: proc(sha256: string, buf: []u8) -> string {
	if !is_valid_sha256(sha256) {
		return ""
	}
	return bounded_path(buf, "%s/%s", STORE_DIR, sha256)
}

store_ensure_dir :: proc() -> bool {
	return os.make_directory_all(STORE_DIR, os.perm(0o755)) == nil
}

// store_relocated_entry_path returns the store-relocated entry directory
// for a keg, scoped by the resolved HOMEBREW_PREFIX it was relocated for.
// The sha256 identifies the bottle artifact, but relocation bakes the
// runtime prefix into rpaths, symlinks and file contents; an entry written
// under one prefix must never be materialized under a different one.
store_relocated_entry_path :: proc(sha256, prefix: string, buf: []u8) -> string {
	if !is_valid_sha256(sha256) {
		return ""
	}
	if len(prefix) < 2 || prefix[0] != '/' {
		return ""
	}
	// Reject any "." / ".." / empty segment so a crafted prefix can never
	// lift the entry path out of STORE_RELOCATED_DIR (e.g. "/../../../tmp").
	{
		start: int = 1
		for start < len(prefix) {
			end := start
			for end < len(prefix) && prefix[end] != '/' {
				end += 1
			}
			segment := prefix[start:end]
			if segment == "" || segment == "." || segment == ".." {
				return ""
			}
			if end == len(prefix) {
				break
			}
			start = end + 1
		}
	}
	return bounded_path(buf, "%s%s/%s", STORE_RELOCATED_DIR, prefix, sha256)
}

store_has_relocated_entry :: proc(sha256, prefix: string) -> bool {
	buf: [512]u8
	result := store_relocated_entry_path(sha256, prefix, buf[:])
	return len(result) > 0 && os.is_dir(result)
}

store_save_relocated_entry :: proc(sha256: string, name: string, version: string, prefix: string) -> bool {
	if !is_valid_sha256(sha256) {
		return false
	}

	if len(name) == 0 || len(version) == 0 {
		return false
	}

	if strings.contains(name, "/") || strings.contains(name, "\\") || name == "." || name == ".." || strings.has_prefix(name, "/") {
		return false
	}
	if strings.contains(version, "/") || strings.contains(version, "\\") || version == "." || version == ".." || strings.has_prefix(version, "/") {
		return false
	}

	src_buf: [512]u8
	src_result := bounded_path(src_buf[:], "%s/%s/%s", CELLAR_DIR, name, version)
	if len(src_result) == 0 {
		return false
	}

	dst_buf: [512]u8
	dst_result := store_relocated_entry_path(sha256, prefix, dst_buf[:])
	if len(dst_result) == 0 {
		return false
	}

	if os.is_dir(dst_result) {
		return true
	}

	os.make_directory_all(STORE_RELOCATED_DIR, os.perm(0o755))

	return platform.cow_copy(src_result, dst_result)
}

store_materialize_from_relocated :: proc(sha256: string, name: string, version: string, prefix: string) -> bool {
	if !is_valid_sha256(sha256) {
		return false
	}

	if len(name) == 0 || len(version) == 0 {
		return false
	}

	if strings.contains(name, "/") || strings.contains(name, "\\") || name == "." || name == ".." || strings.has_prefix(name, "/") {
		return false
	}
	if strings.contains(version, "/") || strings.contains(version, "\\") || version == "." || version == ".." || strings.has_prefix(version, "/") {
		return false
	}

	src_buf: [512]u8
	src_result := store_relocated_entry_path(sha256, prefix, src_buf[:])
	if len(src_result) == 0 {
		return false
	}

	dst_buf: [512]u8
	dst_result := bounded_path(dst_buf[:], "%s/%s/%s", CELLAR_DIR, name, version)
	if len(dst_result) == 0 {
		return false
	}

	parent_buf: [512]u8
	parent_result := bounded_path(parent_buf[:], "%s/%s", CELLAR_DIR, name)
	if len(parent_result) == 0 {
		return false
	}
	os.make_directory_all(parent_result, os.perm(0o755))

	tmp_buf: [512]u8
	tmp_result := bounded_path(tmp_buf[:], "%s/.%s.tmp", CELLAR_DIR, sha256)
	if len(tmp_result) == 0 {
		return false
	}
	_ = os.remove_all(tmp_result)
	if !platform.cow_copy(src_result, tmp_result) {
		_ = os.remove_all(tmp_result)
		return false
	}
	if os.is_dir(dst_result) {
		os.remove_all(dst_result)
	}
	if os.rename(tmp_result, dst_result) != nil {
		_ = os.remove_all(tmp_result)
		return false
	}
	return true
}
