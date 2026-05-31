package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:c/libc"
import "api"
import "cask"
import "formula"
import "installer"

main :: proc() {
    fmt.println("=== ubrew — The Odin Package Manager Experiment ===")

    if len(os.args) < 2 {
        fmt.println("Usage:")
        fmt.println("  ubrew <cask_token>          (Resolve Cask metadata)")
        fmt.println("  ubrew install <formula>    (Install a CLI formula)")
        os.exit(1)
    }

    if os.args[1] == "install" {
        if len(os.args) < 3 {
            fmt.println("Usage: ubrew install <formula>")
            os.exit(1)
        }
        formula_name := os.args[2]
        fmt.printf("==> Resolving formula metadata for: %s\n", formula_name)

        f, err := api.fetch_formula(formula_name)
        if err != nil {
            fmt.printf("Error: Failed to fetch formula metadata: %v\n", err)
            os.exit(1)
        }
        defer api.destroy_formula(f)

        fmt.println("========================================")
        fmt.printf("Name:     %s\n", f.name)
        fmt.printf("Desc:     %s\n", f.desc)
        fmt.printf("Version:  %s\n", f.version)
        fmt.printf("URL:      %s\n", f.bottle_url)
        fmt.printf("SHA256:   %s\n", f.bottle_sha256)
        fmt.println("========================================")

        // Install to a safe, unprivileged, self-contained test prefix:
        test_prefix := "/tmp/ubrew_prefix"
        success := installer.install_bottle(f, test_prefix)
        if !success {
            os.exit(1)
        }

        // Verify that the executable binary was successfully extracted and is functional!
        binary_path := fmt.tprintf("%s/bin/%s", test_prefix, f.name)
        if os.is_file(binary_path) {
            fmt.printf("==> Verification: Staged binary found at %s\n", binary_path)
            fmt.printf("==> Testing binary execution:\n")
            
            // Format command string
            cmd := fmt.tprintf("%s --version 2>&1", binary_path)
            cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
            libc.system(cmd_cstr)
        } else {
            fmt.printf("==> Verification Note: Binary not found at standard bin/%s path.\n", f.name)
        }

    } else {
        cask_token := os.args[1]
        fmt.printf("==> Resolving cask metadata for: %s\n", cask_token)

        c, err := api.fetch_cask(cask_token)
        if err != nil {
            fmt.printf("Error: Failed to fetch cask metadata: %v\n", err)
            os.exit(1)
        }
        defer api.destroy_cask(c)

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
}
