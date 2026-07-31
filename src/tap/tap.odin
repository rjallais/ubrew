package tap

import "core:fmt"
import "core:os"
import "core:strings"
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
Read_Tap_Entry :: struct {
	name: string,
	url:  string,
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

	// Discover local Homebrew taps at $HOMEBREW_PREFIX/Homebrew/Library/Taps/user/repo
	hb_prefix := platform.get_homebrew_prefix()
	taps_dir := fmt.tprintf("%s/Homebrew/Library/Taps", hb_prefix)
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
								name = strings.clone(tap_name, context.allocator),
								url  = "",
							})
						}
					}
				}
			}
		}
	}

	return taps
}

write_taps :: proc(taps: [dynamic]Read_Tap_Entry) -> bool {
	db_dir := fmt.tprintf("%s/db", platform.get_ubrew_root())
	_ = os.make_directory_all(db_dir, os.perm(0o755))

	b := strings.builder_make(context.temp_allocator)
	for t in taps {
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

// tap_add adds a tap to the database. The url parameter is optional; if
// non-empty, it is stored alongside the name and used as the fetch source.
tap_add :: proc(name, url: string) -> bool {
	parts := strings.split(name, "/", context.temp_allocator)
	if len(parts) != 2 || len(parts[0]) == 0 || len(parts[1]) == 0 {
		fmt.printf("Error: Invalid tap name '%s'. Tap name must be in format user/repo.\n", name)
		return false
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

// tap_remove removes a tap from the database.
tap_remove :: proc(name: string) -> bool {
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
	branch := derive_branch_from_url(url)
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
tap_cache_path :: proc(t: Tap, formula_name: string) -> string {
	return fmt.tprintf("%s/%s/Formula/%s.rb", TAPS_CACHE_DIR, t.name, formula_name)
}

// fetch_formula_ruby fetches the Ruby formula file for `formula_name` from the
// given tap's GitHub repository. The result is cached on disk for subsequent
// lookups. Returns the file contents (caller must free with delete()).
// Tries multiple candidate locations: Formula/ subdirectory first, then the
// repo root. Also tries the `homebrew-<name>` convention if the primary URL
// fails.
fetch_formula_ruby :: proc(t: Tap, formula_name: string) -> (contents: string, ok: bool) {
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

trusted_taps_load :: proc() -> ([dynamic]string, bool) {
	names := make([dynamic]string, context.allocator)

	load_file :: proc(path: string, names: ^[dynamic]string) {
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

	load_file(TRUSTED_TAPS_FILE, &names)

	hb_prefix := platform.get_homebrew_prefix()
	hb_trusted_path := fmt.tprintf("%s/etc/homebrew/trusted_taps", hb_prefix)
	load_file(hb_trusted_path, &names)

	return names, false
}

trusted_taps_save :: proc(names: [dynamic]string) {
	db_dir := fmt.tprintf("%s/db", platform.get_ubrew_root())
	_ = os.make_directory_all(db_dir, os.perm(0o755))
	buf: strings.Builder
	strings.builder_init(&buf)
	for name in names {
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

tap_trust :: proc(name: string) -> bool {
	names, _ := trusted_taps_load()
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
	names, _ := trusted_taps_load()
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
