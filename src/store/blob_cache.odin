package store

import "core:os"
import "core:fmt"

BLOBS_DIR :: "/opt/ubrew/cache/blobs"

blob_path :: proc(sha256: string, buf: []u8) -> string {
	assert(len(buf) >= len(BLOBS_DIR) + 1 + len(sha256), "Buffer too small for blob path")
	return fmt.bprintf(buf[:], "%s/%s", BLOBS_DIR, sha256)
}

blob_has :: proc(sha256: string) -> bool {
	if !is_valid_sha256(sha256) {
		return false
	}
	buf: [512]u8
	path := blob_path(sha256, buf[:])
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
