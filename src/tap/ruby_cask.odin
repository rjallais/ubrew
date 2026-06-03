package tap

import "core:fmt"
import "core:strings"

// Ruby_Cask represents the subset of Homebrew's Ruby cask DSL that we parse
// out of `Casks/<name>.rb` files in tapped 3rd-party repositories. Only the
// directives we actually need to install Linux casks are extracted. The
// parser is line-oriented, modeled after nanobrew's tap.zig parser, and
// intentionally does not implement a full Ruby interpreter — it relies on
// the well-behaved patterns used by 3rd-party taps.
Ruby_Cask :: struct {
	token:           string, // e.g. "vscodium-linux"
	name:            string, // e.g. "VSCodium"
	desc:            string,
	homepage:        string,
	version:         string,
	url:             string, // url with #{version} interpolation already applied
	sha256:          string, // sha256 picked for current arch+os
	binaries:        [dynamic]string, // bare names from `binary "..."` (target = source)
	artifact_sources: [dynamic]string, // source paths from `artifact "..."` directives
	artifact_targets: [dynamic]string, // target paths (same length as sources)
}

// destroy_ruby_cask frees heap-allocated strings owned by a Ruby_Cask.
// Safe to call on a zero-value Ruby_Cask.
destroy_ruby_cask :: proc(c: Ruby_Cask) {
	delete(c.token)
	delete(c.name)
	delete(c.desc)
	delete(c.homepage)
	delete(c.version)
	delete(c.url)
	delete(c.sha256)
	nb := len(c.binaries)
	for i := 0; i < nb; i += 1 {
		delete(c.binaries[i])
	}
	delete(c.binaries)
	ns := len(c.artifact_sources)
	for i := 0; i < ns; i += 1 {
		delete(c.artifact_sources[i])
	}
	delete(c.artifact_sources)
	nt := len(c.artifact_targets)
	for i := 0; i < nt; i += 1 {
		delete(c.artifact_targets[i])
	}
	delete(c.artifact_targets)
}

// Cask_Host is the local machine's view of the architecture for cask
// selection. The two values are intentionally machine-friendly (x64 /
// arm64) so they match the `value` side of the Ruby cask's `arch` hash.
Cask_Host :: struct {
	arch: string, // "x64" or "arm64"
	os:   string, // "linux" (ubrew is Linux-only for cask installs)
}

current_cask_host :: proc() -> Cask_Host {
	host: Cask_Host
	when ODIN_OS == .Linux {
		host.os = "linux"
		when ODIN_ARCH == .arm64 {
			host.arch = "arm64"
		} else {
			host.arch = "x64"
		}
	} else {
		// The cask parser is Linux-only; other OSes fall through to x64 linux
		// so url/sha256 lookup still returns a value.
		host.os = "linux"
		host.arch = "x64"
	}
	return host
}

// parse_ruby_cask extracts a Ruby_Cask from a Homebrew Ruby cask file. The
// `cask_name` argument is used when the file does not contain a parseable
// `cask "..."` header. The returned Ruby_Cask is fully heap-allocated; the
// caller must call destroy_ruby_cask when done.
parse_ruby_cask :: proc(src: string, cask_name: string) -> (c: Ruby_Cask, ok: bool) {
	host := current_cask_host()

	// 1. Try to read the cask name from `cask "name" do`. If absent, use
	//    the caller-supplied cask_name as a fallback. extract_cask_token
	//    returns a heap-allocated string; transfer ownership directly.
	c.token = strings.clone(cask_name, context.allocator)
	if name := extract_cask_token(src); len(name) > 0 {
		delete(c.token)
		c.token = name
	}

	// 2. Walk the source line-by-line, tracking block depth and skipping
	//    lines that belong to platform-mismatched blocks or to
	//    side-effect blocks we don't care about.
	//    State for picking the right sha256 when the cask uses an
	//    arch/os-keyed hash:
	arch_keys, arch_values := parse_arch_hash(src)
	defer delete_dynamic_string_array(arch_keys)
	defer delete_dynamic_string_array(arch_values)
	os_keys, os_values := parse_os_hash(src)
	defer delete_dynamic_string_array(os_keys)
	defer delete_dynamic_string_array(os_values)

	if c.version == "" {
		// extract_cask_string_field returns a heap-allocated string;
		// assign directly to avoid leaking the original.
		c.version = extract_cask_string_field(src, "version")
	}

	// 3b. Resolve the arch/os keys for the current host.
	local_arch_key := arch_key_for_host(arch_keys[:], arch_values[:], host.arch)
	local_os_key := os_key_for_host(os_keys[:], os_values[:], host.os)

	// 4. sha256: try a key-based selection first, then fall back to the
	//    first quoted string in the cask's sha256 statement.
	sha256_picked := pick_sha256_for_host(src, local_arch_key, local_os_key, host)
	c.sha256 = strings.clone(sha256_picked, context.allocator)

	// 5. url: read the raw url, then interpolate `#{version}`.
	url_raw := extract_cask_string_field(src, "url")
	defer delete(url_raw)
	if len(url_raw) > 0 {
		c.url = strings.clone(interpolate_version(url_raw, c.version), context.allocator)
	}

	// 6. binary and artifact directives.
	extract_binary_and_artifact_directives(src, &c.binaries, &c.artifact_sources, &c.artifact_targets)

	if len(c.url) == 0 {
		return c, false
	}
	return c, true
}

