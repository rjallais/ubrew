package tap

import "core:fmt"
import "core:strings"

// Ruby_Formula represents the subset of Homebrew's Ruby formula DSL we parse
// out of `Formula/<name>.rb` files in tapped repositories.
Ruby_Formula :: struct {
	class_name:    string, // e.g. "Nanobrew"
	name:          string, // e.g. "nanobrew" (class_name lowercased)
	desc:          string,
	homepage:      string,
	license:       string,
	version:       string,
	// Linux/macOS specific fields. Only one set is populated based on the
	// platform that parses the formula.
	url:           string,
	sha256:        string,
	binaries:      [dynamic]string, // install targets passed to `bin.install "..."`
	// Runtime dependencies extracted from `depends_on "..."` lines.
	dependencies:  [dynamic]string,
	// Build-only dependencies (`:build` flag).
	build_deps:    [dynamic]string,
	// Linux-specific flag. If true, this formula only builds on macOS.
	macos_only:    bool,
}

destroy_ruby_formula :: proc(f: Ruby_Formula) {
	delete(f.class_name)
	delete(f.name)
	delete(f.desc)
	delete(f.homepage)
	delete(f.license)
	delete(f.version)
	delete(f.url)
	delete(f.sha256)
	nb := len(f.binaries)
	for i := 0; i < nb; i += 1 {
		delete(f.binaries[i])
	}
	delete(f.binaries)
	nd := len(f.dependencies)
	for i := 0; i < nd; i += 1 {
		delete(f.dependencies[i])
	}
	delete(f.dependencies)
	nbd := len(f.build_deps)
	for i := 0; i < nbd; i += 1 {
		delete(f.build_deps[i])
	}
	delete(f.build_deps)
}

// Platform indicates which OS block the parser should prefer when selecting
// url/sha256 from formula files with multiple platform blocks.
Platform :: enum {
	Linux,
	macOS,
}

// strip_ruby_comments removes Ruby comment lines and inline comments. It
// operates on the source text and returns a new string. Quoted strings are
// preserved so that '#' characters inside strings are not stripped.
strip_ruby_comments :: proc(src: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	in_string := false
	string_delim := byte(0)
	for i < len(src) {
		c := src[i]
		if in_string {
			strings.write_byte(&b, c)
			if c == '\\' && i + 1 < len(src) {
				strings.write_byte(&b, src[i + 1])
				i += 2
				continue
			}
			if c == string_delim {
				in_string = false
			}
			i += 1
			continue
		}
		if c == '"' || c == '\'' {
			in_string = true
			string_delim = c
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		// Strip "#" comments to end of line (not inside strings).
		if c == '#' {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
			continue
		}
		strings.write_byte(&b, c)
		i += 1
	}
	// `strings.to_string` returns a view into the builder's buffer, which
	// is on the temp allocator and is invalidated when this procedure
	// returns. Clone the result into context.allocator so the caller can
	// keep the returned string.
	return strings.clone(strings.to_string(b), context.allocator)
}

// extract_string_field finds a top-level Ruby call of the form
// `key "value"` and returns the value. Only the first match is returned.
// Quoted strings may contain escaped characters. Returns "" if not found.
extract_string_field :: proc(src, key: string) -> string {
	// Match the key as a Ruby method call: at start-of-line or after
	// whitespace, then key, then optional whitespace, then a quoted string.
	lines := strings.split(src, "\n", context.temp_allocator)
	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) < len(key) {
			continue
		}
		if !strings.has_prefix(trimmed, key) {
			continue
		}
		after := strings.trim_space(trimmed[len(key):])
		// Accept "key value", "key(...)", or "key" (no value). We look for
		// the first quote anywhere in `after`; if present, extract the value.
		if len(after) == 0 {
			continue
		}
		if after[0] == ' ' || after[0] == '"' || after[0] == '\'' {
			// Find first quote in the rest of the line
			quote_idx := -1
			for j := 0; j < len(after); j += 1 {
				if after[j] == '"' || after[j] == '\'' {
					quote_idx = j
					break
				}
			}
			if quote_idx < 0 {
				continue
			}
			delim := after[quote_idx]
			start := quote_idx + 1
			value_b := strings.builder_make(context.temp_allocator)
			j := start
			for j < len(after) {
				ch := after[j]
				if ch == '\\' && j + 1 < len(after) {
					// Skip escape, copy the escaped char as-is for our uses
					strings.write_byte(&value_b, after[j + 1])
					j += 2
					continue
				}
				if ch == delim {
					break
				}
				strings.write_byte(&value_b, ch)
				j += 1
			}
			return strings.clone(strings.to_string(value_b), context.allocator)
		}
	}
	return ""
}

