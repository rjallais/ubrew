package api

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:strings"
import "core:time"
import "core:c"
import fts "../vendor/odin-sqlite3"
import "../cask"
import "../formula"
import "../kernel"
import "../platform"
import "../tap"

get_registry_path :: proc(allocator := context.temp_allocator) -> string {
	opt_path := "/opt/ubrew/db/upstream.json"
	if os.is_file(opt_path) {
		return strings.clone(opt_path, allocator)
	}
	
	if os.is_file("registry/upstream.json") {
		return strings.clone("registry/upstream.json", allocator)
	}
	
	exe_path, exe_err := os.get_executable_path(allocator)
	if exe_err == nil && len(exe_path) > 0 {
		if idx := strings.last_index(exe_path, "/"); idx >= 0 {
			dir := exe_path[:idx]
			rel_path := fmt.tprintf("%s/registry/upstream.json", dir)
			if os.is_file(rel_path) {
				return strings.clone(rel_path, allocator)
			}
			rel_path2 := fmt.tprintf("%s/../registry/upstream.json", dir)
			if os.is_file(rel_path2) {
				return strings.clone(rel_path2, allocator)
			}
		}
	}
	
	return strings.clone("registry/upstream.json", allocator)
}
API_CACHE_DIR :: "/opt/ubrew/cache/api"
FORMULA_LIST_CACHE :: API_CACHE_DIR + "/formula.json"
CASK_LIST_CACHE :: API_CACHE_DIR + "/cask.json"
FORMULA_LIST_URL :: "https://formulae.brew.sh/api/formula.json"
CASK_LIST_URL :: "https://formulae.brew.sh/api/cask.json"

// Phase 2: SQLite search database. Built from the 30MB formula.json /
// 15MB cask.json dumps on first search (or `update`). Uses SQL LIKE
// for fast case-insensitive substring matching via SQLite's B-tree scan.
SEARCH_DB_PATH :: API_CACHE_DIR + "/search-index.db"
FORMULA_SEARCH_INDEX :: API_CACHE_DIR + "/search-index.db"
CASK_SEARCH_INDEX :: API_CACHE_DIR + "/search-index.db"

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

        dl_args := []string{"curl", "-s", "-f", "-L", "--compressed", url, "-o", temp_file}
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