// extract_cask_token reads the cask name from `cask "name" do`. Returns ""
// if not found. Only the FIRST occurrence is used.
extract_cask_token :: proc(src: string) -> string {
	idx := strings.index(src, "cask")
	if idx < 0 {
		return ""
	}
	// Scan until the first quote.
	for j := idx + 4; j < len(src); j += 1 {
		c := src[j]
		if c == '"' || c == '\'' {
			val, _ := read_quoted_string(src, j)
			return val
		}
		if !(c == ' ' || c == '\t' || c == '\n') {
			// Some other token (e.g. a method call), abort.
			return ""
		}
	}
	return ""
}

// extract_cask_string_field returns the value of the FIRST top-level
// directive `key "value"` in the source. Used for `name`, `desc`,
// `homepage`, `version`, `url`, `sha256 "..."` (when not keyed). Stops
// at the first match. Returns "" if not found. (Named differently from
// the formula parser to avoid clashing in the `tap` package.)
extract_cask_string_field :: proc(src, key: string) -> string {
	lines := strings.split(src, "\n", context.temp_allocator)
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, key) {
			continue
		}
		rest := strings.trim_space(trimmed[len(key):])
		// Accept both `key "value"` and `key(value)` styles.
		if len(rest) == 0 {
			continue
		}
		if rest[0] == '"' || rest[0] == '\'' {
			val, _ := read_quoted_string(rest, 0)
			return val
		}
		// Skip hash-style: `key foo: "value"`, `key foo: "value", bar: "..."`.
		// We treat this as a keyed hash and let the dedicated pickers
		// handle it. For `version` and other scalar fields, this means
		// we still scan for the first quoted value.
		if rest[0] == ' ' {
			rest2 := strings.trim_space(rest)
			if len(rest2) > 0 && rest2[0] != '#' {
				// Find first quoted string in the rest.
				val, _ := read_first_quoted(rest2)
				return val
			}
		}
	}
	return ""
}

// parse_arch_hash returns parallel dynamic arrays of keys and values from
// the `arch ...` line in the cask. The keys are the bareword symbols
// (e.g. "arm", "intel"); the values are the quoted strings (e.g. "arm64",
// "x64"). Both dynamic arrays are heap-allocated; the caller must call
// delete_dynamic_string_array on each.
//
// Example: `arch arm: "arm64", intel: "x64"` ->
//   keys = ["arm", "intel"], values = ["arm64", "x64"]
parse_arch_hash :: proc(src: string) -> ([dynamic]string, [dynamic]string) {
	return parse_simple_symbol_hash(src, "arch")
}

// parse_os_hash is the same as parse_arch_hash but for the `os ...` line.
parse_os_hash :: proc(src: string) -> ([dynamic]string, [dynamic]string) {
	return parse_simple_symbol_hash(src, "os")
}

// delete_dynamic_string_array frees each string in a [dynamic]string and
// then deletes the dynamic array itself.
delete_dynamic_string_array :: proc(arr: [dynamic]string) {
	n := len(arr)
	for i := 0; i < n; i += 1 {
		delete(arr[i])
	}
	delete(arr)
}

// parse_simple_symbol_hash parses a single-line `key sym: "value", sym2:
// "value2"` directive. Returns parallel key/value dynamic arrays.
// Allocation is from context.allocator.
parse_simple_symbol_hash :: proc(src, key: string) -> ([dynamic]string, [dynamic]string) {
	keys := make([dynamic]string, context.allocator)
	values := make([dynamic]string, context.allocator)

	lines := strings.split(src, "\n", context.temp_allocator)
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if !strings.has_prefix(trimmed, key) {
			continue
		}
		rest := strings.trim_space(trimmed[len(key):])
		if len(rest) == 0 || rest[0] == '#' {
			continue
		}
		// Walk tokens: bareword, then `:`, then quoted value.
		i := 0
		pending_key: string
		for i < len(rest) {
			c := rest[i]
			if c == ' ' || c == '\t' || c == ',' {
				i += 1
				continue
			}
			if c == '#' {
				// rest of line is a comment
				break
			}
			if c == '"' || c == '\'' {
				val, ni := read_quoted_string(rest, i)
				if ni < 0 {
					break
				}
				if len(pending_key) > 0 {
					append(&keys, strings.clone(pending_key, context.allocator))
					append(&values, strings.clone(val, context.allocator))
					pending_key = ""
				}
				i = ni
				continue
			}
			if is_ident_start(c) {
				word, ni := read_bareword(rest, i)
				if ni < 0 {
					break
				}
				// Optional `:` immediately after.
				if ni < len(rest) && rest[ni] == ':' {
					pending_key = word
					i = ni + 1
				} else {
					i = ni
				}
				continue
			}
			if c == ':' {
				i += 1
				continue
			}
			i += 1
		}
		// Only honour the first occurrence.
		break
	}

	return keys, values
}

