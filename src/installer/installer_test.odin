package installer

// Unit tests for normalize_unpacked_keg_dir — the post-unpack rename logic
// for bottle tarballs whose top-level directory is not named exactly
// <version>. The Cellar is shared with Homebrew and holds multiple version
// kegs, so the rename must only ever touch the directory the current
// unpack created.
// Run with: odin test src/installer

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_normalize_keg_dir_keeps_correctly_named_unpack :: proc(t: ^testing.T) {
	base := test_cellar(t, "libffi-correct-layout")
	defer os.remove_all(base)

	formula := fmt.tprintf("%s/libffi", base)
	mkdir_p(t, fmt.tprintf("%s/3.7.1", formula)) // pre-existing keg (from Homebrew)
	mkdir_p(t, fmt.tprintf("%s/3.8.0", formula)) // freshly unpacked, correct layout

	existing := make(map[string]bool)
	existing["3.7.1"] = true
	defer delete(existing)

	normalize_unpacked_keg_dir(formula, "3.8.0", existing)

	testing.expect(t, os.is_dir(fmt.tprintf("%s/3.7.1", formula)), "pre-existing keg 3.7.1 was preserved")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/3.8.0", formula)), "3.8.0 keg untouched (layout already matched)")
}

@(test)
test_normalize_keg_dir_renames_only_the_unpacked_dir :: proc(t: ^testing.T) {
	base := test_cellar(t, "foo-rename-unpacked")
	defer os.remove_all(base)

	formula := fmt.tprintf("%s/foo", base)
	mkdir_p(t, fmt.tprintf("%s/1.2.3", formula))         // pre-existing keg
	mkdir_p(t, fmt.tprintf("%s/foo-1.2.4", formula))     // pathological bottle top-level dir

	existing := make(map[string]bool)
	existing["1.2.3"] = true
	defer delete(existing)

	normalize_unpacked_keg_dir(formula, "1.2.4", existing)

	testing.expect(t, os.is_dir(fmt.tprintf("%s/1.2.3", formula)), "pre-existing keg 1.2.3 was preserved")
	testing.expect(t, !os.is_dir(fmt.tprintf("%s/foo-1.2.4", formula)), "old unpack dir name was renamed away")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/1.2.4", formula)), "unpacked dir was renamed to the version")
}

@(test)
test_normalize_keg_dir_never_renames_the_preexisting_keg :: proc(t: ^testing.T) {
	base := test_cellar(t, "mesa-never-touch-old")
	defer os.remove_all(base)

	// Regression for the upgrade warning:
	//   Warning: Failed to rename unpacked directory from 3.7.1 to 3.8.0: ENOTEMPTY
	// When only a pre-existing keg is visible before the unpacked dir in
	// readdir order, the old code attempted to rename the OLD keg. With the
	// target dir absent that would have silently relabeled the wrong keg.
	formula := fmt.tprintf("%s/mesa", base)
	mkdir_p(t, fmt.tprintf("%s/26.1.4", formula)) // pre-existing keg
	mkdir_p(t, fmt.tprintf("%s/ubrew-bottle-dir", formula)) // unpacked, wrong name

	existing := make(map[string]bool)
	existing["26.1.4"] = true
	defer delete(existing)

	normalize_unpacked_keg_dir(formula, "26.2.0", existing)

	testing.expect(t, os.is_dir(fmt.tprintf("%s/26.1.4", formula)), "pre-existing keg 26.1.4 was preserved")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/26.2.0", formula)), "unpacked dir was renamed to 26.2.0")
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

test_cellar :: proc(t: ^testing.T, name: string) -> string {
	tmp_dir := os.get_env("TMPDIR", context.temp_allocator)
	if tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	base := fmt.tprintf("%s/ubrew-installer-test-%s", tmp_dir, name)
	os.remove_all(base)
	if err := os.make_directory_all(base); err != nil {
		testing.fail_now(t, "could not create test root")
	}
	return base
}

mkdir_p :: proc(t: ^testing.T, dir: string) {
	if err := os.make_directory_all(dir); err != nil {
		testing.fail_now(t, fmt.tprintf("could not create test dir %q: %v", dir, err))
	}
}