// json_field_array_as_csv extracts a JSON array field and returns its
// string elements as a comma-separated value. E.g. for
// `"executables":["jq","jq.py"]` it returns "jq,jq.py".
// Used by build_formula_search_index to populate the executables column.
json_field_array_as_csv :: proc(obj, key: string) -> string {
	pattern := fmt.tprintf("\"%s\":[", key)
	start_search := 0
	for {
		idx := strings.index(obj[start_search:], pattern)
		if idx < 0 {
			return ""
		}
		idx += start_search
		if idx > 0 {
			prev := obj[idx - 1]
			if (prev >= 'a' && prev <= 'z') || (prev >= 'A' && prev <= 'Z') ||
				(prev >= '0' && prev <= '9') || prev == '_' {
				start_search = idx + 1
				continue
			}
		}
		arr_start := idx + len(pattern)
		depth := 1
		i := arr_start
		in_str := false
		esc := false
		result := make([dynamic]u8, 0, 64, context.temp_allocator)
		first := true
		for i < len(obj) {
			c := obj[i]
			if in_str {
				if esc {
					esc = false
				} else if c == '\\' {
					esc = true
				} else if c == '"' {
					in_str = false
				}
				i += 1
				continue
			}
			if c == '"' {
				if !first {
					append(&result, ',')
				}
				first = false
				i += 1
				s := i
				esc2 := false
				for i < len(obj) {
					cc := obj[i]
					if esc2 {
						esc2 = false
					} else if cc == '\\' {
						esc2 = true
					} else if cc == '"' {
						break
					}
					i += 1
				}
				if i > s {
					for j := s; j < i; j += 1 {
						append(&result, obj[j])
					}
				}
				i += 1
				continue
			}
			if c == '[' { depth += 1 }
			else if c == ']' {
				depth -= 1
				if depth == 0 { break }
			}
			i += 1
		}
		return string(result[:])
	}
	return ""
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
				// Skip formulae unavailable on the current platform
				plat := json_raw_bottle_platforms(obj)
				if !formula_available_on_current_os(plat) {
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
				// Homebrew core casks are macOS-only; skip on other platforms
				when ODIN_OS != .Darwin {
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

// registry_entry_platform_tag returns a platform tag for a registry entry
// based on its assets (top-level and resolved). Returns "LM", "L", "M", or "A".
registry_entry_platform_tag :: proc(rec_obj: json.Object) -> string {
	if rec_obj == nil { return "A" }
	check_assets :: proc(obj: json.Object, has_linux, has_macos: ^bool) {
		if assets_obj, ok := json_object_or_nil(obj, "assets"); ok {
			for k, _ in assets_obj {
				if k == "linux-x86_64" || k == "linux-aarch64" || k == "linux-kde" || k == "linux-gnome" || k == "linux-png" {
					has_linux^ = true
				}
				if k == "macos-x86_64" || k == "macos-arm64" {
					has_macos^ = true
				}
			}
		}
	}
	has_linux, has_macos := false, false
	check_assets(rec_obj, &has_linux, &has_macos)
	if ro, ok := json_object_or_nil(rec_obj, "resolved"); ok {
		check_assets(ro, &has_linux, &has_macos)
	}
	if has_linux && has_macos { return "LM" }
	if has_linux { return "L" }
	if has_macos { return "M" }
	return "A"
}

// registry_has_current_os_asset returns true if the assets object (either
// on the record or in its resolved child) contains an entry compatible with
// the current OS, using the same fallback chain as registry_pick_resolved_asset.
registry_has_current_os_asset :: proc(rec_obj: json.Object) -> bool {
	if rec_obj == nil { return false }
	has_asset_from_obj :: proc(obj: json.Object) -> bool {
		if obj == nil { return false }
		assets_obj, aok := json_object_or_nil(obj, "assets")
		if !aok { return false }

		de := detect_desktop_env_api()
		if de == .KDE {
			if _, exists := assets_obj["linux-kde"]; exists { return true }
		} else if de == .GNOME {
			if _, exists := assets_obj["linux-gnome"]; exists { return true }
		}
		if _, exists := assets_obj["linux-png"]; exists { return true }

		preferred := registry_preferred_asset_key()
		fallback_keys := []string{preferred, "linux-x86_64", "linux-aarch64", "macos-x86_64", "macos-arm64"}
		for k in fallback_keys {
			if _, exists := assets_obj[k]; exists { return true }
		}
		for _, v in assets_obj {
			if _, ok := v.(json.Object); ok { return true }
		}
		return false
	}

	if has_asset_from_obj(rec_obj) { return true }
	if resolved_obj, ok := json_object_or_nil(rec_obj, "resolved"); ok {
		if has_asset_from_obj(resolved_obj) { return true }
	}
	return false
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

    if c_tap, _, ok := fetch_cask_tap(token); ok {
        return c_tap, nil
    }

    // Third-party taps (token contains '/') are not present in the Homebrew cask API.
    // We fall back to our local verified upstream registry when the API fetch fails.
    c2, err2 := fetch_cask_registry(token)
    if err2 == nil {
        return c2, nil
    }

    return c, err
}

ruby_to_cask :: proc(rc: tap.Ruby_Cask) -> (c: cask.Cask, ok: bool) {
	c.token = strings.clone(rc.token, context.allocator)
	c.name = strings.clone(rc.name, context.allocator)
	c.desc = strings.clone(rc.desc, context.allocator)
	c.version = strings.clone(rc.version, context.allocator)
	c.url = strings.clone(rc.url, context.allocator)
	c.sha256 = strings.clone(rc.sha256, context.allocator)
	c.homepage = strings.clone(rc.homepage, context.allocator)
	c.auto_updates = false

	is_appimage := strings.contains(strings.to_lower(rc.url), "appimage")
	is_wallpaper := strings.contains(strings.to_lower(rc.token), "wallpaper")

	artifacts_list := make([dynamic]cask.Artifact, context.allocator)

	if is_wallpaper {
		append(&artifacts_list, cask.Wallpaper_Artifact{glob = strings.clone("*", context.allocator)})
	} else {
		// Process binaries
		for b, i in rc.binaries {
			src := b
			if strings.has_prefix(src, "squashfs-root/") {
				src = src[len("squashfs-root/"):]
			}
			tgt := i < len(rc.binary_targets) ? rc.binary_targets[i] : ""
			if tgt == "" {
				tgt = os.base(src)
			}
			
			if is_appimage {
				append(&artifacts_list, cask.AppImage_Artifact{
					source = strings.clone(src, context.allocator),
					target = strings.clone(tgt, context.allocator),
				})
			} else {
				append(&artifacts_list, cask.Binary_Artifact{
					source = strings.clone(src, context.allocator),
					target = strings.clone(tgt, context.allocator),
				})
			}
		}

		// Process artifacts
		for b, i in rc.artifact_sources {
			src := b
			if strings.has_prefix(src, "squashfs-root/") {
				src = src[len("squashfs-root/"):]
			}
			tgt := i < len(rc.artifact_targets) ? rc.artifact_targets[i] : ""
			if tgt == "" {
				tgt = os.base(src)
			}

			append(&artifacts_list, cask.Generic_Artifact{
				source = strings.clone(src, context.allocator),
				target = strings.clone(tgt, context.allocator),
			})
		}
	}

	c.artifacts = artifacts_list[:]
	return c, true
}

fetch_cask_tap :: proc(token: string) -> (c: cask.Cask, tap_name: string, ok: bool) {
	target_tap, cask_name := parse_tap_token(token)
	defer delete(target_tap)
	defer delete(cask_name)
	if len(target_tap) == 0 {
		return c, "", false
	}

	tap_entries := tap.read_taps()
	defer {
		for e in tap_entries {
			tap.destroy_read_tap_entry(e)
		}
		delete(tap_entries)
	}

	if len(tap_entries) == 0 {
		return c, "", false
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
		return c, "", false
	}
	defer tap.destroy_tap(matched)

	resolved_cask_name := cask_name
	if len(cask_name) == 0 {
		resolved_cask_name = matched.name
		if idx := strings.index(resolved_cask_name, "/"); idx >= 0 {
			resolved_cask_name = resolved_cask_name[idx + 1:]
		}
	}

	if !tap.tap_is_trusted(matched.name) {
		if !tap.prompt_and_trust_tap(matched.name) {
			fmt.eprintf("Error: Tap '%s' is not trusted. To trust it, run: ubrew tap trust %s\n", matched.name, matched.name)
			os.exit(1)
		}
	}

	ruby_src, fetched := tap.fetch_cask_ruby(matched, resolved_cask_name)
	if !fetched {
		return c, "", false
	}
	defer delete(ruby_src)

	rc, parsed := tap.parse_ruby_cask(ruby_src, resolved_cask_name)
	if !parsed {
		return c, "", false
	}
	defer tap.destroy_ruby_cask(rc)

	converted, conv_ok := ruby_to_cask(rc)
	if !conv_ok {
		return c, "", false
	}
	return converted, matched.name, true
}


fetch_cask_homebrew :: proc(token: string) -> (c: cask.Cask, err: json.Error) {
    url := fmt.tprintf("https://formulae.brew.sh/api/cask/%s.json", token)

    // Check the per-cask cache (warmed by warm_casks_cache_parallel).
    cache_path := fmt.tprintf("%s/cask-%s.json", API_CACHE_DIR, token)
    data, read_err := os.read_entire_file(cache_path, context.allocator)
    needs_download := read_err != nil || len(data) == 0

    if needs_download {
        if read_err == nil {
            delete(data)
        }

        temp_f, terr := os.create_temp_file("", "ubrew_fetch_cask_*.json")
        if terr != nil {
            return c, .EOF
        }
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

        new_data, new_err := os.read_entire_file(temp_file, context.allocator)
        if new_err != nil {
            return c, .EOF
        }
        _ = os.write_entire_file(cache_path, new_data)
        data = new_data
    }
    defer delete(data)

    json_val, parse_err := json.parse(data)
    if parse_err != nil {
        return c, parse_err
    }
    defer json.destroy_value(json_val)

    root_obj, root_ok := json_val.(json.Object)
    if !root_ok {
        return c, .EOF
    }

    c.token = strings.clone(root_obj["token"].(json.String))

    if desc_val, exists := root_obj["desc"]; exists {
        if desc_str, ok := desc_val.(json.String); ok {
            c.desc = strings.clone(desc_str)
        }
    }

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
    if auto_val, exists := root_obj["auto_updates"]; exists {
        if auto_bool, ok := auto_val.(json.Boolean); ok {
            c.auto_updates = bool(auto_bool)
        }
    }

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
	json_val, parse_err := registry_mmap_parse(get_registry_path())
	if parse_err != nil {
		return c, parse_err
	}
	defer json.destroy_value(json_val)

    root_obj, root_ok := json_val.(json.Object)
    if !root_ok {
        return c, .EOF
    }
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return c, .EOF
    }

    for rec_item in records_arr {
        rec_obj, rec_ok := rec_item.(json.Object)
        if !rec_ok {
            continue
        }
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

        c.desc = strings.clone(json_string_or_empty(rec_obj, "desc"))

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
    delete(c.desc)
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

    if !tap.tap_is_trusted(matched.name) {
        if !tap.prompt_and_trust_tap(matched.name) {
            fmt.eprintf("Error: Tap '%s' is not trusted. To trust it, run: ubrew tap trust %s\n", matched.name, matched.name)
            os.exit(1)
        }
    }

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

extract_string_array :: proc(obj: json.Object, key: string) -> []string {
    if val, ok := obj[key]; ok {
        if arr, ok2 := val.(json.Array); ok2 {
            res := make([dynamic]string, context.allocator)
            for item in arr {
                if item_str, ok3 := item.(json.String); ok3 {
                    append(&res, strings.clone(item_str))
                } else if item_obj, ok4 := item.(json.Object); ok4 {
                    for k in item_obj {
                        append(&res, strings.clone(k))
                    }
                }
            }
            return res[:]
        }
    }
    return nil
}

fetch_formula_homebrew :: proc(name: string) -> (f: formula.Formula, err: json.Error) {
    url := fmt.tprintf("https://formulae.brew.sh/api/formula/%s.json", name)

    // Check the per-formula cache (warmed by warm_formulae_cache_parallel).
    cache_path := fmt.tprintf("%s/formula-%s.json", API_CACHE_DIR, name)
    data, read_err := os.read_entire_file(cache_path, context.allocator)
    needs_download := read_err != nil || len(data) == 0

    if needs_download {
        if read_err == nil {
            delete(data)
        }

        temp_f, terr := os.create_temp_file("", "ubrew_fetch_formula_*.json")
        if terr != nil {
            return f, .EOF
        }
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

        new_data, new_err := os.read_entire_file(temp_file, context.allocator)
        if new_err != nil {
            return f, .EOF
        }
        _ = os.write_entire_file(cache_path, new_data)
        data = new_data
    }
    defer delete(data)

    json_val, parse_err := json.parse(data)
    if parse_err != nil {
        return f, parse_err
    }
    defer json.destroy_value(json_val)

    root_obj, root_ok := json_val.(json.Object)
    if !root_ok {
        return f, .EOF
    }

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

    f.build_dependencies = extract_string_array(root_obj, "build_dependencies")
    f.test_dependencies = extract_string_array(root_obj, "test_dependencies")
    f.optional_dependencies = extract_string_array(root_obj, "optional_dependencies")
    f.recommended_dependencies = extract_string_array(root_obj, "recommended_dependencies")
    f.uses_from_macos = extract_string_array(root_obj, "uses_from_macos")

    if reqs_val, ok := root_obj["requirements"]; ok {
        if reqs_arr, ok2 := reqs_val.(json.Array); ok2 {
            reqs := make([dynamic]string, context.allocator)
            for req in reqs_arr {
                if req_obj, ok3 := req.(json.Object); ok3 {
                    if name_val, ok4 := req_obj["name"]; ok4 {
                        if name_str, ok5 := name_val.(json.String); ok5 {
                            append(&reqs, strings.clone(name_str))
                        }
                    }
                }
            }
            f.requirements = reqs[:]
        }
    }

    if keg_val, ok := root_obj["keg_only"]; ok {
        if kb, ok2 := keg_val.(json.Boolean); ok2 {
            f.keg_only = bool(kb)
        }
    }

    return f, nil
}

fetch_formula_registry :: proc(name: string) -> (f: formula.Formula, err: json.Error) {
	json_val, parse_err := registry_mmap_parse(get_registry_path())
	if parse_err != nil {
		return f, parse_err
	}
	defer json.destroy_value(json_val)

    root_obj, root_ok := json_val.(json.Object)
    if !root_ok {
        return f, .EOF
    }
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return f, .EOF
    }

    for rec_item in records_arr {
        rec_obj, rec_ok := rec_item.(json.Object)
        if !rec_ok {
            continue
        }
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
    for dep in f.build_dependencies {
        delete(dep)
    }
    delete(f.build_dependencies)
    for dep in f.test_dependencies {
        delete(dep)
    }
    delete(f.test_dependencies)
    for dep in f.optional_dependencies {
        delete(dep)
    }
    delete(f.optional_dependencies)
    for dep in f.recommended_dependencies {
        delete(dep)
    }
    delete(f.recommended_dependencies)
    for dep in f.requirements {
        delete(dep)
    }
    delete(f.requirements)
    for dep in f.uses_from_macos {
        delete(dep)
    }
    delete(f.uses_from_macos)
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
	json_val, parse_err := registry_mmap_parse(get_registry_path())
	if parse_err != nil {
		return
	}
	defer json.destroy_value(json_val)

    root_obj, root_ok := json_val.(json.Object)
    if !root_ok {
        return
    }
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return
    }

    for rec_item in records_arr {
        if len(out^) >= limit {
            return
        }
        rec_obj, rec_ok := rec_item.(json.Object)
        if !rec_ok {
            continue
        }
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

        // Platform filter: skip entries with no asset for the current OS
        if !registry_has_current_os_asset(rec_obj) {
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
	json_val, parse_err := registry_mmap_parse(get_registry_path())
	if parse_err != nil {
		return
	}
	defer json.destroy_value(json_val)

    root_obj, root_ok := json_val.(json.Object)
    if !root_ok {
        return
    }
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return
    }

    for rec_item in records_arr {
        if len(out^) >= limit {
            return
        }
        rec_obj, rec_ok := rec_item.(json.Object)
        if !rec_ok {
            continue
        }
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

        // Platform filter: skip entries with no asset for the current OS
        if !registry_has_current_os_asset(rec_obj) {
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

	// Phase 2: try the compact TSV index first (built by build_search_index
	// at update time). ~500KB, substring scan in <10ms. Falls back to the
	// 30MB JSON dump path if the index doesn't exist yet.
	if index_results := search_index_formulae(query_lower, limit); len(index_results) > 0 {
		defer delete(index_results)
		for r in index_results {
			exists := false
			for existing in results {
				if existing.name == r.name {
					exists = true
					break
				}
			}
			if !exists {
				append(&results, r)
				if len(results) >= limit {
					break
				}
			} else {
				delete(r.name)
				delete(r.desc)
				delete(r.version)
			}
		}
	} else {
		// Auto-build the index if missing (first search after install/cleanup)
		if !os.is_file(SEARCH_DB_PATH) {
			build_search_db()
		}
		if index_results2 := search_index_formulae(query_lower, limit); len(index_results2) > 0 {
			defer delete(index_results2)
			for r in index_results2 {
				exists := false
				for existing in results {
					if existing.name == r.name {
						exists = true
						break
					}
				}
				if !exists {
					append(&results, r)
					if len(results) >= limit {
						break
					}
				} else {
					delete(r.name)
					delete(r.desc)
					delete(r.version)
				}
			}
		} else {
			data, read_err := fetch_cached_api_list(FORMULA_LIST_URL, FORMULA_LIST_CACHE)
			if read_err == nil {
				defer delete(data)
				append_api_formulae_matches_fast(data, &results, query_lower, limit)
			}
		}
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
            curl_args := make([dynamic]string, context.temp_allocator)
            append(&curl_args, "curl")
            append(&curl_args, "-sfL")
            append(&curl_args, "--no-progress-meter")
            append(&curl_args, "-H")
            append(&curl_args, "Accept: application/vnd.github+json")
            // Optional GitHub token bumps the rate limit from 60/hr (per IP,
            // unauthenticated) to 5000/hr. We only add the header when a
            // token is available via `gh auth token` or $GH_TOKEN.
            if token := platform.get_gh_token(); len(token) > 0 {
                append(&curl_args, "-H")
                append(&curl_args, fmt.tprintf("Authorization: Bearer %s", token))
            }
            append(&curl_args, api_url)
            append(&curl_args, "-o")
            append(&curl_args, cache_path)
            curl_ok := platform.exec_cmd("curl", curl_args[:])
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

    // Phase 2: try the compact TSV index first. Falls back to the
    // 15MB JSON dump if the index doesn't exist.
    if index_results := search_index_casks(query_lower, limit); len(index_results) > 0 {
        defer delete(index_results)
        for r in index_results {
            exists := false
            for existing in results {
                if existing.token == r.token {
                    exists = true
                    break
                }
            }
            if !exists {
                append(&results, r)
                if len(results) >= limit {
                    break
                }
            } else {
                delete(r.token)
                delete(r.name)
                delete(r.desc)
                delete(r.version)
            }
        }
    } else {
        data, read_err := fetch_cached_api_list(CASK_LIST_URL, CASK_LIST_CACHE)
        if read_err == nil {
            defer delete(data)
            append_api_cask_matches_fast(data, &results, query_lower, limit)
        }
    }

    if len(results) == 0 {
        return out, .EOF
    }

    return results[:], nil
}

// fetch_urls_parallel_http2 issues all (url, out_file) pairs as parallel
// HTTP/2 requests over a single TCP+TLS connection (via curl's --http2
// --parallel). Replaces the posix.fork()-per-URL pattern used in
// run_update and run_upgrade. The HTTP/2 multiplexer lets many requests
// share one connection, so latency is dominated by the single TLS
// handshake + first request (~50-200ms cold, ~5-30ms warm), not N
// handshakes.
//
// `urls` and `out_files` must have the same length; `out_files[i]` is
// the destination for `urls[i]`. The file is overwritten on success;
// on failure (e.g. HTTP 4xx with the -f flag) the file is NOT touched.
// `headers` is a list of "Name: value" pairs applied to every request.
//
// Returns true iff curl exited 0. Use per-file checks (e.g.
// verify_tap_cache) to inspect individual outputs.
fetch_urls_parallel_http2 :: proc(urls, out_files: []string, headers: []string, z_files: []string = nil) -> bool {
    if len(urls) != len(out_files) || len(urls) == 0 {
        return false
    }
    args := make([dynamic]string, context.temp_allocator)
    defer delete(args)
    append(&args, "curl")
    // No `-f`: with `--parallel`, `-f` causes ALL output files to be
    // discarded when any single request fails (curl bug/feature). We
    // want the successful ones to land on disk so verify_tap_cache can
    // check them; the failed ones will leave behind a JSON error blob
    // (e.g. "rate limit exceeded") that starts with `{` and is rejected
    // by verify_tap_cache.
    append(&args, "-sL")
    append(&args, "--compressed")
    append(&args, "--no-progress-meter")
    append(&args, "--http2")
    append(&args, "--parallel")
    for h in headers {
        append(&args, "-H")
        append(&args, h)
    }
    for i in 0..<len(urls) {
        if len(z_files) > i && len(z_files[i]) > 0 {
            append(&args, "-z")
            append(&args, z_files[i])
        }
        append(&args, "-o")
        append(&args, out_files[i])
        append(&args, urls[i])
    }
    return platform.exec_cmd("curl", args[:])
}

// fetch_single_with_etag downloads a single URL to out_file using curl's
// --etag-compare and --etag-save. Returns true if the file was actually
// downloaded (200 response), false if 304 Not Modified or on error.
// The etag_file stores the ETag header value between runs.
fetch_single_with_etag :: proc(url, out_file, etag_file: string, headers: []string = nil) -> bool {
    args := make([dynamic]string, context.temp_allocator)
    defer delete(args)
    append(&args, "curl")
    append(&args, "-sfL")
    append(&args, "--compressed")
    append(&args, "--http2")
    if os.is_file(etag_file) {
        append(&args, "--etag-compare")
        append(&args, etag_file)
    }
    append(&args, "--etag-save")
    append(&args, etag_file)
    for h in headers {
        append(&args, "-H")
        append(&args, h)
    }
    append(&args, "-o")
    append(&args, out_file)
    append(&args, url)

    ok := platform.exec_cmd("curl", args[:])
    if !ok { return false }
    fi, fi_err := os.stat(out_file, context.temp_allocator)
    if fi_err != nil || fi.size == 0 { return false }
    return true
}

// fetch_etag_batch downloads multiple URLs sequentially in a single curl
// process using --next between transfers. Each URL gets its own ETag file.
// Saves one fork/exec per additional URL vs calling fetch_single_with_etag N
// times. Returns true if any output file was actually written (200 response).
fetch_etag_batch :: proc(urls, out_files, etag_files: []string, headers: []string) -> bool {
    if len(urls) == 0 || len(urls) != len(out_files) || len(urls) != len(etag_files) {
        return false
    }

    // Snapshot pre-transfer sizes so we can detect actual new content
    // vs. a 304 that left the old file untouched.
    pre_sizes := make([]i64, len(urls), context.temp_allocator)
    for i in 0..<len(urls) {
        if fi, err := os.stat(out_files[i], context.temp_allocator); err == nil {
            pre_sizes[i] = fi.size
        }
    }

    args := make([dynamic]string, context.temp_allocator)
    defer delete(args)

    for i in 0..<len(urls) {
        if i > 0 {
            append(&args, "--next")
        } else {
            append(&args, "curl")
        }
        append(&args, "-sfL")
        append(&args, "--compressed")
        append(&args, "--http2")
        if os.is_file(etag_files[i]) {
            append(&args, "--etag-compare")
            append(&args, etag_files[i])
        }
        append(&args, "--etag-save")
        append(&args, etag_files[i])
        for h in headers {
            append(&args, "-H")
            append(&args, h)
        }
        append(&args, "-o")
        append(&args, out_files[i])
        append(&args, urls[i])
    }

    ok := platform.exec_cmd("curl", args[:])
    if !ok { return false }

    any_updated := false
    for i in 0..<len(out_files) {
        if fi, err := os.stat(out_files[i], context.temp_allocator); err == nil && fi.size > 0 && fi.size != pre_sizes[i] {
            any_updated = true
        }
    }
    return any_updated
}

// warm_formulae_cache_parallel batch-fetches the per-formula JSON files
// for `names` that are not already cached, using a single
// --http2 --parallel curl invocation. The cached files are written to
// API_CACHE_DIR/formula-<name>.json, which is the path that
// fetch_formula_homebrew reads from. After this call, a subsequent
// per-name fetch_formula loop hits the warm cache for every name and
// only does a (sequential) disk read + JSON parse per formula.
//
// Returns the count of formulae that were actually fetched over the
// network (i.e. not already cached).
warm_formulae_cache_parallel :: proc(names: []string) -> int {
    if len(names) == 0 {
        return 0
    }
    refresh := os.get_env("UBREW_REFRESH", context.temp_allocator) == "1"
    urls := make([dynamic]string, context.temp_allocator)
    out_files := make([dynamic]string, context.temp_allocator)
    defer {
        delete(urls)
        delete(out_files)
    }
    for name in names {
        cache_path := fmt.tprintf("%s/formula-%s.json", API_CACHE_DIR, name)
        if !refresh && os.is_file(cache_path) {
            fi, fi_err := os.stat(cache_path, context.temp_allocator)
            if fi_err == nil && fi.size > 0 {
                continue
            }
        }
        url := fmt.tprintf("https://formulae.brew.sh/api/formula/%s.json", name)
        append(&urls, url)
        append(&out_files, cache_path)
    }
    if len(urls) == 0 {
        return 0
    }
    _ = fetch_urls_parallel_http2(urls[:], out_files[:], nil)
    return len(urls)
}

// warm_casks_cache_parallel is the cask counterpart of
// warm_formulae_cache_parallel.
warm_casks_cache_parallel :: proc(tokens: []string) -> int {
	if len(tokens) == 0 {
		return 0
	}
	refresh := os.get_env("UBREW_REFRESH", context.temp_allocator) == "1"
	urls := make([dynamic]string, context.temp_allocator)
	out_files := make([dynamic]string, context.temp_allocator)
	defer {
		delete(urls)
		delete(out_files)
	}
	for token in tokens {
		cache_path := fmt.tprintf("%s/cask-%s.json", API_CACHE_DIR, token)
		if !refresh && os.is_file(cache_path) {
			fi, fi_err := os.stat(cache_path, context.temp_allocator)
			if fi_err == nil && fi.size > 0 {
				continue
			}
		}
		url := fmt.tprintf("https://formulae.brew.sh/api/cask/%s.json", token)
		append(&urls, url)
		append(&out_files, cache_path)
	}
	if len(urls) == 0 {
		return 0
	}
	_ = fetch_urls_parallel_http2(urls[:], out_files[:], nil)
	return len(urls)
}

// which_formula returns the list of homebrew-core formula names whose
// `executables` array contains `cmd`. Tries the compact TSV index first
// (~5ms); falls back to the 30MB JSON scan (~140ms) if the index is
// missing. The result excludes any formulae that are already provided
// by something on PATH (so the suggestion is useful rather than redundant).
//
// This is the homebrew equivalent of the `command-not-found` hook
// data: when the user types an unknown command, the shell handler
// asks "which formula provides X?" and suggests an install.
which_formula :: proc(cmd: string) -> []string {
	if indexed := which_formula_indexed(cmd); indexed != nil {
		return indexed
	}

	// Auto-build the index if missing (first which-formula call)
	if !os.is_file(SEARCH_DB_PATH) {
		build_search_db()
		if indexed2 := which_formula_indexed(cmd); indexed2 != nil {
			return indexed2
		}
	}

	data, rerr := os.read_entire_file(FORMULA_LIST_CACHE, context.allocator)
	if rerr != nil || len(data) == 0 {
		return nil
	}
	defer delete(data)

	matches := make([dynamic]string, context.allocator)
	// Walk the JSON dump and find every formula whose `executables`
	// array contains the cmd string. Skip formulae that already have
	// the binary on PATH (those aren't the ones the user is missing).
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
				if formula_provides_executable(obj, cmd) {
					append(&matches, strings.clone(name, context.allocator))
				}
			}
		}
	}
	return matches[:]
}

// which_formula_indexed uses the SQLite search database's executables
// column instead of scanning the 30MB formula.json. Returns nil if the
// DB doesn't exist (caller should fall back to the JSON scan). Returns
// an empty (non-nil) slice if the DB exists but has no matches.
which_formula_indexed :: proc(cmd: string) -> []string {
	db, ok := _open_search_db()
	if !ok { return nil }
	defer fts.close(db)

	csql := strings.clone_to_cstring("SELECT name, platform FROM formulae WHERE instr(',' || executables || ',', ',' || ? || ',') > 0")
	defer delete(csql)
	stmt: ^Statement
	rc := fts.prepare_v2(db, csql, -1, &stmt, nil)
	if rc != .Ok { return nil }
	defer fts.finalize(stmt)

	_db_bind_text(stmt, 1, cmd)

	matches := make([dynamic]string, context.allocator)
	for fts.step(stmt) == .Row {
		name := _db_col_text(stmt, 0)
		platform := _db_col_text(stmt, 1)
		if !formula_available_on_current_os(platform) { continue }
		append(&matches, strings.clone(name, context.allocator))
	}

	// Return a non-nil empty slice to distinguish "exists but no matches"
	// from "doesn't exist".
	if len(matches) == 0 {
		dummy := make([dynamic]string, 0, 1, context.allocator)
		return dummy[:]
	}
	return matches[:]
}

// csv_contains checks whether a comma-separated value string contains
// the given command as an exact element. Both original and lowercased
// cmd are provided so we can do a fast check on the already-lowered input.
csv_contains :: proc(csv, cmd, cmd_lower: string) -> bool {
	s := 0
	for s <= len(csv) {
		comma := strings.index_byte(csv[s:], ',')
		e: int
		if comma >= 0 {
			e = s + comma
		} else {
			e = len(csv)
		}
		elem := csv[s:e]
		if len(elem) == len(cmd) && strings.to_lower(elem, context.temp_allocator) == cmd_lower {
			return true
		}
		if comma < 0 { break }
		s = e + 1
	}
	return false
}

// formula_provides_executable returns true iff the formula object's
// `executables` array contains `cmd` as a string element. Operates on
// the raw JSON object text (the same view as `append_api_formulae_matches_fast`).
formula_provides_executable :: proc(obj, cmd: string) -> bool {
	// Locate `"executables":[...]`
	marker := `"executables":[`
	start := strings.index(obj, marker)
	if start < 0 {
		return false
	}
	// Find the matching close bracket
	arr_start := start + len(marker)
	depth := 1
	i := arr_start
	in_string := false
	escaped := false
	for i < len(obj) {
		c := obj[i]
		if in_string {
			if escaped {
				escaped = false
			} else if c == '\\' {
				escaped = true
			} else if c == '"' {
				in_string = false
			}
			i += 1
			continue
		}
		if c == '"' {
			// Start of a string element. Read until closing quote.
			i += 1
			s := i
			esc2 := false
			for i < len(obj) {
				cc := obj[i]
				if esc2 {
					esc2 = false
				} else if cc == '\\' {
					esc2 = true
				} else if cc == '"' {
					break
				}
				i += 1
			}
			if i >= len(obj) {
				return false
			}
			if i - s == len(cmd) && obj[s:i] == cmd {
				return true
			}
			i += 1
			continue
		}
		if c == '[' { depth += 1 }
		else if c == ']' {
			depth -= 1
			if depth == 0 {
				return false
			}
		}
		i += 1
	}
	return false
}

refresh_cache_file :: proc(url, cache_path, temp_pattern: string) -> bool {
	_ = os.make_directory_all(API_CACHE_DIR, os.perm(0o755))

	temp_f, terr := os.create_temp_file("", temp_pattern)
	if terr != nil {
		return false
	}
	temp_file := strings.clone(os.name(temp_f), context.allocator)
	defer delete(temp_file)
	defer os.remove(temp_file)
	defer os.close(temp_f)

	curl_args := make([dynamic]string, context.temp_allocator)
	append(&curl_args, "curl")
	append(&curl_args, "-s")
	append(&curl_args, "-f")
	append(&curl_args, "-L")
	append(&curl_args, "--compressed")
	append(&curl_args, "--no-progress-meter")
	if os.is_file(cache_path) {
		append(&curl_args, "-z")
		append(&curl_args, cache_path)
	}
	append(&curl_args, url)
	append(&curl_args, "-o")
	append(&curl_args, temp_file)

	if !platform.exec_cmd("curl", curl_args[:]) {
		return false
	}

	fi, fi_err := os.stat(temp_file, context.temp_allocator)
	if fi_err == nil && fi.size > 0 {
		cp_args := []string{"cp", temp_file, cache_path}
		_ = platform.exec_cmd("cp", cp_args)
	}

	return os.is_file(cache_path)
}

refresh_homebrew_api_lists :: proc() -> bool {
	_ = os.make_directory_all(API_CACHE_DIR, os.perm(0o755))

	temp_f1, terr1 := os.create_temp_file("", "ubrew_formula_list_*.json")
	if terr1 != nil do return false
	temp_file1 := strings.clone(os.name(temp_f1), context.allocator)
	defer delete(temp_file1)
	defer os.remove(temp_file1)
	defer os.close(temp_f1)

	temp_f2, terr2 := os.create_temp_file("", "ubrew_cask_list_*.json")
	if terr2 != nil do return false
	temp_file2 := strings.clone(os.name(temp_f2), context.allocator)
	defer delete(temp_file2)
	defer os.remove(temp_file2)
	defer os.close(temp_f2)

	curl_args := make([dynamic]string, context.temp_allocator)
	append(&curl_args, "curl")
	append(&curl_args, "-s")
	append(&curl_args, "-L")
	append(&curl_args, "--compressed")
	append(&curl_args, "--no-progress-meter")
	append(&curl_args, "--http2")
	append(&curl_args, "--parallel")

	// First URL: formula.json
	if os.is_file(FORMULA_LIST_CACHE) {
		append(&curl_args, "-z")
		append(&curl_args, FORMULA_LIST_CACHE)
	}
	append(&curl_args, "-o")
	append(&curl_args, temp_file1)
	append(&curl_args, FORMULA_LIST_URL)

	// Second URL: cask.json
	if os.is_file(CASK_LIST_CACHE) {
		append(&curl_args, "-z")
		append(&curl_args, CASK_LIST_CACHE)
	}
	append(&curl_args, "-o")
	append(&curl_args, temp_file2)
	append(&curl_args, CASK_LIST_URL)

	if !platform.exec_cmd("curl", curl_args[:]) {
		return false
	}

	fi1, fi_err1 := os.stat(temp_file1, context.temp_allocator)
	if fi_err1 == nil && fi1.size > 0 {
		cp_args := []string{"cp", temp_file1, FORMULA_LIST_CACHE}
		_ = platform.exec_cmd("cp", cp_args)
	}

	fi2, fi_err2 := os.stat(temp_file2, context.temp_allocator)
	if fi_err2 == nil && fi2.size > 0 {
		cp_args := []string{"cp", temp_file2, CASK_LIST_CACHE}
		_ = platform.exec_cmd("cp", cp_args)
	}

	return os.is_file(FORMULA_LIST_CACHE) && os.is_file(CASK_LIST_CACHE)
}

tap_primary_candidates :: proc(t: tap.Tap, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	// Primary: the owner/repo from the explicit URL (if given), otherwise
	// the tap's own name (e.g. "valkyrie00/bbrew" -> "valkyrie00/bbrew").
	if len(t.url) > 0 {
		if owner_repo := extract_owner_repo_from_github_url(t.url); len(owner_repo) > 0 {
			append(&out, owner_repo)
		}
	} else if strings.contains(t.name, "/") {
		append(&out, t.name)
	}
	// Secondary: homebrew-<repo> variant (for taps named like
	// "valkyrie00/bbrew" that are actually at "valkyrie00/homebrew-bbrew").
	if strings.contains(t.name, "/") {
		slash := strings.index(t.name, "/")
		user := t.name[:slash]
		repo := t.name[slash + 1:]
		hb := fmt.tprintf("%s/homebrew-%s", user, repo)
		already_present := false
		for rc in out {
			if rc == hb {
				already_present = true
				break
			}
		}
		if !already_present {
			append(&out, hb)
		}
	}
	return out[:]
}

tap_api_url :: proc(t: tap.Tap, owner_repo: string, suffix: string) -> string {
	return fmt.tprintf("https://api.github.com/repos/%s%s?ref=%s", owner_repo, suffix, t.branch)
}

verify_tap_cache :: proc(t: tap.Tap) -> bool {
	cache_path := fmt.tprintf("%s/cache/taps/%s/Formula_listing.json", "/opt/ubrew", t.name)
	data, rerr := os.read_entire_file(cache_path, context.allocator)
	if rerr != nil {
		return false
	}
	defer delete(data)
	if len(data) == 0 {
		return false
	}
	i := 0
	for i < len(data) && (data[i] == ' ' || data[i] == '\t' || data[i] == '\n' || data[i] == '\r') {
		i += 1
	}
	return i < len(data) && data[i] == '['
}

// Infer_Hit_From_Cache reads the cached Formula_listing.json and determines
// which (candidate_index, suffix_index) produced it, by matching the first
// entry's GitHub API URL against the probe candidates. Returns false if the
// cache is empty or the URL cannot be parsed.
Infer_Hit_From_Cache :: proc(data: []u8, candidates: []string, suffixes: []string) -> (c_idx: int, s_idx: int, ok: bool) {
	text := string(data)
	// Find the first `"url"` key, then skip whitespace + colon to reach the value.
	url_key := strings.index(text, `"url"`)
	if url_key < 0 { return 0, 0, false }
	after_key := text[url_key + len(`"url"`):]
	// Skip whitespace and colon
	i := 0
	for i < len(after_key) && (after_key[i] == ' ' || after_key[i] == '\t' || after_key[i] == '\n' || after_key[i] == '\r' || after_key[i] == ':') {
		i += 1
	}
	if i >= len(after_key) || after_key[i] != '"' { return 0, 0, false }
	// Skip opening quote and "https://api.github.com/repos/" prefix
	url_start := i + 1
	prefix := "https://api.github.com/repos/"
	if len(after_key) < url_start + len(prefix) { return 0, 0, false }
	if after_key[url_start:url_start + len(prefix)] != prefix { return 0, 0, false }
	rest := after_key[url_start + len(prefix):]
	end := strings.index(rest, `"`)
	if end < 0 { return 0, 0, false }
	full_path := rest[:end]
	// full_path is "owner/repo/contents/..." or "owner/repo/contents/Formula/..."
	first_slash := strings.index(full_path, "/")
	if first_slash < 0 { return 0, 0, false }
	remainder := full_path[first_slash + 1:]
	second_slash := strings.index(remainder, "/")
	if second_slash < 0 { return 0, 0, false }
	owner_repo := full_path[:first_slash + 1 + second_slash]

	// Determine which suffix was used
	path_after_repo := remainder[second_slash + 1:]
	suffix_is_formula := strings.has_prefix(path_after_repo, "contents/Formula")
	suffix_is_root := strings.has_prefix(path_after_repo, "contents/")
	if !suffix_is_formula && !suffix_is_root { return 0, 0, false }
	s_idx = 0 if suffix_is_formula else 1

	for c, i in candidates {
		if c == owner_repo {
			return i, s_idx, true
		}
	}
	return 0, 0, false
}

// Phase 2: build a compact TSV search index from the JSON dump.
// The full formula.json is 30MB / 8403 formulae and cask.json is 15MB /
// ~5000 casks. The formulae index is `name\tdesc\tversion\texecutables\n`
// per record (~600KB). The casks index is `token\tname\tdesc\tversion\n`
// per record (~250KB). Substring search on the TSV is ~50x faster than
// parsing the JSON for matches. The executables column also enables
// which_formula to do a fast index lookup instead of scanning the 30MB
// formula.json.
//
// Writes to a temp file in API_CACHE_DIR then atomically renames over
// the target. Returns true on success.
// json_raw_bottle_platforms inspects a raw formula JSON object and returns
// a compact platform tag based on which bottle keys are present:
//   "A"  – the "all" key is present (works everywhere)
//   "LM" – both Linux and macOS keys are present
//   "L"  – only Linux keys are present
//   "M"  – only macOS keys are present
//   ""   – no bottle section found (head-only / source-only formula)
// This avoids full JSON parsing; it simply checks for key substrings
// within the "files" sub-object of the bottle section.
json_raw_bottle_platforms :: proc(obj: string) -> string {
	// Locate the correct "bottle" section (must be followed by ":" and then "{")
	bottle_idx := -1
	start_search := 0
	for {
		idx := strings.index(obj[start_search:], "\"bottle\"")
		if idx < 0 {
			break
		}
		idx += start_search
		
		// Verify character after "bottle"
		pos := idx + len("\"bottle\"")
		// skip whitespace
		for pos < len(obj) && (obj[pos] == ' ' || obj[pos] == '\t' || obj[pos] == '\r' || obj[pos] == '\n') {
			pos += 1
		}
		if pos < len(obj) && obj[pos] == ':' {
			pos += 1
			for pos < len(obj) && (obj[pos] == ' ' || obj[pos] == '\t' || obj[pos] == '\r' || obj[pos] == '\n') {
				pos += 1
			}
			if pos < len(obj) && obj[pos] == '{' {
				bottle_idx = idx
				break
			}
		}
		start_search = idx + 1
	}

	if bottle_idx < 0 {
		return ""
	}
	// Narrow the search to the bottle section. Find the opening brace
	// of the bottle object and scan until its matching closing brace.
	rest := obj[bottle_idx:]
	brace_start := strings.index_byte(rest, '{')
	if brace_start < 0 {
		return ""
	}
	// Find the matching closing brace by depth-tracking.
	depth := 0
	bottle_end := brace_start
	in_str := false
	esc := false
	for i := brace_start; i < len(rest); i += 1 {
		c := rest[i]
		if in_str {
			if esc { esc = false }
			else if c == '\\' { esc = true }
			else if c == '"' { in_str = false }
			continue
		}
		if c == '"' { in_str = true; continue }
		if c == '{' { depth += 1 }
		else if c == '}' {
			depth -= 1
			if depth == 0 {
				bottle_end = i + 1
				break
			}
		}
	}
	bottle_section := rest[:bottle_end]

	// Check for the universal "all" key
	if strings.contains(bottle_section, "\"all\"") {
		return "A"
	}

	has_linux := strings.contains(bottle_section, "\"x86_64_linux\"") ||
	             strings.contains(bottle_section, "\"arm64_linux\"")
	has_macos := strings.contains(bottle_section, "\"arm64_sonoma\"") ||
	             strings.contains(bottle_section, "\"arm64_sequoia\"") ||
	             strings.contains(bottle_section, "\"arm64_ventura\"") ||
	             strings.contains(bottle_section, "\"ventura\"") ||
	             strings.contains(bottle_section, "\"sonoma\"") ||
	             strings.contains(bottle_section, "\"sequoia\"") ||
	             strings.contains(bottle_section, "\"monterey\"") ||
	             strings.contains(bottle_section, "\"big_sur\"") ||
	             strings.contains(bottle_section, "\"catalina\"")

	if has_linux && has_macos { return "LM" }
	if has_linux             { return "L" }
	if has_macos             { return "M" }
	return ""
}

// formula_available_on_current_os returns true if a platform tag from
// the search index indicates the formula is available on the current OS.
// An empty tag (source-only) is treated as available everywhere.
formula_available_on_current_os :: proc(platform_tag: string) -> bool {
	if len(platform_tag) == 0 || platform_tag == "A" || platform_tag == "LM" {
		return true
	}
	when ODIN_OS == .Linux {
		return platform_tag == "L"
	} else when ODIN_OS == .Darwin {
		return platform_tag == "M"
	}
	return true
}

// cask_available_on_current_os returns true if a platform tag from the
// cask search index indicates the cask is available on the current OS.
cask_available_on_current_os :: proc(platform_tag: string) -> bool {
	if len(platform_tag) == 0 || platform_tag == "A" || platform_tag == "LM" {
		return true
	}
	when ODIN_OS == .Linux {
		return platform_tag == "L"
	} else when ODIN_OS == .Darwin {
		return platform_tag == "M"
	}
	return true
}

// --- SQLite Search Database ---

_db_bind_text :: proc(stmt: ^Statement, idx: i32, val: string) {
	cstr := cstring(raw_data(val))
	fts.bind_text(stmt, c.int(idx), cstr, c.int(len(val)), Destructor{behaviour = .Transient})
}

_db_col_text :: proc(stmt: ^Statement, iCol: i32) -> string {
	cstr := fts.column_text(stmt, c.int(iCol))
	if cstr == nil { return "" }
	return string(cstr)
}

escape_like :: proc(s: string, allocator := context.temp_allocator) -> string {
	buf := strings.builder_make(allocator)
	for i in 0..<len(s) {
		b := s[i]
		if b == '%' || b == '_' || b == '\\' {
			strings.write_byte(&buf, '\\')
		}
		strings.write_byte(&buf, b)
	}
	return strings.to_string(buf)
}

// build_fts_query converts a user's lowercase search string into an FTS5
// MATCH query. Each word gets '*' appended for prefix matching so that
// typing "wget" also matches "wget2", "wgetter", etc.  Terms are AND-ed
// (space-separated, which is FTS5's default conjunction operator).
build_fts_query :: proc(s: string, allocator := context.temp_allocator) -> string {
	buf := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		// Skip whitespace
		for i < len(s) && (s[i] == ' ' || s[i] == '	' || s[i] == '\n' || s[i] == '\r') {
			i += 1
		}
		if i >= len(s) { break }

		if len(strings.to_string(buf)) > 0 {
			strings.write_byte(&buf, ' ')
		}

		start := i
		for i < len(s) && s[i] != ' ' && s[i] != '	' && s[i] != '\n' && s[i] != '\r' {
			i += 1
		}
		term := s[start:i]
		strings.write_string(&buf, term)
		strings.write_byte(&buf, '*')
	}
	return strings.to_string(buf)
}

build_search_db :: proc() -> bool {
	if fts.initialize() != .Ok { return false }

	data_f, rerr_f := os.read_entire_file(FORMULA_LIST_CACHE, context.allocator)
	if rerr_f != nil || len(data_f) == 0 { return false }
	defer delete(data_f)

	data_c, rerr_c := os.read_entire_file(CASK_LIST_CACHE, context.allocator)
	if rerr_c != nil || len(data_c) == 0 { return false }
	defer delete(data_c)

	os.make_directory_all(API_CACHE_DIR)

	tmp_path := SEARCH_DB_PATH + ".tmp"

	db: ^Connection
	cpath := strings.clone_to_cstring(tmp_path, context.temp_allocator)
	rc := fts.open_v2(cpath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
	if rc != .Ok { return false }
	defer fts.close(db)

	fts.exec(db, strings.clone_to_cstring("PRAGMA synchronous=OFF", context.temp_allocator), nil, nil, nil)
	fts.exec(db, strings.clone_to_cstring("PRAGMA journal_mode=MEMORY", context.temp_allocator), nil, nil, nil)
	fts.exec(db, strings.clone_to_cstring("PRAGMA cache_size=-64000", context.temp_allocator), nil, nil, nil)

	ddl := strings.clone_to_cstring(
		"DROP TABLE IF EXISTS formulae;" +
		"CREATE TABLE formulae(name TEXT, desc TEXT, version TEXT, executables TEXT, platform TEXT);" +
		"DROP TABLE IF EXISTS casks;" +
		"CREATE TABLE casks(token TEXT, name TEXT, desc TEXT, version TEXT, platform TEXT);" +
		"DROP TABLE IF EXISTS registry;" +
		"CREATE TABLE registry(token TEXT, name TEXT, desc TEXT, version TEXT, kind TEXT, platform TEXT);" +
		// FTS5 virtual tables for full-text search (also dropped when content tables are dropped)
		"DROP TABLE IF EXISTS formulae_fts;" +
		"CREATE VIRTUAL TABLE formulae_fts USING fts5(name, desc, version, executables, platform, tokenize='porter unicode61');" +
		"DROP TABLE IF EXISTS casks_fts;" +
		"CREATE VIRTUAL TABLE casks_fts USING fts5(token, name, desc, version, platform, tokenize='porter unicode61');" +
		"DROP TABLE IF EXISTS registry_fts;" +
		"CREATE VIRTUAL TABLE registry_fts USING fts5(token, name, desc, version, kind, platform, tokenize='porter unicode61');",
		context.temp_allocator)
	rc = fts.exec(db, ddl, nil, nil, nil)
	if rc != .Ok { return false }

	stmt: ^Statement
	csql := strings.clone_to_cstring("INSERT INTO formulae(name, desc, version, executables, platform) VALUES(?, ?, ?, ?, ?)")
	defer delete(csql)
	rc = fts.prepare_v2(db, csql, -1, &stmt, nil)
	if rc != .Ok { return false }
	defer fts.finalize(stmt)

	fts.exec(db, "BEGIN TRANSACTION", nil, nil, nil)

	text := string(data_f)
	depth := 0
	obj_start := 0
	in_string := false
	escaped := false
	for i := 0; i < len(text); i += 1 {
		c := text[i]
		if in_string {
			if escaped { escaped = false }
			else if c == '\\' { escaped = true }
			else if c == '"' { in_string = false }
			continue
		}
		if c == '"' { in_string = true; continue }
		if c == '{' {
			if depth == 0 { obj_start = i }
			depth += 1
			continue
		}
		if c == '}' && depth > 0 {
			depth -= 1
			if depth == 0 {
				obj := text[obj_start:i+1]
				name := json_field_string_raw(obj, "name")
				if name == "" { continue }
				desc := json_field_string_raw(obj, "desc")
				version := json_field_string_raw(obj, "stable")
				execs := json_field_array_as_csv(obj, "executables")
				plat := json_raw_bottle_platforms(obj)

				fts.reset(stmt)
				_db_bind_text(stmt, 1, name)
				_db_bind_text(stmt, 2, desc)
				_db_bind_text(stmt, 3, version)
				_db_bind_text(stmt, 4, execs)
				_db_bind_text(stmt, 5, plat)
				if fts.step(stmt) != .Done { return false }
			}
		}
	}
	if fts.exec(db, strings.clone_to_cstring("COMMIT", context.temp_allocator), nil, nil, nil) != .Ok { return false }

	cstmt: ^Statement
	ccsql := strings.clone_to_cstring("INSERT INTO casks(token, name, desc, version, platform) VALUES(?, ?, ?, ?, ?)")
	defer delete(ccsql)
	rc = fts.prepare_v2(db, ccsql, -1, &cstmt, nil)
	if rc != .Ok { return false }
	defer fts.finalize(cstmt)

	fts.exec(db, "BEGIN TRANSACTION", nil, nil, nil)

	text_c := string(data_c)
	depth = 0
	obj_start = 0
	in_string = false
	escaped = false
	for i := 0; i < len(text_c); i += 1 {
		c := text_c[i]
		if in_string {
			if escaped { escaped = false }
			else if c == '\\' { escaped = true }
			else if c == '"' { in_string = false }
			continue
		}
		if c == '"' { in_string = true; continue }
		if c == '{' {
			if depth == 0 { obj_start = i }
			depth += 1
			continue
		}
		if c == '}' && depth > 0 {
			depth -= 1
			if depth == 0 {
				obj := text_c[obj_start:i+1]
				token := json_field_string_raw(obj, "token")
				if token == "" { continue }
				name := json_field_string_raw(obj, "name")
				if name == "" { name = token }
				desc := json_field_string_raw(obj, "desc")
				v := json_field_string_raw(obj, "version")
				plat := "M"

				fts.reset(cstmt)
				_db_bind_text(cstmt, 1, token)
				_db_bind_text(cstmt, 2, name)
				_db_bind_text(cstmt, 3, desc)
				_db_bind_text(cstmt, 4, v)
				_db_bind_text(cstmt, 5, plat)
				if fts.step(cstmt) != .Done { return false }
			}
		}
	}
	if fts.exec(db, strings.clone_to_cstring("COMMIT", context.temp_allocator), nil, nil, nil) != .Ok { return false }

	// Index upstream registry entries into the DB
	rstmt: ^Statement
	rcsql := strings.clone_to_cstring("INSERT INTO registry(token, name, desc, version, kind, platform) VALUES(?, ?, ?, ?, ?, ?)")
	defer delete(rcsql)
	rc = fts.prepare_v2(db, rcsql, -1, &rstmt, nil)
	if rc != .Ok { return false }
	defer fts.finalize(rstmt)

	reg_path := get_registry_path()
	if os.is_file(reg_path) {
		if reg_data, reg_err := os.read_entire_file(reg_path, context.allocator); reg_err == nil {
			defer delete(reg_data)
			if reg_val, reg_parse_err := json.parse(reg_data); reg_parse_err == nil {
				if root_obj, root_ok := reg_val.(json.Object); root_ok {
					if records_arr, arr_ok := json_array_or_nil(root_obj, "records"); arr_ok {
						fts.exec(db, "BEGIN TRANSACTION", nil, nil, nil)
						for rec_item in records_arr {
							if rec_obj, rec_ok := rec_item.(json.Object); rec_ok {
								token, name, desc, version, kind := "", "", "", "", ""
								if tv, ok := rec_obj["token"]; ok { if ts, ok := tv.(json.String); ok { token = string(ts) } }
								if nv, ok := rec_obj["name"]; ok { if ns, ok := nv.(json.String); ok { name = string(ns) } }
								if dv, ok := rec_obj["desc"]; ok { if ds, ok := dv.(json.String); ok { desc = string(ds) } }
								if kv, ok := rec_obj["kind"]; ok { if ks, ok := kv.(json.String); ok { kind = string(ks) } }
								if rv, ok := rec_obj["resolved"]; ok {
									if ro, ok := rv.(json.Object); ok {
										if vv, ok := ro["version"]; ok {
											if vs, ok := vv.(json.String); ok { version = string(vs) }
										}
									}
								}
								if token == "" && name != "" { token = name }
								if token == "" { continue }

								fts.reset(rstmt)
								rplat := registry_entry_platform_tag(rec_obj)
								_db_bind_text(rstmt, 1, token)
								_db_bind_text(rstmt, 2, name)
								_db_bind_text(rstmt, 3, desc)
								_db_bind_text(rstmt, 4, version)
								_db_bind_text(rstmt, 5, kind)
								_db_bind_text(rstmt, 6, rplat)
								if fts.step(rstmt) != .Done { return false }
							}
						}
						if fts.exec(db, strings.clone_to_cstring("COMMIT", context.temp_allocator), nil, nil, nil) != .Ok { return false }
					}
				}
				json.destroy_value(reg_val)
			}
		}
	}

	// Create indexes after all data is loaded (faster than per-insert)
	index_sqls := []string{
		"CREATE INDEX IF NOT EXISTS idx_formulae_name ON formulae(name)",
		"CREATE INDEX IF NOT EXISTS idx_casks_token ON casks(token)",
		"CREATE INDEX IF NOT EXISTS idx_registry_token ON registry(token)",
		"CREATE INDEX IF NOT EXISTS idx_registry_kind ON registry(kind)",
	}
	for idx_sql in index_sqls {
		if fts.exec(db, strings.clone_to_cstring(idx_sql, context.temp_allocator), nil, nil, nil) != .Ok { return false }
	}

	// Populate FTS5 virtual tables from the content tables.
	// Done as a single INSERT...SELECT per table, which is much faster
	// than per-row inserts into the FTS index.
	fts_populate := []string{
		"INSERT INTO formulae_fts(rowid, name, desc, version, executables, platform) SELECT rowid, name, desc, version, executables, platform FROM formulae",
		"INSERT INTO casks_fts(rowid, token, name, desc, version, platform) SELECT rowid, token, name, desc, version, platform FROM casks",
		"INSERT INTO registry_fts(rowid, token, name, desc, version, kind, platform) SELECT rowid, token, name, desc, version, kind, platform FROM registry",
	}
	for pop_sql in fts_populate {
		if fts.exec(db, strings.clone_to_cstring(pop_sql, context.temp_allocator), nil, nil, nil) != .Ok {
			return false
		}
	}

	os.remove(SEARCH_DB_PATH)
	if os.rename(tmp_path, SEARCH_DB_PATH) != nil { return false }
	return true
}

build_formula_search_index :: proc() -> bool { return build_search_db() }

build_cask_search_index :: proc() -> bool { return build_search_db() }

build_search_index :: proc() -> (formulae_ok, casks_ok: bool) {
	if !index_is_stale() { return true, true }
	ok := build_search_db()
	return ok, ok
}

index_is_stale :: proc() -> bool {
	if !os.is_file(SEARCH_DB_PATH) { return true }
	dst_info, dst_err := os.stat(SEARCH_DB_PATH, context.allocator)
	if dst_err != nil { return true }
	defer os.file_info_delete(dst_info, context.allocator)

	src_paths := []string{FORMULA_LIST_CACHE, CASK_LIST_CACHE, get_registry_path()}
	for src_path in src_paths {
		src_info, src_err := os.stat(src_path, context.temp_allocator)
		if src_err != nil { continue }
		if time.time_to_unix(src_info.modification_time) >
		   time.time_to_unix(dst_info.modification_time) {
			return true
		}
	}
	return false
}

// --- SQLite-backed search ---

_open_search_db :: proc() -> (db: ^Connection, ok: bool) {
	fts.initialize()
	cpath := strings.clone_to_cstring(SEARCH_DB_PATH)
	defer delete(cpath)
	rc := fts.open_v2(cpath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
	if rc != .Ok { return nil, false }
	return db, true
}

search_index_formulae :: proc(query_lower: string, limit: int) -> []Formula_Search_Result {
	db, ok := _open_search_db()
	if !ok { return nil }
	defer fts.close(db)

	fts_q := build_fts_query(query_lower)

	// Step 1: core formulae via `formulae_fts`. Three MATCH binds,
	// no `kind` predicate, no UNION. The fix isolates the broken
	// `AND kind MATCH …` from the (now-fine) per-column MATCH.
	stmt: ^Statement
	csql0 := strings.clone_to_cstring(
		"SELECT name, desc, version, platform FROM formulae_fts " +
		"WHERE name MATCH ? OR desc MATCH ? OR executables MATCH ? " +
		"LIMIT ?")
	defer delete(csql0)
	if fts.prepare_v2(db, csql0, -1, &stmt, nil) != .Ok { return nil }
	defer fts.finalize(stmt)
	_db_bind_text(stmt, 1, fts_q)
	_db_bind_text(stmt, 2, fts_q)
	_db_bind_text(stmt, 3, fts_q)
	fts.bind_int(stmt, 4, i32(limit))

	out := make([dynamic]Formula_Search_Result)
	for fts.step(stmt) == .Row {
		name := _db_col_text(stmt, 0)
		if name == "" { continue }
		desc := _db_col_text(stmt, 1)
		version := _db_col_text(stmt, 2)
		platform := _db_col_text(stmt, 3)
		if !formula_available_on_current_os(platform) { continue }
		append(&out, Formula_Search_Result{
			name    = strings.clone(name),
			desc    = strings.clone(desc),
			version = strings.clone(version),
		})
		if len(out) >= limit { break }
	}

	// Step 2: 3rd-party-tap formulae via `registry_fts`. The original
	// code used a `UNION` whose second arm carried
	// `AND kind MATCH 'formula'`. Under SQLite FTS5 that predicate
	// returns zero rows when its rowid source also has other MATCH
	// operators in the same WHERE (the FTS5 planner mixes the two
	// expressions across columns instead of AND-intersecting).
	// We isolate `registry_fts` into a separate prepare and look up
	// the row's `kind` in the regular `registry` content table.
	stmt2: ^Statement
	csql1 := strings.clone_to_cstring(
		"SELECT token, name, desc, version, platform FROM registry_fts " +
		"WHERE token MATCH ? OR name MATCH ? OR desc MATCH ? " +
		"LIMIT ?")
	defer delete(csql1)
	if fts.prepare_v2(db, csql1, -1, &stmt2, nil) != .Ok { return out[:] }
	defer fts.finalize(stmt2)
	_db_bind_text(stmt2, 1, fts_q)
	_db_bind_text(stmt2, 2, fts_q)
	_db_bind_text(stmt2, 3, fts_q)
	fts.bind_int(stmt2, 4, i32(limit))

	for fts.step(stmt2) == .Row {
		token := _db_col_text(stmt2, 0)
		if token == "" { continue }
		if !_registry_kind_is(db, token, "formula") { continue }
		desc := _db_col_text(stmt2, 2)
		version := _db_col_text(stmt2, 3)
		platform := _db_col_text(stmt2, 4)
		if !formula_available_on_current_os(platform) { continue }
		append(&out, Formula_Search_Result{
			name    = strings.clone(token),
			desc    = strings.clone(desc),
			version = strings.clone(version),
		})
		if len(out) >= limit { break }
	}
	return out[:]
}

search_index_casks :: proc(query_lower: string, limit: int) -> []Cask_Search_Result {
	db, ok := _open_search_db()
	if !ok { return nil }
	defer fts.close(db)

	fts_q := build_fts_query(query_lower)

	// Same two-step pattern as `search_index_formulae`: split the
	// core casks FTS query from the registry-tap query to avoid the
	// broken `AND kind MATCH …` inside a UNION.
	stmt: ^Statement
	csql0 := strings.clone_to_cstring(
		"SELECT token, name, desc, version, platform FROM casks_fts " +
		"WHERE token MATCH ? OR name MATCH ? OR desc MATCH ? " +
		"LIMIT ?")
	defer delete(csql0)
	if fts.prepare_v2(db, csql0, -1, &stmt, nil) != .Ok { return nil }
	defer fts.finalize(stmt)
	_db_bind_text(stmt, 1, fts_q)
	_db_bind_text(stmt, 2, fts_q)
	_db_bind_text(stmt, 3, fts_q)
	fts.bind_int(stmt, 4, i32(limit))

	out := make([dynamic]Cask_Search_Result)
	for fts.step(stmt) == .Row {
		token := _db_col_text(stmt, 0)
		if token == "" { continue }
		name := _db_col_text(stmt, 1)
		desc := _db_col_text(stmt, 2)
		version := _db_col_text(stmt, 3)
		platform := _db_col_text(stmt, 4)
		if !cask_available_on_current_os(platform) { continue }
		append(&out, Cask_Search_Result{
			token   = strings.clone(token),
			name    = strings.clone(name),
			desc    = strings.clone(desc),
			version = strings.clone(version),
		})
		if len(out) >= limit { break }
	}

	// Tap-provided casks via `registry_fts`, filtered by `kind` in
	// the regular `registry` content table (see the formulae proc for
	// why the inline `AND kind MATCH …` is broken).
	stmt2: ^Statement
	csql1 := strings.clone_to_cstring(
		"SELECT token, name, desc, version, platform FROM registry_fts " +
		"WHERE token MATCH ? OR name MATCH ? OR desc MATCH ? " +
		"LIMIT ?")
	defer delete(csql1)
	if fts.prepare_v2(db, csql1, -1, &stmt2, nil) != .Ok { return out[:] }
	defer fts.finalize(stmt2)
	_db_bind_text(stmt2, 1, fts_q)
	_db_bind_text(stmt2, 2, fts_q)
	_db_bind_text(stmt2, 3, fts_q)
	fts.bind_int(stmt2, 4, i32(limit))

	for fts.step(stmt2) == .Row {
		token := _db_col_text(stmt2, 0)
		if token == "" { continue }
		if !_registry_kind_is(db, token, "cask") { continue }
		name := _db_col_text(stmt2, 1)
		desc := _db_col_text(stmt2, 2)
		version := _db_col_text(stmt2, 3)
		platform := _db_col_text(stmt2, 4)
		if !cask_available_on_current_os(platform) { continue }
		append(&out, Cask_Search_Result{
			token   = strings.clone(token),
			name    = strings.clone(name),
			desc    = strings.clone(desc),
			version = strings.clone(version),
		})
		if len(out) >= limit { break }
	}
	return out[:]
}

// _registry_kind_is returns true iff registry.kind == kind_for for the
// given token. The kind filter is run against the regular content table
// rather than inside a virtual-table MATCH predicate (the FTS5 quirk
// motivating this split). Each call is one prepared/executed query;
// for large hit sets a small per-search cache could amortise this —
// not currently a hot path because `append_tap_formulae_matches` in
// main.odin still hits `registry` directly.
_registry_kind_is :: proc(db: ^Connection, token: string, kind_for: string) -> bool {
	stmt: ^Statement
	csql := strings.clone_to_cstring(
		"SELECT kind FROM registry WHERE token = ? AND kind = ?")
	defer delete(csql)
	if fts.prepare_v2(db, csql, -1, &stmt, nil) != .Ok { return false }
	defer fts.finalize(stmt)
	_db_bind_text(stmt, 1, token)
	_db_bind_text(stmt, 2, kind_for)
	got := false
	for fts.step(stmt) == .Row {
		k := _db_col_text(stmt, 0)
		if k == kind_for { got = true; break }
	}
	return got
}


is_core_formula :: proc(name: string) -> bool {
	db, ok := _open_search_db()
	if !ok { return false }
	defer fts.close(db)

	stmt: ^Statement
	csql := strings.clone_to_cstring("SELECT 1 FROM formulae WHERE name = ?")
	defer delete(csql)
	rc := fts.prepare_v2(db, csql, -1, &stmt, nil)
	if rc != .Ok { return false }
	defer fts.finalize(stmt)

	_db_bind_text(stmt, 1, name)
	return fts.step(stmt) == .Row
}

is_core_cask :: proc(name: string) -> bool {
	db, ok := _open_search_db()
	if !ok { return false }
	defer fts.close(db)

	stmt: ^Statement
	csql := strings.clone_to_cstring("SELECT 1 FROM casks WHERE token = ?")
	defer delete(csql)
	rc := fts.prepare_v2(db, csql, -1, &stmt, nil)
	if rc != .Ok { return false }
	defer fts.finalize(stmt)

	_db_bind_text(stmt, 1, name)
	return fts.step(stmt) == .Row
}

// --- Public helpers for main.odin ---

get_all_formula_names :: proc(allocator := context.allocator) -> []string {
	db, ok := _open_search_db()
	if !ok { return nil }
	defer fts.close(db)

	csql := strings.clone_to_cstring(
		"SELECT name, platform FROM formulae " +
		"UNION SELECT token, platform FROM registry WHERE kind = 'formula'")
	defer delete(csql)
	stmt: ^Statement
	rc := fts.prepare_v2(db, csql, -1, &stmt, nil)
	if rc != .Ok { return nil }
	defer fts.finalize(stmt)

	out := make([dynamic]string, allocator)
	for fts.step(stmt) == .Row {
		name := _db_col_text(stmt, 0)
		platform := _db_col_text(stmt, 1)
		if !formula_available_on_current_os(platform) { continue }
		append(&out, strings.clone(name, allocator))
	}
	return out[:]
}

search_db_all_formulae :: proc(allocator := context.allocator) -> []Formula_Search_Result {
	db, ok := _open_search_db()
	if !ok { return nil }
	defer fts.close(db)

	csql := strings.clone_to_cstring(
		"SELECT name, desc, version, platform FROM formulae " +
		"UNION SELECT token, desc, version, platform FROM registry WHERE kind = 'formula'")
	defer delete(csql)
	stmt: ^Statement
	rc := fts.prepare_v2(db, csql, -1, &stmt, nil)
	if rc != .Ok { return nil }
	defer fts.finalize(stmt)

	out := make([dynamic]Formula_Search_Result, allocator)
	for fts.step(stmt) == .Row {
		name := _db_col_text(stmt, 0)
		desc := _db_col_text(stmt, 1)
		version := _db_col_text(stmt, 2)
		platform := _db_col_text(stmt, 3)
		if !formula_available_on_current_os(platform) { continue }
		append(&out, Formula_Search_Result{
			name = strings.clone(name, allocator),
			desc = strings.clone(desc, allocator),
			version = strings.clone(version, allocator),
		})
	}
	return out[:]
}

search_db_all_casks :: proc(allocator := context.allocator) -> []Cask_Search_Result {
	db, ok := _open_search_db()
	if !ok { return nil }
	defer fts.close(db)

	csql := strings.clone_to_cstring(
		"SELECT token, name, desc, version, platform FROM casks " +
		"UNION SELECT token, name, desc, version, platform FROM registry WHERE kind = 'cask'")
	defer delete(csql)
	stmt: ^Statement
	rc := fts.prepare_v2(db, csql, -1, &stmt, nil)
	if rc != .Ok { return nil }
	defer fts.finalize(stmt)

	out := make([dynamic]Cask_Search_Result, allocator)
	for fts.step(stmt) == .Row {
		token := _db_col_text(stmt, 0)
		name := _db_col_text(stmt, 1)
		desc := _db_col_text(stmt, 2)
		version := _db_col_text(stmt, 3)
		platform := _db_col_text(stmt, 4)
		if !cask_available_on_current_os(platform) { continue }
		append(&out, Cask_Search_Result{
			token = strings.clone(token, allocator),
			name = strings.clone(name, allocator),
			desc = strings.clone(desc, allocator),
			version = strings.clone(version, allocator),
		})
	}
	return out[:]
}

warm_mixed_cache_parallel :: proc(formula_names, cask_tokens: []string) -> int {
	if len(formula_names) == 0 && len(cask_tokens) == 0 {
		return 0
	}
	refresh := os.get_env("UBREW_REFRESH", context.temp_allocator) == "1"
	urls := make([dynamic]string, context.temp_allocator)
	out_files := make([dynamic]string, context.temp_allocator)
	defer {
		delete(urls)
		delete(out_files)
	}

	for name in formula_names {
		if strings.contains(name, "/") do continue

		cache_path := fmt.tprintf("%s/formula-%s.json", API_CACHE_DIR, name)
		if !refresh && os.is_file(cache_path) {
			fi, fi_err := os.stat(cache_path, context.temp_allocator)
			if fi_err == nil && fi.size > 0 {
				continue
			}
		}
		url := fmt.tprintf("https://formulae.brew.sh/api/formula/%s.json", name)
		append(&urls, url)
		append(&out_files, cache_path)
	}

	for token in cask_tokens {
		if strings.contains(token, "/") do continue

		cache_path := fmt.tprintf("%s/cask-%s.json", API_CACHE_DIR, token)
		if !refresh && os.is_file(cache_path) {
			fi, fi_err := os.stat(cache_path, context.temp_allocator)
			if fi_err == nil && fi.size > 0 {
				continue
			}
		}
		url := fmt.tprintf("https://formulae.brew.sh/api/cask/%s.json", token)
		append(&urls, url)
		append(&out_files, cache_path)
	}

	if len(urls) == 0 {
		return 0
	}
	_ = fetch_urls_parallel_http2(urls[:], out_files[:], nil)
	return len(urls)
}

