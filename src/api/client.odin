package api

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:strings"
import "core:time"
import "../cask"
import "../formula"
import "../kernel"
import "../platform"
import "../tap"

REGISTRY_PATH :: "registry/upstream.json"
API_CACHE_DIR :: "/opt/ubrew/cache/api"
FORMULA_LIST_CACHE :: API_CACHE_DIR + "/formula.json"
CASK_LIST_CACHE :: API_CACHE_DIR + "/cask.json"
FORMULA_LIST_URL :: "https://formulae.brew.sh/api/formula.json"
CASK_LIST_URL :: "https://formulae.brew.sh/api/cask.json"

registry_mmap_parse :: proc(path: string) -> (json.Value, json.Error) {
	mf, ok := kernel.mapped_file_open(path)
	if !ok {
		return nil, .EOF
	}

	data := kernel.mapped_file_bytes(&mf)
	data_copy := make([]u8, len(data), context.allocator)
	copy(data_copy, data)
	kernel.mapped_file_close(&mf)

	val, err := json.parse(data_copy)
	// json.parse copies all string data it needs out of the input bytes;
	// the buffer is no longer needed once parsing is done. Free it eagerly
	// to avoid the ~600KB registry file living in memory for the lifetime
	// of the parsed Value.
	delete(data_copy, context.allocator)
	return val, err
}

json_string_or_empty :: proc(obj: json.Object, key: string) -> string {
    if v, ok := obj[key]; ok {
        if s, ok2 := v.(json.String); ok2 {
            return s
        }
    }
    return ""
}

json_object_or_nil :: proc(obj: json.Object, key: string) -> (out: json.Object, ok: bool) {
    if v, exists := obj[key]; exists {
        if o, ok2 := v.(json.Object); ok2 {
            return o, true
        }
    }
    return out, false
}

json_array_or_nil :: proc(obj: json.Object, key: string) -> (out: json.Array, ok: bool) {
    if v, exists := obj[key]; exists {
        if a, ok2 := v.(json.Array); ok2 {
            return a, true
        }
    }
    return out, false
}

lower_contains :: proc(haystack: string, needle_lower: string) -> bool {
	if len(needle_lower) == 0 {
		return true
	}
	if len(needle_lower) > len(haystack) {
		return false
	}

	end := len(haystack) - len(needle_lower)
	for i in 0..=end {
		matched := true
		for j in 0..<len(needle_lower) {
			c := haystack[i + j]
			if c >= 'A' && c <= 'Z' {
				c = c + 32
			}
			if c != needle_lower[j] {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

fetch_cached_api_list :: proc(url, cache_path: string) -> (data: []u8, err: os.Error) {
	if cached, read_err := os.read_entire_file(cache_path, context.allocator); read_err == nil {
		return cached, nil
	}

	_ = os.make_directory_all(API_CACHE_DIR, os.perm(0o755))

	temp_f, terr := os.create_temp_file("", "ubrew_api_list_*.json")
	if terr != nil {
		return nil, terr
	}
	// Clone the name so it remains valid after we close the file handle.
	temp_file := strings.clone(os.name(temp_f), context.allocator)
	defer delete(temp_file)
	defer os.remove(temp_file)
	defer os.close(temp_f)

	dl_args := []string{"curl", "-s", "-f", "-L", url, "-o", temp_file}
	if !platform.exec_cmd("curl", dl_args) {
		return nil, .EOF
	}

	body, read_err := os.read_entire_file(temp_file, context.allocator)
	if read_err != nil {
		return nil, read_err
	}

	if os.is_dir(API_CACHE_DIR) {
		cp_args := []string{"cp", temp_file, cache_path}
		_ = platform.exec_cmd("cp", cp_args)
	}

	return body, nil
}

json_field_string_raw :: proc(obj, key: string) -> string {
	pattern := fmt.tprintf("\"%s\"", key)
	start_search := 0
	for {
		idx := strings.index(obj[start_search:], pattern)
		if idx < 0 {
			return ""
		}
		idx += start_search

		// Verify the character before the pattern is not part of a longer key
		// (e.g. don't match "name" inside "full_name" or "username").
		if idx > 0 {
			prev := obj[idx - 1]
			if (prev >= 'a' && prev <= 'z') || (prev >= 'A' && prev <= 'Z') ||
			   (prev >= '0' && prev <= '9') || prev == '_' {
				start_search = idx + 1
				continue
			}
		}

		pos := idx + len(pattern)
		for pos < len(obj) && (obj[pos] == ' ' || obj[pos] == '\n' || obj[pos] == '\r' || obj[pos] == '\t') {
			pos += 1
		}
		if pos >= len(obj) || obj[pos] != ':' {
			start_search = idx + 1
			continue
		}
		pos += 1
		for pos < len(obj) && obj[pos] != '"' {
			pos += 1
		}
		if pos >= len(obj) {
			return ""
		}

		start := pos + 1
		pos = start
		escaped := false
		for pos < len(obj) {
			c := obj[pos]
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				return obj[start:pos]
			}
			pos += 1
		}

		return ""
	}
}

append_api_formulae_matches_fast :: proc(data: []u8, out: ^[dynamic]Formula_Search_Result, query_lower: string, limit: int) {
	text := string(data)
	depth := 0
	obj_start := 0
	in_string := false
	escaped := false

	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if in_string {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			continue
		}

		if c == '"' {
			in_string = true
			continue
		}
		if c == '{' {
			if depth == 0 {
				obj_start = i
			}
			depth += 1
			continue
		}
		if c == '}' && depth > 0 {
			depth -= 1
			if depth == 0 {
				obj := text[obj_start:i+1]
				name := json_field_string_raw(obj, "name")
				if name == "" {
					continue
				}
				desc := json_field_string_raw(obj, "desc")
				if !lower_contains(name, query_lower) && !lower_contains(desc, query_lower) {
					continue
				}
				if formula_results_contains(out^[:], name) {
					continue
				}

				append(out, Formula_Search_Result{
					name = strings.clone(name),
					desc = strings.clone(desc),
					version = strings.clone(json_field_string_raw(obj, "stable")),
				})
				if len(out^) >= limit {
					return
				}
			}
		}
	}
}

append_api_cask_matches_fast :: proc(data: []u8, out: ^[dynamic]Cask_Search_Result, query_lower: string, limit: int) {
	text := string(data)
	depth := 0
	obj_start := 0
	in_string := false
	escaped := false

	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if in_string {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			continue
		}

		if c == '"' {
			in_string = true
			continue
		}
		if c == '{' {
			if depth == 0 {
				obj_start = i
			}
			depth += 1
			continue
		}
		if c == '}' && depth > 0 {
			depth -= 1
			if depth == 0 {
				obj := text[obj_start:i+1]
				token := json_field_string_raw(obj, "token")
				if token == "" {
					continue
				}
				name := json_field_string_raw(obj, "name")
				if name == "" {
					name = token
				}
				desc := json_field_string_raw(obj, "desc")
				if !lower_contains(token, query_lower) && !lower_contains(name, query_lower) && !lower_contains(desc, query_lower) {
					continue
				}
				if cask_results_contains(out^[:], token) {
					continue
				}

				append(out, Cask_Search_Result{
					token = strings.clone(token),
					name = strings.clone(name),
					desc = strings.clone(desc),
					version = strings.clone(json_field_string_raw(obj, "version")),
				})
				if len(out^) >= limit {
					return
				}
			}
		}
	}
}

Desktop_Env_Api :: enum {
	Unknown,
	GNOME,
	KDE,
}

detect_desktop_env_api :: proc() -> Desktop_Env_Api {
	desktop := strings.to_lower(os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator), context.temp_allocator)
	session := strings.to_lower(os.get_env("XDG_SESSION_DESKTOP", context.temp_allocator), context.temp_allocator)
	de := desktop
	if len(de) == 0 {
		de = session
	}

	if strings.contains(de, "gnome") { return .GNOME }
	if strings.contains(de, "kde") || strings.contains(de, "plasma") { return .KDE }

	return .Unknown
}

