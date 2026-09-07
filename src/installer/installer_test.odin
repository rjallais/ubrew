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
	ok1 := materialize_preflight_file(test_dir, pf1)
	testing.expect(t, ok1, "materialize preflight file")
	target_file := fmt.tprintf("%s/%s", test_dir, pf1.path)
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

	// Preflight file with no_overwrite: true through production helper
	pf_skip := cask.Preflight_File{
		path         = "config.txt",
		content      = "new content",
		no_overwrite = true,
	}
	ok_skip := materialize_preflight_file(test_dir, pf_skip)
	testing.expect(t, ok_skip, "materialize_preflight_file with no_overwrite should succeed (skip)")

	data1, err1 := os.read_entire_file(target_file, context.temp_allocator)
	testing.expect(t, err1 == nil, "read target file after skip")
	testing.expect_value(t, string(data1), "original content")

	// Preflight file with no_overwrite: false (overwrite default) through production helper
	pf_overwrite := cask.Preflight_File{
		path         = "config.txt",
		content      = "new content",
		no_overwrite = false,
	}
	ok_overwrite := materialize_preflight_file(test_dir, pf_overwrite)
	testing.expect(t, ok_overwrite, "materialize_preflight_file with default overwrite should succeed")

	data2, err2 := os.read_entire_file(target_file, context.temp_allocator)
	testing.expect(t, err2 == nil, "read target file after overwrite")
	testing.expect_value(t, string(data2), "new content")
}

@(test)
test_clear_desktop_mime_defaults_custom_xdg :: proc(t: ^testing.T) {
	tmp_dir := os.get_env("TMPDIR", context.temp_allocator)
	if tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	test_dir := fmt.tprintf("%s/ubrew-custom-xdg-test", tmp_dir)
	_ = os.remove_all(test_dir)
	_ = os.make_directory_all(test_dir, os.perm(0o755))
	defer os.remove_all(test_dir)

	custom_config := fmt.tprintf("%s/config", test_dir)
	custom_data := fmt.tprintf("%s/share", test_dir)
	custom_apps := fmt.tprintf("%s/applications", custom_data)
	_ = os.make_directory_all(custom_config, os.perm(0o755))
	_ = os.make_directory_all(custom_apps, os.perm(0o755))

	old_config := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	old_data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	defer {
		_ = os.set_env("XDG_CONFIG_HOME", old_config)
		_ = os.set_env("XDG_DATA_HOME", old_data)
	}

	_ = os.set_env("XDG_CONFIG_HOME", custom_config)
	_ = os.set_env("XDG_DATA_HOME", custom_data)

	// 1. $XDG_CONFIG_HOME/mimeapps.list
	cfg_mime := fmt.tprintf("%s/mimeapps.list", custom_config)
	_ = os.write_entire_file_from_string(
		cfg_mime,
		"[Default Applications]\nx-scheme-handler/app=app-handler.desktop\ntext/plain=app.desktop;other.desktop;\nimage/png=other.desktop;\n",
	)

	// 2. Desktop-specific $XDG_CONFIG_HOME/gnome-mimeapps.list
	cfg_gnome := fmt.tprintf("%s/gnome-mimeapps.list", custom_config)
	_ = os.write_entire_file_from_string(
		cfg_gnome,
		"[Default Applications]\nx-scheme-handler/app=app-handler.desktop;\n[Added Associations]\nx-scheme-handler/app=app-handler.desktop;other-app.desktop;\n",
	)

	// 3. $XDG_DATA_HOME/applications/mimeapps.list
	data_mime := fmt.tprintf("%s/applications/mimeapps.list", custom_data)
	_ = os.write_entire_file_from_string(
		data_mime,
		"[Default Applications]\nx-scheme-handler/app=app-handler.desktop\n",
	)

	// 4. Desktop-specific $XDG_DATA_HOME/applications/kde-mimeapps.list
	data_kde := fmt.tprintf("%s/applications/kde-mimeapps.list", custom_data)
	_ = os.write_entire_file_from_string(
		data_kde,
		"[Added Associations]\ntext/markdown=app.desktop;\n",
	)

	// Remove app-handler.desktop
	clear_desktop_mime_defaults("app-handler.desktop")

	d1, err1 := os.read_entire_file(cfg_mime, context.temp_allocator)
	testing.expect(t, err1 == nil, "read cfg_mime")
	s1 := string(d1)
	testing.expect(t, !strings.contains(s1, "app-handler.desktop"), "app-handler removed from cfg_mime")
	testing.expect(t, strings.contains(s1, "text/plain=app.desktop;other.desktop;"), "text/plain preserved in cfg_mime")
	testing.expect(t, strings.contains(s1, "image/png=other.desktop;"), "image/png preserved in cfg_mime")

	d2, err2 := os.read_entire_file(cfg_gnome, context.temp_allocator)
	testing.expect(t, err2 == nil, "read cfg_gnome")
	s2 := string(d2)
	testing.expect(t, !strings.contains(s2, "app-handler.desktop"), "app-handler removed from cfg_gnome")
	testing.expect(t, strings.contains(s2, "x-scheme-handler/app=other-app.desktop;"), "other-app preserved in cfg_gnome")

	d3, err3 := os.read_entire_file(data_mime, context.temp_allocator)
	testing.expect(t, err3 == nil, "read data_mime")
	s3 := string(d3)
	testing.expect(t, !strings.contains(s3, "app-handler.desktop"), "app-handler removed from data_mime")

	// Remove app.desktop and ensure other-app.desktop substring is NOT removed
	clear_desktop_mime_defaults("app.desktop")

	d1b, err1b := os.read_entire_file(cfg_mime, context.temp_allocator)
	testing.expect(t, err1b == nil, "read cfg_mime after second clear")
	s1b := string(d1b)
	testing.expect(t, strings.contains(s1b, "text/plain=other.desktop;"), "app.desktop removed from text/plain list")

	d2b, err2b := os.read_entire_file(cfg_gnome, context.temp_allocator)
	testing.expect(t, err2b == nil, "read cfg_gnome after second clear")
	s2b := string(d2b)
	testing.expect(t, strings.contains(s2b, "other-app.desktop;"), "other-app.desktop not stripped by app.desktop removal")

	d4, err4 := os.read_entire_file(data_kde, context.temp_allocator)
	testing.expect(t, err4 == nil, "read data_kde")
	s4 := string(d4)
	testing.expect(t, !strings.contains(s4, "app.desktop"), "app.desktop removed from data_kde")
}