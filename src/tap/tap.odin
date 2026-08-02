package tap

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "../platform"

// Runtime tap paths. Re-bound by init_paths() after platform.init_paths().
TAPS_DB_PATH:       string = "/opt/ubrew/db/taps.txt"
TAPS_CACHE_DIR:     string = "/opt/ubrew/cache/taps"
TRUSTED_TAPS_FILE:  string = "/opt/ubrew/db/trusted_taps.txt"

init_paths :: proc() {
	root := platform.get_ubrew_root()
	TAPS_DB_PATH       = fmt.aprintf("%s/db/taps.txt", root)
	TAPS_CACHE_DIR     = fmt.aprintf("%s/cache/taps", root)
	TRUSTED_TAPS_FILE  = fmt.aprintf("%s/db/trusted_taps.txt", root)
}

// Tap_Mode selects the tap storage strategy.
//
//	Shared     — a real Homebrew install is present ($HOMEBREW_PREFIX has a
//	             Homebrew/Library/Taps dir): taps are git clones managed in
//	             the same store Homebrew uses, and taps.txt is kept as a
//	             compatibility view (TAP-INTEROP-MIGRATION.md §2.2).
//	Standalone — no brew install: taps stay in ubrew's fetch-based
//	             $UBREW_ROOT/cache/taps registry (today's behavior).
Tap_Mode :: enum {
	Shared,
	Standalone,
}

// mode returns the active tap storage mode. Detection is a pure existence
// check on brew's Library/Taps directory; write-permission problems surface
// naturally when a clone is attempted (git fails, we print a `brew tap` hint).
mode :: proc() -> Tap_Mode {
	if os.is_dir(shared_taps_dir()) {
		return .Shared
	}
	return .Standalone
}

// taps_dir_override lets unit tests redirect shared_taps_dir at a fixture.
// Never set in production code; only *_test.odin files assign it (and always
// restore the previous value afterwards).
taps_dir_override: string

// shared_taps_dir returns the Library/Taps directory of the detected
// Homebrew install. Temp-allocated; do not free.
shared_taps_dir :: proc() -> string {
	if len(taps_dir_override) > 0 {
		return taps_dir_override
	}
	return fmt.tprintf("%s/Homebrew/Library/Taps", platform.get_homebrew_prefix())
}

// homebrew_repo_name maps a repo name to Homebrew's folder convention:
// "brewtils" -> "homebrew-brewtils", "homebrew-brewtils" -> unchanged.
// Temp-allocated; do not free.
homebrew_repo_name :: proc(repo: string) -> string {
	if strings.has_prefix(repo, "homebrew-") {
		return strings.clone(repo, context.temp_allocator)
	}
	return fmt.tprintf("homebrew-%s", repo)
}

// shared_tap_dir_in is the pure derivation behind shared_tap_dir, factored
// out so unit tests can exercise the folder-name math with an arbitrary
// taps dir (no real brew prefix needed). Temp-allocated; do not free.
shared_tap_dir_in :: proc(taps_dir, name: string) -> string {
	parts := strings.split(name, "/", context.temp_allocator)
	if len(parts) != 2 || len(parts[0]) == 0 || len(parts[1]) == 0 {
		return fmt.tprintf("%s/%s", taps_dir, name)
	}
	return fmt.tprintf("%s/%s/%s", taps_dir, parts[0], homebrew_repo_name(parts[1]))
}

// shared_tap_dir returns the clone directory for a tap in shared mode, e.g.
// "gromgit/brewtils" -> <taps>/gromgit/homebrew-brewtils. Temp-allocated.
shared_tap_dir :: proc(name: string) -> string {
	return shared_tap_dir_in(shared_taps_dir(), name)
}

// tap_clone_url derives the git URL to clone for a tap: the explicit URL
// when given, else the Homebrew-convention
// https://github.com/<user>/homebrew-<repo>. Temp-allocated; do not free.
tap_clone_url :: proc(name, url: string) -> string {
	if len(url) > 0 {
		return strings.clone(url, context.temp_allocator)
	}
	parts := strings.split(name, "/", context.temp_allocator)
	if len(parts) != 2 {
		return strings.clone(fmt.tprintf("https://github.com/%s", name), context.temp_allocator)
	}
	return fmt.tprintf("https://github.com/%s/%s", parts[0], homebrew_repo_name(parts[1]))
}

// tap_shallow_enabled reports whether UBREW_TAP_SHALLOW=1/true/yes is set,
// which makes new clones shallow (--depth=1).
tap_shallow_enabled :: proc() -> bool {
	v := os.get_env("UBREW_TAP_SHALLOW", context.temp_allocator)
	if v == "1" {
		return true
	}
	lower := strings.to_lower(v, context.temp_allocator)
	return lower == "true" || lower == "yes"
}

// ensure_shared_clone materializes a shared-mode tap as a git clone in brew's
// Library/Taps. Idempotent: a clone that already exists is a no-op (true).
// homebrew/core and homebrew/cask are never cloned (API-based) and return
// true. On clone failure prints a warning with a `brew tap` hint and returns
// false so callers can surface the failure (the tap is not added).
ensure_shared_clone :: proc(name, url: string) -> bool {
	if strings.has_prefix(name, "homebrew/") {
		return true
	}
	return ensure_shared_clone_into(shared_taps_dir(), name, url)
}

// clone_origin_remote returns the origin remote URL of a git clone, or
// ("", false) when the clone has no origin remote (or git is unavailable).
clone_origin_remote :: proc(repo_dir: string) -> (string, bool) {
	buf := make([]u8, 4096, context.temp_allocator)
	out, _ := platform.exec_cmd_capture(
		"git",
		[]string{"git", "-C", repo_dir, "remote", "get-url", "origin"},
		buf,
	)
	trimmed := strings.trim_space(out)
	if len(trimmed) == 0 do return "", false
	return trimmed, true
}