// find_block_range returns the start (after "do") and end (before "end") of
// the first occurrence of `block_name do ... end`. Returns -1, -1 if not
// found. Handles nested `do...end` blocks correctly by tracking depth.
find_block_range :: proc(src, block_name: string) -> (start, end: int) {
	idx := strings.index(src, block_name)
	if idx < 0 {
		return -1, -1
	}
	// Make sure this is a method call: must be followed by whitespace or 'd'
	// (for "do").
	if idx + len(block_name) < len(src) {
		next := src[idx + len(block_name)]
		if next != ' ' && next != '\t' && next != 'd' {
			// Recurse into the rest of the string; the recursive call returns
			// indices relative to the sliced `src`, so add the slice offset
			// back to translate them into the original `src`'s frame.
			s, e := find_block_range(src[idx + 1:], block_name)
			if s < 0 {
				return -1, -1
			}
			return s + idx + 1, e + idx + 1
		}
	}

	do_idx := strings.index(src[idx:], " do")
	if do_idx < 0 {
		do_idx = strings.index(src[idx:], " do |")
	}
	if do_idx < 0 {
		return -1, -1
	}
	body_start := idx + do_idx + 3
	// Skip past the optional "|args|" block parameter
	if body_start < len(src) && src[body_start] == ' ' && body_start + 1 < len(src) && src[body_start + 1] == '|' {
		// The opening '|' is at body_start+1; search for the closing '|'
		// starting AFTER it (i.e. at body_start+2).
		pipe_end := strings.index(src[body_start + 2:], "|")
		if pipe_end < 0 {
			return -1, -1
		}
		body_start = body_start + pipe_end + 3
	}

	depth := 1
	i := body_start
	// We need to skip strings to avoid matching "do" or "end" inside them.
	in_string := false
	string_delim := byte(0)
	for i < len(src) {
		c := src[i]
		if in_string {
			if c == '\\' && i + 1 < len(src) {
				i += 2
				continue
			}
			if c == string_delim {
				in_string = false
			}
			i += 1
			continue
		}
		if c == '"' || c == '\'' {
			in_string = true
			string_delim = c
			i += 1
			continue
		}
		// Match " do" with surrounding word-boundary semantics
		if c == 'd' && i + 1 < len(src) && src[i + 1] == 'o' {
			// Check that "do" is preceded by whitespace/start.
			prev_ok := i == 0 || src[i - 1] == ' ' || src[i - 1] == '\t' || src[i - 1] == '\n'
			// Check that "do" is followed by whitespace/newline or "|" (block args).
			next_idx := i + 2
			next_ok := next_idx >= len(src) || src[next_idx] == ' ' || src[next_idx] == '\t' ||
				src[next_idx] == '\n' || src[next_idx] == '|'
			if prev_ok && next_ok {
				depth += 1
				i += 2
				continue
			}
		}
		if c == 'e' && i + 2 < len(src) && src[i + 1] == 'n' && src[i + 2] == 'd' {
			prev_ok := i == 0 || src[i - 1] == ' ' || src[i - 1] == '\t' || src[i - 1] == '\n'
			next_idx := i + 3
			next_ok := next_idx >= len(src) || src[next_idx] == ' ' || src[next_idx] == '\t' ||
				src[next_idx] == '\n' || src[next_idx] == '.' || src[next_idx] == ','
			if prev_ok && next_ok {
				depth -= 1
				if depth == 0 {
					return body_start, i
				}
				i += 3
				continue
			}
		}
		i += 1
	}
	return -1, -1
}

