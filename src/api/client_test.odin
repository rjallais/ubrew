package api

// Unit tests for the api package.
// Run with: odin test src/api

import "core:testing"
import "core:strings"
import "core:os"
import "core:fmt"
import "../tap"

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

// ---------------------------------------------------------------------------
// synth_tap_listing_from_dir — listing synthesis from a local clone (Phase 2)
// ---------------------------------------------------------------------------

@(test)
test_synth_tap_listing_from_dir :: proc(t: ^testing.T) {
    fixture := temp_test_dir(t, "ubrew-synth-*")
    defer os.remove_all(fixture)

    _ = os.make_directory_all(fmt.tprintf("%s/Formula", fixture), os.perm(0o755))
    _ = os.make_directory_all(fmt.tprintf("%s/Formula/w", fixture), os.perm(0o755))
    _ = os.make_directory_all(fmt.tprintf("%s/Casks", fixture), os.perm(0o755))
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/wget.rb", fixture), "class Wget < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/w/wget2.rb", fixture), "class Wget2 < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Casks/foo.rb", fixture), "cask \"foo\" do\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/wget2.rb", fixture), "class Wget2 < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/bar.rb", fixture), "class Bar < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/README.md", fixture), "not a formula")

    listing, ok := synth_tap_listing_from_dir(fixture)
    testing.expectf(t, ok, "synth_tap_listing_from_dir should succeed")
    defer delete(listing)

    text := string(listing)
    testing.expectf(t, strings.has_prefix(text, "["), "listing must be a JSON array, got %q", text)
    testing.expectf(t, strings.has_suffix(text, "]"), "listing must end with ], got %q", text)
    wants := []string{"wget.rb", "wget2.rb", "foo.rb", "bar.rb"}
    for want in wants {
        testing.expectf(t, strings.contains(text, fmt.tprintf("\"%s\"", want)), "listing should contain %q, got %q", want, text)
    }
    testing.expectf(t, !strings.contains(text, "README"), "listing must not contain non-rb files, got %q", text)
    // Dedupe: wget2.rb lives in both Formula/w/ and the clone root, two
    // scanned directories — it must appear exactly once in the listing.
    testing.expectf(t, strings.count(text, "\"wget2.rb\"") == 1, "wget2.rb must appear exactly once, got %q", text)
}

@(test)
test_synth_tap_listing_from_dir_missing :: proc(t: ^testing.T) {
    listing, ok := synth_tap_listing_from_dir("/nonexistent/ubrew/fixture")
    testing.expectf(t, !ok, "missing clone must not synthesize a listing")
    testing.expectf(t, listing == nil, "missing clone must return nil data")
}

// ---------------------------------------------------------------------------
// scan_dir_for_formulae — local .rb scanning with query matching (Phase 2)
// ---------------------------------------------------------------------------

@(test)
test_scan_dir_for_formulae :: proc(t: ^testing.T) {
    fixture := temp_test_dir(t, "ubrew-scan-*")
    defer os.remove_all(fixture)

    _ = os.write_entire_file_from_string(fmt.tprintf("%s/foo.rb", fixture), "class Foo < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/foobar.rb", fixture), "class Foobar < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/bar.rb", fixture), "class Bar < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/NOTES.txt", fixture), "not a formula")

    out := make([dynamic]Formula_Search_Result, context.allocator)
    defer {
        for r in out {
            delete(r.name)
            delete(r.desc)
            delete(r.version)
        }
        delete(out)
    }

    t_obj := tap.Tap{name = "testuser/tapfixture"}
    at_limit, found_any := scan_dir_for_formulae(&out, t_obj, fixture, "fo", 25)
    testing.expectf(t, !at_limit, "limit 25 must not be reached with 2 matches")
    testing.expectf(t, found_any, "directory with .rb files must report found_any")

    // "foo" and "foobar" match "fo"; "bar" and NOTES.txt do not.
    testing.expectf(t, len(out) == 2, "expected 2 matches, got %d", len(out))
    got_foo := false
    got_foobar := false
    for r in out {
        if r.name == "testuser/tapfixture/foo" do got_foo = true
        if r.name == "testuser/tapfixture/foobar" do got_foobar = true
    }
    testing.expectf(t, got_foo, "expected testuser/tapfixture/foo in results")
    testing.expectf(t, got_foobar, "expected testuser/tapfixture/foobar in results")
}

@(test)
test_append_tap_search_result_dedupe :: proc(t: ^testing.T) {
    out := make([dynamic]Formula_Search_Result, context.allocator)
    defer {
        for r in out {
            delete(r.name)
            delete(r.desc)
            delete(r.version)
        }
        delete(out)
    }
    t_obj := tap.Tap{name = "user/tap"}

    testing.expectf(t, !append_tap_search_result(&out, t_obj, "wget", "wget", 25), "first add should not hit limit")
    testing.expectf(t, !append_tap_search_result(&out, t_obj, "wget", "wget", 25), "duplicate add must be rejected")
    testing.expectf(t, len(out) == 1, "duplicate add must not grow results, got %d", len(out))
    testing.expectf(t, append_tap_search_result(&out, t_obj, "wget2", "wget", 1), "second distinct add should hit limit")
    testing.expectf(t, len(out) == 2, "expected 2 results, got %d", len(out))
}

// temp_test_dir creates a unique temp directory (create_temp_file then reuse
// the name) and returns its heap-allocated path; caller removes with os.remove_all.
temp_test_dir :: proc(t: ^testing.T, pattern: string) -> string {
    f, err := os.create_temp_file("", pattern)
    if err != nil {
        testing.fail_now(t, "create_temp_file failed")
    }
    name := strings.clone(os.name(f), context.allocator)
    os.close(f)
    os.remove(name)
    if mk_err := os.make_directory_all(name, os.perm(0o755)); mk_err != nil {
        testing.fail_now(t, "make_directory_all failed")
    }
    return name
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