registry_preferred_asset_key :: proc() -> string {
    when ODIN_OS == .Linux {
        when ODIN_ARCH == .amd64 {
            return "linux-x86_64"
        } else when ODIN_ARCH == .arm64 {
            return "linux-aarch64"
        }
        return "linux-x86_64"
    } else when ODIN_OS == .Darwin {
        when ODIN_ARCH == .amd64 {
            return "macos-x86_64"
        } else when ODIN_ARCH == .arm64 {
            return "macos-arm64"
        }
        return "macos-arm64"
    }

    return "macos-arm64"
}

registry_pick_resolved_asset :: proc(resolved_obj: json.Object) -> (url: string, sha256: string) {
    // Preferred path: resolved.assets[platform].{url, sha256}
    if assets_obj, ok := json_object_or_nil(resolved_obj, "assets"); ok {
        // Desktop environment specific wallpaper selections
        de := detect_desktop_env_api()
        if de == .KDE {
            if v, exists := assets_obj["linux-kde"]; exists {
                if ao, ok2 := v.(json.Object); ok2 {
                    return json_string_or_empty(ao, "url"), json_string_or_empty(ao, "sha256")
                }
            }
        } else if de == .GNOME {
            if v, exists := assets_obj["linux-gnome"]; exists {
                if ao, ok2 := v.(json.Object); ok2 {
                    return json_string_or_empty(ao, "url"), json_string_or_empty(ao, "sha256")
                }
            }
        }

        // Fallback wallpaper key
        if v, exists := assets_obj["linux-png"]; exists {
            if ao, ok2 := v.(json.Object); ok2 {
                return json_string_or_empty(ao, "url"), json_string_or_empty(ao, "sha256")
            }
        }

        preferred := registry_preferred_asset_key()
        fallback_keys := []string{preferred, "linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-arm64"}

        for k in fallback_keys {
            if v, exists := assets_obj[k]; exists {
                if ao, ok2 := v.(json.Object); ok2 {
                    return json_string_or_empty(ao, "url"), json_string_or_empty(ao, "sha256")
                }
            }
        }

        // Fallback: first available asset
        for _, v in assets_obj {
            if ao, ok2 := v.(json.Object); ok2 {
                return json_string_or_empty(ao, "url"), json_string_or_empty(ao, "sha256")
            }
        }
    }

    // Some records may inline url/sha256 directly under resolved
    return json_string_or_empty(resolved_obj, "url"), json_string_or_empty(resolved_obj, "sha256")
}

fetch_cask :: proc(token: string) -> (c: cask.Cask, err: json.Error) {
    c, err = fetch_cask_homebrew(token)
    if err == nil {
        return c, nil
    }

    // Third-party taps (token contains '/') are not present in the Homebrew cask API.
    // We fall back to our local verified upstream registry when the API fetch fails.
    c2, err2 := fetch_cask_registry(token)
    if err2 == nil {
        return c2, nil
    }

    return c, err
}

