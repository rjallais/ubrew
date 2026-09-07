package installer

// Unit tests for normalize_unpacked_keg_dir — the post-unpack rename logic
// for bottle tarballs whose top-level directory is not named exactly
// <version>. The Cellar is shared with Homebrew and holds multiple version
// kegs, so the rename must only ever touch the directory the current
// unpack created.
// Run with: odin test src/installer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "../cask"

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

@(test)
test_link_keg_files_replaces_old_directory_symlink :: proc(t: ^testing.T) {
	base := test_cellar(t, "link-dir-symlink")
	defer os.remove_all(base)

	prefix := fmt.tprintf("%s/prefix", base)
	cellar := fmt.tprintf("%s/Cellar", base)
	formula_dir := fmt.tprintf("%s/appstream/", cellar)

	// Create old version 1.1.6
	old_keg := fmt.tprintf("%s/appstream/1.1.6", cellar)
	mkdir_p(t, fmt.tprintf("%s/include/appstream", old_keg))
	write_test_file(t, fmt.tprintf("%s/include/appstream/appstream.h", old_keg), "/* 1.1.6 */")

	// Create new version 1.2.0
	new_keg := fmt.tprintf("%s/appstream/1.2.0", cellar)
	mkdir_p(t, fmt.tprintf("%s/include/appstream", new_keg))
	write_test_file(t, fmt.tprintf("%s/include/appstream/appstream.h", new_keg), "/* 1.2.0 */")
	write_test_file(t, fmt.tprintf("%s/include/appstream/as-version.h", new_keg), "/* version */")

	// Create prefix with old directory symlink: prefix/include/appstream -> old_keg/include/appstream
	mkdir_p(t, fmt.tprintf("%s/include", prefix))
	os.symlink(fmt.tprintf("%s/include/appstream", old_keg), fmt.tprintf("%s/include/appstream", prefix))

	linked, deleted, failed := 0, 0, 0
	link_keg_files(new_keg, prefix, formula_dir, false, false, &linked, &deleted, &failed)

	testing.expect_value(t, failed, 0)
	testing.expect_value(t, deleted, 1) // replaced directory symlink
	testing.expect_value(t, linked, 2)  // 2 header files linked

	// Verify prefix/include/appstream is now a real directory, not a symlink
	_, is_sym := os.read_link(fmt.tprintf("%s/include/appstream", prefix), context.temp_allocator)
	testing.expect(t, is_sym != nil, "prefix/include/appstream must now be a real directory")

	// Verify header files are symlinks to new_keg
	h_target, h_err := os.read_link(fmt.tprintf("%s/include/appstream/appstream.h", prefix), context.temp_allocator)
	testing.expect(t, h_err == nil, "appstream.h symlink must exist")
	testing.expect_value(t, h_target, fmt.tprintf("%s/include/appstream/appstream.h", new_keg))
}

@(test)
test_link_keg_files_handles_dangling_directory_symlink :: proc(t: ^testing.T) {
	base := test_cellar(t, "link-dangling-dir-symlink")
	defer os.remove_all(base)

	prefix := fmt.tprintf("%s/prefix", base)
	cellar := fmt.tprintf("%s/Cellar", base)
	formula_dir := fmt.tprintf("%s/orc/", cellar)

	// Create new version 0.4.43
	new_keg := fmt.tprintf("%s/orc/0.4.43", cellar)
	mkdir_p(t, fmt.tprintf("%s/include/orc-0.4/orc", new_keg))
	write_test_file(t, fmt.tprintf("%s/include/orc-0.4/orc/orc.h", new_keg), "/* orc.h */")

	// Create prefix with dangling directory symlink pointing to deleted 0.4.42
	mkdir_p(t, fmt.tprintf("%s/include", prefix))
	os.symlink(fmt.tprintf("%s/orc/0.4.42/include/orc-0.4", cellar), fmt.tprintf("%s/include/orc-0.4", prefix))

	linked, deleted, failed := 0, 0, 0
	link_keg_files(new_keg, prefix, formula_dir, false, false, &linked, &deleted, &failed)

	testing.expect_value(t, failed, 0)
	testing.expect_value(t, deleted, 1)
	testing.expect_value(t, linked, 1)

	// Verify header file exists and resolves
	h_target, h_err := os.read_link(fmt.tprintf("%s/include/orc-0.4/orc/orc.h", prefix), context.temp_allocator)
	testing.expect(t, h_err == nil, "orc.h symlink must exist")
	testing.expect_value(t, h_target, fmt.tprintf("%s/include/orc-0.4/orc/orc.h", new_keg))
}

