package tap

// Unit tests for the tap package.
// Run with: odin test src/tap
// or via:   mise run test-unit  (runs odin test src src/tap)

import "core:testing"
import "core:strings"
import "core:os"
import "core:fmt"
import "core:sync"
import "../platform"

// The odin test runner executes tests in parallel across a thread pool. The
// shared-state tests below mutate package globals (taps_dir_override,
// TAPS_DB_PATH, TAPS_CACHE_DIR) to redirect them at temp fixtures, so they
// must be serialized against each other.
tap_state_mutex: sync.Mutex

// ---------------------------------------------------------------------------
// derive_branch_from_url — branch derivation for non-GitHub URLs is pure
// (returns "main" without any network call)
// ---------------------------------------------------------------------------

@(test)
test_derive_branch_non_github_returns_main :: proc(t: ^testing.T) {
    // Non-GitHub URLs must return "main" immediately, no network needed.
    non_gh_cases := []string{
        "https://gitlab.com/some/repo",
        "https://bitbucket.org/some/repo",
        "ssh://git@myserver.com/repo.git",
        "https://example.com/my-tap",
    }
    for url in non_gh_cases {
        branch := derive_branch_from_url(url)
        defer delete(branch)
        if branch != "main" {
            testing.expectf(t, false, "derive_branch_from_url(%q): expected \"main\", got %q", url, branch)
        }
    }
}

// ---------------------------------------------------------------------------
// Tap struct construction — verify field assignment is consistent
// ---------------------------------------------------------------------------

@(test)
test_tap_struct_fields :: proc(t: ^testing.T) {
    t_val := Tap{
        name   = "ublue-os/tap",
        url    = "https://github.com/ublue-os/homebrew-tap",
        branch = "main",
    }
    testing.expect_value(t, t_val.name,   "ublue-os/tap")
    testing.expect_value(t, t_val.url,    "https://github.com/ublue-os/homebrew-tap")
    testing.expect_value(t, t_val.branch, "main")
}

// ---------------------------------------------------------------------------
// Read_Tap_Entry — simple struct smoke test
// ---------------------------------------------------------------------------

@(test)
test_read_tap_entry_struct :: proc(t: ^testing.T) {
    e := Read_Tap_Entry{
        name = "homebrew/core",
        url  = "https://github.com/Homebrew/homebrew-core",
    }
    testing.expect_value(t, e.name, "homebrew/core")
    testing.expect_value(t, e.url,  "https://github.com/Homebrew/homebrew-core")
}

// ---------------------------------------------------------------------------
// Shared-store path derivation (TAP-INTEROP-MIGRATION.md §2.2)
// ---------------------------------------------------------------------------

@(test)
test_shared_tap_dir_derivation :: proc(t: ^testing.T) {
    cases := []struct{ name, want: string }{
        { "gromgit/brewtils",            "/taps/gromgit/homebrew-brewtils" },
        { "ublue-os/experimental-tap",   "/taps/ublue-os/homebrew-experimental-tap" },
        // Explicit homebrew- prefixes pass through untouched.
        { "foo/homebrew-bar",            "/taps/foo/homebrew-bar" },
        // homebrew/core is API-based and never cloned, but path math still
        // follows the folder convention.
        { "homebrew/core",               "/taps/homebrew/homebrew-core" },
    }
    for c in cases {
        got := shared_tap_dir_in("/taps", c.name)
        testing.expectf(t, got == c.want, "shared_tap_dir_in(\"/taps\", %q): expected %q, got %q", c.name, c.want, got)
    }
}

@(test)
test_homebrew_repo_name :: proc(t: ^testing.T) {
    testing.expect_value(t, homebrew_repo_name("brewtils"), "homebrew-brewtils")
    testing.expect_value(t, homebrew_repo_name("homebrew-brewtils"), "homebrew-brewtils")
}

@(test)
test_tap_clone_url :: proc(t: ^testing.T) {
    // Default: Homebrew-convention URL with the homebrew- prefix.
    testing.expect_value(t, tap_clone_url("gromgit/brewtils", ""), "https://github.com/gromgit/homebrew-brewtils")
    // Explicit URL wins verbatim.
    testing.expect_value(t, tap_clone_url("rjallais/ubrew", "https://github.com/rjallais/ubrew"), "https://github.com/rjallais/ubrew")
}