// find_method_block_range handles the pattern:
// `method_name "value" do ... end`
// Returns the start (after the "do") and end (before the "end").
find_method_block_range :: proc(src, method_name: string) -> (start, end: int) {
	idx := strings.index(src, method_name)
	if idx < 0 {
		return -1, -1
	}
	// Skip until we hit "do"
	do_idx := strings.index(src[idx:], " do")
	if do_idx < 0 {
		return -1, -1
	}
	body_start := idx + do_idx + 3
	depth := 1
	i := body_start
	in_string := false
	string_delim := byte(0)
	for i < len(src) {
		c := src[i]
		if in_string {
			if c == '\\' && i + 1 < len(src) {
				i += 2
				continue
			}
			if c == string_delim {
				in_string = false
			}
			i += 1
			continue
		}
		if c == '"' || c == '\'' {
			in_string = true
			string_delim = c
			i += 1
			continue
		}
		if c == 'd' && i + 1 < len(src) && src[i + 1] == 'o' {
			prev_ok := i == 0 || src[i - 1] == ' ' || src[i - 1] == '\t' || src[i - 1] == '\n'
			next_idx := i + 2
			next_ok := next_idx >= len(src) || src[next_idx] == ' ' || src[next_idx] == '\t' ||
				src[next_idx] == '\n' || src[next_idx] == '|'
			if prev_ok && next_ok {
				depth += 1
				i += 2
				continue
			}
		}
		if c == 'e' && i + 2 < len(src) && src[i + 1] == 'n' && src[i + 2] == 'd' {
			prev_ok := i == 0 || src[i - 1] == ' ' || src[i - 1] == '\t' || src[i - 1] == '\n'
			next_idx := i + 3
			next_ok := next_idx >= len(src) || src[next_idx] == ' ' || src[next_idx] == '\t' ||
				src[next_idx] == '\n' || src[next_idx] == '.' || src[next_idx] == ','
			if prev_ok && next_ok {
				depth -= 1
				if depth == 0 {
					return body_start, i
				}
				i += 3
				continue
			}
		}
		i += 1
	}
	return -1, -1
}

// extract_class_name returns the class name declared in the formula header
// (e.g. "Nanobrew" from "class Nanobrew < Formula").
extract_class_name :: proc(src: string) -> string {
	idx := strings.index(src, "class ")
	if idx < 0 {
		return ""
	}
	rest := src[idx + len("class "):]
	end := len(rest)
	for j := 0; j < len(rest); j += 1 {
		c := rest[j]
		if c == ' ' || c == '\t' || c == '<' || c == '\n' || c == '\r' {
			end = j
			break
		}
	}
	if end == 0 {
		return ""
	}
	return strings.clone(rest[:end], context.allocator)
}


// Line_Scan holds the per-line state used by scan_ruby_lines. The state is
// reset as `do`/`end` blocks open and close, so platform conditionals and
// test blocks are correctly isolated.
Line_Scan :: struct {
	// How deeply nested we are inside `do`/`end` blocks overall. Starts at 0.
	block_depth: int,
	// block_depth at which the current `test do ... end` block was entered.
	// Zero means "not currently inside a test block". Test blocks contain
	// arbitrary Ruby (assert_match, shell_output, etc.) and are skipped
	// wholesale to avoid false matches on strings like `--version`.
	test_depth:  int,
	// If true, we're inside a platform block that does not match the current
	// host (e.g. `on_macos` while building on Linux). Lines in this region
	// are ignored for url/sha256/depends_on extraction.
	platform_skip: bool,
	// block_depth at which the current platform-skip region was entered. We
	// use it to know when to clear platform_skip on `end`.
	platform_depth: int,
}