fetch_cask_homebrew :: proc(token: string) -> (c: cask.Cask, err: json.Error) {
    url := fmt.tprintf("https://formulae.brew.sh/api/cask/%s.json", token)

    temp_f, terr := os.create_temp_file("", "ubrew_fetch_cask_*.json")
    if terr != nil {
        return c, .EOF
    }
    // Clone the name so it remains valid after we close the file handle.
    temp_file := strings.clone(os.name(temp_f), context.allocator)
    defer delete(temp_file)
    defer os.remove(temp_file)
    defer os.close(temp_f)

    if !strings.has_prefix(url, "http://") && !strings.has_prefix(url, "https://") {
        return c, .EOF
    }

    dl_args := []string{"curl", "-s", "-f", "-L", url, "-o", temp_file}
    if !platform.exec_cmd("curl", dl_args) {
        return c, .EOF
    }

    data, read_err := os.read_entire_file(temp_file, context.allocator)
    if read_err != nil {
        return c, .EOF
    }
    defer delete(data)

    json_val, parse_err := json.parse(data)
    if parse_err != nil {
        return c, parse_err
    }
    defer json.destroy_value(json_val)

    root_obj := json_val.(json.Object)

    c.token = strings.clone(root_obj["token"].(json.String))

    if name_val, exists := root_obj["name"]; exists {
        name_arr := name_val.(json.Array)
        if len(name_arr) > 0 {
            c.name = strings.clone(name_arr[0].(json.String))
        } else {
            c.name = strings.clone(c.token)
        }
    } else {
        c.name = strings.clone(c.token)
    }

    c.version = strings.clone(root_obj["version"].(json.String))
    c.url = strings.clone(root_obj["url"].(json.String))
    c.sha256 = strings.clone(root_obj["sha256"].(json.String))
    c.homepage = strings.clone(root_obj["homepage"].(json.String))

    artifacts_list := make([dynamic]cask.Artifact)
    if arts, ok2 := root_obj["artifacts"]; ok2 {
        arts_arr := arts.(json.Array)
        for art_item in arts_arr {
            art_obj := art_item.(json.Object)

            // Check app
            if app_val, ok3 := art_obj["app"]; ok3 {
                app_arr := app_val.(json.Array)
                for app_name in app_arr {
                    append(&artifacts_list, cask.App_Artifact{name = strings.clone(app_name.(json.String))})
                }
            }
            // Check font
            if font_val, ok3 := art_obj["font"]; ok3 {
                font_arr := font_val.(json.Array)
                for font_name in font_arr {
                    append(&artifacts_list, cask.Font_Artifact{name = strings.clone(font_name.(json.String))})
                }
            }
            // Check binary
            if bin_val, ok3 := art_obj["binary"]; ok3 {
                bin_arr := bin_val.(json.Array)
                if len(bin_arr) > 0 {
                    if src_str, ok4 := bin_arr[0].(json.String); ok4 {
                        src := strings.clone(src_str)
                        target := src
                        if len(bin_arr) > 1 {
                            if obj, ok5 := bin_arr[1].(json.Object); ok5 {
                                if t, ok6 := obj["target"]; ok6 {
                                    target = strings.clone(t.(json.String))
                                }
                            }
                        }
                        append(&artifacts_list, cask.Binary_Artifact{source = src, target = target})
                    }
                }
            }
        }
    }

    c.artifacts = artifacts_list[:]
    return c, nil
}

fetch_cask_registry :: proc(token: string) -> (c: cask.Cask, err: json.Error) {
	json_val, parse_err := registry_mmap_parse(REGISTRY_PATH)
	if parse_err != nil {
		return c, parse_err
	}
	defer json.destroy_value(json_val)

    root_obj := json_val.(json.Object)
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return c, .EOF
    }

    for rec_item in records_arr {
        rec_obj := rec_item.(json.Object)
        if json_string_or_empty(rec_obj, "kind") != "cask" {
            continue
        }
        rec_token := json_string_or_empty(rec_obj, "token")
        match := false
        if rec_token == token {
            match = true
        } else if !strings.contains(token, "/") {
            suffix := fmt.tprintf("/%s", token)
            if strings.has_suffix(rec_token, suffix) {
                match = true
            }
        }
        if !match {
            continue
        }

        c.token = strings.clone(rec_token)

        name := json_string_or_empty(rec_obj, "name")
        if name == "" {
            c.name = strings.clone(rec_token)
        } else {
            c.name = strings.clone(name)
        }

        c.homepage = strings.clone(json_string_or_empty(rec_obj, "homepage"))

        if resolved_obj, ok2 := json_object_or_nil(rec_obj, "resolved"); ok2 {
            c.version = strings.clone(json_string_or_empty(resolved_obj, "version"))
            url, sha := registry_pick_resolved_asset(resolved_obj)
            c.url = strings.clone(url)
            c.sha256 = strings.clone(sha)
        }

        artifacts_list := make([dynamic]cask.Artifact)
        if arts_arr, ok2 := json_array_or_nil(rec_obj, "artifacts"); ok2 {
            for art_item in arts_arr {
                art_obj := art_item.(json.Object)
                typ := json_string_or_empty(art_obj, "type")
                path := json_string_or_empty(art_obj, "path")

		switch typ {
		case "app":
			append(&artifacts_list, cask.App_Artifact{name = strings.clone(path)})
		case "font":
			append(&artifacts_list, cask.Font_Artifact{name = strings.clone(path)})
		case "binary":
			tgt := json_string_or_empty(art_obj, "target")
			if tgt == "" {
				tgt = path
			}
			append(&artifacts_list, cask.Binary_Artifact{source = strings.clone(path), target = strings.clone(tgt)})
		case "wallpaper":
			glob := json_string_or_empty(art_obj, "glob")
			if glob == "" {
				glob = path
			}
			append(&artifacts_list, cask.Wallpaper_Artifact{glob = strings.clone(glob)})
		case "appimage":
			src := strings.clone(path)
			tgt_raw := json_string_or_empty(art_obj, "target")
			tgt := tgt_raw != "" ? strings.clone(tgt_raw) : strings.clone(path)
			append(&artifacts_list, cask.AppImage_Artifact{source = src, target = tgt})
		case "artifact":
			src := json_string_or_empty(art_obj, "source")
			if src == "" {
				src = json_string_or_empty(art_obj, "path")
			}
			tgt := json_string_or_empty(art_obj, "target")
			if tgt == "" {
				tgt = json_string_or_empty(art_obj, "path")
			}
			append(&artifacts_list, cask.Generic_Artifact{source = strings.clone(src), target = strings.clone(tgt)})
		}
            }
        }

        c.artifacts = artifacts_list[:]
        return c, nil
    }

    return c, .EOF
}

destroy_cask :: proc(c: cask.Cask) {
    delete(c.token)
    delete(c.name)
    delete(c.version)
    delete(c.url)
    delete(c.sha256)
    delete(c.homepage)
    for art in c.artifacts {
	switch a in art {
	case cask.App_Artifact:
		delete(a.name)
	case cask.Font_Artifact:
		delete(a.name)
	case cask.Binary_Artifact:
		delete(a.source)
		delete(a.target)
	case cask.Wallpaper_Artifact:
		delete(a.glob)
	case cask.AppImage_Artifact:
		delete(a.source)
		delete(a.target)
	case cask.Generic_Artifact:
		delete(a.source)
		delete(a.target)
	}
    }
    delete(c.artifacts)
}

