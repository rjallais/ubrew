package tap

import "core:fmt"
import "core:os"
import "core:strings"
import "../platform"

TAPS_DB_PATH :: "/opt/ubrew/db/taps.txt"
TAPS_CACHE_DIR :: "/opt/ubrew/cache/taps"

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
	if !os.is_file(TAPS_DB_PATH) {
		return taps
	}
	data, read_err := os.read_entire_file(TAPS_DB_PATH, context.allocator)
	if read_err != nil {
		return taps
	}
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
	return taps
}

write_taps :: proc(taps: [dynamic]Read_Tap_Entry) -> bool {
	_ = os.make_directory_all("/opt/ubrew/db", os.perm(0o755))

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

	// Convert https://github.com/user/repo[.git] -> api url.
	// Use context.temp_allocator for intermediate strings so they are
	// reclaimed at scope exit.
	api_url, _ := strings.replace_all(url, "https://github.com/", "https://api.github.com/repos/", allocator = context.temp_allocator)
	api_url, _ = strings.replace_all(api_url, "http://github.com/", "https://api.github.com/repos/", allocator = context.temp_allocator)
	if strings.has_suffix(api_url, ".git") {
		api_url = api_url[:len(api_url) - 4]
	}
	api_url = strings.concatenate({api_url, "?ref=default"}, context.temp_allocator)

	temp_f, terr := os.create_temp_file("", "ubrew_tap_branch_*.json")
	if terr != nil {
		return strings.clone("main", context.allocator)
	}
	// `os.name` returns a string view into the File struct; cloning here
	// keeps the path valid after we close the handle.
	temp_file := strings.clone(os.name(temp_f), context.allocator)
	defer delete(temp_file)
	defer os.remove(temp_file)
	os.close(temp_f)

	cmd_args := []string{
		"curl",
		"-sfL",
		"--no-progress-meter",
		"-H", "Accept: application/vnd.github+json",
		api_url,
		"-o", temp_file,
	}
	if !platform.exec_cmd("curl", cmd_args) {
		return strings.clone("main", context.allocator)
	}

	data, read_err := os.read_entire_file(temp_file, context.allocator)
	if read_err != nil {
		return strings.clone("main", context.allocator)
	}
	defer delete(data)

	// Look for "default_branch":"<name>" in the response.
	marker := strings.index(string(data), "\"default_branch\"")
	if marker < 0 {
		return strings.clone("main", context.allocator)
	}
	rest := string(data[marker:])
	colon_idx := strings.index(rest, ":")
	if colon_idx < 0 {
		return strings.clone("main", context.allocator)
	}
	rest = rest[colon_idx + 1:]
	quote_start := strings.index(rest, "\"")
	if quote_start < 0 {
		return strings.clone("main", context.allocator)
	}
	rest = rest[quote_start + 1:]
	quote_end := strings.index(rest, "\"")
	if quote_end < 0 {
		return strings.clone("main", context.allocator)
	}
	return strings.clone(rest[:quote_end], context.allocator)
}

// url_to_tap_name converts a GitHub URL like "https://github.com/justrach/nanobrew"
// to a tap name like "justrach/nanobrew". Returns "" for non-GitHub URLs.
url_to_tap_name :: proc(url: string) -> string {
	if !strings.contains(url, "github.com") {
		return strings.clone("", context.allocator)
	}

	// Use context.temp_allocator for intermediate strings so they are
	// reclaimed at scope exit. The final return is heap-allocated.
	stripped, _ := strings.replace_all(url, "https://github.com/", "", allocator = context.temp_allocator)
	stripped, _ = strings.replace_all(stripped, "http://github.com/", "", allocator = context.temp_allocator)
	stripped, _ = strings.replace_all(stripped, "git@github.com:", "", allocator = context.temp_allocator)
	if strings.has_suffix(stripped, ".git") {
		stripped = stripped[:len(stripped) - 4]
	}
	if strings.has_suffix(stripped, "/") {
		stripped = stripped[:len(stripped) - 1]
	}

	parts := strings.split(stripped, "/", context.temp_allocator)
	if len(parts) < 2 {
		return strings.clone("", context.allocator)
	}
	return strings.clone(fmt.tprintf("%s/%s", parts[0], parts[1]), context.allocator)
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

TRUSTED_TAPS_FILE :: "/opt/ubrew/db/trusted_taps.txt"

trusted_taps_load :: proc() -> (names: [dynamic]string, err: bool) {
	names = make([dynamic]string, context.allocator)
	data, rerr := os.read_entire_file(TRUSTED_TAPS_FILE, context.allocator)
	if rerr != nil || len(data) == 0 {
		return names, rerr != nil
	}
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
			if len(line) > 0 {
				append(&names, strings.clone(line, context.allocator))
			}
		}
		start = end + 1
	}
	return names, false
}

trusted_taps_save :: proc(names: [dynamic]string) {
	_ = os.make_directory_all("/opt/ubrew/db", os.perm(0o755))
	buf: strings.Builder
	strings.builder_init(&buf)
	for name in names {
		strings.write_string(&buf, name)
		strings.write_byte(&buf, '\n')
	}
	result := strings.to_string(buf)
	_ = os.write_entire_file(TRUSTED_TAPS_FILE, result)
	strings.builder_destroy(&buf)
	delete(result)
}

tap_is_trusted :: proc(name: string) -> bool {
	if strings.has_prefix(name, "homebrew/") {
		return true
	}
	names, _ := trusted_taps_load()
	defer delete(names)
	for n in names {
		if n == name {
			return true
		}
	}
	return false
}

tap_trust :: proc(name: string) -> bool {
	names, _ := trusted_taps_load()
	// Check if already trusted
	for n in names {
		if n == name {
			return true
		}
	}
	_ = os.make_directory_all("/opt/ubrew/db", os.perm(0o755))
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

tap_cask_cache_path :: proc(t: Tap, cask_name: string) -> string {
	return fmt.tprintf("%s/cache/taps/%s/Casks/%s.rb", "/opt/ubrew", t.name, cask_name)
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
	return string(fetched_data), true
}