// effective_url returns the url captured by the most recent applicable
// platform block, or the original top-level url if no block matched.
scan_effective_url :: proc(s: ^Line_Scan, line, top_url: string) -> (new_url: string, updated: bool) {
	if s.platform_skip { return "", false }
	if s.test_depth > 0 { return "", false }
	// If the line declares `url "..."` while we're inside a matching
	// platform block, we accept the override.
	if strings.has_prefix(strings.trim_space(line), "url") {
		val := extract_string_field(line, "url")
		if len(val) > 0 {
			return val, true
		}
	}
	_ = top_url
	return "", false
}

// extract_depends_on parses a single `depends_on "name"` (or
// `depends_on "name" => :build`) line. Returns the dependency name, whether
// it's a :build dep, and ok. If the line is not a depends_on statement, ok
// is false.
extract_depends_on :: proc(line: string) -> (name: string, is_build: bool, ok: bool) {
	trimmed := strings.trim_space(line)
	if !strings.has_prefix(trimmed, "depends_on") {
		return "", false, false
	}
	// Find the first quoted string after "depends_on"
	idx := strings.index(trimmed, "depends_on")
	if idx < 0 { return "", false, false }
	rest := trimmed[idx + len("depends_on"):]
	// Skip optional `(`
	if len(rest) > 0 && rest[0] == '(' {
		rest = rest[1:]
	}
	// Find first quote
	q := -1
	for j := 0; j < len(rest); j += 1 {
		if rest[j] == '"' || rest[j] == '\'' {
			q = j
			break
		}
	}
	if q < 0 { return "", false, false }
	delim := rest[q]
	start := q + 1
	// Check for skip flags BEFORE allocating, to avoid a leak on the
	// early-return path. :optional / :recommended deps are filtered out.
	if strings.contains(trimmed, ":optional") || strings.contains(trimmed, ":recommended") {
		// Caller should treat as "skip" - return ok=true but empty name
		return "", false, true
	}
	// Read until closing quote
	b := strings.builder_make(context.temp_allocator)
	j := start
	for j < len(rest) {
		ch := rest[j]
		if ch == '\\' && j + 1 < len(rest) {
			strings.write_byte(&b, rest[j + 1])
			j += 2
			continue
		}
		if ch == delim { break }
		strings.write_byte(&b, ch)
		j += 1
	}
	name = strings.clone(strings.to_string(b), context.allocator)
	// Check for optional :build flag in the rest of the line
	if strings.contains(trimmed, ":build") {
		is_build = true
	}
	if len(name) == 0 {
		return "", false, false
	}
	return name, is_build, true
}