// ensure_shared_clone_into is the testable core of ensure_shared_clone: it
// clones <name> from <url> (or the Homebrew-convention URL when empty) into
// <taps_dir>/<user>/homebrew-<repo>. Returns false when the clone fails.
ensure_shared_clone_into :: proc(taps_dir, name, url: string) -> bool {
	if !is_valid_tap_name(name) {
		return false
	}
	dest := shared_tap_dir_in(taps_dir, name)
	if is_symlink(dest) {
		fmt.printf("Error: Refusing to use '%s' for tap '%s' (symlink).\n", dest, name)
		return false
	}
	clone_url := tap_clone_url(name, url)
	if os.is_dir(fmt.tprintf("%s/.git", dest)) {
		// The clone already exists: verify its origin remote before treating
		// it as the requested tap, so a stale, partial, or unrelated
		// repository is never used for formula/cask reads. An explicitly
		// given URL must match; otherwise any working origin is accepted.
		if remote, ok := clone_origin_remote(dest); !ok {
			fmt.printf("Warning: Tap '%s' clone at %s has no origin remote; re-cloning.\n", name, dest)
			_ = os.remove_all(dest)
		} else if len(url) > 0 && remote != clone_url {
			fmt.printf("Warning: Tap '%s' clone at %s points at %s, not %s; re-cloning.\n", name, dest, remote, clone_url)
			_ = os.remove_all(dest)
		} else {
			return true
		}
	}
	user_part := name[:strings.index(name, "/")]
	user_dir := fmt.tprintf("%s/%s", taps_dir, user_part)
	if mk_err := os.make_directory_all(user_dir, os.perm(0o755)); mk_err != nil {
		// POSIX make_directory_all returns .Exist when the dir already
		// exists (e.g. a leftover from an earlier failed clone); that is
		// fine, git clone populates the repo dir below.
		if !os.is_dir(user_dir) {
			fmt.printf("Warning: Cannot create %s: %v\n", user_dir, mk_err)
			return false
		}
	}

	fmt.printf("==> Tapping '%s'\n", name)
	// Clone into a temporary sibling and rename it into place only after
	// success, so a concurrent reader never observes a partial clone.
	tmp := fmt.tprintf("%s.tmp", dest)
	_ = os.remove_all(tmp)
	args := make([dynamic]string, context.temp_allocator)
	defer delete(args)
	append(&args, "git")
	append(&args, "clone")
	if tap_shallow_enabled() {
		append(&args, "--depth=1")
	}
	append(&args, clone_url)
	append(&args, tmp)
	if !platform.exec_cmd("git", args[:]) {
		fmt.printf("Warning: Failed to clone tap '%s' from %s.\n", name, clone_url)
		fmt.printf("  If the repo does not follow the homebrew-<repo> convention, pass its URL explicitly:\n")
		fmt.printf("    brew tap %s <url>\n", name)
		_ = os.remove_all(tmp)
		return false
	}
	if os.is_dir(dest) {
		_ = os.remove_all(dest)
	}
	if err := os.rename(tmp, dest); err != os.ERROR_NONE {
		fmt.printf("Warning: Failed to move cloned tap into place at %s: %v\n", dest, err)
		_ = os.remove_all(tmp)
		return false
	}
	return true
}

// Tap represents a tapped 3rd-party Homebrew tap repository.
Tap :: struct {
	name:   string, // "user/repo" e.g. "justrach/nanobrew"
	url:    string, // e.g. "https://github.com/justrach/nanobrew"
	branch: string, // e.g. "main" or "master"
}

destroy_tap :: proc(t: Tap) {
	delete(t.name)
	delete(t.url)
	delete(t.branch)
}

// Read_Tap_Entry represents a single line in taps.txt.
// Format: "user/repo" or "user/repo<TAB>https://github.com/user/repo".
// discovered marks entries synthesized from a shared Library/Taps clone
// (not a taps.txt row); write_taps skips them so the database only ever
// holds rows the user (or standalone mode) actually recorded.
Read_Tap_Entry :: struct {
	name:       string,
	url:        string,
	discovered: bool,
}

// ── cross-process lock for shared tap mutations ──
//
// Concurrent ubrew processes can race on the same Library/Taps store
// (tap add cloning while another untaps, `ubrew update` pulling while a
// clone is being removed). An advisory fcntl record lock on a lock file
// inside the taps dir serializes ubrew's own tap add/remove/update.
// NOTE: this coordinates ubrew processes only — `brew` itself does not
// honor the lock, so keep mutating operations short.

