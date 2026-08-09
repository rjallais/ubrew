package store

// Unit tests for the store relocation helpers.
// Run with: odin test src/store

import "core:fmt"
import "core:os"
import "core:testing"

// Save-side relocation must create the full <STORE_RELOCATED_DIR><prefix>
// chain before the COW copy: cow_copy (clonefile / FICLONE ioctl / cp -R)
// requires the destination's parent directory to already exist, and only
// creating STORE_RELOCATED_DIR left the prefix subdirectories missing, so
// the save silently failed and the relocation cache never populated.
//
// The test is hermetic: it repoints the package vars at a scratch layout
// and does not depend on platform.init_paths having run in this binary.
@(test)
test_save_relocated_entry_creates_destination_parents :: proc(t: ^testing.T) {
    saved_relocated := STORE_RELOCATED_DIR
    saved_cellar := CELLAR_DIR
    defer {
        STORE_RELOCATED_DIR = saved_relocated
        CELLAR_DIR = saved_cellar
    }

    tmp := os.get_env("TMPDIR", context.temp_allocator)
    if len(tmp) == 0 {
        tmp = "/tmp"
    }
    base := fmt.tprintf("%s/ubrew-store-reloc-test", tmp)
    _ = os.remove_all(base)
    defer os.remove_all(base)

    STORE_RELOCATED_DIR = fmt.tprintf("%s/store-relocated", base)
    CELLAR_DIR = fmt.tprintf("%s/cellar", base)

    // Fake installed keg: Cellar/<name>/<version> is a regular file so the
    // FICLONE ioctl path can succeed when the filesystem supports reflinks.
    keg := fmt.tprintf("%s/hello/1.0", CELLAR_DIR)
    testing.expect(t, os.make_directory_all(os.dir(keg), os.perm(0o755)) == nil,
        "create fake keg directory")
    testing.expect(t, os.write_entire_file_from_string(keg, "fake keg") == nil,
        "write fake keg file")

    sha := "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    prefix := "/home/linuxbrew/.linuxbrew"

    testing.expect(t, store_save_relocated_entry(sha, "hello", "1.0", prefix),
        "store_save_relocated_entry must create the prefix chain and copy the keg")

    want := fmt.tprintf("%s%s/%s", STORE_RELOCATED_DIR, prefix, sha)
    testing.expectf(t, os.is_file(want),
        "expected relocated entry at %q, got none", want)
}