// extract_bin_install_names parses a single `bin.install "a", "b"` or
// `bin.install "src" => "dst"` line. Returns up to N install targets. The
// returned slice is heap-allocated; caller frees.
extract_bin_install_names :: proc(line: string) -> [dynamic]string {
	out := make([dynamic]string, context.allocator)
	trimmed := strings.trim_space(line)
	if !strings.has_prefix(trimmed, "bin.install") {
		return out
	}
	rest := trimmed[len("bin.install"):]
	// Skip optional `(` and whitespace
	for len(rest) > 0 && (rest[0] == '(' || rest[0] == ' ' || rest[0] == '\t') {
		rest = rest[1:]
	}
	// Read quoted strings, handling `,` separators and `=>` rename markers.
	for len(rest) > 0 {
		// Skip leading whitespace/comma
		for len(rest) > 0 && (rest[0] == ' ' || rest[0] == '\t' || rest[0] == ',') {
			rest = rest[1:]
		}
		if len(rest) == 0 { break }
		if rest[0] != '"' && rest[0] != '\'' { break }
		delim := rest[0]
		b := strings.builder_make(context.temp_allocator)
		j := 1
		for j < len(rest) {
			ch := rest[j]
			if ch == '\\' && j + 1 < len(rest) {
				strings.write_byte(&b, rest[j + 1])
				j += 2
				continue
			}
			if ch == delim { break }
			strings.write_byte(&b, ch)
			j += 1
		}
		first_name := strings.to_string(b)
		// Advance past closing quote
		if j < len(rest) { j += 1 }
		// Skip whitespace
		for j < len(rest) && (rest[j] == ' ' || rest[j] == '\t') {
			j += 1
		}
		// Check for `=>` rename
		if j + 1 < len(rest) && rest[j] == '=' && rest[j + 1] == '>' {
			// Skip the `=>` and whitespace
			j += 2
			for j < len(rest) && (rest[j] == ' ' || rest[j] == '\t') {
				j += 1
			}
			// Read the destination name (the symlink target)
			if j < len(rest) && (rest[j] == '"' || rest[j] == '\'') {
				d_delim := rest[j]
				jb := strings.builder_make(context.temp_allocator)
				jj := j + 1
				for jj < len(rest) {
					ch := rest[jj]
					if ch == '\\' && jj + 1 < len(rest) {
						strings.write_byte(&jb, rest[jj + 1])
						jj += 2
						continue
					}
					if ch == d_delim { break }
					strings.write_byte(&jb, ch)
					jj += 1
				}
				dst := strings.to_string(jb)
				if len(dst) > 0 {
					append(&out, strings.clone(dst, context.allocator))
				}
				if jj < len(rest) { jj += 1 }
				j = jj
			}
		} else {
			// No rename; use the first name as the install target
			if len(first_name) > 0 {
				append(&out, strings.clone(first_name, context.allocator))
			}
		}
		// Advance rest
		rest = rest[j:]
	}
	return out
}

// is_block_opener returns true if the trimmed line is a Ruby block opener
// (ends with " do" or is just "do"). It does NOT match methods that take a
// `do` block argument like `foo do |x|` -- those are handled by the parser
// only if they end with " do" too.
is_block_opener :: proc(trimmed: string) -> bool {
	if trimmed == "do" { return true }
	if strings.has_suffix(trimmed, " do") { return true }
	if strings.has_suffix(trimmed, " do |") { return true }
	// " do |x|" style
	return false
}

// is_only_end reports whether a trimmed line is just `end` (possibly with
// trailing comment already stripped).
is_only_end :: proc(trimmed: string) -> bool {
	return trimmed == "end"
}

// is_test_block reports whether a trimmed line is a `test do` opener.
is_test_block :: proc(trimmed: string) -> bool {
	return trimmed == "test do" || strings.has_prefix(trimmed, "test do ")
}

