package tap

// Unit tests for the tap package.
// Run with: odin test src/tap
// or via:   mise run test-unit  (runs odin test src src/tap)

import "core:testing"
import "core:strings"

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
