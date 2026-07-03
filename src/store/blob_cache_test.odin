package store

// Unit tests for the blob_cache package.
// Run with: odin test src/store

import "core:fmt"
import "core:testing"

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
