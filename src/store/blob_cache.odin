package store

import "core:os"
import "core:fmt"
import "../platform"

BLOBS_DIR := platform.DEFAULT_UBREW_ROOT + "/cache/blobs"

init_blob_paths :: proc() {
	BLOBS_DIR = fmt.aprintf("%s/cache/blobs", platform.get_ubrew_root())
}

blob_path :: proc(sha256: string, buf: []u8) -> string {
	// The build compiles asserts out (-disable-assert), so the historical
	// size assert was dead code; bounded_path returns "" for an oversized
	// buffer instead. Callers must treat "" as "no blob path" and bail.
	return bounded_path(buf, "%s/%s", BLOBS_DIR, sha256)
}

blob_has :: proc(sha256: string) -> bool {
	if !is_valid_sha256(sha256) {
		return false
	}
	buf: [512]u8
	path := blob_path(sha256, buf[:])
	if len(path) == 0 {
		return false
	}
	return os.is_file(path)
}

blob_ensure_dir :: proc() -> bool {
	return os.make_directory_all(BLOBS_DIR, os.perm(0o755)) == nil
}

is_valid_sha256 :: proc(sha256: string) -> bool {
	if len(sha256) != 64 {
		return false
	}
	for c in sha256 {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}
