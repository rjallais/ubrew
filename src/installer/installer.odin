package installer

import "core:fmt"
import "core:os"
import "core:c/libc"
import "core:strings"
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