@(test)
test_unlink_keg_files_removes_directory_symlink_and_cleans_empty_dir :: proc(t: ^testing.T) {
	base := test_cellar(t, "unlink-dir-symlink")
	defer os.remove_all(base)

	prefix := fmt.tprintf("%s/prefix", base)
	cellar := fmt.tprintf("%s/Cellar", base)
	formula_dir := fmt.tprintf("%s/appstream/", cellar)

	old_keg := fmt.tprintf("%s/appstream/1.1.6", cellar)
	mkdir_p(t, fmt.tprintf("%s/include/appstream", old_keg))
	write_test_file(t, fmt.tprintf("%s/include/appstream/appstream.h", old_keg), "/* 1.1.6 */")

	// 1. Directory symlink case
	mkdir_p(t, fmt.tprintf("%s/include", prefix))
	os.symlink(fmt.tprintf("%s/include/appstream", old_keg), fmt.tprintf("%s/include/appstream", prefix))

	unlinked, failed := 0, 0
	unlink_keg_files(old_keg, prefix, formula_dir, false, &unlinked, &failed)

	testing.expect_value(t, failed, 0)
	testing.expect_value(t, unlinked, 1)
	testing.expect(t, !os.exists(fmt.tprintf("%s/include/appstream", prefix)), "directory symlink should be unlinked")

	// 2. Individual file symlinks and empty directory pruning case
	mkdir_p(t, fmt.tprintf("%s/include/appstream", prefix))
	os.symlink(fmt.tprintf("%s/include/appstream/appstream.h", old_keg), fmt.tprintf("%s/include/appstream/appstream.h", prefix))

	unlinked, failed = 0, 0
	unlink_keg_files(old_keg, prefix, formula_dir, false, &unlinked, &failed)

	testing.expect_value(t, failed, 0)
	testing.expect_value(t, unlinked, 1)
	testing.expect(t, !os.exists(fmt.tprintf("%s/include/appstream", prefix)), "empty subdirectory should be pruned")
	testing.expect(t, os.is_dir(fmt.tprintf("%s/include", prefix)), "top-level include directory must be kept")

	// 3. Foreign directory symlink and non-directory file preservation case
	mkdir_p(t, fmt.tprintf("%s/other_keg/include/appstream", cellar))
	write_test_file(t, fmt.tprintf("%s/other_keg/include/appstream/foreign.h", cellar), "/* foreign */")
	os.symlink(fmt.tprintf("%s/other_keg/include/appstream", cellar), fmt.tprintf("%s/include/appstream", prefix))
	write_test_file(t, fmt.tprintf("%s/include/appstream_foreign_file", prefix), "foreign")

	unlinked, failed = 0, 0
	unlink_keg_files(old_keg, prefix, formula_dir, false, &unlinked, &failed)

	testing.expect_value(t, failed, 0)
	testing.expect_value(t, unlinked, 0)
	testing.expect(t, os.exists(fmt.tprintf("%s/include/appstream", prefix)), "foreign directory symlink must not be deleted")
	testing.expect(t, os.exists(fmt.tprintf("%s/other_keg/include/appstream/foreign.h", cellar)), "file in foreign directory must not be deleted")
	testing.expect(t, os.exists(fmt.tprintf("%s/include/appstream_foreign_file", prefix)), "foreign file must not be deleted")
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

write_test_file :: proc(t: ^testing.T, path, content: string) {
	if err := os.write_entire_file_from_string(path, content); err != nil {
		testing.fail_now(t, fmt.tprintf("could not write test file %q: %v", path, err))
	}
}

@(test)
test_preflight_materialize_and_neutralize_update :: proc(t: ^testing.T) {
	tmp_dir := os.get_env("TMPDIR", context.temp_allocator)
	if tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	test_dir := fmt.tprintf("%s/ubrew-cask-preflight-test", tmp_dir)
	_ = os.remove_all(test_dir)
	_ = os.make_directory_all(test_dir, os.perm(0o755))
	defer os.remove_all(test_dir)

	// 1. Test preflight file creation
	pf1 := cask.Preflight_File{
		path    = "subdir/app.desktop",
		content = "[Desktop Entry]\nName=TestApp\nMimeType=x-scheme-handler/test;\n",
	}
	target_file := fmt.tprintf("%s/%s", test_dir, pf1.path)
	parent := dir_name(target_file)
	_ = os.make_directory_all(parent, os.perm(0o755))
	write_err := os.write_entire_file_from_string(target_file, pf1.content)
	testing.expect(t, write_err == nil, "write preflight file")
	testing.expect(t, os.is_file(target_file), "preflight file must exist on disk")

	// 2. Test app-update.yml removal
	update_yml := fmt.tprintf("%s/app-update.yml", test_dir)
	_ = os.write_entire_file_from_string(update_yml, "owner: test\nrepo: app\n")
	testing.expect(t, os.is_file(update_yml), "app-update.yml created")

	found_update, ok := find_file_by_basename(test_dir, "app-update.yml")
	testing.expect(t, ok, "find_file_by_basename should find app-update.yml")
	if ok {
		_ = os.remove(found_update)
	}
	testing.expect(t, !os.is_file(update_yml), "app-update.yml neutralized")
}

@(test)
test_preflight_no_overwrite_preserves_existing_file :: proc(t: ^testing.T) {
	tmp_dir := os.get_env("TMPDIR", context.temp_allocator)
	if tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	test_dir := fmt.tprintf("%s/ubrew-cask-no-overwrite-test", tmp_dir)
	_ = os.remove_all(test_dir)
	_ = os.make_directory_all(test_dir, os.perm(0o755))
	defer os.remove_all(test_dir)

	target_file := fmt.tprintf("%s/config.txt", test_dir)
	_ = os.write_entire_file_from_string(target_file, "original content")

	// Preflight file with no_overwrite: true
	pf_skip := cask.Preflight_File{
		path         = "config.txt",
		content      = "new content",
		no_overwrite = true,
	}
	if !(pf_skip.no_overwrite && os.exists(target_file)) {
		_ = os.write_entire_file_from_string(target_file, pf_skip.content)
	}
	data1, err1 := os.read_entire_file(target_file, context.temp_allocator)
	testing.expect(t, err1 == nil, "read target file after skip")
	testing.expect_value(t, string(data1), "original content")

	// Preflight file with no_overwrite: false (overwrite default)
	pf_overwrite := cask.Preflight_File{
		path         = "config.txt",
		content      = "new content",
		no_overwrite = false,
	}
	if !(pf_overwrite.no_overwrite && os.exists(target_file)) {
		_ = os.write_entire_file_from_string(target_file, pf_overwrite.content)
	}
	data2, err2 := os.read_entire_file(target_file, context.temp_allocator)
	testing.expect(t, err2 == nil, "read target file after overwrite")
	testing.expect_value(t, string(data2), "new content")
}