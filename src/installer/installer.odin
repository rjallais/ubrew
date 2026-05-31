package installer

import "core:fmt"
import "core:os"
import "core:c/libc"
import "core:strings"
import "core:crypto/hash"
import "core:encoding/hex"
import "../cask"
import "../formula"

install_bottle :: proc(f: formula.Formula, prefix: string) -> bool {
    fmt.printf("==> Installing bottle: %s %s\n", f.name, f.version)
    
    if len(f.bottle_url) == 0 {
        fmt.println("Error: No bottle URL available for this platform.")
        return false
    }

    dl_path := fmt.tprintf("/tmp/%s-%s.bottle.tar.gz", f.name, f.version)
    fmt.printf("==> Downloading: %s\n", f.bottle_url)
    
    cmd_dl := fmt.tprintf("curl -H \"Authorization: Bearer QQ==\" -L \"%s\" -o %s", f.bottle_url, dl_path)
    cmd_dl_cstr := strings.clone_to_cstring(cmd_dl, context.temp_allocator)
    if libc.system(cmd_dl_cstr) != 0 {
        fmt.println("Error: Download failed.")
        return false
    }
    defer os.remove(dl_path)

    fmt.printf("==> Creating prefix: %s\n", prefix)
    // Core:os make_directory expects mode as second argument on Linux:
    // os.make_directory(path, mode) -> os.make_directory(prefix, os.perm(0o755))
    os.make_directory(prefix, os.perm(0o755))

    fmt.printf("==> Unpacking to: %s\n", prefix)
    cmd_ex := fmt.tprintf("tar -xzf %s --strip-components=2 -C %s", dl_path, prefix)
    cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
    if libc.system(cmd_ex_cstr) != 0 {
        cmd_ex_fallback := fmt.tprintf("tar -xzf %s -C %s", dl_path, prefix)
        cmd_ex_fallback_cstr := strings.clone_to_cstring(cmd_ex_fallback, context.temp_allocator)
        if libc.system(cmd_ex_fallback_cstr) != 0 {
            fmt.println("Error: Extraction failed.")
            return false
        }
    }

    fmt.println("==> Performing native binary relocation...")
    binary_path := fmt.tprintf("%s/bin/%s", prefix, f.name)
    if os.is_file(binary_path) {
        // 1. Make binary writable so we can modify it
        cmd_chmod := fmt.tprintf("chmod +w %s", binary_path)
        cmd_chmod_cstr := strings.clone_to_cstring(cmd_chmod, context.temp_allocator)
        libc.system(cmd_chmod_cstr)

        // 2. Set interpreter to host's dynamic linker using patchelf
        cmd_patch := fmt.tprintf("patchelf --set-interpreter /lib64/ld-linux-x86-64.so.2 %s 2>/dev/null", binary_path)
        cmd_patch_cstr := strings.clone_to_cstring(cmd_patch, context.temp_allocator)
        if libc.system(cmd_patch_cstr) == 0 {
            fmt.printf("==> Successfully relocated %s binary interpreter!\n", f.name)
        } else {
            fmt.printf("==> Warning: patchelf failed to relocate %s (may not be dynamically linked or interpreter already correct)\n", f.name)
        }
    }

    fmt.printf("==> Successful installation of %s into %s!\n", f.name, prefix)
    return true
}

flatten_token :: proc(token: string) -> string {
    out, _ := strings.replace_all(token, "/", "-", context.temp_allocator)
    return out
}

url_basename :: proc(url: string) -> string {
    // Strip query string if present
    base := url
    if q := strings.index_byte(url, '?'); q >= 0 {
        base = url[:q]
    }
    if idx := strings.last_index_byte(base, '/'); idx >= 0 {
        return base[idx+1:]
    }
    return base
}

sha256_matches :: proc(path: string, expected_sha256: string) -> bool {
    expected := strings.to_lower(strings.trim_space(expected_sha256), context.temp_allocator)
    if expected == "" || expected == "no_check" {
        return true
    }

    digest, io_err := hash.hash_file_by_name(hash.Algorithm.SHA256, path, true, context.allocator)
    if io_err != nil {
        return false
    }
    defer delete(digest)

    encoded, enc_err := hex.encode(digest, context.allocator)
    if enc_err != nil {
        return false
    }
    defer delete(encoded)

    got := string(encoded)
    return strings.to_lower(got, context.temp_allocator) == expected
}

find_file_by_basename :: proc(root_dir, base: string) -> (path: string, ok: bool) {
    w := os.walker_create(root_dir)
    defer os.walker_destroy(&w)

    for info in os.walker_walk(&w) {
        if info.type != .Regular {
            continue
        }
        if info.name == base {
            return strings.clone(info.fullpath, context.temp_allocator), true
        }
    }

    return "", false
}

install_cask :: proc(c: cask.Cask) -> bool {
    for art in c.artifacts {
        if _, ok := art.(cask.Font_Artifact); ok {
            return install_font_cask(c)
        }
    }

    fmt.println("Error: Only font casks are currently supported by ubrew.")
    return false
}