// ---------------------------------------------------------------------------
// Mode detection — shared vs standalone (TAP-INTEROP-MIGRATION.md §2.1)
// ---------------------------------------------------------------------------

@(test)
test_mode_detection :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    old_override := taps_dir_override
    defer taps_dir_override = old_override

    // No Library/Taps dir → standalone.
    taps_dir_override = fmt.tprintf("%s/Homebrew/Library/Taps", temp_test_dir(t, "ubrew-mode-*"))
    defer os.remove_all(taps_dir_override)
    testing.expect_value(t, mode(), Tap_Mode.Standalone)

    // Create the brew-like Library/Taps dir → shared.
    os.make_directory_all(taps_dir_override, os.perm(0o755))
    testing.expect_value(t, mode(), Tap_Mode.Shared)
}

// ---------------------------------------------------------------------------
// Local clone reads — flat, letter-nested, root; HTML/empty rejected
// ---------------------------------------------------------------------------

@(test)
test_read_tap_ruby_from_clone_resolution :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    fixture := temp_test_dir(t, "ubrew-clone-*")
    defer os.remove_all(fixture)

    os.make_directory_all(fmt.tprintf("%s/Formula", fixture), os.perm(0o755))
    os.make_directory_all(fmt.tprintf("%s/Formula/f", fixture), os.perm(0o755))
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/foo.rb", fixture), "class Foo < Formula\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/f/foobar.rb", fixture), "class Foobar < Formula\nend\n")
    // Empty + HTML files must be rejected as non-formulae.
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/empty.rb", fixture), "   \n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/html.rb", fixture), "<html>404</html>")

    // Redirect the cache mirror target away from /opt/ubrew during the test.
    old_cache := TAPS_CACHE_DIR
    defer TAPS_CACHE_DIR = old_cache
    TAPS_CACHE_DIR = fmt.tprintf("%s/cache", fixture)

    t_obj := Tap{name = "testuser/tapfixture"}

    src, ok := read_tap_ruby_from_clone_in(fixture, t_obj, "Formula", "foo")
    testing.expectf(t, ok, "flat Formula/foo.rb should resolve")
    testing.expectf(t, strings.contains(src, "class Foo"), "flat read content mismatch: %q", src)
    delete(src)

    src, ok = read_tap_ruby_from_clone_in(fixture, t_obj, "Formula", "foobar")
    testing.expectf(t, ok, "letter-nested Formula/f/foobar.rb should resolve")
    testing.expectf(t, strings.contains(src, "class Foobar"), "nested read content mismatch: %q", src)
    delete(src)

    src, ok = read_tap_ruby_from_clone_in(fixture, t_obj, "Formula", "missing")
    testing.expectf(t, !ok, "missing formula must not resolve")
    testing.expectf(t, len(src) == 0, "missing formula must return empty content")

    src, ok = read_tap_ruby_from_clone_in(fixture, t_obj, "Formula", "empty")
    testing.expectf(t, !ok, "empty file must be rejected")

    src, ok = read_tap_ruby_from_clone_in(fixture, t_obj, "Formula", "html")
    testing.expectf(t, !ok, "HTML file must be rejected")

    // The mirror must land in the (redirected) cache dir.
    testing.expectf(t, os.is_file(fmt.tprintf("%s/testuser/tapfixture/Formula/foo.rb", TAPS_CACHE_DIR)),
        "clone read should mirror Formula/foo.rb into the cache dir")
}

@(test)
test_read_tap_ruby_from_clone_gated_by_mode :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    old_override := taps_dir_override
    defer taps_dir_override = old_override
    taps_dir_override = fmt.tprintf("%s/Homebrew/Library/Taps", temp_test_dir(t, "ubrew-mode-*"))
    defer os.remove_all(taps_dir_override)

    // Standalone mode: clone reads are inactive regardless of the path.
    src, ok := read_tap_ruby_from_clone(Tap{name = "a/b"}, "Formula", "x")
    testing.expectf(t, !ok && len(src) == 0, "clone read must be inactive in standalone mode")
}

// ---------------------------------------------------------------------------
// Shared-mode tap add/remove against a real file:// git origin
// ---------------------------------------------------------------------------

git_cmd :: proc(args: ..string) -> bool {
    full := make([dynamic]string, context.temp_allocator)
    defer delete(full)
    append(&full, "git")
    for a in args {
        append(&full, a)
    }
    return platform.exec_cmd("git", full[:])
}

