package store

import "core:os"
import "core:fmt"
import "core:strings"
import "../platform"

STORE_DIR :: "/opt/ubrew/store"
STORE_RELOCATED_DIR :: "/opt/ubrew/store-relocated"
CELLAR_DIR :: "/opt/ubrew/prefix/Cellar"

store_entry_path :: proc(sha256: string, buf: []u8) -> string {
	if !is_valid_sha256(sha256) {
		return ""
	}
	return fmt.bprintf(buf[:], "%s/%s", STORE_DIR, sha256)
}

store_ensure_dir :: proc() -> bool {
	return os.make_directory_all(STORE_DIR, os.perm(0o755)) == nil
}

store_has_relocated_entry :: proc(sha256: string) -> bool {
	if !is_valid_sha256(sha256) {
		return false
	}
	buf: [512]u8
	result := fmt.bprintf(buf[:], "%s/%s", STORE_RELOCATED_DIR, sha256)
	return os.is_dir(result)
}

store_save_relocated_entry :: proc(sha256: string, name: string, version: string) -> bool {
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
	src_result := fmt.bprintf(src_buf[:], "%s/%s/%s", CELLAR_DIR, name, version)

	dst_buf: [512]u8
	dst_result := fmt.bprintf(dst_buf[:], "%s/%s", STORE_RELOCATED_DIR, sha256)

	if os.is_dir(dst_result) {
		return true
	}

	os.make_directory_all(STORE_RELOCATED_DIR, os.perm(0o755))

	return platform.cow_copy(src_result, dst_result)
}

store_materialize_from_relocated :: proc(sha256: string, name: string, version: string) -> bool {
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
	src_result := fmt.bprintf(src_buf[:], "%s/%s", STORE_RELOCATED_DIR, sha256)

	dst_buf: [512]u8
	dst_result := fmt.bprintf(dst_buf[:], "%s/%s/%s", CELLAR_DIR, name, version)

	parent_buf: [512]u8
	parent_result := fmt.bprintf(parent_buf[:], "%s/%s", CELLAR_DIR, name)
	os.make_directory_all(parent_result, os.perm(0o755))

	tmp_buf: [512]u8
	tmp_result := fmt.bprintf(tmp_buf[:], "%s/.%s.tmp", CELLAR_DIR, sha256)
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
