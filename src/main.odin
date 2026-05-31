package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"
import "api"
import "cask"
import "formula"
import "installer"

print_usage :: proc() {
    fmt.println("\x1b[1mubrew\x1b[0m \x1b[90mv0.1.0\x1b[0m — The Odin Package Manager Experiment")
    fmt.println("\n  Faster than zerobrew. Faster than homebrew. Written in Odin.")
    fmt.println("  Native compiled binary + perfect JSON parsing + curl driver.")
    fmt.println("  Works on Linux.")
    fmt.println("\nUSAGE:")
    fmt.println("  ubrew <command> [arguments]")
    fmt.println("\nCOMMANDS:")
    fmt.println("  search <query>             Search for formulae and casks (includes local 3rd-party registry)")
    fmt.println("  info <formula>             Show formula metadata")
    fmt.println("  info --cask <token>        Show cask metadata (supports 3rd-party tap tokens)")
    fmt.println("  install <formula>          Install standard Homebrew CLI formula (bottle)")
    fmt.println("  install --cask <token>     Install a cask (currently supports font casks)")
    fmt.println("  nuke [--yes|-y]            Completely uninstall ubrew and all packages")
    fmt.println("  version, --version         Show version")
    fmt.println("  help, --help, -h           Show this help banner")
    fmt.println("\nEXAMPLES:")
    fmt.println("  ubrew search bluefin")
    fmt.println("  ubrew info tree")
    fmt.println("  ubrew info --cask font-jetbrains-mono")
    fmt.println("  ubrew install --cask font-jetbrains-mono")
    fmt.println("  ubrew nuke --yes")
}

run_nuke :: proc(args: []string) {
    force := false
    for arg in args {
        if arg == "--yes" || arg == "-y" {
            force = true
        }
    }

    fmt.println("\n\x1b[31;1m  WARNING: This will completely remove ubrew and all installed packages.\x1b[0m\n")
    fmt.println("  The following will be deleted:")
    fmt.println("    - /tmp/ubrew_prefix      (all packages and staged binaries)")
    fmt.println("    - ~/.local/bin/ubrew     (ubrew binary, if exists)\n")

    if !force {
        fmt.print("  Type \x1b[1myes\x1b[0m to confirm: ")
        
        buf: [64]u8
        n, read_err := os.read(os.stdin, buf[:])
        if read_err != nil {
            fmt.println("\nubrew: failed to read input")
            os.exit(1)
        }
        
        input := strings.trim_space(string(buf[:n]))
        if input != "yes" {
            fmt.println("\n  Aborted.")
            return
        }
    }

    fmt.println("\n==> Removing ubrew...")

    // 1. Remove /tmp/ubrew_prefix
    fmt.println("  Removing /tmp/ubrew_prefix...")
    cmd_rm_prefix := "rm -rf /tmp/ubrew_prefix"
    cmd_rm_prefix_cstr := strings.clone_to_cstring(cmd_rm_prefix, context.temp_allocator)
    if libc.system(cmd_rm_prefix_cstr) != 0 {
        fmt.println("ubrew: failed to remove /tmp/ubrew_prefix")
    }

    // 2. Remove ~/.local/bin/ubrew
    fmt.println("  Removing ~/.local/bin/ubrew...")
    home_dir := os.get_env("HOME", context.temp_allocator)
    if home_dir != "" {
        ubrew_bin_path := fmt.tprintf("%s/.local/bin/ubrew", home_dir)
        if os.is_file(ubrew_bin_path) {
            os.remove(ubrew_bin_path)
        }
    }

    fmt.println("\n\x1b[32;1m  ubrew has been removed.\x1b[0m\n")
}

print_cask :: proc(c: cask.Cask) {
    fmt.println("========================================")
    fmt.printf("Token:    %s\n", c.token)
    fmt.printf("Name:     %s\n", c.name)
    fmt.printf("Version:  %s\n", c.version)
    fmt.printf("URL:      %s\n", c.url)
    fmt.printf("SHA256:   %s\n", c.sha256)
    fmt.printf("Homepage: %s\n", c.homepage)
    fmt.println("========================================")

    if len(c.artifacts) > 0 {
        fmt.println("Artifacts:")
        for art in c.artifacts {
            switch a in art {
            case cask.App_Artifact:
                fmt.printf("  [App]  %s\n", a.name)
            case cask.Font_Artifact:
                fmt.printf("  [Font] %s\n", a.name)
            case cask.Binary_Artifact:
                fmt.printf("  [Bin]  %s -> %s\n", a.source, a.target)
            }
        }
    }
}

print_formula :: proc(f: formula.Formula) {
    fmt.println("========================================")
    fmt.printf("Name:     %s\n", f.name)
    fmt.printf("Desc:     %s\n", f.desc)
    fmt.printf("Version:  %s\n", f.version)
    fmt.printf("URL:      %s\n", f.bottle_url)
    fmt.printf("SHA256:   %s\n", f.bottle_sha256)
    fmt.println("========================================")
}

