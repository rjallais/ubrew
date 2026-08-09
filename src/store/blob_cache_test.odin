package store

// Unit tests for the blob_cache package.
// Run with: odin test src/store

import "core:fmt"
import "core:os"
import "core:testing"
import "../platform"

// ---------------------------------------------------------------------------
// is_valid_sha256
// ---------------------------------------------------------------------------

@(test)
test_is_valid_sha256_correct :: proc(t: ^testing.T) {
    valid := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    testing.expect(t, is_valid_sha256(valid), "valid 64-char hex sha256")
}

@(test)
test_is_valid_sha256_uppercase_rejected :: proc(t: ^testing.T) {
    invalid := "ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789"
    testing.expect(t, !is_valid_sha256(invalid), "uppercase hex rejected")
}

@(test)
test_is_valid_sha256_wrong_length :: proc(t: ^testing.T) {
    too_short := "abc123"
    testing.expect(t, !is_valid_sha256(too_short), "too short rejected")
    too_long := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789ff"
    testing.expect(t, !is_valid_sha256(too_long), "too long rejected")
}

@(test)
test_is_valid_sha256_non_hex :: proc(t: ^testing.T) {
    bad := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef01234567gx"
    // 64 chars total, last two chars are non-hex ('g' and 'x')
    testing.expect(t, !is_valid_sha256(bad), "non-hex chars rejected")
}

@(test)
test_is_valid_sha256_empty :: proc(t: ^testing.T) {
    testing.expect(t, !is_valid_sha256(""), "empty string rejected")
}

// ---------------------------------------------------------------------------
// blob_path
// ---------------------------------------------------------------------------

@(test)
test_blob_path_format :: proc(t: ^testing.T) {
    sha := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    buf: [512]u8
    result := blob_path(sha, buf[:])
    expected := fmt.tprintf("%s/%s", "/opt/ubrew/cache/blobs", sha)
    testing.expectf(t, result == expected,
        "expected %q, got %q", expected, result)
}

@(test)
test_blob_path_undersized_buffer_returns_empty :: proc(t: ^testing.T) {
    sha := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    buf: [8]u8
    result := blob_path(sha, buf[:])
    testing.expectf(t, result == "",
        "undersized buffer must yield empty path, got %q", result)
}

// ---------------------------------------------------------------------------
// init_blob_paths / runtime-root rebinding
// ---------------------------------------------------------------------------

// A non-default runtime root must re-bind BLOBS_DIR via init_blob_paths()
// (store.init_paths() calls it), so the blob cache follows UBREW_ROOT
// overrides instead of staying pinned to the compile-time default.
@(test)
test_blob_path_rebound_with_custom_root :: proc(t: ^testing.T) {
    // Save the ambient env state (UBREW_ROOT, if set) and the current
    // BLOBS_DIR so cleanup restores them instead of clobbering the
    // environment or hardcoding the default path.
    had_root := os.get_env("UBREW_ROOT", context.temp_allocator)
    saved_blobs := BLOBS_DIR
    defer {
        if had_root == "" {
            _ = os.set_env("UBREW_ROOT", "")
        } else {
            _ = os.set_env("UBREW_ROOT", had_root)
        }
        BLOBS_DIR = saved_blobs
    }

    testing.expect(t, os.set_env("UBREW_ROOT", "/tmp/ubrew-blob-test") == nil,
        "set UBREW_ROOT")

    platform.init_paths()
    init_blob_paths()

    sha := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    buf: [512]u8
    result := blob_path(sha, buf[:])
    expected := fmt.tprintf("%s/cache/blobs/%s", "/tmp/ubrew-blob-test", sha)
    testing.expectf(t, result == expected,
        "expected %q, got %q", expected, result)
}