// arch_key_for_host returns the *key* in the `arch` hash whose value
// matches `host_arch`. e.g. for `arch arm: "arm64", intel: "x64"` and
// host_arch="x64", returns "intel". If no match, returns the host_arch
// itself as a sensible default.
arch_key_for_host :: proc(keys, values: []string, host_arch: string) -> string {
	for v, i in values {
		if v == host_arch {
			return keys[i]
		}
	}
	return host_arch
}

os_key_for_host :: proc(keys, values: []string, host_os: string) -> string {
	for v, i in values {
		if v == host_os {
			return keys[i]
		}
	}
	return host_os
}

// pick_sha256_for_host returns the sha256 value appropriate for the local
// arch+os. The search order is:
//   1. `<arch_key>_<os_key>:`         (e.g. `intel_linux:`)
//   2. `<arch_key>:`                 (e.g. `intel:`)
//   3. `<os_key>:`                   (e.g. `linux:`)
//   4. `<host_arch>_<host_os>:`      (e.g. `x64_linux:`)
//   5. The first quoted string in any `sha256` directive.
// If nothing is found, returns "".
pick_sha256_for_host :: proc(src, arch_key, os_key: string, host: Cask_Host) -> string {
	// candidates is a slice literal whose elements are fmt.tprintf strings
	// from the temp allocator; we must NOT call `delete` on the slice
	// itself (it's not a heap allocation) and the strings are managed by
	// the temp allocator so they don't need explicit cleanup.
	candidates := []string{
		fmt.tprintf("%s_%s:", arch_key, os_key),
		fmt.tprintf("%s:", arch_key),
		fmt.tprintf("%s:", os_key),
		fmt.tprintf("%s_%s:", host.arch, host.os),
	}

	for cand in candidates {
		if v := find_sha256_value_for_key(src, cand); len(v) > 0 {
			return v
		}
	}
	// Fallback: first quoted string in any `sha256 ...` directive.
	return extract_cask_string_field(src, "sha256")
}

// find_sha256_value_for_key scans the entire source for `sha256 ... <key>
// "value"` and returns the value. Multi-line sha256 statements are handled
// by stripping newlines and treating the whole statement as one logical
// line for the search.
find_sha256_value_for_key :: proc(src, key: string) -> string {
	// Find every `sha256` directive and check the keys in the statement.
	lines := strings.split(src, "\n", context.temp_allocator)
	defer delete(lines)
	in_sha256 := false
	stmt := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&stmt)
	for line in lines {
		trimmed := strings.trim_space(line)
		if in_sha256 {
			// Continue appending until we hit a line that doesn't end with
			// a comma (the statement is finished).
			strings.write_string(&stmt, " ")
			strings.write_string(&stmt, trimmed)
			if !strings.has_suffix(trimmed, ",") {
				body := strings.to_string(stmt)
				if idx := strings.index(body, key); idx >= 0 {
					after := body[idx + len(key):]
					// Skip whitespace and `=>` (Ruby hash rocket), look
					// for the quoted value.
					if val, _ := read_first_quoted(after); len(val) > 0 {
						return val
					}
				}
				strings.builder_reset(&stmt)
				in_sha256 = false
			}
			continue
		}
		if strings.has_prefix(trimmed, "sha256 ") || trimmed == "sha256" {
			in_sha256 = true
			strings.builder_reset(&stmt)
			strings.write_string(&stmt, trimmed)
		}
	}
	return ""
}

