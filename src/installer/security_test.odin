package installer

// Unit tests for security-related functions in the installer package.
// Run with: odin test src/installer

import "core:fmt"
import "core:os"
import "core:testing"

// ---------------------------------------------------------------------------
// is_safe_binary_name
// ---------------------------------------------------------------------------

@(test)
test_is_safe_binary_name_allows_standard :: proc(t: ^testing.T) {
    valid := []string{
        "git", "node", "python3", "aws-cdk", "rustc",
        "my-app", "libfoo.so.1", "nproc",
    }
    for name in valid {
        testing.expectf(t, is_safe_binary_name(name),
            "expected is_safe_binary_name(%q) = true", name)
    }
}

@(test)
test_is_safe_binary_name_rejects_paths :: proc(t: ^testing.T) {
    invalid := []string{
        "", "/bin/sh", "../etc/passwd", "a/b", "..\\windows",
        "/", ".", "..",
    }
    for name in invalid {
        testing.expectf(t, !is_safe_binary_name(name),
            "expected is_safe_binary_name(%q) = false", name)
    }
}

@(test)
test_is_safe_binary_name_rejects_control_chars :: proc(t: ^testing.T) {
    testing.expect(t, !is_safe_binary_name("name\x00null"), "null byte rejected")
    testing.expect(t, !is_safe_binary_name("new\nline"), "newline rejected")
}

// ---------------------------------------------------------------------------
// is_safe_to_remove_dir
// ---------------------------------------------------------------------------

@(test)
test_is_safe_to_remove_dir_rejects_roots :: proc(t: ^testing.T) {
    dangerous := []string{
        "/", "/opt", "/usr", "/usr/local", "/home",
    }
    for path in dangerous {
        testing.expectf(t, !is_safe_to_remove_dir(path),
            "expected is_safe_to_remove_dir(%q) = false", path)
    }
}

@(test)
test_is_safe_to_remove_dir_allows_subdirs :: proc(t: ^testing.T) {
    safe := []string{
        "/opt/ubrew/cache/blobs",
        "/opt/ubrew/store",
        "/home/linuxbrew/.linuxbrew/Cellar/pkg/0.1.0",
        "/tmp/some-pkg",
    }
    for path in safe {
        // These should be safe; actual HOME dir may also block the test
        // account's own Desktop etc., but that depends on HOME env.
        // We assert the function accepts our synthetic paths.
        testing.expectf(t, is_safe_to_remove_dir(path),
            "expected is_safe_to_remove_dir(%q) = true", path)
    }
}

// ---------------------------------------------------------------------------
// expand_home
// ---------------------------------------------------------------------------

@(test)
test_expand_home_unchanged :: proc(t: ^testing.T) {
    result := expand_home("/opt/ubrew/store", context.temp_allocator)
    defer delete(result, context.temp_allocator)
    testing.expect_value(t, result, "/opt/ubrew/store")
}

@(test)
test_expand_home_tilde_expanded :: proc(t: ^testing.T) {
    home := os.get_env("HOME", context.temp_allocator)
    result := expand_home("~/test", context.temp_allocator)
    defer delete(result, context.temp_allocator)
    expected := fmt.tprintf("%s/test", home)
    testing.expectf(t, result == expected,
        "expected ~/test -> %q, got %q", expected, result)
}

// ---------------------------------------------------------------------------
// dir_name
// ---------------------------------------------------------------------------

@(test)
test_dir_name_standard :: proc(t: ^testing.T) {
    dir_name_check :: proc(t: ^testing.T, input, expected: string) {
        result := dir_name(input)
        // dir_name returns a pointer into the input — no allocation
        if result != expected {
            testing.expectf(t, false,
                "dir_name(%q): want %q, got %q", input, expected, result)
        }
    }
    dir_name_check(t, "/opt/ubrew/cache/blobs/abc",    "/opt/ubrew/cache/blobs")
    dir_name_check(t, "/usr/local/bin/git",            "/usr/local/bin")
    dir_name_check(t, "relative/path/to/file",         "relative/path/to")
    dir_name_check(t, "single",                        ".")
}

// ---------------------------------------------------------------------------
// verify_jws_token
// ---------------------------------------------------------------------------

@(test)
test_verify_jws_token_valid :: proc(t: ^testing.T) {
    // Realistic fixtures: a 64-hex SHA-256 digest, base64url-encoded
    // header/payload. The signature seg is dummy because verify_jws_token
    // deliberately does NOT cryptographically verify it (see SECURITY NOTE
    // in jws.odin) — it only requires the segment to be present.
    header    := "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9" // {"alg":"RS256","typ":"JWT"}
    payload   := "eyJzaGEyNTYiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIn0" // {"sha256":"<64-hex>"}
    digest    := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    token     := fmt.tprintf("%s.%s.%s", header, payload, "dummy_signature")
    testing.expectf(t, verify_jws_token(token, digest),
        "valid JWS token with matching 64-hex sha256 must pass")
}

@(test)
test_verify_jws_token_invalid_format :: proc(t: ^testing.T) {
    testing.expect(t, !verify_jws_token("invalid_token_parts", "hash"), "reject invalid parts")
    testing.expect(t, !verify_jws_token("", ""), "reject empty token")
}

@(test)
test_verify_jws_token_hash_mismatch_rejected :: proc(t: ^testing.T) {
    // The payload carries a valid 64-hex digest; a different expected digest
    // must fail at the expected_sha256 check (no fallback bypass).
    header  := "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    payload := "eyJzaGEyNTYiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIn0"
    token   := fmt.tprintf("%s.%s.%s", header, payload, "dummy_signature")
    wrong   := "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    testing.expect(t, !verify_jws_token(token, wrong), "reject payload that does not contain expected_sha256")
}

@(test)
test_verify_jws_token_empty_expected_rejected :: proc(t: ^testing.T) {
    // expected_sha256 is mandatory: a structurally valid token with a valid
    // payload and non-empty signature is still rejected when the expected
    // digest is empty, so a missing expectation can never silently widen
    // the trust decision.
    header  := "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    payload := "eyJzaGEyNTYiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIn0"
    token   := fmt.tprintf("%s.%s.%s", header, payload, "dummy_signature")
    testing.expect(t, !verify_jws_token(token, ""), "reject token when expected_sha256 is empty")
}

@(test)
test_verify_jws_token_empty_signature_rejected :: proc(t: ^testing.T) {
    // The only signature-related contract verify_jws_token enforces is
    // presence: a structurally valid token with an empty signature segment
    // must be rejected.
    header  := "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    digest  := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    payload := "eyJzaGEyNTYiOiIwMTIzNDU2Nzg5YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYwMTIzNDU2Nzg5YWJjZGVmIn0"
    token := fmt.tprintf("%s.%s.", header, payload) // empty signature segment
    testing.expect(t, !verify_jws_token(token, digest), "reject token with empty signature segment")
}