install_font_cask :: proc(c: cask.Cask) -> bool {
    if len(c.url) == 0 {
        fmt.println("Error: Cask has no download URL.")
        return false
    }

    home_dir := os.get_env("HOME", context.temp_allocator)
    if home_dir == "" {
        fmt.println("Error: $HOME is not set.")
        return false
    }

    fonts_dir := fmt.tprintf("%s/.local/share/fonts", home_dir)
    _ = os.make_directory_all(fonts_dir, os.perm(0o755))

    cache_dir := "/tmp/ubrew_cache"
    _ = os.make_directory_all(cache_dir, os.perm(0o755))

    flat := flatten_token(c.token)
    ver := c.version
    if ver == "" {
        ver = "unknown"
    }
    ver_flat, _ := strings.replace_all(ver, "/", "-", context.temp_allocator)

    ext := ".zip"
    url := c.url
    if strings.has_suffix(url, ".tar.gz") || strings.has_suffix(url, ".tgz") {
        ext = ".tar.gz"
    } else if strings.has_suffix(url, ".tar.bz2") || strings.has_suffix(url, ".tbz2") {
        ext = ".tar.bz2"
    } else if strings.has_suffix(url, ".tar.xz") || strings.has_suffix(url, ".txz") {
        ext = ".tar.xz"
    } else if strings.has_suffix(url, ".tar.zst") || strings.has_suffix(url, ".tar.zstd") {
        ext = ".tar.zst"
    } else if strings.has_suffix(url, ".ttf") {
        ext = ".ttf"
    } else if strings.has_suffix(url, ".otf") {
        ext = ".otf"
    } else if strings.has_suffix(url, ".ttc") {
        ext = ".ttc"
    }

    dl_path := fmt.tprintf("%s/%s-%s%s", cache_dir, flat, ver_flat, ext)
    fmt.printf("==> Downloading cask: %s\n", c.token)

    cmd_dl := fmt.tprintf("curl -sfSL \"%s\" -o \"%s\"", c.url, dl_path)
    cmd_dl_cstr := strings.clone_to_cstring(cmd_dl, context.temp_allocator)
    if libc.system(cmd_dl_cstr) != 0 {
        fmt.println("Error: Download failed.")
        return false
    }

    if !sha256_matches(dl_path, c.sha256) {
        fmt.println("Error: SHA256 verification failed.")
        return false
    }

    extract_root := "/tmp/ubrew_caskroom"
    _ = os.make_directory_all(extract_root, os.perm(0o755))

    extract_dir := fmt.tprintf("%s/%s/%s", extract_root, flat, ver_flat)
    _ = os.remove_all(extract_dir)
    _ = os.make_directory_all(extract_dir, os.perm(0o755))

    fmt.printf("==> Staging into: %s\n", extract_dir)

    if ext == ".zip" {
        cmd_ex := fmt.tprintf("unzip -q \"%s\" -d \"%s\"", dl_path, extract_dir)
        cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
        if libc.system(cmd_ex_cstr) != 0 {
            fmt.println("Error: unzip failed.")
            return false
        }
    } else if ext == ".tar.gz" {
        cmd_ex := fmt.tprintf("tar -xzf \"%s\" -C \"%s\"", dl_path, extract_dir)
        cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
        if libc.system(cmd_ex_cstr) != 0 {
            fmt.println("Error: tar extraction failed.")
            return false
        }
    } else if ext == ".tar.bz2" {
        cmd_ex := fmt.tprintf("tar -xjf \"%s\" -C \"%s\"", dl_path, extract_dir)
        cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
        if libc.system(cmd_ex_cstr) != 0 {
            fmt.println("Error: tar extraction failed.")
            return false
        }
    } else if ext == ".tar.xz" {
        cmd_ex := fmt.tprintf("tar -xJf \"%s\" -C \"%s\"", dl_path, extract_dir)
        cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
        if libc.system(cmd_ex_cstr) != 0 {
            fmt.println("Error: tar extraction failed.")
            return false
        }
    } else if ext == ".tar.zst" {
        cmd_ex := fmt.tprintf("tar --use-compress-program=unzstd -xf \"%s\" -C \"%s\"", dl_path, extract_dir)
        cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
        if libc.system(cmd_ex_cstr) != 0 {
            fmt.println("Error: zstd tar extraction failed.")
            return false
        }
    } else {
        // Direct font file download (.ttf/.otf/.ttc)
        base := url_basename(c.url)
        dst := fmt.tprintf("%s/%s", extract_dir, base)
        if err := os.copy_file(dst, dl_path); err != nil {
            fmt.println("Error: failed staging downloaded font file.")
            return false
        }
    }

    installed := 0

    for art in c.artifacts {
        switch a in art {
        case cask.Font_Artifact:
            rel := a.name
            if strings.has_prefix(rel, "/") || strings.contains(rel, "..") {
                fmt.printf("==> Skipping suspicious font path: %s\n", rel)
                continue
            }

            src := fmt.tprintf("%s/%s", extract_dir, rel)
            if !os.is_file(src) {
                base := os.base(rel)
                if p, ok := find_file_by_basename(extract_dir, base); ok {
                    src = p
                } else {
                    fmt.printf("==> Missing font artifact: %s\n", rel)
                    continue
                }
            }

            dst := fmt.tprintf("%s/%s", fonts_dir, os.base(src))
            if err := os.copy_file(dst, src); err != nil {
                fmt.printf("Error: failed copying font %s\n", rel)
                return false
            }
            installed += 1
        case cask.App_Artifact:
            // Not handled by this installer.
        case cask.Binary_Artifact:
            // Not handled by this installer.
        }
    }

    if installed == 0 {
        fmt.println("Error: No fonts were installed (no font artifacts found).")
        return false
    }

    // Refresh font cache if available
    cmd_cache := "fc-cache -f >/dev/null 2>&1"
    cmd_cache_cstr := strings.clone_to_cstring(cmd_cache, context.temp_allocator)
    _ = libc.system(cmd_cache_cstr)

    fmt.printf("==> Installed %d font file(s) to %s\n", installed, fonts_dir)
    return true
}