@(test)
test_shared_tap_add_clone_and_remove :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    // --- origin repo with flat + letter-nested formulae ---
    origin := temp_test_dir(t, "ubrew-origin-*")
    defer os.remove_all(origin)
    os.make_directory_all(fmt.tprintf("%s/Formula", origin), os.perm(0o755))
    os.make_directory_all(fmt.tprintf("%s/Formula/w", origin), os.perm(0o755))
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/wget.rb", origin), "class Wget < Formula\n  url \"https://example.com/wget.tar.gz\"\nend\n")
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/Formula/w/wget2.rb", origin), "class Wget2 < Formula\nend\n")
    testing.expectf(t, git_cmd("-C", origin, "init", "-b", "main"), "git init failed")
    testing.expectf(t, git_cmd("-C", origin, "add", "-A"), "git add failed")
    testing.expectf(t, git_cmd("-C", origin, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"), "git commit failed")

    // --- brew-like Library/Taps fixture + isolated state paths ---
    fixture := temp_test_dir(t, "ubrew-taps-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))
    os.make_directory_all(fmt.tprintf("%s/db", fixture), os.perm(0o755))

    old_override := taps_dir_override
    old_db := TAPS_DB_PATH
    old_cache := TAPS_CACHE_DIR
    defer {
        taps_dir_override = old_override
        TAPS_DB_PATH = old_db
        TAPS_CACHE_DIR = old_cache
    }
    taps_dir_override = taps_dir
    TAPS_DB_PATH = fmt.tprintf("%s/db/taps.txt", fixture)
    TAPS_CACHE_DIR = fmt.tprintf("%s/cache/taps", fixture)

    testing.expect_value(t, mode(), Tap_Mode.Shared)

    // --- tap add: clones into <taps>/testuser/homebrew-tapfixture ---
    clone_url := fmt.tprintf("file://%s", origin)
    testing.expectf(t, tap_add("testuser/tapfixture", clone_url), "tap_add should succeed")
    clone_dir := fmt.tprintf("%s/testuser/homebrew-tapfixture", taps_dir)
    testing.expectf(t, os.is_dir(fmt.tprintf("%s/.git", clone_dir)), "clone dir with .git should exist after tap_add")
    testing.expectf(t, os.is_file(fmt.tprintf("%s/Formula/wget.rb", clone_dir)), "cloned tap should contain Formula/wget.rb")
    testing.expectf(t, tap_row_exists("testuser/tapfixture"), "taps.txt row should be recorded")

    // --- double add: no-op (already tapped) ---
    testing.expectf(t, tap_add("testuser/tapfixture", clone_url), "double tap_add should not fail")
    testing.expectf(t, os.is_dir(fmt.tprintf("%s/.git", clone_dir)), "clone must still exist after double add")

    // --- fetch from the clone: flat + letter-nested + cache mirror ---
    t_obj := Tap{name = "testuser/tapfixture"}
    src, ok := fetch_formula_ruby(t_obj, "wget")
    testing.expectf(t, ok, "fetch_formula_ruby(wget) from clone should succeed")
    testing.expectf(t, strings.contains(src, "class Wget"), "flat fetch content mismatch: %q", src)
    delete(src)

    src, ok = fetch_formula_ruby(t_obj, "wget2")
    testing.expectf(t, ok, "fetch_formula_ruby(wget2) letter-nested should succeed")
    testing.expectf(t, strings.contains(src, "class Wget2"), "nested fetch content mismatch: %q", src)
    delete(src)

    src, ok = fetch_formula_ruby(t_obj, "nonexistent")
    testing.expectf(t, !ok, "unknown formula should fail")
    testing.expectf(t, os.is_file(fmt.tprintf("%s/testuser/tapfixture/Formula/wget.rb", TAPS_CACHE_DIR)),
        "clone fetch should mirror Formula/wget.rb into the cache dir")

    // --- untap: removes the clone dir and the taps.txt row ---
    testing.expectf(t, tap_remove("testuser/tapfixture"), "tap_remove should succeed")
    testing.expectf(t, !os.is_dir(clone_dir), "clone dir should be removed after untap")
    testing.expectf(t, !tap_row_exists("testuser/tapfixture"), "taps.txt row should be removed after untap")

    // Untapping again must report "not tapped".
    testing.expectf(t, !tap_remove("testuser/tapfixture"), "second untap should fail with not tapped")
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