fetch_formula :: proc(name: string) -> (f: formula.Formula, err: json.Error) {
    f, err = fetch_formula_homebrew(name)
    if err == nil {
        return f, nil
    }

    // Try to resolve the name as an oldname/alias of a current formula
    // (e.g. "dash" -> "dash-shell"). This requires the cached formula list.
    if canonical, ok := resolve_formula_alias(name); ok {
        f, err = fetch_formula_homebrew(canonical)
        if err == nil {
            return f, nil
        }
    }

    // 3rd-party taps: fetch the Ruby formula directly from a tapped repo.
    // The name token can be just "formula" (try all taps) or "user/repo/formula".
    if f_tap, _, ok := fetch_formula_tap(name); ok {
        return f_tap, nil
    }

    // Third-party taps (name contains '/') are not present in the Homebrew formula API.
    // We fall back to our local verified upstream registry when the API fetch fails.
    f2, err2 := fetch_formula_registry(name)
    if err2 == nil {
        return f2, nil
    }

    return f, err
}

// current_platform returns the platform enum used by the tap Ruby parser.
// Hardcoded to .Linux for now; macOS support is out of scope.
current_tap_platform :: proc() -> tap.Platform {
    return .Linux
}

// ruby_to_formula converts a parsed Ruby_Formula into a formula.Formula
// suitable for the install pipeline. Returns the converted formula and ok.
// Note: `homepage` and `license` are not stored in the Formula struct; they
// are dropped here since the install pipeline does not consume them. The
// original Ruby_Formula is the source of truth for those fields.
ruby_to_formula :: proc(rf: tap.Ruby_Formula, tap_name: string) -> (f: formula.Formula, ok: bool) {
    f.name = strings.clone(rf.name, context.allocator)
    f.desc = strings.clone(rf.desc, context.allocator)
    f.version = strings.clone(rf.version, context.allocator)

    f.source_url = strings.clone(rf.url, context.allocator)
    f.source_sha256 = strings.clone(rf.sha256, context.allocator)

    // bottle_url/bottle_sha256 are left empty: 3rd-party taps usually do not
    // publish prebuilt bottles. The install pipeline falls back to building
    // from source when the bottle fields are empty.
    f.bottle_url = ""
    f.bottle_sha256 = ""

    // Copy runtime dependencies from `depends_on "..."` lines (skipping
    // :build, :optional, :recommended). Build-only deps are currently
    // discarded because the install pipeline doesn't track a separate
    // build_deps field; they would be required to support compilation-time
    // tools like `pkg-config` properly.
    nd := len(rf.dependencies)
    if nd > 0 {
        f.dependencies = make([]string, nd, context.allocator)
        for d, i in rf.dependencies {
            f.dependencies[i] = strings.clone(d, context.allocator)
        }
    }

    // Copy the binary install list from `bin.install "..."` directives.
    n := len(rf.binaries)
    if n > 0 {
        f.binaries = make([]string, n, context.allocator)
        for b, i in rf.binaries {
            f.binaries[i] = strings.clone(b, context.allocator)
        }
    }

    f.tap = strings.clone(tap_name, context.allocator)
    return f, true
}

// parse_tap_token splits a token like "user/repo/formula" or "user/repo" or
// just "formula" into its components. Returns (tap_name, formula_name).
// If the input has fewer than 2 slashes, tap_name is "". Both returned
// strings (when non-empty) are allocated from the calling context's
// allocator; the caller is responsible for freeing them.
parse_tap_token :: proc(token: string) -> (tap_name, formula_name: string) {
    parts := strings.split(token, "/", context.temp_allocator)
    switch len(parts) {
    case 0, 1:
        return "", strings.clone(token, context.allocator)
    case 2:
        return strings.concatenate({parts[0], "/", parts[1]}, context.allocator),
               strings.clone("", context.allocator)
    case:
        tap_name = strings.concatenate({parts[0], "/", parts[1]}, context.allocator)
        // Rejoin the rest in case the formula name contains slashes
        // (e.g. "lib/foo"). Use context.allocator so the returned string
        // outlives this scope; the caller frees it.
        formula_name = strings.join(parts[2:], "/", context.allocator)
        return
    }
    return "", ""
}

// fetch_formula_tap attempts to fetch a formula from a tapped 3rd-party
// repository. The token can be:
//   - "formula"           — search all taps for a formula with this name
//   - "user/repo"         — use the formula named after the repo
//   - "user/repo/formula" — explicit formula in a specific tap
// Returns (formula, tap_name, ok).
fetch_formula_tap :: proc(token: string) -> (f: formula.Formula, tap_name: string, ok: bool) {
    target_tap, formula_name := parse_tap_token(token)
    // parse_tap_token allocates both from context.allocator; free them
    // when we're done.
    defer delete(target_tap)
    defer delete(formula_name)
    if len(target_tap) == 0 {
        return f, "", false
    }

    tap_entries := tap.read_taps()
    defer {
        for e in tap_entries {
            tap.destroy_read_tap_entry(e)
        }
        delete(tap_entries)
    }

    if len(tap_entries) == 0 {
        return f, "", false
    }

    if len(formula_name) == 0 {
        // If token is just "user/repo" and the repo's name matches a formula
        // in the tap, fetch that. Otherwise we cannot infer the formula.
        // First, find the matching tap.
        matched: tap.Tap
        matched_ok := false
        for e in tap_entries {
            if e.name == target_tap {
                matched = tap.tap_from_entry(e)
                matched_ok = true
                break
            }
        }
        if !matched_ok {
            return f, "", false
        }
        defer tap.destroy_tap(matched)
        formula_name = matched.name
        // Strip the "user/" prefix
        if idx := strings.index(formula_name, "/"); idx >= 0 {
            formula_name = formula_name[idx + 1:]
        }
    }

    // Find the matching tap entry
    matched: tap.Tap
    matched_ok := false
    for e in tap_entries {
        if e.name == target_tap {
            matched = tap.tap_from_entry(e)
            matched_ok = true
            break
        }
    }
    if !matched_ok {
        return f, "", false
    }
    defer tap.destroy_tap(matched)

    ruby_src, fetched := tap.fetch_formula_ruby(matched, formula_name)
    if !fetched {
        return f, "", false
    }
    defer delete(ruby_src)

    rf, parsed := tap.parse_ruby_formula(ruby_src, current_tap_platform())
    if !parsed {
        return f, "", false
    }
    defer tap.destroy_ruby_formula(rf)

    if rf.macos_only && current_tap_platform() == .Linux {
        fmt.printf("Note: %s is macOS-only and cannot be installed on Linux.\n", rf.name)
        return f, "", false
    }

    converted, conv_ok := ruby_to_formula(rf, matched.name)
    if !conv_ok {
        return f, "", false
    }
    return converted, matched.name, true
}

