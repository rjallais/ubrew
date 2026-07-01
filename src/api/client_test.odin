package api

// Unit tests for the api package.
// Run with: odin test src/api

import "core:testing"
import "core:strings"

// ---------------------------------------------------------------------------
// lower_contains — case-insensitive substring search
// ---------------------------------------------------------------------------

@(test)
test_lower_contains_basic :: proc(t: ^testing.T) {
    // needle_lower must be passed already lowercased
    testing.expect(t, lower_contains("Wget", "wget"),       "wget in Wget")
    testing.expect(t, lower_contains("FFMPEG", "ffmpeg"),   "ffmpeg in FFMPEG")
    testing.expect(t, lower_contains("OpenSSL@3", "openssl"),"openssl in OpenSSL@3")
    testing.expect(t, lower_contains("tree", "tree"),        "tree in tree")
}

@(test)
test_lower_contains_empty_needle :: proc(t: ^testing.T) {
    // Empty needle must always match
    testing.expect(t, lower_contains("anything", ""),  "empty needle matches any haystack")
    testing.expect(t, lower_contains("", ""),          "empty needle matches empty haystack")
}

@(test)
test_lower_contains_needle_longer :: proc(t: ^testing.T) {
    testing.expect(t, !lower_contains("hi", "hello"), "longer needle must not match")
    testing.expect(t, !lower_contains("", "x"),       "non-empty needle in empty haystack")
}

@(test)
test_lower_contains_no_match :: proc(t: ^testing.T) {
    testing.expect(t, !lower_contains("ripgrep", "wget"),  "ripgrep does not contain wget")
    testing.expect(t, !lower_contains("git", "github"),    "git does not contain github")
}

// ---------------------------------------------------------------------------
// extract_owner_repo_from_github_url — pure URL parsing
// ---------------------------------------------------------------------------

@(test)
test_extract_owner_repo_standard :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"https://github.com/Homebrew/homebrew-core", "Homebrew/homebrew-core"},
        {"https://github.com/rjallais/ubrew",         "rjallais/ubrew"},
        {"https://github.com/ublue-os/homebrew-tap",  "ublue-os/homebrew-tap"},
    }
    for pair in cases {
        result := extract_owner_repo_from_github_url(pair[0])
        defer delete(result)
        if result != pair[1] {
            testing.expectf(t, false, "extract_owner_repo_from_github_url(%q): want %q, got %q",
                pair[0], pair[1], result)
        }
    }
}

@(test)
test_extract_owner_repo_with_git_suffix :: proc(t: ^testing.T) {
    result := extract_owner_repo_from_github_url("https://github.com/rjallais/ubrew.git")
    defer delete(result)
    testing.expect_value(t, result, "rjallais/ubrew")
}

@(test)
test_extract_owner_repo_with_subpath :: proc(t: ^testing.T) {
    result := extract_owner_repo_from_github_url("https://github.com/rjallais/ubrew/releases/latest")
    defer delete(result)
    testing.expect_value(t, result, "rjallais/ubrew")
}

@(test)
test_extract_owner_repo_non_github :: proc(t: ^testing.T) {
    result := extract_owner_repo_from_github_url("https://gitlab.com/user/repo")
    testing.expect_value(t, result, "")
}

@(test)
test_extract_owner_repo_empty :: proc(t: ^testing.T) {
    result := extract_owner_repo_from_github_url("")
    testing.expect_value(t, result, "")
}

// ---------------------------------------------------------------------------
// parse_tap_token — tap/formula token splitting
// ---------------------------------------------------------------------------

@(test)
test_parse_tap_token_three_parts :: proc(t: ^testing.T) {
    tap_name, formula_name := parse_tap_token("ublue-os/tap/ublue-os-centos")
    defer delete(tap_name)
    defer delete(formula_name)
    testing.expect_value(t, tap_name,     "ublue-os/tap")
    testing.expect_value(t, formula_name, "ublue-os-centos")
}

@(test)
test_parse_tap_token_two_parts :: proc(t: ^testing.T) {
    tap_name, formula_name := parse_tap_token("homebrew/core")
    defer delete(tap_name)
    defer delete(formula_name)
    testing.expect_value(t, tap_name,     "homebrew/core")
    testing.expect_value(t, formula_name, "")
}

@(test)
test_parse_tap_token_one_part :: proc(t: ^testing.T) {
    tap_name, formula_name := parse_tap_token("wget")
    defer delete(tap_name)
    defer delete(formula_name)
    testing.expect_value(t, tap_name,     "")
    testing.expect_value(t, formula_name, "wget")
}
