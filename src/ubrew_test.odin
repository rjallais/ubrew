package main

// Unit tests for ubrew main package.
// Run with: odin test src
// or:       mise run test-unit

import "core:testing"
import "core:strings"

// ---------------------------------------------------------------------------
// package_name_safe — validates that formula token names are safe
// ---------------------------------------------------------------------------

@(test)
test_package_name_safe_valid :: proc(t: ^testing.T) {
    valid_names := []string{
        "wget", "tree", "ffmpeg", "git", "node", "python3",
        "aws-cdk", "ca-certificates", "openssl@3",
    }
    for name in valid_names {
        if !package_name_safe(name) {
            testing.expectf(t, false, "expected package_name_safe(%q) = true, got false", name)
        }
    }
}

@(test)
test_package_name_safe_invalid :: proc(t: ^testing.T) {
    invalid_names := []string{
        "../etc/passwd",
        "/absolute/path",
        "has space",
        "",
        "../../traversal",
        "name\x00with\x00nulls",
    }
    for name in invalid_names {
        if package_name_safe(name) {
            testing.expectf(t, false, "expected package_name_safe(%q) = false, got true", name)
        }
    }
}

// ---------------------------------------------------------------------------
// extract_quoted_strings — parses dependency lists from Ruby formula lines
// ---------------------------------------------------------------------------

@(test)
test_extract_quoted_strings_single :: proc(t: ^testing.T) {
    results := extract_quoted_strings(`  depends_on "openssl@3"`, context.allocator)
    defer delete(results)
    testing.expect_value(t, len(results), 1)
    if len(results) >= 1 {
        testing.expect_value(t, results[0], "openssl@3")
    }
}

@(test)
test_extract_quoted_strings_multiple :: proc(t: ^testing.T) {
    results := extract_quoted_strings(`  depends_on "readline", "xz", "openssl@3"`, context.allocator)
    defer delete(results)
    testing.expect_value(t, len(results), 3)
    if len(results) >= 3 {
        testing.expect_value(t, results[0], "readline")
        testing.expect_value(t, results[1], "xz")
        testing.expect_value(t, results[2], "openssl@3")
    }
}

@(test)
test_extract_quoted_strings_empty_line :: proc(t: ^testing.T) {
    results := extract_quoted_strings(`  homepage ""`, context.allocator)
    defer delete(results)
    // An empty quoted string should either return an empty string or nothing
    // depending on implementation. Just verify it doesn't crash.
    _ = results
}

@(test)
test_extract_quoted_strings_no_quotes :: proc(t: ^testing.T) {
    results := extract_quoted_strings(`  bottle :unneeded`, context.allocator)
    defer delete(results)
    testing.expect_value(t, len(results), 0)
}