// resolve_formula_alias scans the cached Homebrew formula list for entries whose
// `oldnames` or `aliases` arrays contain the given name. If found, the current
// canonical formula name is returned. This handles cases like "dash" -> "dash-shell".
resolve_formula_alias :: proc(name: string) -> (canonical: string, ok: bool) {
    data, read_err := fetch_cached_api_list(FORMULA_LIST_URL, FORMULA_LIST_CACHE)
    if read_err != nil {
        return "", false
    }
    defer delete(data)

    text := string(data)
    depth := 0
    obj_start := 0
    in_string := false
    escaped := false
    target_lower := strings.to_lower(name, context.temp_allocator)

    for i := 0; i < len(text); i += 1 {
        c := text[i]
        if in_string {
            if escaped {
                escaped = false
            } else if c == '\\' {
                escaped = true
            } else if c == '"' {
                in_string = false
            }
            continue
        }

        if c == '"' {
            in_string = true
            continue
        }
        if c == '{' {
            if depth == 0 {
                obj_start = i
            }
            depth += 1
            continue
        }
        if c == '}' && depth > 0 {
            depth -= 1
            if depth == 0 {
                obj := text[obj_start:i+1]
                full_name := json_field_string_raw(obj, "full_name")
                if full_name == "" {
                    full_name = json_field_string_raw(obj, "name")
                }
                if full_name == "" {
                    continue
                }

                // Scan for oldnames/aliases arrays containing the target name.
                if contains_string_in_json_array(obj, "oldnames", target_lower) ||
                   contains_string_in_json_array(obj, "aliases", target_lower) {
                    return strings.clone(full_name), true
                }
            }
        }
    }

    return "", false
}

// contains_string_in_json_array performs a fast scan over the
// `key` JSON array within `obj` looking for `target` (case-insensitive).
// It extracts each JSON string element and compares for exact equality
// (case-insensitive) rather than a naive substring match, so e.g.
// searching for "dash" does not falsely match "dashboard".
// It avoids full json.parse() overhead for large list responses.
contains_string_in_json_array :: proc(obj, key, target_lower: string) -> bool {
    pattern := fmt.tprintf("\"%s\"", key)
    idx := strings.index(obj, pattern)
    if idx < 0 {
        return false
    }

    pos := idx + len(pattern)
    for pos < len(obj) && (obj[pos] == ' ' || obj[pos] == '\n' || obj[pos] == '\r' || obj[pos] == '\t') {
        pos += 1
    }
    if pos >= len(obj) || obj[pos] != ':' {
        return false
    }
    pos += 1
    for pos < len(obj) && (obj[pos] == ' ' || obj[pos] == '\n' || obj[pos] == '\r' || obj[pos] == '\t') {
        pos += 1
    }
    if pos >= len(obj) || obj[pos] != '[' {
        return false
    }
    pos += 1

    // Iterate JSON string elements within the array body.
    for pos < len(obj) {
        for pos < len(obj) && (obj[pos] == ' ' || obj[pos] == '\n' || obj[pos] == '\r' || obj[pos] == '\t' || obj[pos] == ',') {
            pos += 1
        }
        if pos >= len(obj) || obj[pos] == ']' {
            break
        }
        if obj[pos] != '"' {
            return false
        }
        pos += 1

        // Extract string content with escape handling.
        start := pos
        escaped := false
        for pos < len(obj) {
            c := obj[pos]
            if escaped {
                escaped = false
            } else if c == '\\' {
                escaped = true
            } else if c == '"' {
                break
            }
            pos += 1
        }
        if pos >= len(obj) {
            return false
        }
        element := obj[start:pos]
        element_lower := strings.to_lower(element, context.temp_allocator)
        if element_lower == target_lower {
            return true
        }
        pos += 1 // skip closing quote
    }

    return false
}

