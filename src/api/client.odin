package api

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:strings"
import "core:c/libc"
import "../cask"
import "../formula"

fetch_cask :: proc(token: string) -> (c: cask.Cask, err: json.Error) {
    url := fmt.tprintf("https://formulae.brew.sh/api/cask/%s.json", token)
    
    // Create a temporary file to capture curl output securely
    temp_file := "/tmp/ubrew_fetch.json"
    cmd := fmt.tprintf("curl -sSL \"%s\" -o %s", url, temp_file)
    
    cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
    exit_code := libc.system(cmd_cstr)
    if exit_code != 0 {
        return c, .EOF
    }
    defer os.remove(temp_file)

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
                    append(&artifacts_list, cask.App_Artifact{
                        name = strings.clone(app_name.(json.String)),
                    })
                }
            }
            // Check font
            if font_val, ok3 := art_obj["font"]; ok3 {
                font_arr := font_val.(json.Array)
                for font_name in font_arr {
                    append(&artifacts_list, cask.Font_Artifact{
                        name = strings.clone(font_name.(json.String)),
                    })
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
                        append(&artifacts_list, cask.Binary_Artifact{
                            source = src,
                            target = target,
                        })
                    }
                }
            }
        }
    }

    c.artifacts = artifacts_list[:]
    return c, nil
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
    
    temp_file := "/tmp/ubrew_fetch_formula.json"
    cmd := fmt.tprintf("curl -sSL \"%s\" -o %s", url, temp_file)
    
    cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
    exit_code := libc.system(cmd_cstr)
    if exit_code != 0 {
        return f, .EOF
    }
    defer os.remove(temp_file)

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