// shared_tap_lock acquires an exclusive lock for shared tap mutations.
// The returned fd must be closed (defer posix.close) to release the lock.
// Returns (-1, false) when the lock cannot be taken.
shared_tap_lock :: proc() -> (posix.FD, bool) {
	lock_path := strings.clone_to_cstring(fmt.tprintf("%s/.ubrew.lock", shared_taps_dir()), context.temp_allocator)
	fd := posix.open(lock_path, {.RDWR, .CREAT}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd == -1 {
		return -1, false
	}
	fl := posix.flock {
		l_start  = 0,
		l_len    = 0,
		l_pid    = 0,
		l_type   = posix.Lock_Type.WRLCK,
		l_whence = c.short(0), // SEEK_SET
	}
	if posix.fcntl(fd, posix.FCNTL_Cmd.SETLKW, &fl) != 0 {
		posix.close(fd)
		return -1, false
	}
	return fd, true
}

destroy_read_tap_entry :: proc(e: Read_Tap_Entry) {
	delete(e.name)
	delete(e.url)
}

// read_taps returns the list of tapped repositories from the taps database.
// Each entry is a struct with name and url fields (url may be empty for
// taps added without a URL).
read_taps :: proc() -> (taps: [dynamic]Read_Tap_Entry) {
	taps = make([dynamic]Read_Tap_Entry, context.allocator)
	if os.is_file(TAPS_DB_PATH) {
		if data, read_err := os.read_entire_file(TAPS_DB_PATH, context.allocator); read_err == nil {
			defer delete(data)

			lines := strings.split(string(data), "\n", context.temp_allocator)
			for line in lines {
				trimmed := strings.trim_space(line)
				if len(trimmed) == 0 {
					continue
				}
				// Format: "name" or "name<TAB>url"
				parts := strings.split(trimmed, "\t", context.temp_allocator)
				name := strings.trim_space(parts[0])
				url := ""
				if len(parts) > 1 {
					url = strings.trim_space(parts[1])
				}
				if len(name) > 0 {
					append(&taps, Read_Tap_Entry{
						name = strings.clone(name, context.allocator),
						url  = strings.clone(url, context.allocator),
					})
				}
			}
		}
	}

	// Discover local Homebrew taps in the shared Library/Taps store
	// (shared_taps_dir honors the unit-test override; production behavior is
	// unchanged: it derives from get_homebrew_prefix the same way).
	taps_dir := shared_taps_dir()
	if os.is_dir(taps_dir) {
		if user_infos, u_err := os.read_directory_by_path(taps_dir, -1, context.allocator); u_err == nil {
			defer os.file_info_slice_delete(user_infos, context.allocator)
			for u_info in user_infos {
				if u_info.type != .Directory do continue
				user_dir := u_info.fullpath
				user_name := u_info.name
				if repo_infos, r_err := os.read_directory_by_path(user_dir, -1, context.allocator); r_err == nil {
					defer os.file_info_slice_delete(repo_infos, context.allocator)
					for r_info in repo_infos {
						if r_info.type != .Directory do continue
						repo_folder := r_info.name
						clean_repo := repo_folder
						if strings.has_prefix(repo_folder, "homebrew-") {
							clean_repo = repo_folder[9:]
						}
						tap_name := fmt.tprintf("%s/%s", user_name, clean_repo)
						already := false
						for t in taps {
							if t.name == tap_name {
								already = true
								break
							}
						}
						if !already {
							append(&taps, Read_Tap_Entry{
								name       = strings.clone(tap_name, context.allocator),
								url        = strings.clone("", context.allocator),
								discovered = true,
							})
						}
					}
				}
			}
		}
	}

	// Shared mode: Library/Taps is the sole source of *active* taps. A
	// taps.txt row with no backing clone is stale — either brew untapped it
	// or the clone failed — so drop it from the view (homebrew/* pseudo-taps
	// are API-based and legitimately never cloned). Standalone mode keeps
	// every row.
	if os.is_dir(taps_dir) {
		kept := make([dynamic]Read_Tap_Entry, 0, len(taps), context.allocator)
		for t in taps {
			if !t.discovered && !strings.has_prefix(t.name, "homebrew/") {
				if !os.is_dir(fmt.tprintf("%s/.git", shared_tap_dir_in(taps_dir, t.name))) {
					destroy_read_tap_entry(t)
					continue
				}
			}
			append(&kept, t)
		}
		delete(taps)
		taps = kept
	}

	return taps
}

write_taps :: proc(taps: [dynamic]Read_Tap_Entry) -> bool {
	db_dir := fmt.tprintf("%s/db", platform.get_ubrew_root())
	_ = os.make_directory_all(db_dir, os.perm(0o755))

	b := strings.builder_make(context.temp_allocator)
	for t in taps {
		// Discovered entries are shared-mode clones, not taps.txt rows:
		// never persist them (prevents homebrew/core, homebrew/cask and
		// dir-only taps from leaking into the database file).
		if t.discovered do continue
		strings.write_string(&b, t.name)
		if len(t.url) > 0 {
			strings.write_string(&b, "\t")
			strings.write_string(&b, t.url)
		}
		strings.write_string(&b, "\n")
	}

	data_str := strings.to_string(b)
	err := os.write_entire_file(TAPS_DB_PATH, transmute([]byte)data_str)
	return err == nil
}

// read_taps_rows returns only the taps.txt rows (no clone discovery, no
// shared-mode filtering). Used by `ubrew tap migrate` so pre-shared state
// recorded only in taps.txt is still visible for cloning.
read_taps_rows :: proc() -> (taps: [dynamic]Read_Tap_Entry) {
	taps = make([dynamic]Read_Tap_Entry, context.allocator)
	if !os.is_file(TAPS_DB_PATH) do return taps
	data, read_err := os.read_entire_file(TAPS_DB_PATH, context.allocator)
	if read_err != nil do return taps
	defer delete(data)

	lines := strings.split(string(data), "\n", context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 do continue
		parts := strings.split(trimmed, "\t", context.temp_allocator)
		name := strings.trim_space(parts[0])
		url := ""
		if len(parts) > 1 {
			url = strings.trim_space(parts[1])
		}
		if len(name) > 0 {
			append(&taps, Read_Tap_Entry{
				name = strings.clone(name, context.allocator),
				url  = strings.clone(url, context.allocator),
			})
		}
	}
	return taps
}

// tap_add adds a tap to the database. The url parameter is optional; if
// non-empty, it is stored alongside the name and used as the fetch source.
// In shared mode the tap is also cloned into brew's Library/Taps first.
tap_add :: proc(name, url: string) -> bool {
	if !is_valid_tap_name(name) {
		fmt.printf("Error: Invalid tap name '%s'. Tap name must be in format user/repo.\n", name)
		return false
	}

	// Shared mode: the tap store is brew's Library/Taps. Clone before the
	// dedupe so taps already listed in taps.txt but not yet cloned still get
	// materialized. homebrew/core & homebrew/cask are API-based, never cloned.
	if mode() == .Shared && !strings.has_prefix(name, "homebrew/") {
		lock_fd, lock_ok := shared_tap_lock()
		if !lock_ok {
			fmt.printf("Error: Could not lock the shared taps directory for '%s'.\n", name)
			return false
		}
		defer posix.close(lock_fd)
		if !ensure_shared_clone(name, url) {
			// Shared mode: the clone is the record of the tap; a failed
			// clone means the tap was not added (ensure_shared_clone
			// already printed the warning with the `brew tap` hint).
			return false
		}
	}

	taps := read_taps()
	defer {
		for t in taps {
			destroy_read_tap_entry(t)
		}
		delete(taps)
	}

	for &t in taps {
		if t.name == name {
			// A discovered entry is a shared-mode clone; the git remote is
			// authoritative and there is no taps.txt row to update.
			if t.discovered {
				fmt.printf("Warning: Already tapped '%s'\n", name)
				return true
			}
			// Update URL if a new one was provided
			if len(url) > 0 && t.url != url {
				old_url := t.url
				t.url = strings.clone(url, context.allocator)
				if !write_taps(taps) {
					// Revert the in-memory change so the on-disk and in-memory
					// states stay in sync.
					delete(t.url)
					t.url = old_url
					fmt.printf("Error: Failed to update tap URL for '%s'\n", name)
					return false
				}
				delete(old_url)
				fmt.printf("==> Tapped '%s' (URL updated)\n", name)
			} else {
				fmt.printf("Warning: Already tapped '%s'\n", name)
			}
			return true
		}
	}

	// In shared mode the clone itself is the record of the tap; write a
	// taps.txt row only for standalone mode (and homebrew/* pseudo-taps).
	// This keeps Library/Taps the sole source of active taps.
	if mode() == .Shared {
		return true
	}

	append(&taps, Read_Tap_Entry{
		name = strings.clone(name, context.allocator),
		url  = strings.clone(url, context.allocator),
	})
	if write_taps(taps) {
		fmt.printf("==> Tapped '%s'", name)
		if len(url) > 0 {
			fmt.printf(" (%s)", url)
		}
		fmt.println()
		return true
	} else {
		fmt.printf("Error: Failed to tap '%s'\n", name)
		return false
	}
}

// remove_tap_row drops a tap from taps.txt if present. Returns true when the
// write succeeded or the row did not exist; false on write failure.
remove_tap_row :: proc(name: string) -> bool {
	taps := read_taps()
	defer {
		for t in taps {
			destroy_read_tap_entry(t)
		}
		delete(taps)
	}
	found := -1
	for t, i in taps {
		if t.name == name {
			found = i
			break
		}
	}
	if found == -1 {
		return true
	}
	destroy_read_tap_entry(taps[found])
	unordered_remove(&taps, found)
	return write_taps(taps)
}

// tap_row_exists reports whether a tap name is present in taps.txt.
tap_row_exists :: proc(name: string) -> bool {
	taps := read_taps()
	defer {
		for t in taps {
			destroy_read_tap_entry(t)
		}
		delete(taps)
	}
	for t in taps {
		if t.name == name {
			return true
		}
	}
	return false
}

// is_symlink reports whether path is a symbolic link (any type of target).
is_symlink :: proc(path: string) -> bool {
	target, err := os.read_link(path, context.temp_allocator)
	return err == nil && len(target) > 0
}

// tap_remove removes a tap from the database.
tap_remove :: proc(name: string) -> bool {
	// Shared mode: the clone directory in brew's Library/Taps is the tap.
	// Untap = remove the directory (guarded to stay under Library/Taps) and
	// drop the taps.txt compatibility row. A DB-only tap (clone missing)
	// still gets its row removed.
	if mode() == .Shared && !strings.has_prefix(name, "homebrew/") {
		// Validate the name shape before deriving any path: a name like
		// "a/../../tmp/x" would otherwise produce a dest that still has the
		// taps_dir prefix and could escape Library/Taps (path traversal).
		if !is_valid_tap_name(name) {
			fmt.printf("Error: Invalid tap name '%s'. Tap name must be in format user/repo.\n", name)
			return false
		}
		lock_fd, lock_ok := shared_tap_lock()
		if !lock_ok {
			fmt.printf("Error: Could not lock the shared taps directory for '%s'.\n", name)
			return false
		}
		defer posix.close(lock_fd)
		dest := shared_tap_dir(name)
		taps_dir := shared_taps_dir()
		if !strings.has_prefix(dest, taps_dir) || strings.contains(dest, "/../") {
			fmt.printf("Error: Refusing to remove '%s' (outside %s).\n", dest, taps_dir)
			return false
		}
		if is_symlink(dest) {
			fmt.printf("Error: Refusing to remove '%s' (symlink; refusing to follow it out of %s).\n", dest, taps_dir)
			return false
		}
		dir_exists := os.is_dir(dest)
		row_exists := tap_row_exists(name)
		if !dir_exists && !row_exists {
			fmt.printf("Error: Tap '%s' is not tapped.\n", name)
			return false
		}
		_ = remove_tap_row(name)
		if dir_exists {
			if err := os.remove_all(dest); err != nil {
				fmt.printf("Error: Failed to untap '%s': %v\n", name, err)
				return false
			}
		}
		fmt.printf("==> Untapped '%s'\n", name)
		return true
	}

	taps := read_taps()
	defer {
		for t in taps {
			destroy_read_tap_entry(t)
		}
		delete(taps)
	}

	found := -1
	for t, i in taps {
		if t.name == name {
			found = i
			break
		}
	}

	if found == -1 {
		fmt.printf("Error: Tap '%s' is not tapped.\n", name)
		return false
	}

	destroy_read_tap_entry(taps[found])
	unordered_remove(&taps, found)
	if write_taps(taps) {
		fmt.printf("==> Untapped '%s'\n", name)
		return true
	} else {
		fmt.printf("Error: Failed to untap '%s'\n", name)
		return false
	}
}

// derive_branch_from_url attempts to determine the default branch of a GitHub
// repository by querying the GitHub API. Returns "main" as a fallback if the
// query fails. This is best-effort; callers should fall back to "main" on any
// fetch failure regardless of what this returns. The returned string is
// always heap-allocated so callers can pass it to `delete()`.
derive_branch_from_url :: proc(url: string) -> string {
	if !strings.contains(url, "github.com") {
		return strings.clone("main", context.allocator)
	}

	repo := ""
	if strings.has_prefix(url, "https://github.com/") {
		repo = url[len("https://github.com/"):]
	} else if strings.has_prefix(url, "http://github.com/") {
		repo = url[len("http://github.com/"):]
	} else if strings.has_prefix(url, "git@github.com:") {
		repo = url[len("git@github.com:"):]
	}

	if len(repo) == 0 {
		return strings.clone("main", context.allocator)
	}
	if strings.has_suffix(repo, ".git") {
		repo = repo[:len(repo) - 4]
	}

	repo_candidates := make([dynamic]string, context.temp_allocator)
	defer delete(repo_candidates)
	append(&repo_candidates, repo)

	if slash := strings.index(repo, "/"); slash >= 0 {
		user := repo[:slash]
		r := repo[slash + 1:]
		if !strings.has_prefix(r, "homebrew-") {
			append(&repo_candidates, fmt.tprintf("%s/homebrew-%s", user, r))
		}
	}

	for candidate in repo_candidates {
		api_url := fmt.tprintf("https://api.github.com/repos/%s?ref=default", candidate)

		temp_f, terr := os.create_temp_file("", "ubrew_tap_branch_*.json")
		if terr != nil do continue
		temp_file := strings.clone(os.name(temp_f), context.temp_allocator)
		os.close(temp_f)
		defer os.remove(temp_file)

		cmd_args := []string{
			"curl",
			"-sfL",
			"--no-progress-meter",
			"--connect-timeout", "5",
			"--max-time", "30",
			"-H", "Accept: application/vnd.github+json",
			api_url,
			"-o", temp_file,
		}
		if !platform.exec_cmd("curl", cmd_args) do continue

		data, read_err := os.read_entire_file(temp_file, context.temp_allocator)
		if read_err != nil || len(data) == 0 do continue

		marker := strings.index(string(data), "\"default_branch\"")
		if marker < 0 do continue
		rest := string(data[marker:])
		colon_idx := strings.index(rest, ":")
		if colon_idx < 0 do continue
		rest = rest[colon_idx + 1:]
		quote_start := strings.index(rest, "\"")
		if quote_start < 0 do continue
		rest = rest[quote_start + 1:]
		quote_end := strings.index(rest, "\"")
		if quote_end < 0 do continue
		return strings.clone(rest[:quote_end], context.allocator)
	}

	return strings.clone("main", context.allocator)
}

// derive_branches_batch fires a single curl --parallel for all GitHub URLs
// and returns a slice of branch names, one per input URL. Non-GitHub URLs
// get "main" immediately.
//
// Ownership: the returned slice and each element string are independently
// heap-allocated via context.allocator. Callers must `delete()` every
// element string before deleting the slice itself.
derive_branches_batch :: proc(urls: []string) -> []string {
	branches := make([]string, len(urls), context.allocator)

	// Collect indices of GitHub URLs that need parallel probing
	gh_indices := make([dynamic]int, context.temp_allocator)
	defer delete(gh_indices)
	api_urls := make([dynamic]string, context.temp_allocator)
	defer delete(api_urls)
	temp_files := make([dynamic]string, context.temp_allocator)
	defer {
		for tf in temp_files {
			if len(tf) > 0 {
				os.remove(tf)
				delete(tf)
			}
		}
		delete(temp_files)
	}

	for url, idx in urls {
		repo := ""
		if strings.has_prefix(url, "https://github.com/") {
			repo = url[len("https://github.com/"):]
		} else if strings.has_prefix(url, "http://github.com/") {
			repo = url[len("http://github.com/"):]
		} else if strings.has_prefix(url, "git@github.com:") {
			repo = url[len("git@github.com:"):]
		}

		if len(repo) > 0 {
			if strings.has_suffix(repo, ".git") {
				repo = repo[:len(repo) - 4]
			}
			api_url := fmt.tprintf("https://api.github.com/repos/%s?ref=default", repo)

			temp_f, terr := os.create_temp_file("", "ubrew_branch_*.json")
			if terr != nil {
				// Could not allocate a temp file for this probe — fall back
				// to "main" immediately and skip the curl batch for this URL
				// so json doesn't leak to stdout.
				branches[idx] = strings.clone("main", context.allocator)
				continue
			}
			append(&gh_indices, idx)
			append(&api_urls, api_url)
			temp_name := strings.clone(os.name(temp_f), context.allocator)
			os.close(temp_f)
			append(&temp_files, temp_name)
		} else {
			branches[idx] = strings.clone("main", context.allocator)
		}
	}

	if len(api_urls) > 0 {
		args := make([dynamic]string, context.temp_allocator)
		defer delete(args)
		append(&args, "curl")
		append(&args, "-sfL")
		append(&args, "--compressed")
		append(&args, "--no-progress-meter")
		append(&args, "--connect-timeout")
		append(&args, "5")
		append(&args, "--max-time")
		append(&args, "30")
		append(&args, "--http2")
		append(&args, "--parallel")

		for i in 0..<len(api_urls) {
			if len(temp_files[i]) > 0 {
				append(&args, "-o")
				append(&args, temp_files[i])
			}
			append(&args, api_urls[i])
		}

		_ = platform.exec_cmd("curl", args[:])
		// Ignore curl exit code — we parse each response individually;
		// failed requests just fall back to "main" below.
	}

	for i in 0..<len(gh_indices) {
		idx := gh_indices[i]
		branch := "main"
		if i < len(temp_files) && len(temp_files[i]) > 0 {
			if data, read_err := os.read_entire_file(temp_files[i], context.temp_allocator); read_err == nil {
				marker := strings.index(string(data), "\"default_branch\"")
				if marker >= 0 {
					rest := string(data[marker:])
					colon_idx := strings.index(rest, ":")
					if colon_idx >= 0 {
						rest = rest[colon_idx + 1:]
						quote_start := strings.index(rest, "\"")
						if quote_start >= 0 {
							rest = rest[quote_start + 1:]
							quote_end := strings.index(rest, "\"")
							if quote_end >= 0 {
								branch = rest[:quote_end]
							}
						}
					}
				}
			}
		}
		branches[idx] = strings.clone(branch, context.allocator)
	}

	return branches
}

// tap_from_entry builds a Tap struct from a Read_Tap_Entry, inferring the
// GitHub URL and branch if not explicitly provided. The returned Tap owns
// its own copies of the strings, so destroying both the Tap and the source
// Read_Tap_Entry will not double-free any string.
tap_from_entry :: proc(e: Read_Tap_Entry) -> Tap {
	url: string
	if len(e.url) == 0 {
		// Default: assume GitHub repo with the same name
		url = strings.clone(fmt.tprintf("https://github.com/%s", e.name), context.allocator)
	} else {
		url = strings.clone(e.url, context.allocator)
	}
	branch: string
	if mode() == .Shared && os.is_dir(shared_tap_dir(e.name)) {
		// Shared mode with a local clone reads Ruby straight from the
		// working tree, so skip the GitHub API probe entirely.
		branch = strings.clone("main", context.allocator)
	} else {
		// Standalone mode — or shared mode without a local clone (clone
		// failed or not yet migrated): the raw-URL fallback needs the real
		// default branch.
		branch = derive_branch_from_url(url)
	}
	return Tap{
		name   = strings.clone(e.name, context.allocator),
		url    = url,
		branch = branch,
	}
}

// tap_repo_path extracts the "user/repo" portion from a tap's GitHub URL.
// e.g. "https://github.com/pkgxdev/homebrew-made" -> "pkgxdev/homebrew-made".
// Returns "" if the URL is not a recognizable GitHub URL.
tap_repo_path :: proc(t: Tap) -> string {
	if !strings.contains(t.url, "github.com") {
		return ""
	}
	stripped, _ := strings.replace_all(t.url, "https://github.com/", "", allocator = context.temp_allocator)
	stripped, _ = strings.replace_all(stripped, "http://github.com/", "", allocator = context.temp_allocator)
	stripped, _ = strings.replace_all(stripped, "git@github.com:", "", allocator = context.temp_allocator)
	if strings.has_suffix(stripped, ".git") {
		stripped = stripped[:len(stripped) - 4]
	}
	if strings.has_suffix(stripped, "/") {
		stripped = stripped[:len(stripped) - 1]
	}
	return strings.clone(stripped, context.allocator)
}

// tap_cache_path returns the local cache file path for a formula in a tap.
// This stays rooted at $UBREW_ROOT/cache/taps even in shared mode: clone
// reads mirror into it (see read_tap_ruby_from_clone) so cache-path readers
// such as the install-time formula/cask classification keep working.
tap_cache_path :: proc(t: Tap, formula_name: string) -> string {
	return fmt.tprintf("%s/%s/Formula/%s.rb", TAPS_CACHE_DIR, t.name, formula_name)
}

// read_tap_ruby_from_clone reads a Ruby file (formula or cask) straight from
// a shared-mode local clone. Candidates, in order: <subdir>/<name>.rb,
// <subdir>/<first-letter>/<name>.rb (Homebrew's letter-nested layout for
// homebrew/core-style taps), and the repo root. On success the content is
// mirrored into ubrew's cache dir so cache-path readers keep working in
// shared mode. Only active in shared mode; returns ("", false) otherwise so
// standalone behavior is unchanged.
read_tap_ruby_from_clone :: proc(t: Tap, subdir, name: string) -> (contents: string, ok: bool) {
	if mode() != .Shared || len(name) == 0 {
		return "", false
	}
	return read_tap_ruby_from_clone_in(shared_tap_dir(t.name), t, subdir, name)
}

// read_tap_ruby_from_clone_in is the testable core of read_tap_ruby_from_clone;
// `dest` is the clone directory (any base — a fixture in tests). Temp-allocated
// intermediates; the returned string is heap-allocated and caller-freed.
read_tap_ruby_from_clone_in :: proc(dest: string, t: Tap, subdir, name: string) -> (contents: string, ok: bool) {
	if len(name) == 0 {
		return "", false
	}
	base := fmt.tprintf("%s/%s", dest, subdir)
	candidates := make([dynamic]string, context.temp_allocator)
	defer delete(candidates)
	append(&candidates, fmt.tprintf("%s/%s.rb", base, name))
	append(&candidates, fmt.tprintf("%s/%s/%s.rb", base, name[:1], name))
	append(&candidates, fmt.tprintf("%s/%s.rb", dest, name))

	for c in candidates {
		data, rerr := os.read_entire_file(c, context.allocator)
		if rerr != nil {
			continue
		}
		trimmed := strings.trim_space(string(data))
		if len(trimmed) == 0 || trimmed[0] == '<' {
			// Empty file or HTML (e.g. a stale 404 page): not a real formula.
			delete(data, context.allocator)
			continue
		}
		cloned := strings.clone(trimmed, context.allocator)
		delete(data, context.allocator)
		// Mirror to the cache dir so cache-path readers (install
		// classification, `ubrew --repo`) see the file in shared mode too.
		cache_path := fmt.tprintf("%s/%s/%s/%s.rb", TAPS_CACHE_DIR, t.name, subdir, name)
		_ = os.make_directory_all(fmt.tprintf("%s/%s/%s", TAPS_CACHE_DIR, t.name, subdir), os.perm(0o755))
		_ = os.write_entire_file(cache_path, transmute([]u8)cloned)
		return cloned, true
	}
	return "", false
}

// fetch_formula_ruby fetches the Ruby formula file for `formula_name` from the
// given tap's GitHub repository. The result is cached on disk for subsequent
// lookups. Returns the file contents (caller must free with delete()).
// Tries multiple candidate locations: Formula/ subdirectory first, then the
// repo root. Also tries the `homebrew-<name>` convention if the primary URL
// fails. In shared mode a local clone is consulted first.
fetch_formula_ruby :: proc(t: Tap, formula_name: string) -> (contents: string, ok: bool) {
	if src, found := read_tap_ruby_from_clone(t, "Formula", formula_name); found {
		return src, true
	}

	_ = os.make_directory_all(fmt.tprintf("%s/%s/Formula", TAPS_CACHE_DIR, t.name), os.perm(0o755))

	cache_path := tap_cache_path(t, formula_name)
	repo := tap_repo_path(t)
	if len(repo) == 0 {
		// Fall back to t.name if the URL is not parseable.
		repo = t.name
	}

	// Build candidate raw URLs. Order: primary repo Formula/, primary repo root,
	// homebrew- variant Formula/, homebrew- variant root.
	candidates := make([dynamic]string, context.temp_allocator)
	defer delete(candidates)
	append(&candidates, fmt.tprintf("https://raw.githubusercontent.com/%s/%s/Formula/%s.rb", repo, t.branch, formula_name))
	append(&candidates, fmt.tprintf("https://raw.githubusercontent.com/%s/%s/%s.rb", repo, t.branch, formula_name))

	if slash := strings.index(t.name, "/"); slash >= 0 {
		user := t.name[:slash]
		rest := t.name[slash + 1:]
		hb := fmt.tprintf("%s/homebrew-%s", user, rest)
		if hb != repo {
			append(&candidates, fmt.tprintf("https://raw.githubusercontent.com/%s/%s/Formula/%s.rb", hb, t.branch, formula_name))
			append(&candidates, fmt.tprintf("https://raw.githubusercontent.com/%s/%s/%s.rb", hb, t.branch, formula_name))
		}
	}

	for url in candidates {
		cmd_args := []string{
			"curl",
			"-sfL",
			"--no-progress-meter",
			url,
			"-o", cache_path,
		}
		curl_ok := platform.exec_cmd("curl", cmd_args)
		if !curl_ok {
			continue
		}
		data, read_err := os.read_entire_file(cache_path, context.allocator)
		if read_err != nil {
			continue
		}
		if len(data) == 0 {
			delete(data)
			continue
		}
		// Reject if the response is an HTML 404 page (raw.githubusercontent.com
		// returns 404 as HTML when the file doesn't exist; the -f flag should
		// already prevent this, but be defensive).
		trimmed := strings.trim_space(string(data))
		if len(trimmed) == 0 || trimmed[0] == '<' {
			delete(data)
			continue
		}
		// `trimmed` is a view into `data`; clone it first so the returned
		// string is independent of `data`, then free `data`.
		cloned := strings.clone(trimmed, context.allocator)
		delete(data)
		return cloned, true
	}
	return "", false
}

// load_trusted_file appends every non-empty, non-comment line of path to
// names (deduplicated). No-op when the file is missing.
load_trusted_file :: proc(path: string, names: ^[dynamic]string) {
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil || len(data) == 0 do return
	defer delete(data)
	text := string(data)
	start := 0
	for start < len(text) {
		end := start
		for end < len(text) && text[end] != '\n' {
			end += 1
		}
		if end > start {
			line := strings.trim_space(text[start:end])
			if len(line) > 0 && !strings.has_prefix(line, "#") {
				already := false
				for n in names^ {
					if n == line {
						already = true
						break
					}
				}
				if !already {
					append(names, strings.clone(line, context.allocator))
				}
			}
		}
		start = end + 1
	}
}

// homebrew_trusted_taps returns the trusted taps recorded by the actual
// Homebrew install at the *runtime* prefix (the same prefix shared-mode
// clones come from). The file is honored whenever it exists; a custom
// HOMEBREW_PREFIX/UBREW_PREFIX tree carries its own trust state. Callers
// must delete the returned strings and slice.
homebrew_trusted_taps :: proc() -> [dynamic]string {
	return homebrew_trusted_taps_at(platform.get_homebrew_prefix())
}

// homebrew_trusted_taps_at is the testable core of homebrew_trusted_taps:
// it loads <prefix>/etc/homebrew/trusted_taps when that file exists.
homebrew_trusted_taps_at :: proc(prefix: string) -> [dynamic]string {
	names := make([dynamic]string, context.allocator)
	hb_trusted_path := fmt.tprintf("%s/etc/homebrew/trusted_taps", prefix)
	if os.is_file(hb_trusted_path) {
		load_trusted_file(hb_trusted_path, &names)
	}
	return names
}

// trusted_taps_load returns the merged trust view: ubrew's own
// TRUSTED_TAPS_FILE plus the Homebrew install's trusted_taps overlay.
// The overlay is read-only — mutating commands must use
// trusted_taps_load_own so Homebrew entries are never copied into
// ubrew's file.
trusted_taps_load :: proc() -> ([dynamic]string, bool) {
	names := make([dynamic]string, context.allocator)
	load_trusted_file(TRUSTED_TAPS_FILE, &names)
	homebrew := homebrew_trusted_taps()
	defer {
		for n in homebrew {
			delete(n)
		}
		delete(homebrew)
	}
	for n in homebrew {
		already := false
		for own in names {
			if own == n {
				already = true
				break
			}
		}
		if !already {
			append(&names, strings.clone(n, context.allocator))
		}
	}
	return names, false
}

// trusted_taps_load_own returns only the entries owned by ubrew's own
// TRUSTED_TAPS_FILE — the set mutating commands may add to or remove
// from. Callers must delete the returned strings and slice.
trusted_taps_load_own :: proc() -> [dynamic]string {
	names := make([dynamic]string, context.allocator)
	load_trusted_file(TRUSTED_TAPS_FILE, &names)
	return names
}

// trusted_taps_save persists names to TRUSTED_TAPS_FILE, excluding any
// entries owned by the Homebrew overlay so ubrew's file never absorbs
// brew's trust state.
trusted_taps_save :: proc(names: [dynamic]string) {
	db_dir := fmt.tprintf("%s/db", platform.get_ubrew_root())
	_ = os.make_directory_all(db_dir, os.perm(0o755))

	homebrew := homebrew_trusted_taps()
	defer {
		for n in homebrew {
			delete(n)
		}
		delete(homebrew)
	}
	is_brew_owned :: proc(n: string, hb: [dynamic]string) -> bool {
		for h in hb {
			if h == n do return true
		}
		return false
	}

	buf: strings.Builder
	strings.builder_init(&buf)
	for name in names {
		if is_brew_owned(name, homebrew) do continue
		strings.write_string(&buf, name)
		strings.write_byte(&buf, '\n')
	}
	result := strings.to_string(buf)
	_ = os.write_entire_file(TRUSTED_TAPS_FILE, result)
	strings.builder_destroy(&buf)
}

tap_is_trusted :: proc(name: string) -> bool {
	if strings.has_prefix(name, "homebrew/") {
		return true
	}
	no_require := os.get_env("HOMEBREW_NO_REQUIRE_TAP_TRUST", context.temp_allocator)
	if no_require == "1" || strings.to_lower(no_require, context.temp_allocator) == "true" || strings.to_lower(no_require, context.temp_allocator) == "yes" {
		return true
	}
	names, _ := trusted_taps_load()
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	for n in names {
		if n == name {
			return true
		}
	}
	return false
}

// is_valid_tap_name reports whether a name looks like a tap: exactly one '/'
// with non-empty user and repo parts, no URL scheme markers, and no "." or
// ".." path components (which could escape the taps directory via
// shared_tap_dir). This guards trusted_taps.txt against entries like
// "https:/..." (a real corruption seen in the live /opt/ubrew state) being
// written verbatim.
is_valid_tap_name :: proc(name: string) -> bool {
	if len(name) == 0 || strings.contains(name, "://") || strings.contains(name, ":") {
		return false
	}
	parts := strings.split(name, "/", context.temp_allocator)
	if len(parts) != 2 do return false
	for p in parts {
		if len(p) == 0 || p == "." || p == ".." do return false
	}
	return true
}

tap_trust :: proc(name: string) -> bool {
	if !is_valid_tap_name(name) {
		fmt.printf("Error: Invalid tap name '%s'. Tap name must be in format user/repo.\n", name)
		return false
	}
	// A Homebrew-owned trust entry is already trusted; nothing to save —
	// never copy brew's entries into ubrew's file.
	homebrew := homebrew_trusted_taps()
	defer {
		for n in homebrew {
			delete(n)
		}
		delete(homebrew)
	}
	for n in homebrew {
		if n == name {
			return true
		}
	}
	names := trusted_taps_load_own()
	defer {
		for n in names {
			delete(n)
		}
		delete(names)
	}
	// Check if already trusted
	for n in names {
		if n == name {
			return true
		}
	}
	db_dir := fmt.tprintf("%s/db", platform.get_ubrew_root())
	_ = os.make_directory_all(db_dir, os.perm(0o755))
	append(&names, strings.clone(name, context.allocator))
	trusted_taps_save(names)
	return true
}

tap_untrust :: proc(name: string) -> bool {
	// Homebrew-owned entries are managed by brew's trusted_taps file;
	// ubrew must not silently pretend to remove them.
	homebrew := homebrew_trusted_taps()
	defer {
		for n in homebrew {
			delete(n)
		}
		delete(homebrew)
	}
	for n in homebrew {
		if n == name {
			fmt.printf("Error: Tap '%s' is trusted by Homebrew (%s/etc/homebrew/trusted_taps).\n", name, platform.get_homebrew_prefix())
			fmt.printf("  Remove it there (or run `brew untap %s --force`) instead.\n", name)
			return false
		}
	}
	names := trusted_taps_load_own()
	defer delete(names)
	found := false
	new_names := make([dynamic]string, context.allocator)
	for n in names {
		if n == name {
			found = true
		} else {
			append(&new_names, n)
		}
	}
	trusted_taps_save(new_names)
	delete(new_names)
	return found
}

get_trusted_taps :: proc(allocator := context.allocator) -> []string {
	names, _ := trusted_taps_load()
	result := make([]string, len(names), allocator)
	for n, i in names {
		result[i] = strings.clone(n, allocator)
	}
	return result
}

prompt_and_trust_tap :: proc(name: string) -> bool {
	fmt.printf("==> Tap '%s' is not trusted.\n", name)
	fmt.printf("Do you want to trust this tap? (y/N) ")
	buf := make([]u8, 16, context.temp_allocator)
	n, _ := os.read(os.stdin, buf)
	if n > 0 {
		input := strings.trim_space(string(buf[:n]))
		if input == "y" || input == "Y" {
			return tap_trust(name)
		}
	}
	return false
}

// print_untrusted_taps_warning prints a Homebrew-style batch warning when any
// tapped repositories are not trusted. Returns true if a warning was printed.
// Honors HOMEBREW_NO_REQUIRE_TAP_TRUST (no warning when trust checks disabled).
print_untrusted_taps_warning :: proc() -> bool {
	no_require := os.get_env("HOMEBREW_NO_REQUIRE_TAP_TRUST", context.temp_allocator)
	lower := strings.to_lower(no_require, context.temp_allocator)
	if no_require == "1" || lower == "true" || lower == "yes" {
		return false
	}

	taps := read_taps()
	defer {
		for t in taps {
			destroy_read_tap_entry(t)
		}
		delete(taps)
	}

	untrusted := make([dynamic]string, context.temp_allocator)
	defer delete(untrusted)
	for t in taps {
		if !tap_is_trusted(t.name) {
			append(&untrusted, strings.clone(t.name, context.temp_allocator))
		}
	}

	if len(untrusted) == 0 {
		return false
	}

	fmt.println("Warning: The following taps are not trusted:")
	for name in untrusted {
		fmt.printf("  %s\n", name)
	}
	fmt.println("")
	fmt.println("ubrew is currently ignoring formulae, casks and commands from these taps because tap trust is required.")
	fmt.println("")

	fmt.println("Untap them with:")
	untap_args := strings.join(untrusted[:], " ", context.temp_allocator)
	fmt.printf("  ubrew untap %s\n", untap_args)

	fmt.println("Trust whole taps with:")
	trust_args := strings.join(untrusted[:], " ", context.temp_allocator)
	fmt.printf("  ubrew tap trust %s\n", trust_args)

	fmt.println("To disable trust checks:")
	fmt.println("  export HOMEBREW_NO_REQUIRE_TAP_TRUST=1")
	fmt.println("For more information, see:")
	fmt.println("  https://docs.brew.sh/Tap-Trust")
	return true
}

tap_cask_cache_path :: proc(t: Tap, cask_name: string) -> string {
	return fmt.tprintf("%s/%s/Casks/%s.rb", TAPS_CACHE_DIR, t.name, cask_name)
}

fetch_cask_ruby :: proc(t: Tap, cask_name: string) -> (string, bool) {
	if src, found := read_tap_ruby_from_clone(t, "Casks", cask_name); found {
		return src, true
	}

	cache_path := tap_cask_cache_path(t, cask_name)
	data, rerr := os.read_entire_file(cache_path, context.allocator)
	if rerr == nil && len(data) > 0 {
		return string(data), true
	}
	// Fallback: try fetching from GitHub via curl
	url := fmt.tprintf("https://raw.githubusercontent.com/%s/HEAD/Casks/%s.rb", t.name, cask_name)
	tmp_f, terr := os.create_temp_file("", "cask-rb-")
	if terr != nil {
		return "", false
	}
	tmp_name := strings.clone(os.name(tmp_f), context.allocator)
	defer {
		os.close(tmp_f)
		os.remove(tmp_name)
	}
	_ = platform.exec_cmd("curl", []string{"curl", "-fsL", "-o", tmp_name, url})
	fetched_data, ferr := os.read_entire_file(tmp_name, context.allocator)
	if ferr != nil || len(fetched_data) == 0 {
		return "", false
	}
	_ = os.make_directory_all(fmt.tprintf("%s/%s/Casks", TAPS_CACHE_DIR, t.name), os.perm(0o755))
	_ = os.write_entire_file(cache_path, fetched_data)
	return string(fetched_data), true
}