fetch_formula_homebrew :: proc(name: string) -> (f: formula.Formula, err: json.Error) {
    url := fmt.tprintf("https://formulae.brew.sh/api/formula/%s.json", name)

    temp_f, terr := os.create_temp_file("", "ubrew_fetch_formula_*.json")
    if terr != nil {
        return f, .EOF
    }
    // Clone the name so it remains valid after we close the file handle.
    temp_file := strings.clone(os.name(temp_f), context.allocator)
    defer delete(temp_file)
    defer os.remove(temp_file)
    defer os.close(temp_f)

    if !strings.has_prefix(url, "http://") && !strings.has_prefix(url, "https://") {
        return f, .EOF
    }

    dl_args := []string{"curl", "-s", "-f", "-L", url, "-o", temp_file}
    if !platform.exec_cmd("curl", dl_args) {
        return f, .EOF
    }

    data, read_err := os.read_entire_file(temp_file, context.allocator)
    if read_err != nil {
        return f, .EOF
    }
    defer delete(data)

    json_val, parse_err := json.parse(data)
    if parse_err != nil {
        return f, parse_err
    }
    defer json.destroy_value(json_val)

    root_obj := json_val.(json.Object)

    f.name = strings.clone(root_obj["name"].(json.String))
    f.desc = strings.clone(root_obj["desc"].(json.String))

    versions := root_obj["versions"].(json.Object)
    f.version = strings.clone(versions["stable"].(json.String))

    if urls_val, ok5 := root_obj["urls"]; ok5 {
        if urls_obj, ok6 := urls_val.(json.Object); ok6 {
            if stable_val, ok7 := urls_obj["stable"]; ok7 {
                if stable_obj, ok8 := stable_val.(json.Object); ok8 {
                    if url_val, ok9 := stable_obj["url"]; ok9 {
                        if url_str, ok10 := url_val.(json.String); ok10 {
                            f.source_url = strings.clone(url_str)
                        }
                    }
                    if checksum_val, ok11 := stable_obj["checksum"]; ok11 {
                        if checksum_str, ok12 := checksum_val.(json.String); ok12 {
                            f.source_sha256 = strings.clone(checksum_str)
                        }
                    }
                }
            }
        }
    }

    if bottle_val, ok2 := root_obj["bottle"]; ok2 {
        bottle_obj := bottle_val.(json.Object)
        if stable_val, ok3 := bottle_obj["stable"]; ok3 {
            stable_obj := stable_val.(json.Object)
            if files_val, ok4 := stable_obj["files"]; ok4 {
                files_obj := files_val.(json.Object)

                target_key := "x86_64_linux"
                if _, exists := files_obj[target_key]; !exists {
                    target_key = "all"
                }

                if target_val, exists := files_obj[target_key]; exists {
                    target_obj := target_val.(json.Object)
                    f.bottle_url = strings.clone(target_obj["url"].(json.String))
                    f.bottle_sha256 = strings.clone(target_obj["sha256"].(json.String))
                }
            }
        }
    }

    if deps_val, ok := root_obj["dependencies"]; ok {
        if deps_arr, ok2 := deps_val.(json.Array); ok2 {
            deps := make([dynamic]string, context.allocator)
            for d in deps_arr {
                if d_str, ok3 := d.(json.String); ok3 {
                    append(&deps, strings.clone(d_str))
                }
            }
            f.dependencies = deps[:]
        }
    }

    return f, nil
}

fetch_formula_registry :: proc(name: string) -> (f: formula.Formula, err: json.Error) {
	json_val, parse_err := registry_mmap_parse(REGISTRY_PATH)
	if parse_err != nil {
		return f, parse_err
	}
	defer json.destroy_value(json_val)

    root_obj := json_val.(json.Object)
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return f, .EOF
    }

    for rec_item in records_arr {
        rec_obj := rec_item.(json.Object)
        if json_string_or_empty(rec_obj, "kind") != "formula" {
            continue
        }
        rec_token := json_string_or_empty(rec_obj, "token")
        match := false
        if rec_token == name {
            match = true
        } else if !strings.contains(name, "/") {
            suffix := fmt.tprintf("/%s", name)
            if strings.has_suffix(rec_token, suffix) {
                match = true
            }
        }
        if !match {
            continue
        }

        f.name = strings.clone(rec_token)
        f.desc = strings.clone(json_string_or_empty(rec_obj, "desc"))

        if resolved_obj, ok2 := json_object_or_nil(rec_obj, "resolved"); ok2 {
            f.version = strings.clone(json_string_or_empty(resolved_obj, "version"))
            url, sha := registry_pick_resolved_asset(resolved_obj)
            f.bottle_url = strings.clone(url)
            f.bottle_sha256 = strings.clone(sha)
        }

        if deps_val, ok := rec_obj["dependencies"]; ok {
            if deps_arr, ok2 := deps_val.(json.Array); ok2 {
                deps := make([dynamic]string, context.allocator)
                for d in deps_arr {
                    if d_str, ok3 := d.(json.String); ok3 {
                        append(&deps, strings.clone(d_str))
                    }
                }
                f.dependencies = deps[:]
            }
        }

        return f, nil
    }

    return f, .EOF
}

destroy_formula :: proc(f: formula.Formula) {
    delete(f.name)
    delete(f.desc)
    delete(f.version)
    delete(f.bottle_url)
    delete(f.bottle_sha256)
    delete(f.source_url)
    delete(f.source_sha256)
    for dep in f.dependencies {
        delete(dep)
    }
    delete(f.dependencies)
    for b in f.binaries {
        delete(b)
    }
    delete(f.binaries)
    delete(f.tap)
}

Formula_Search_Result :: struct {
    name:    string,
    desc:    string,
    version: string,
}

Cask_Search_Result :: struct {
    token:   string,
    name:    string,
    desc:    string,
    version: string,
}

destroy_formula_search_results :: proc(results: []Formula_Search_Result) {
    for r in results {
        delete(r.name)
        delete(r.desc)
        delete(r.version)
    }
    delete(results)
}

destroy_cask_search_results :: proc(results: []Cask_Search_Result) {
    for r in results {
        delete(r.token)
        delete(r.name)
        delete(r.desc)
        delete(r.version)
    }
    delete(results)
}

formula_results_contains :: proc(results: []Formula_Search_Result, name: string) -> bool {
    for r in results {
        if r.name == name {
            return true
        }
    }
    return false
}

cask_results_contains :: proc(results: []Cask_Search_Result, token: string) -> bool {
    for r in results {
        if r.token == token {
            return true
        }
    }
    return false
}

append_registry_formulae_matches :: proc(out: ^[dynamic]Formula_Search_Result, query_lower: string, limit: int) {
	json_val, parse_err := registry_mmap_parse(REGISTRY_PATH)
	if parse_err != nil {
		return
	}
	defer json.destroy_value(json_val)

    root_obj := json_val.(json.Object)
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return
    }

    for rec_item in records_arr {
        if len(out^) >= limit {
            return
        }
        rec_obj := rec_item.(json.Object)
        if json_string_or_empty(rec_obj, "kind") != "formula" {
            continue
        }

        token := json_string_or_empty(rec_obj, "token")
        name := json_string_or_empty(rec_obj, "name")
        desc := json_string_or_empty(rec_obj, "desc")
        version := ""
        if resolved_obj, ok2 := json_object_or_nil(rec_obj, "resolved"); ok2 {
            version = json_string_or_empty(resolved_obj, "version")
        }

        if !lower_contains(token, query_lower) && !lower_contains(name, query_lower) && !lower_contains(desc, query_lower) {
            continue
        }
        if formula_results_contains(out^[:], token) {
            continue
        }

        append(out, Formula_Search_Result{
            name = strings.clone(token),
            desc = strings.clone(desc),
            version = strings.clone(version),
        })
    }
}