// parse_ruby_formula extracts a Ruby_Formula from a Homebrew Ruby formula
// file. It uses a single-pass line scanner that respects block nesting and
// skip flags (test blocks, wrong-platform blocks), so that:
//
//   - `test do ... end` contents are ignored (they can contain arbitrary
//     Ruby like `assert_match("--version", ...)` that would otherwise cause
//     false matches on directive-like strings).
//   - `on_macos`/`on_linux`/`on_arm`/`on_intel` blocks are honored: the
//     url/sha256 from the matching block wins; wrong-platform blocks are
//     skipped.
//   - `depends_on` lines outside of skipped regions are captured.
//   - `bin.install "..."` directives are captured only from `def install
//     ... end` blocks (so test-block code can't poison the binary list).
parse_ruby_formula :: proc(src: string, platform: Platform) -> (f: Ruby_Formula, ok: bool) {
	clean := strip_ruby_comments(src)
	defer delete(clean)

	class_name := extract_class_name(clean)
	if len(class_name) == 0 {
		return f, false
	}
	// extract_class_name already returns a heap-allocated string, so we
	// take ownership directly rather than cloning again.
	f.class_name = class_name
	// Capture the lower-cased form in a temp-allocated string, then clone it
	// into the persisted field. `strings.to_lower` allocates from the
	// passed-in allocator; if we used context.allocator and then strings.clone
	// it, the original allocation would be leaked.
	lower_name := strings.to_lower(class_name, context.temp_allocator)
	f.name = strings.clone(lower_name, context.allocator)

	// Determine the host architecture name used to evaluate `on_arm` /
	// `on_intel` blocks. We currently only build on Linux x86_64, so this
	// is a stub; expand when targeting more architectures.
	host_arch_is_arm := false
	host_os_is_linux := platform == .Linux

	// Single-pass line scanner.
	state := Line_Scan{}
	in_install := false
	install_depth := 0
	// Track which `on_<x>` blocks have been seen at the top level, for the
	// macos-only heuristic below.
	seen_on_linux := false
	seen_on_macos := false

	lines := strings.split(clean, "\n", context.temp_allocator)
	for raw_line in lines {
		trimmed := strings.trim_space(raw_line)

		// If we're inside a test block, skip everything until it closes.
		if state.test_depth > 0 {
			if is_only_end(trimmed) {
				state.block_depth -= 1
				if state.block_depth < state.test_depth {
					state.test_depth = 0
				}
			} else if is_block_opener(trimmed) {
				state.block_depth += 1
			}
			continue
		}

		// Detect a `test do` opener before we bump block_depth, so we set
		// test_depth to the new outer depth.
		if is_test_block(trimmed) {
			state.block_depth += 1
			state.test_depth = state.block_depth
			continue
		}

		// `def install` opener - mark that bin.install extraction is active.
		if strings.has_prefix(trimmed, "def install") {
			in_install = true
			install_depth = state.block_depth + 1
		}

		// Track `on_<x>` block openers for macos-only detection.
		if strings.has_prefix(trimmed, "on_linux") && is_block_opener(trimmed) {
			seen_on_linux = true
			state.block_depth += 1
			if !host_os_is_linux {
				state.platform_skip = true
				state.platform_depth = state.block_depth
			}
			continue
		}
		if strings.has_prefix(trimmed, "on_macos") && is_block_opener(trimmed) {
			seen_on_macos = true
			state.block_depth += 1
			if host_os_is_linux {
				state.platform_skip = true
				state.platform_depth = state.block_depth
			}
			continue
		}
		if strings.has_prefix(trimmed, "on_arm") && is_block_opener(trimmed) {
			state.block_depth += 1
			if !host_arch_is_arm {
				state.platform_skip = true
				state.platform_depth = state.block_depth
			}
			continue
		}
		if strings.has_prefix(trimmed, "on_intel") && is_block_opener(trimmed) {
			state.block_depth += 1
			if host_arch_is_arm {
				state.platform_skip = true
				state.platform_depth = state.block_depth
			}
			continue
		}

		// Track other `do` block openers for depth accounting.
		if is_block_opener(trimmed) && !state.platform_skip {
			state.block_depth += 1
		} else if is_block_opener(trimmed) {
			// Still inside a platform-skip block; bump depth so `end`
			// matches correctly, but don't process the line's contents.
			state.block_depth += 1
			continue
		}

		// Handle `end` for the outermost (non-platform) blocks.
		if is_only_end(trimmed) {
			state.block_depth -= 1
			// Close out of `def install` if we drop below its depth.
			if in_install && state.block_depth < install_depth {
				in_install = false
			}
			// Clear platform_skip if we just closed the platform block.
			if state.platform_skip && state.block_depth < state.platform_depth {
				state.platform_skip = false
			}
			continue
		}

		// Skip the rest of processing for lines inside wrong-platform
		// blocks. This is the critical false-positive guard.
		if state.platform_skip {
			continue
		}

		// Top-level / matching-block field extraction. Only accept a value
		// if it isn't already set, EXCEPT for url/sha256 inside a matching
		// platform block which should override the top-level value.
		// Note: extract_string_field returns heap-allocated strings, so we
		// assign them directly (no clone) to avoid leaks. For url/sha256 we
		// delete the previous value before reassigning.
		if len(f.desc) == 0 {
			if v := extract_string_field(trimmed, "desc"); len(v) > 0 {
				f.desc = v
			}
		}
		if len(f.homepage) == 0 {
			if v := extract_string_field(trimmed, "homepage"); len(v) > 0 {
				f.homepage = v
			}
		}
		if len(f.license) == 0 {
			if v := extract_string_field(trimmed, "license"); len(v) > 0 {
				f.license = v
			}
		}
		if len(f.version) == 0 {
			if v := extract_string_field(trimmed, "version"); len(v) > 0 {
				f.version = v
			}
		}
		// url/sha256: always update, so platform-block overrides win.
		if v := extract_string_field(trimmed, "url"); len(v) > 0 {
			delete(f.url)
			f.url = v
		}
		if v := extract_string_field(trimmed, "sha256"); len(v) > 0 {
			delete(f.sha256)
			f.sha256 = v
		}

		// `depends_on "name"` (optionally => :build / :optional). The
		// returned `name` is heap-allocated; transfer ownership directly
		// into the dynamic array (no clone, no double-free).
		if strings.has_prefix(trimmed, "depends_on") {
			name, is_build, dep_ok := extract_depends_on(trimmed)
			if dep_ok && len(name) > 0 {
				if is_build {
					append(&f.build_deps, name)
				} else {
					append(&f.dependencies, name)
				}
			} else if dep_ok {
				// Optional/recommended - signal was consumed but we own no name.
				_ = name
			}
		}

		// `bin.install "..."` - only inside `def install` blocks. The returned
		// names are heap-allocated; transfer ownership directly into
		// f.binaries. The temporary dynamic-array backing buffer is freed
		// with `delete(names)`, but the strings themselves are now owned by
		// f.binaries.
		if in_install && strings.has_prefix(trimmed, "bin.install") {
			names := extract_bin_install_names(trimmed)
			for n in names {
				append(&f.binaries, n)
			}
			delete(names)
		}
	}

	// If the formula has no explicit `version "..."` field, infer the version
	// from the source URL. Homebrew formulae often rely on the URL pattern
	// (e.g. `pkgm-0.12.2.tgz`, `v0.4.0/...`, `archive/refs/tags/v1.8.1.tar.gz`).
	if len(f.version) == 0 && len(f.url) > 0 {
		inferred := version_from_url(f.url)
		if len(inferred) > 0 {
			f.version = strings.clone(inferred, context.allocator)
		}
	}

	// macos-only heuristic: on Linux, if the formula has an `on_macos` block
	// but no `on_linux` block, it can only build on macOS.
	if platform == .Linux && seen_on_macos && !seen_on_linux {
		f.macos_only = true
	}

	// Sanity check: we need at least a name. The class is the source of truth.
	if len(f.name) == 0 {
		destroy_ruby_formula(f)
		return Ruby_Formula{}, false
	}

	return f, true
}

