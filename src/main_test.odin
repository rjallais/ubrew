package main

import "core:testing"
import "core:os"
import "core:fmt"
import "installer"

// test_cask_is_installed exercises the cask installation-state predicate
// against a temporary Caskroom: empty dirs, .metadata-only shells, valid
// metadata caskfiles, arbitrary stale child dirs, version dirs, and partial
// installs (version dir present but metadata write incomplete).
@(test)
test_cask_is_installed :: proc(t: ^testing.T) {
	tmp_dir := os.get_env("TMPDIR", context.temp_allocator)
	if tmp_dir == "" {
		tmp_dir = "/tmp"
	}
	root := fmt.tprintf("%s/ubrew-casktest-%d", tmp_dir, os.get_pid())
	_ = os.remove_all(root)
	defer os.remove_all(root)

	old := installer.CASKROOM_DIR
	defer {
		installer.CASKROOM_DIR = old
	}
	installer.CASKROOM_DIR = root

	mkdir :: proc(p: string) {
		_ = os.make_directory_all(p, os.perm(0o755))
	}
	write_file :: proc(p, s: string) {
		_ = os.write_entire_file_from_string(p, s)
	}

	// 1. empty dir -> not installed
	mkdir(fmt.tprintf("%s/empty", root))
	testing.expect(t, !cask_is_installed("empty"), "empty dir must not be installed")

	// 2. .metadata shell without a caskfile -> not installed
	mkdir(fmt.tprintf("%s/metaonly/.metadata", root))
	testing.expect(t, !cask_is_installed("metaonly"), ".metadata shell without caskfile must not be installed")

	// 3. .metadata with a caskfile -> installed
	mkdir(fmt.tprintf("%s/metaok/.metadata/1.0.0/20260101.000000/Casks", root))
	write_file(fmt.tprintf("%s/metaok/.metadata/1.0.0/20260101.000000/Casks/metaok.json", root), "{}\n")
	testing.expect(t, cask_is_installed("metaok"), "metadata caskfile must count as installed")

	// 4. arbitrary stale child dir -> not installed
	mkdir(fmt.tprintf("%s/stale/whatever", root))
	testing.expect(t, !cask_is_installed("stale"), "arbitrary child dir must not count as installed")

	// 5. version dir -> installed
	mkdir(fmt.tprintf("%s/ver/3.5.0", root))
	testing.expect(t, cask_is_installed("ver"), "version dir must count as installed")

	// 6. partial install: version dir plus .metadata without a caskfile -> not installed
	mkdir(fmt.tprintf("%s/partial/2.0.0", root))
	mkdir(fmt.tprintf("%s/partial/.metadata", root))
	testing.expect(t, !cask_is_installed("partial"), "partial install without caskfile must not count as installed")

	// 7. .metadata shell + spoofed staged-version Casks/<flat>.json -> not installed
	mkdir(fmt.tprintf("%s/spoof/.metadata", root))
	mkdir(fmt.tprintf("%s/spoof/3.5.0/Casks", root))
	write_file(fmt.tprintf("%s/spoof/3.5.0/Casks/spoof.json", root), "{}\n")
	testing.expect(t, !cask_is_installed("spoof"), "metadata-less cask with spoofed version-dir caskfile must not be installed")
}