append_registry_cask_matches :: proc(out: ^[dynamic]Cask_Search_Result, query_lower: string, limit: int) {
	json_val, parse_err := registry_mmap_parse(REGISTRY_PATH)
	if parse_err != nil {
		return
	}
	defer json.destroy_value(json_val)

    root_obj := json_val.(json.Object)
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return
    }

    for rec_item in records_arr {
        if len(out^) >= limit {
            return
        }
        rec_obj := rec_item.(json.Object)
        if json_string_or_empty(rec_obj, "kind") != "cask" {
            continue
        }

        token := json_string_or_empty(rec_obj, "token")
        name := json_string_or_empty(rec_obj, "name")
        desc := json_string_or_empty(rec_obj, "desc")
        version := ""
        if resolved_obj, ok2 := json_object_or_nil(rec_obj, "resolved"); ok2 {
            version = json_string_or_empty(resolved_obj, "version")
        }

        if !lower_contains(token, query_lower) && !lower_contains(name, query_lower) && !lower_contains(desc, query_lower) {
            continue
        }
        if cask_results_contains(out^[:], token) {
            continue
        }

        append(out, Cask_Search_Result{
            token = strings.clone(token),
            name = strings.clone(name),
            desc = strings.clone(desc),
            version = strings.clone(version),
        })
    }
}

search_formulae :: proc(query: string, limit: int = 25) -> (out: []Formula_Search_Result, err: json.Error) {
    if len(strings.trim_space(query)) == 0 {
        return out, .EOF
    }

    results := make([dynamic]Formula_Search_Result)
    query_lower := strings.to_lower(query, context.temp_allocator)

    append_registry_formulae_matches(&results, query_lower, limit)

    data, read_err := fetch_cached_api_list(FORMULA_LIST_URL, FORMULA_LIST_CACHE)
    if read_err == nil {
        defer delete(data)
        append_api_formulae_matches_fast(data, &results, query_lower, limit)
    }

    append_tap_formulae_matches(&results, query_lower, limit)

    if len(results) == 0 {
        return out, .EOF
    }

    return results[:], nil
}

// append_tap_formulae_matches walks the tapped 3rd-party repositories and
// appends search results for any formula whose name, desc, or tap prefix
// matches `query_lower`. It first enumerates the Formula/ directory of each
// tap via the GitHub API (or local cache), then parses each .rb file.
append_tap_formulae_matches :: proc(out: ^[dynamic]Formula_Search_Result, query_lower: string, limit: int) {
    tap_entries := tap.read_taps()
    defer {
        for e in tap_entries {
            tap.destroy_read_tap_entry(e)
        }
        delete(tap_entries)
    }
    if len(tap_entries) == 0 {
        return
    }

    for entry in tap_entries {
        if len(out^) >= limit {
            return
        }
        t := tap.tap_from_entry(entry)

        listing_data, ok := fetch_tap_listing_cached(t)
        if !ok {
            tap.destroy_tap(t)
            continue
        }

        // Walk the listing JSON and extract every "name" ending in ".rb".
        listing_text := string(listing_data)
        i := 0
        for {
            marker := "\"name\""
            found := strings.index(listing_text[i:], marker)
            if found < 0 {
                break
            }
            i += found + len(marker)
            for i < len(listing_text) && (listing_text[i] == ' ' || listing_text[i] == ':' || listing_text[i] == '\t') {
                i += 1
            }
            if i >= len(listing_text) || listing_text[i] != '"' {
                continue
            }
            i += 1
            end := i
            for end < len(listing_text) && listing_text[end] != '"' {
                end += 1
            }
            if end >= len(listing_text) {
                break
            }
            fname := listing_text[i:end]
            if !strings.has_suffix(fname, ".rb") {
                i = end + 1
                continue
            }
            formula_name := fname[:len(fname) - 3]

            name_lc := strings.to_lower(formula_name, context.temp_allocator)
            tap_lc := strings.to_lower(t.name, context.temp_allocator)
            if !strings.contains(name_lc, query_lower) && !strings.contains(tap_lc, query_lower) {
                continue
            }

            // Use the full "tap_name/formula_name" so users can install with
            // `ubrew install user/repo/formula`.
            token := fmt.tprintf("%s/%s", t.name, formula_name)
            exists := false
            for r in out^ {
                if r.name == token {
                    exists = true
                    break
                }
            }
            if exists {
                continue
            }

            append(out, Formula_Search_Result{
                name    = strings.clone(token),
                desc    = strings.clone(fmt.tprintf("(from %s tap)", t.name)),
                version = "",
            })
            if len(out^) >= limit {
                delete(listing_data)
                tap.destroy_tap(t)
                return
            }
        }
        delete(listing_data)
        tap.destroy_tap(t)
    }
}