// version_from_url extracts a semver-like version (X.Y.Z with optional
// pre-release/build suffix) from a Homebrew formula's source URL. It
// recognizes the most common URL patterns:
//   - `<name>-1.2.3.tgz`         (e.g. `pkgm-0.12.2.tgz`)
//   - `<name>-v1.2.3.tar.gz`     (e.g. `mash-v0.4.0.sh`)
//   - `releases/download/v1.2.3/<name>-1.2.3.tar.xz`
//   - `archive/refs/tags/v1.2.3.tar.gz`
//
// Returns the matched version (e.g. "1.2.3") or "" if no version can be
// confidently inferred.
version_from_url :: proc(url: string) -> string {
	if len(url) == 0 {
		return ""
	}

	// Try the leaf (last path segment) first, then fall back to searching
	// the whole URL. The leaf usually contains the explicit version
	// (e.g. `pkgm-0.12.2.tgz`).
	last_slash := strings.last_index(url, "/")
	if last_slash >= 0 {
		leaf := url[last_slash + 1:]
		if v := find_version_in(leaf); len(v) > 0 {
			return v
		}
	}
	return find_version_in(url)
}

// find_version_in scans `s` for the first substring that looks like a
// semver version: optional leading "v", then digit "." digit "." digit,
// followed by an optional pre-release/build suffix of [-_.+a-zA-Z0-9].
// The first match wins. Returns "" if no match is found.
find_version_in :: proc(s: string) -> string {
	// Find the first '.' that has at least one non-'.' char before it
	// and is followed by at least one alphabetic char (file extension).
	// This identifies `.tgz`, `.tar.gz`, `.sh`, etc.
	strip_end := len(s)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '.' && i + 1 < len(s) {
			// Check that this looks like an extension (alphabetic suffix)
			// rather than part of a version (e.g. "1.2.3" has dots but
			// is followed by another digit).
			rest := s[i + 1:]
			if len(rest) > 0 && (rest[0] >= 'a' && rest[0] <= 'z' || rest[0] >= 'A' && rest[0] <= 'Z') {
				strip_end = i
				break
			}
		}
	}
	// Find the start of a version token. We need at least 3 dot-separated
	// digits (X.Y.Z) preceded by an optional "v" or non-alnum boundary.
	for i := 0; i < strip_end; i += 1 {
		c := s[i]
		// Look for the start of a version: a digit, or "v" followed by a digit.
		is_v_prefix := c == 'v' && i + 1 < strip_end && is_digit(s[i + 1])
		is_digit_start := is_digit(c)
		if !is_v_prefix && !is_digit_start {
			continue
		}
		// If this is a "v" prefix, the actual version starts at i+1.
		ver_start := is_v_prefix ? i + 1 : i
		// Must have at least 3 dot-separated numeric segments.
		if !scan_version(s, ver_start, strip_end) {
			continue
		}
		// Find the end of the version token (last char of the version or
		// its pre-release/build suffix).
		j := ver_start
		saw_digit := false
		for j < strip_end {
			ch := s[j]
			if is_digit(ch) {
				saw_digit = true
				j += 1
			} else if ch == '.' {
				j += 1
			} else if (ch == '-' || ch == '_' || ch == '+' ||
			            (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')) && saw_digit {
				// Pre-release/build separator and identifier chars.
				j += 1
			} else {
				break
			}
		}
		return strings.clone(s[ver_start:j], context.allocator)
	}
	return ""
}

