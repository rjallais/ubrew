package main

import "core:fmt"
import "core:os"
import "api"
import "cask"

main :: proc() {
    fmt.println("=== ubrew — The Odin Package Manager Experiment ===")

    if len(os.args) < 2 {
        fmt.println("Usage: ubrew <cask_token>")
        os.exit(1)
    }

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