// extract_binary_and_artifact_directives parses `binary` and `artifact`
// directives in the source. Returns heap-allocated slices owned by the
// caller.
extract_binary_and_artifact_directives :: proc(
	src: string,
	binaries: ^[dynamic]string,
	artifact_sources: ^[dynamic]string,
	artifact_targets: ^[dynamic]string,
) {
	lines := strings.split(src, "\n", context.temp_allocator)
	defer delete(lines)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 {
			continue
		}
		// `binary "path"` — single line, no continuation.
		if strings.has_prefix(trimmed, "binary ") || trimmed == "binary" {
			rest := strings.trim_space(trimmed[len("binary"):])
			if len(rest) > 0 {
				val, _ := read_first_quoted(rest)
				if len(val) > 0 {
					append(binaries, strings.clone(val, context.allocator))
				}
			}
			continue
		}
		// `bash_completion "..."`, `zsh_completion "..."`, etc. — skip.
		if strings.has_prefix(trimmed, "bash_completion") ||
		   strings.has_prefix(trimmed, "zsh_completion") ||
		   strings.has_prefix(trimmed, "fish_completion") {
			continue
		}
		if strings.has_prefix(trimmed, "artifact ") || trimmed == "artifact" {
			rest := strings.trim_space(trimmed[len("artifact"):])
			path, after_idx := read_first_quoted(rest)
			if len(path) > 0 {
				target := extract_target_from_hash(rest[after_idx:])
				append(artifact_sources, strings.clone(path, context.allocator))
				append(artifact_targets, strings.clone(target, context.allocator))
			}
			continue
		}
	}
}

// extract_target_from_hash looks for `target: "value"` in a string that
// follows an artifact's source path. Returns "" if not present.
extract_target_from_hash :: proc(s: string) -> string {
	idx := strings.index(s, "target")
	if idx < 0 {
		return ""
	}
	// Find the next `:` after `target`.
	for j := idx + len("target"); j < len(s); j += 1 {
		if s[j] == ':' {
			for k := j + 1; k < len(s); k += 1 {
				if s[k] == '"' || s[k] == '\'' {
					val, _ := read_quoted_string(s, k)
					return val
				}
			}
			return ""
		}
		if !(s[j] == ' ' || s[j] == '\t') {
			return ""
		}
	}
	return ""
}

// interpolate_version substitutes `#{version}` occurrences in s with the
// provided version string. Unknown `#{...}` expressions are left intact.
interpolate_version :: proc(s, version: string) -> string {
	marker := "#{version}"
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if i + len(marker) <= len(s) && strings.has_prefix(s[i:], marker) {
			strings.write_string(&b, version)
			i += len(marker)
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.clone(strings.to_string(b), context.allocator)
}

// read_quoted_string reads a quoted string starting at position `start`.
// Returns the value (without surrounding quotes) and the index of the
// character after the closing quote. Returns "", -1 if the start position
// is not a quote.
read_quoted_string :: proc(src: string, start: int) -> (string, int) {
	if start >= len(src) {
		return "", -1
	}
	delim := src[start]
	if delim != '"' && delim != '\'' {
		return "", -1
	}
	b := strings.builder_make(context.temp_allocator)
	for j := start + 1; j < len(src); j += 1 {
		c := src[j]
		if c == '\\' && j + 1 < len(src) {
			// Preserve the escaped character; we don't interpret Ruby
			// escape sequences in detail.
			strings.write_byte(&b, c)
			strings.write_byte(&b, src[j + 1])
			j += 1
			continue
		}
		if c == delim {
			return strings.clone(strings.to_string(b), context.allocator), j + 1
		}
		// Detect interpolation `#{...}` and resolve `version`; leave
		// other interpolations literal.
		if c == '#' && j + 1 < len(src) && src[j + 1] == '{' {
			end := strings.index(src[j + 2:], "}")
			if end >= 0 {
				name := src[j + 2:j + 2 + end]
				if name == "version" {
					// Caller should have interpolated already; leave
					// the literal text for visibility.
				}
				strings.write_string(&b, "#{")
				strings.write_string(&b, name)
				strings.write_byte(&b, '}')
				j = j + 2 + end
				continue
			}
		}
		strings.write_byte(&b, c)
	}
	return strings.clone(strings.to_string(b), context.allocator), -1
}

// read_first_quoted returns the first quoted string in `s` and the index
// immediately after it. Returns "", 0 if none found.
read_first_quoted :: proc(s: string) -> (string, int) {
	for i := 0; i < len(s); i += 1 {
		if s[i] == '"' || s[i] == '\'' {
			return read_quoted_string(s, i)
		}
	}
	return "", 0
}

// read_bareword reads a Ruby bareword identifier starting at `start`.
// Returns the identifier and the index immediately after it, or "", -1
// if the start is not an identifier character.
read_bareword :: proc(src: string, start: int) -> (string, int) {
	if start >= len(src) || !is_ident_start(src[start]) {
		return "", -1
	}
	b := strings.builder_make(context.temp_allocator)
	for j := start; j < len(src); j += 1 {
		c := src[j]
		if is_ident_cont(c) {
			strings.write_byte(&b, c)
		} else {
			return strings.clone(strings.to_string(b), context.allocator), j
		}
	}
	return strings.clone(strings.to_string(b), context.allocator), len(src)
}

is_ident_start :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

is_ident_cont :: proc(c: byte) -> bool {
	return is_ident_start(c) || (c >= '0' && c <= '9') || c == '?' || c == '!'
}