// is_digit reports whether `c` is an ASCII digit.
is_digit :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

// scan_version checks that `s[ver_start..strip_end]` starts with at least
// three dot-separated numeric segments (e.g. "1.2.3").
scan_version :: proc(s: string, ver_start, strip_end: int) -> bool {
	if ver_start >= strip_end {
		return false
	}
	dot_count := 0
	i := ver_start
	for i < strip_end {
		if is_digit(s[i]) {
			i += 1
		} else if s[i] == '.' && i > ver_start && is_digit(s[i + 1] if i + 1 < strip_end else 0) {
			// Allow leading dot only after at least one digit.
			dot_count += 1
			if dot_count >= 2 {
				return true
			}
			i += 1
		} else {
			break
		}
	}
	// If we ended with two or more dots and at least 2 dots, accept.
	return dot_count >= 2 && i > ver_start + 1
}

// unquote_github_url strips the branch reference and `.git` extension from a
// GitHub URL. Returns the cleaned https URL.
unquote_github_url :: proc(url: string) -> string {
	clean := url
	if strings.has_prefix(clean, "git@github.com:") {
		clean = strings.concatenate({"https://github.com/", clean[len("git@github.com:"):]}, context.temp_allocator)
	}
	if strings.has_suffix(clean, ".git") {
		clean = clean[:len(clean) - 4]
	}
	if strings.has_suffix(clean, "/") {
		clean = clean[:len(clean) - 1]
	}
	return strings.clone(clean, context.allocator)
}
