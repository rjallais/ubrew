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

    // Keep the base dir so the whole tree (base + Homebrew/Library/Taps)
    // is removed after the test — removing only the nested override path
    // would orphan the base temp directory.
    base_dir := temp_test_dir(t, "ubrew-mode-*")
    defer os.remove_all(base_dir)

    // No Library/Taps dir → standalone.
    taps_dir_override = fmt.tprintf("%s/Homebrew/Library/Taps", base_dir)
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
    base_dir := temp_test_dir(t, "ubrew-mode-*")
    defer os.remove_all(base_dir)
    taps_dir_override = fmt.tprintf("%s/Homebrew/Library/Taps", base_dir)

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
    // Shared mode: the clone itself is the record of the tap (Library/Taps
    // is the sole source of active taps) — no taps.txt row is written.
    // tap_row_exists would see the discovered clone, so probe the raw file.
    row_written := false
    if data, err := os.read_entire_file(TAPS_DB_PATH, context.temp_allocator); err == nil {
        row_written = strings.contains(string(data), "testuser/tapfixture")
    }
    testing.expectf(t, !row_written, "shared-mode tap_add must not write a taps.txt row")

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

@(test)
test_ensure_shared_clone_tolerates_existing_user_dir :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    // --- origin repo (single commit) ---
    origin := temp_test_dir(t, "ubrew-origin2-*")
    defer os.remove_all(origin)
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/README.md", origin), "tap fixture\n")
    testing.expectf(t, git_cmd("-C", origin, "init", "-b", "main"), "git init failed")
    testing.expectf(t, git_cmd("-C", origin, "add", "-A"), "git add failed")
    testing.expectf(t, git_cmd("-C", origin, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"), "git commit failed")

    // --- taps fixture with the user dir ALREADY present (failed-clone leftover) ---
    fixture := temp_test_dir(t, "ubrew-taps2-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))
    os.make_directory_all(fmt.tprintf("%s/testuser", taps_dir), os.perm(0o755))

    old_override := taps_dir_override
    defer {
        taps_dir_override = old_override
    }
    taps_dir_override = taps_dir

    clone_url := fmt.tprintf("file://%s", origin)
    testing.expectf(t, ensure_shared_clone_into(taps_dir, "testuser/tapfixture", clone_url),
        "clone must proceed even when the user dir already exists")
    clone_dir := fmt.tprintf("%s/testuser/homebrew-tapfixture", taps_dir)
    testing.expectf(t, os.is_dir(fmt.tprintf("%s/.git", clone_dir)), "clone dir with .git should exist")
    testing.expectf(t, os.is_file(fmt.tprintf("%s/README.md", clone_dir)), "cloned tap should contain README.md")
}

@(test)
test_tap_from_entry_shared_branch_is_owned :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    // Shared-mode fixture with a real clone: tap_from_entry skips the GitHub
    // branch probe and returns branch "main", which must be heap-owned so
    // destroy_tap can free it. Before the ownership fix this deleted the
    // "main" string literal and aborted the process (free(): invalid pointer).
    origin := temp_test_dir(t, "ubrew-origin3-*")
    defer os.remove_all(origin)
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/README.md", origin), "fixture\n")
    testing.expectf(t, git_cmd("-C", origin, "init", "-b", "main"), "git init failed")
    testing.expectf(t, git_cmd("-C", origin, "add", "-A"), "git add failed")
    testing.expectf(t, git_cmd("-C", origin, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "init"), "git commit failed")

    fixture := temp_test_dir(t, "ubrew-taps3-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))

    old_override := taps_dir_override
    defer {
        taps_dir_override = old_override
    }
    taps_dir_override = taps_dir

    clone_url := fmt.tprintf("file://%s", origin)
    testing.expectf(t, ensure_shared_clone_into(taps_dir, "testuser/tapfixture", clone_url), "clone should succeed")

    entry := Read_Tap_Entry{name = "testuser/tapfixture", url = clone_url}
    tap_val := tap_from_entry(entry)
    testing.expect_value(t, tap_val.branch, "main")
    // Must not abort: this frees the branch (and name/url) strings.
    destroy_tap(tap_val)
}

// ---------------------------------------------------------------------------
// CodeRabbit fixes — name validation, discovered-row separation, traversal
// ---------------------------------------------------------------------------

@(test)
test_is_valid_tap_name_rejects_dotdot :: proc(t: ^testing.T) {
    // Path-traversal components and malformed names must be rejected; they
    // would otherwise reach shared_tap_dir / os.remove_all via tap_remove.
    bad_names := []string{"a/..", "../a", "a/.", "./a", "a//b", "a", "a/b/c", "a:b", "https://github.com/a/b", ""}
    for bad in bad_names {
        testing.expectf(t, !is_valid_tap_name(bad), "is_valid_tap_name(%q) must be false", bad)
    }
    good_names := []string{"user/repo", "homebrew/core", "ublue-os/tap"}
    for good in good_names {
        testing.expectf(t, is_valid_tap_name(good), "is_valid_tap_name(%q) must be true", good)
    }
}

@(test)
test_write_taps_excludes_discovered :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    fixture := temp_test_dir(t, "ubrew-wtaps-*")
    defer os.remove_all(fixture)
    os.make_directory_all(fmt.tprintf("%s/db", fixture), os.perm(0o755))

    old_db := TAPS_DB_PATH
    defer TAPS_DB_PATH = old_db
    TAPS_DB_PATH = fmt.tprintf("%s/db/taps.txt", fixture)

    taps := make([dynamic]Read_Tap_Entry, context.temp_allocator)
    append(&taps, Read_Tap_Entry{name = "row/tap", url = "https://example.com/row"})
    append(&taps, Read_Tap_Entry{name = "discovered/tap", url = "", discovered = true})
    testing.expectf(t, write_taps(taps), "write_taps should succeed")

    data, _ := os.read_entire_file(TAPS_DB_PATH, context.temp_allocator)
    text := string(data)
    testing.expectf(t, strings.contains(text, "row/tap"), "row entry must be persisted")
    testing.expectf(t, !strings.contains(text, "discovered/tap"), "discovered entry must not be persisted to taps.txt")
}

@(test)
test_read_taps_shared_filters_row_without_clone :: proc(t: ^testing.T) {
    // Integration behavior for external `brew untap`: in shared mode a
    // taps.txt row whose clone is gone (brew removed it) must not be
    // reported as an active tap — Library/Taps is the sole source. The
    // homebrew/* pseudo-taps are API-based and legitimately never cloned.
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    fixture := temp_test_dir(t, "ubrew-phantom-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))
    os.make_directory_all(fmt.tprintf("%s/db", fixture), os.perm(0o755))

    old_override := taps_dir_override
    old_db := TAPS_DB_PATH
    defer {
        taps_dir_override = old_override
        TAPS_DB_PATH = old_db
    }
    taps_dir_override = taps_dir
    TAPS_DB_PATH = fmt.tprintf("%s/db/taps.txt", fixture)
    _ = os.write_entire_file_from_string(TAPS_DB_PATH, "phantom/tap\nhomebrew/core\n")

    taps := read_taps()
    defer {
        for t in taps {
            destroy_read_tap_entry(t)
        }
        delete(taps)
    }
    has_phantom := false
    has_core := false
    for t in taps {
        if t.name == "phantom/tap" do has_phantom = true
        if t.name == "homebrew/core" do has_core = true
    }
    testing.expectf(t, !has_phantom, "row without a backing clone must be filtered out in shared mode")
    testing.expectf(t, has_core, "homebrew/* pseudo-tap row must remain visible")
}

@(test)
test_tap_remove_rejects_traversal :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    fixture := temp_test_dir(t, "ubrew-trav-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))

    old_override := taps_dir_override
    defer taps_dir_override = old_override
    taps_dir_override = taps_dir

    // A traversal-style name must be refused before any path math: it would
    // otherwise resolve to a directory outside Library/Taps.
    testing.expectf(t, !tap_remove("a/../../tmp/x"), "tap_remove must reject traversal-style names")
    testing.expectf(t, !tap_remove("a/.."), "tap_remove must reject dotdot names")
}

@(test)
test_tap_remove_rejects_symlink :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    fixture := temp_test_dir(t, "ubrew-symlink-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))
    os.make_directory_all(fmt.tprintf("%s/testuser", taps_dir), os.perm(0o755))
    target := temp_test_dir(t, "ubrew-symlink-target-*")
    defer os.remove_all(target)

    old_override := taps_dir_override
    defer taps_dir_override = old_override
    taps_dir_override = taps_dir

    clone_dir := fmt.tprintf("%s/testuser/homebrew-tapfixture", taps_dir)
    testing.expectf(t, os.symlink(target, clone_dir) == nil, "creating the symlink fixture should succeed")
    testing.expectf(t, !tap_remove("testuser/tapfixture"), "tap_remove must refuse a symlinked clone dir")
    testing.expectf(t, os.is_dir(target), "the symlink target must be left untouched")
}

@(test)
test_ensure_shared_clone_reclones_on_remote_mismatch :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    origin_a := temp_test_dir(t, "ubrew-origin-a-*")
    defer os.remove_all(origin_a)
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/marker.txt", origin_a), "AAA")
    testing.expectf(t, git_cmd("-C", origin_a, "init", "-b", "main"), "git init A failed")
    testing.expectf(t, git_cmd("-C", origin_a, "add", "-A"), "git add A failed")
    testing.expectf(t, git_cmd("-C", origin_a, "-c", "user.name=Test", "-c", "user.email=t@e.c", "commit", "-m", "init"), "git commit A failed")

    origin_b := temp_test_dir(t, "ubrew-origin-b-*")
    defer os.remove_all(origin_b)
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/marker.txt", origin_b), "BBB")
    testing.expectf(t, git_cmd("-C", origin_b, "init", "-b", "main"), "git init B failed")
    testing.expectf(t, git_cmd("-C", origin_b, "add", "-A"), "git add B failed")
    testing.expectf(t, git_cmd("-C", origin_b, "-c", "user.name=Test", "-c", "user.email=t@e.c", "commit", "-m", "init"), "git commit B failed")

    fixture := temp_test_dir(t, "ubrew-reclone-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))

    url_a := fmt.tprintf("file://%s", origin_a)
    url_b := fmt.tprintf("file://%s", origin_b)
    clone_dir := fmt.tprintf("%s/testuser/homebrew-tapfixture", taps_dir)

    testing.expectf(t, ensure_shared_clone_into(taps_dir, "testuser/tapfixture", url_a), "initial clone A failed")
    testing.expectf(t, os.is_file(fmt.tprintf("%s/marker.txt", clone_dir)), "clone A marker present")

    // Same URL: accepted as-is, no re-clone.
    testing.expectf(t, ensure_shared_clone_into(taps_dir, "testuser/tapfixture", url_a), "same-URL ensure must succeed")
    testing.expectf(t, os.is_file(fmt.tprintf("%s/marker.txt", clone_dir)), "clone unchanged after same-URL ensure")

    // Different URL: the existing clone's remote does not match → re-clone.
    testing.expectf(t, ensure_shared_clone_into(taps_dir, "testuser/tapfixture", url_b), "re-clone from B must succeed")
    marker, _ := os.read_entire_file(fmt.tprintf("%s/marker.txt", clone_dir), context.temp_allocator)
    testing.expectf(t, strings.trim_space(string(marker)) == "BBB", "clone must now point at origin B")
}

@(test)
test_ensure_shared_clone_cleans_failed_temp :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    fixture := temp_test_dir(t, "ubrew-tmpclean-*")
    defer os.remove_all(fixture)
    taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", fixture)
    os.make_directory_all(taps_dir, os.perm(0o755))

    testing.expectf(t, !ensure_shared_clone_into(taps_dir, "testuser/tapfixture", "file:///nonexistent/origin"),
        "clone from a bogus origin must fail")
    clone_dir := fmt.tprintf("%s/testuser/homebrew-tapfixture", taps_dir)
    testing.expectf(t, !os.is_dir(fmt.tprintf("%s.tmp", clone_dir)), "failed clone must leave no temp dir behind")
    testing.expectf(t, !os.is_dir(clone_dir), "failed clone must leave no destination dir behind")
}

@(test)
test_homebrew_trusted_taps_at_prefix :: proc(t: ^testing.T) {
    fixture := temp_test_dir(t, "ubrew-hbtrust-*")
    defer os.remove_all(fixture)
    os.make_directory_all(fmt.tprintf("%s/etc/homebrew", fixture), os.perm(0o755))
    _ = os.write_entire_file_from_string(fmt.tprintf("%s/etc/homebrew/trusted_taps", fixture), "# comment\nublue-os/tap\njustrach/nanobrew\n")

    names := homebrew_trusted_taps_at(fixture)
    defer {
        for n in names {
            delete(n)
        }
        delete(names)
    }
    has_ublue := false
    has_justrach := false
    for n in names {
        if n == "ublue-os/tap" do has_ublue = true
        if n == "justrach/nanobrew" do has_justrach = true
    }
    testing.expectf(t, has_ublue && has_justrach, "fixture trusted_taps must load (ublue=%v justrach=%v)", has_ublue, has_justrach)

    // A prefix without the file yields an empty set.
    empty_prefix := temp_test_dir(t, "ubrew-hbtrust-empty-*")
    defer os.remove_all(empty_prefix)
    empty := homebrew_trusted_taps_at(empty_prefix)
    defer {
        for n in empty {
            delete(n)
        }
        delete(empty)
    }
    testing.expectf(t, len(empty) == 0, "prefix without trusted_taps must yield no entries")
}

@(test)
test_trusted_taps_load_own_roundtrip :: proc(t: ^testing.T) {
    sync.mutex_lock(&tap_state_mutex)
    defer sync.mutex_unlock(&tap_state_mutex)

    fixture := temp_test_dir(t, "ubrew-owntrust-*")
    defer os.remove_all(fixture)
    os.make_directory_all(fmt.tprintf("%s/db", fixture), os.perm(0o755))

    old_file := TRUSTED_TAPS_FILE
    defer TRUSTED_TAPS_FILE = old_file
    TRUSTED_TAPS_FILE = fmt.tprintf("%s/db/trusted_taps.txt", fixture)

    names := trusted_taps_load_own()
    defer {
        for n in names {
            delete(n)
        }
        delete(names)
    }
    append(&names, strings.clone("ubrewtest/roundtrip-fixture", context.allocator))
    trusted_taps_save(names)

    reloaded := trusted_taps_load_own()
    defer {
        for n in reloaded {
            delete(n)
        }
        delete(reloaded)
    }
    found := false
    for n in reloaded {
        if n == "ubrewtest/roundtrip-fixture" do found = true
    }
    testing.expectf(t, found, "trusted_taps_load_own must round-trip entries through trusted_taps_save")
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
