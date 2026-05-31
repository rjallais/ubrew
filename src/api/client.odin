package api

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:strings"
import "core:c/libc"
import "../cask"
import "../formula"

REGISTRY_PATH :: "registry/upstream.json"

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
    hay_lower := strings.to_lower(haystack, context.temp_allocator)
    return strings.contains(hay_lower, needle_lower)
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
    defer os.close(temp_f)
    temp_file := os.name(temp_f)
    defer os.remove(temp_file)

    cmd := fmt.tprintf("curl -sfSL \"%s\" -o \"%s\"", url, temp_file)
    cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
    if libc.system(cmd_cstr) != 0 {
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
    data, read_err := os.read_entire_file(REGISTRY_PATH, context.allocator)
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
    records_arr, ok := json_array_or_nil(root_obj, "records")
    if !ok {
        return c, .EOF
    }

    for rec_item in records_arr {
        rec_obj := rec_item.(json.Object)
        if json_string_or_empty(rec_obj, "kind") != "cask" {
            continue
        }
        if json_string_or_empty(rec_obj, "token") != token {
            continue
        }

        c.token = strings.clone(token)

        name := json_string_or_empty(rec_obj, "name")
        if name == "" {
            c.name = strings.clone(token)
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
                    append(&artifacts_list, cask.Binary_Artifact{source = strings.clone(path), target = strings.clone(path)})
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
        }
    }
    delete(c.artifacts)
}

fetch_formula :: proc(name: string) -> (f: formula.Formula, err: json.Error) {
    url := fmt.tprintf("https://formulae.brew.sh/api/formula/%s.json", name)

    temp_f, terr := os.create_temp_file("", "ubrew_fetch_formula_*.json")
    if terr != nil {
        return f, .EOF
    }
    defer os.close(temp_f)
    temp_file := os.name(temp_f)
    defer os.remove(temp_file)

    cmd := fmt.tprintf("curl -sfSL \"%s\" -o \"%s\"", url, temp_file)
    cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
    if libc.system(cmd_cstr) != 0 {
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

    return f, nil
}

destroy_formula :: proc(f: formula.Formula) {
    delete(f.name)
    delete(f.desc)
    delete(f.version)
    delete(f.bottle_url)
    delete(f.bottle_sha256)
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
    data, read_err := os.read_entire_file(REGISTRY_PATH, context.allocator)
    if read_err != nil {
        return
    }
    defer delete(data)

    json_val, parse_err := json.parse(data)
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
    data, read_err := os.read_entire_file(REGISTRY_PATH, context.allocator)
    if read_err != nil {
        return
    }
    defer delete(data)

    json_val, parse_err := json.parse(data)
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

    temp_f, terr := os.create_temp_file("", "ubrew_search_formulae_*.json")
    if terr == nil {
        defer os.close(temp_f)
        temp_file := os.name(temp_f)
        defer os.remove(temp_file)

        cmd := fmt.tprintf("curl -sfSL \"https://formulae.brew.sh/api/formula.json\" -o \"%s\"", temp_file)
        cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
        if libc.system(cmd_cstr) == 0 {
            data, read_err := os.read_entire_file(temp_file, context.allocator)
            if read_err == nil {
                defer delete(data)
                json_val, parse_err := json.parse(data)
                if parse_err == nil {
                    defer json.destroy_value(json_val)

                    arr := json_val.(json.Array)
                    for item in arr {
                        if len(results) >= limit {
                            break
                        }
                        obj := item.(json.Object)
                        name := json_string_or_empty(obj, "name")
                        desc := json_string_or_empty(obj, "desc")
                        if !lower_contains(name, query_lower) && !lower_contains(desc, query_lower) {
                            continue
                        }
                        if formula_results_contains(results[:], name) {
                            continue
                        }
                        append(&results, Formula_Search_Result{
                            name = strings.clone(name),
                            desc = strings.clone(desc),
                            version = strings.clone(""),
                        })
                    }
                }
            }
        }
    }

    if len(results) == 0 {
        return out, .EOF
    }

    return results[:], nil
}

search_casks :: proc(query: string, limit: int = 25) -> (out: []Cask_Search_Result, err: json.Error) {
    if len(strings.trim_space(query)) == 0 {
        return out, .EOF
    }

    results := make([dynamic]Cask_Search_Result)
    query_lower := strings.to_lower(query, context.temp_allocator)

    append_registry_cask_matches(&results, query_lower, limit)

    temp_f, terr := os.create_temp_file("", "ubrew_search_casks_*.json")
    if terr == nil {
        defer os.close(temp_f)
        temp_file := os.name(temp_f)
        defer os.remove(temp_file)

        cmd := fmt.tprintf("curl -sfSL \"https://formulae.brew.sh/api/cask.json\" -o \"%s\"", temp_file)
        cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
        if libc.system(cmd_cstr) == 0 {
            data, read_err := os.read_entire_file(temp_file, context.allocator)
            if read_err == nil {
                defer delete(data)
                json_val, parse_err := json.parse(data)
                if parse_err == nil {
                    defer json.destroy_value(json_val)

                    arr := json_val.(json.Array)
                    for item in arr {
                        if len(results) >= limit {
                            break
                        }
                        obj := item.(json.Object)
                        token := json_string_or_empty(obj, "token")
                        desc := json_string_or_empty(obj, "desc")
                        version := json_string_or_empty(obj, "version")
                        name := ""
                        if name_val, ok := obj["name"]; ok {
                            if name_arr, ok2 := name_val.(json.Array); ok2 {
                                if len(name_arr) > 0 {
                                    if s, ok3 := name_arr[0].(json.String); ok3 {
                                        name = s
                                    }
                                }
                            }
                        }
                        if name == "" {
                            name = token
                        }

                        if !lower_contains(token, query_lower) && !lower_contains(name, query_lower) && !lower_contains(desc, query_lower) {
                            continue
                        }
                        if cask_results_contains(results[:], token) {
                            continue
                        }

                        append(&results, Cask_Search_Result{
                            token = strings.clone(token),
                            name = strings.clone(name),
                            desc = strings.clone(desc),
                            version = strings.clone(version),
                        })
                    }
                }
            }
        }
    }

    if len(results) == 0 {
        return out, .EOF
    }

    return results[:], nil
}