// extract_owner_repo_from_github_url returns the "owner/repo" portion of a
// GitHub URL (https or ssh forms), or "" if the URL doesn't match. Useful
// for re-deriving the canonical repo path for API calls. The returned string
// is allocated from the calling context's allocator; pass context.allocator
// at the call site if you need it to outlive this scope.
extract_owner_repo_from_github_url :: proc(url: string) -> string {
    if len(url) == 0 {
        return ""
    }
    rest := url
    // Strip scheme:// prefix
    if idx := strings.index(url, "://"); idx >= 0 {
        rest = url[idx + 3:]
    }
    // Strip leading "www."
    if strings.has_prefix(rest, "www.") {
        rest = rest[4:]
    }
    // Now expect "github.com[:port]/owner/repo[.git][/...]"
    if !strings.has_prefix(rest, "github.com") {
        return ""
    }
    rest = rest[len("github.com"):]
    // Strip optional port
    if rest[0] == ':' {
        // skip ":<port>"
        for j := 1; j < len(rest); j += 1 {
            if rest[j] == '/' {
                rest = rest[j:]
                break
            }
        }
    }
    // Strip leading slashes
    for len(rest) > 0 && rest[0] == '/' {
        rest = rest[1:]
    }
    if len(rest) == 0 {
        return ""
    }
    // Find first slash to separate owner from the rest
    slash := strings.index(rest, "/")
    if slash < 0 {
        return ""
    }
    owner := rest[:slash]
    after_owner := rest[slash + 1:]
    // repo is the next path component, optionally with .git suffix
    end := strings.index(after_owner, "/")
    repo := after_owner if end < 0 else after_owner[:end]
    if strings.has_suffix(repo, ".git") {
        repo = repo[:len(repo) - 4]
    }
    if len(owner) == 0 || len(repo) == 0 {
        return ""
    }
    return strings.clone(fmt.tprintf("%s/%s", owner, repo), context.allocator)
}

// fetch_tap_listing_cached returns the cached tap formula listing (a JSON
// array of objects with a "name" field per GitHub's API), refreshing from
// GitHub if the cache is missing or stale (older than 1 hour). It tries
// multiple candidate locations in order:
//   1. <tap.url>/contents/Formula        (Homebrew standard Formula/ dir)
//   2. <tap.url>/contents/                (root, e.g. pkgxdev/homebrew-made)
//   3. <github.com/user/homebrew-repo>/... (homebrew- prefix convention)
// The first one that returns a non-empty JSON array is used.
fetch_tap_listing_cached :: proc(t: tap.Tap) -> (data: []u8, ok: bool) {
    cache_dir := fmt.tprintf("/opt/ubrew/cache/taps/%s", t.name)
    cache_path := fmt.tprintf("%s/Formula_listing.json", cache_dir)

    // Try the cache first if fresh.
    info, serr := os.stat(cache_path, context.allocator)
    use_cache := false
    if serr == nil {
        now_secs := time.time_to_unix(time.now())
        mtime_secs := time.time_to_unix(info.modification_time)
        if now_secs - mtime_secs < 3600 {
            use_cache = true
        }
        os.file_info_delete(info, context.allocator)
    }
    if use_cache {
        if cached, rerr := os.read_entire_file(cache_path, context.allocator); rerr == nil {
            return cached, true
        }
    }

    // Build the list of candidate GitHub repo paths to try. We try
    // tap-specific URL first, then the homebrew- convention. The values
    // stored here are the `owner/repo` (no scheme, no host) so the loop
    // below can construct the JSON Contents API URL.
    repo_candidates := make([dynamic]string, context.allocator)
    defer {
        for rc in repo_candidates {
            delete(rc)
        }
        delete(repo_candidates)
    }
    if owner_repo := extract_owner_repo_from_github_url(t.url); len(owner_repo) > 0 {
        append(&repo_candidates, owner_repo)
    }

    // Derive the "homebrew-" variant from t.name (e.g. "pkgxdev/made" ->
    // "pkgxdev/homebrew-made") if it differs from the canonical owner/repo.
    if slash := strings.index(t.name, "/"); slash >= 0 {
        user := t.name[:slash]
        repo := t.name[slash + 1:]
        hb := strings.clone(fmt.tprintf("%s/homebrew-%s", user, repo), context.allocator)
        defer delete(hb)
        already_present := false
        for rc in repo_candidates {
            if rc == hb {
                already_present = true
                break
            }
        }
        if !already_present {
            // Clone again so the version stored in the slice outlives the
            // local `hb` (which is freed by the defer above).
            append(&repo_candidates, strings.clone(hb, context.allocator))
        }
    }

    // Path suffixes to try against each repo. Combined with the API host
    // below, these produce the JSON Contents API endpoint rather than the
    // HTML web page.
    suffixes := []string{"/contents/Formula", "/contents"}

    _ = os.make_directory_all(cache_dir, os.perm(0o755))

    for owner_repo in repo_candidates {
        for suffix in suffixes {
            // The HTML view of /contents/... returns a 200 with an HTML
            // page even for missing files. The Contents API at
            // https://api.github.com/repos/.../contents/... is what we want.
            api_url := fmt.tprintf("https://api.github.com/repos/%s%s?ref=%s", owner_repo, suffix, t.branch)
            curl_args := []string{
                "curl",
                "-sfSL",
                "--no-progress-meter",
                "-H", "Accept: application/vnd.github+json",
                api_url,
                "-o", cache_path,
            }
            curl_ok := platform.exec_cmd("curl", curl_args)
            if !curl_ok {
                continue
            }
            cached, rerr := os.read_entire_file(cache_path, context.allocator)
            if rerr != nil {
                continue
            }
            if len(cached) == 0 {
                delete(cached)
                continue
            }
            // Confirm the response looks like a directory listing (starts
            // with `[`). Errors come back as `{"message":...}` objects.
            trimmed := strings.trim_space(string(cached))
            if len(trimmed) == 0 || trimmed[0] != '[' {
                delete(cached)
                continue
            }
            return cached, true
        }
    }

    // All candidates failed. Fall back to whatever is cached, even if stale.
    if cached, rerr := os.read_entire_file(cache_path, context.allocator); rerr == nil && len(cached) > 0 {
        return cached, true
    }
    return nil, false
}
search_casks :: proc(query: string, limit: int = 25) -> (out: []Cask_Search_Result, err: json.Error) {
    if len(strings.trim_space(query)) == 0 {
        return out, .EOF
    }

    results := make([dynamic]Cask_Search_Result)
    query_lower := strings.to_lower(query, context.temp_allocator)

    append_registry_cask_matches(&results, query_lower, limit)

    data, read_err := fetch_cached_api_list(CASK_LIST_URL, CASK_LIST_CACHE)
    if read_err == nil {
        defer delete(data)
        append_api_cask_matches_fast(data, &results, query_lower, limit)
    }

    if len(results) == 0 {
        return out, .EOF
    }

    return results[:], nil
}