main :: proc() {
    if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "--help" || os.args[1] == "-h" {
        print_usage()
        os.exit(0)
    }

    cmd := os.args[1]

    if cmd == "version" || cmd == "--version" {
        fmt.println("ubrew 0.1.0")
        os.exit(0)
    }

    if cmd == "search" {
        if len(os.args) < 3 {
            fmt.println("Usage: ubrew search <query>")
            os.exit(1)
        }
        query := os.args[2]
        fmt.printf("==> Searching for: %s\n", query)

        if formulae, err := api.search_formulae(query, 20); err == nil {
            defer api.destroy_formula_search_results(formulae)
            if len(formulae) > 0 {
                fmt.println("\nFormulae:")
                for r in formulae {
                    if r.version != "" {
                        fmt.printf("  %s (%s)\n    %s\n", r.name, r.version, r.desc)
                    } else {
                        fmt.printf("  %s\n    %s\n", r.name, r.desc)
                    }
                }
            }
        }

        if casks, err := api.search_casks(query, 20); err == nil {
            defer api.destroy_cask_search_results(casks)
            if len(casks) > 0 {
                fmt.println("\nCasks:")
                for r in casks {
                    if r.version != "" {
                        fmt.printf("  %s (%s)\n    %s\n", r.token, r.version, r.desc)
                    } else {
                        fmt.printf("  %s\n    %s\n", r.token, r.desc)
                    }
                }
            }
        }

        return
    }

    if cmd == "info" {
        if len(os.args) < 3 {
            fmt.println("Usage: ubrew info <formula> | ubrew info --cask <token>")
            os.exit(1)
        }

        if os.args[2] == "--cask" {
            if len(os.args) < 4 {
                fmt.println("Usage: ubrew info --cask <token>")
                os.exit(1)
            }

            cask_token := os.args[3]
            fmt.printf("==> Resolving cask metadata for: %s\n", cask_token)
            c, err := api.fetch_cask(cask_token)
            if err != nil {
                fmt.printf("Error: Failed to fetch cask metadata: %v\n", err)
                os.exit(1)
            }
            print_cask(c)
            api.destroy_cask(c)
            return
        }

        formula_name := os.args[2]
        fmt.printf("==> Resolving formula metadata for: %s\n", formula_name)
        f, err := api.fetch_formula(formula_name)
        if err != nil {
            fmt.printf("Error: Failed to fetch formula metadata: %v\n", err)
            os.exit(1)
        }
        print_formula(f)
        api.destroy_formula(f)
        return
    }

    if cmd == "install" {
        if len(os.args) < 3 {
            fmt.println("Usage: ubrew install <formula> | ubrew install --cask <token>")
            os.exit(1)
        }

        if os.args[2] == "--cask" {
            if len(os.args) < 4 {
                fmt.println("Usage: ubrew install --cask <token>")
                os.exit(1)
            }

            cask_token := os.args[3]
            fmt.printf("==> Resolving cask metadata for: %s\n", cask_token)
            c, err := api.fetch_cask(cask_token)
            if err != nil {
                fmt.printf("Error: Failed to fetch cask metadata: %v\n", err)
                os.exit(1)
            }

            ok := installer.install_cask(c)
            api.destroy_cask(c)
            if !ok {
                os.exit(1)
            }
            return
        }

        formula_name := os.args[2]
        fmt.printf("==> Resolving formula metadata for: %s\n", formula_name)

        f, err := api.fetch_formula(formula_name)
        if err != nil {
            fmt.printf("Error: Failed to fetch formula metadata: %v\n", err)
            os.exit(1)
        }
        print_formula(f)

        test_prefix := "/tmp/ubrew_prefix"
        if !installer.install_bottle(f, test_prefix) {
            os.exit(1)
        }

        binary_path := fmt.tprintf("%s/bin/%s", test_prefix, f.name)
        if os.is_file(binary_path) {
            fmt.printf("==> Verification: Staged binary found at %s\n", binary_path)
            cmd2 := fmt.tprintf("%s --version 2>&1", binary_path)
            cmd2_cstr := strings.clone_to_cstring(cmd2, context.temp_allocator)
            libc.system(cmd2_cstr)
        }

        api.destroy_formula(f)
        return
    }

    if cmd == "nuke" {
        run_nuke(os.args[2:])
        return
    }

    // Backwards-compatible fallback: treat a bare token as `info --cask <token>`
    cask_token := cmd
    fmt.printf("==> Resolving cask metadata for: %s\n", cask_token)

    c, err := api.fetch_cask(cask_token)
    if err != nil {
        fmt.printf("Error: Failed to fetch cask metadata: %v\n", err)
        os.exit(1)
    }
    defer api.destroy_cask(c)
    print_cask(c)
}
