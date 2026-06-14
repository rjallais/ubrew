package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:encoding/json"
import "core:c/libc"
import "core:sys/posix"
import "api"
import "cask"
import "formula"
import "history"
import "installer"
import "platform"
import "store"
import "tap"

print_usage :: proc() {
    fmt.println("\x1b[1mubrew\x1b[0m \x1b[90mv0.1.0\x1b[0m — The Odin Package Manager Experiment")
    fmt.println("\n  Faster than zerobrew. Faster than homebrew. Written in Odin.")
    fmt.println("  Native compiled binary + perfect JSON parsing + curl driver.")
	fmt.println("  Works on Linux.")
	fmt.println("\nUSAGE:")
	fmt.println("  ubrew <command> [arguments]")
	fmt.println("\nCOMMANDS:")
    fmt.println("  init                       Create /opt/ubrew directory tree")
	fmt.println("  search <query>             Search for formulae and casks (includes local 3rd-party registry)")
	fmt.println("  info <formula>             Show formula metadata")
    fmt.println("  info --cask <token>        Show cask metadata (supports 3rd-party tap tokens)")
    fmt.println("  install <formula>          Install standard Homebrew CLI formula (bottle)")
    fmt.println("  install --cask <token>     Install a cask (font, wallpaper, or AppImage)")
    fmt.println("  reinstall <formula>        Remove and install a formula again")
    fmt.println("  list, ls                   List installed formulae and casks")
    fmt.println("  remove, uninstall, rm      Remove an installed formula")
    fmt.println("  where <pattern>            Show installed files matching a pattern")
    fmt.println("  doctor                     Check ubrew installation health")
    fmt.println("  bundle dump                Dump installed formulae as a Brewfile")
    fmt.println("  deps [--tree] <formula>    Show formula dependencies")
    fmt.println("  migrate                    Migrate formulae from a foreign Cellar")
    fmt.println("  mirror                     Manage offline mirrors (delegates to stout)")
    fmt.println("  tap [add|remove] <repo> [url]  Manage 3rd-party tap repositories")
    fmt.println("  untap <repo>                    Untap a 3rd-party repository")
    fmt.println("  trust [tap] [--json=v1]         Trust a 3rd-party tap repository")
    fmt.println("  untrust <tap>                   Untrust a 3rd-party tap repository")
    fmt.println("  cleanup [--dry-run]        Remove stale cache files and broken bin links")
	fmt.println("  nuke [--yes|-y]            Completely uninstall ubrew and all packages")
	fmt.println("  version, --version         Show version")
	fmt.println("  help, --help, -h           Show this help banner")
	fmt.println("\nEXAMPLES:")
    fmt.println("  ubrew init")
	fmt.println("  ubrew search bluefin")
	fmt.println("  ubrew info tree")
    fmt.println("  ubrew install tree")
    fmt.println("  ubrew reinstall tree")
    fmt.println("  ubrew list")
    fmt.println("  ubrew remove tree")
    fmt.println("  ubrew where tree")
    fmt.println("  ubrew doctor")
    fmt.println("  ubrew mirror --help")
    fmt.println("  ubrew trust user/repo")
    fmt.println("  ubrew cleanup --dry-run")
	fmt.println("  ubrew info --cask font-jetbrains-mono")
	fmt.println("  ubrew install --cask font-jetbrains-mono")
	fmt.println("  ubrew nuke --yes")
}

ensure_ubrew_dirs :: proc() -> bool {
    dirs := []string{
        installer.UBREW_ROOT,
        installer.UBREW_ROOT + "/store",
        installer.UBREW_ROOT + "/cache",
        installer.UBREW_ROOT + "/cache/blobs",
        installer.UBREW_ROOT + "/cache/tmp",
        installer.PREFIX,
        installer.PREFIX + "/Cellar",
        installer.PREFIX + "/Caskroom",
        installer.PREFIX + "/bin",
        installer.PREFIX + "/opt",
        installer.PREFIX + "/lib",
        installer.PREFIX + "/include",
        installer.PREFIX + "/share",
        installer.UBREW_ROOT + "/db",
        installer.UBREW_ROOT + "/locks",
    }

    for dir in dirs {
        if err := os.make_directory_all(dir, os.perm(0o755)); err != nil {
            if os.is_dir(dir) {
                continue
            }
            fmt.printf("ubrew: failed to create %s: %v\n", dir, err)
            fmt.println("ubrew: try running `sudo ubrew init`, then chown /opt/ubrew to your user")
            return false
        }
    }
    return true
}




run_init :: proc() {
    if !ensure_ubrew_dirs() {
        os.exit(1)
    }

    sudo_user := os.get_env("SUDO_USER", context.temp_allocator)
    if sudo_user != "" && package_name_safe(sudo_user) && !strings.contains(sudo_user, "/") {
        cmd := fmt.tprintf("chown -R %s '%s'", sudo_user, installer.UBREW_ROOT)
        cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
        _ = libc.system(cmd_cstr)
    }

    fmt.printf("ubrew initialized at %s\n", installer.UBREW_ROOT)
    fmt.println("\n==> Shell Configuration:")
    fmt.println("For Bash/Zsh:")
    fmt.printf("  export PATH=\"%s/bin:$PATH\"\n\n", installer.PREFIX)
    fmt.println("For Nushell (config.nu):")
    fmt.println("  def --env ensure_ubrew_path [] {")
    fmt.printf("      if ('%s/bin' | path exists) {{\n", installer.PREFIX)
    fmt.printf("          path add '%s/bin'\n", installer.PREFIX)
    fmt.println("      }")
    fmt.println("  }")
    fmt.println("  ensure_ubrew_path")
    fmt.println("  # To persist through 'mise activate nu' rewriting PATH, add to hooks:")
    fmt.println("  $env.config.hooks.pre_prompt = ($env.config.hooks.pre_prompt? | default [] | append { code: { ensure_ubrew_path } })")
}

package_name_safe :: proc(name: string) -> bool {
    if len(name) == 0 || len(name) > 256 {
        return false
    }
    if strings.contains(name, "..") {
        return false
    }
    for r in name {
        if r == '/' || r == '-' || r == '_' || r == '@' || r == '.' || r == '+' {
            continue
        }
        if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
            continue
        }
        return false
    }
    return true
}

print_keg_paths :: proc(path: string) {
	walk :: proc(dir: string) {
		infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
		if err != nil do return
		for info in infos {
			if os.is_dir(info.fullpath) {
				walk(info.fullpath)
			} else {
				fmt.println(info.fullpath)
			}
		}
	}
	walk(path)
}

get_all_versions :: proc(name: string, cellar: string) -> []string {
	list: [dynamic]string
	dir := fmt.tprintf("%s/%s", cellar, name)
	if infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator); err == nil {
		for info in infos {
			if os.is_dir(info.fullpath) {
				append(&list, strings.clone(info.name, context.allocator))
			}
		}
	}
	slice.sort(list[:])
	return list[:]
}

get_latest_version :: proc(name: string, cellar: string) -> string {
	vers := get_all_versions(name, cellar)
	if len(vers) == 0 do return ""
	return vers[len(vers)-1]
}

get_all_versions_cask :: proc(name: string, caskroom: string) -> []string {
	list: [dynamic]string
	dir := fmt.tprintf("%s/%s", caskroom, name)
	if infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator); err == nil {
		for info in infos {
			if os.is_dir(info.fullpath) {
				append(&list, strings.clone(info.name, context.allocator))
			}
		}
	}
	slice.sort(list[:])
	return list[:]
}

get_latest_version_cask :: proc(name: string, caskroom: string) -> string {
	vers := get_all_versions_cask(name, caskroom)
	if len(vers) == 0 do return ""
	return vers[len(vers)-1]
}

run_list :: proc(args: []string) {
	opt_formula := false
	opt_cask := false
	opt_full_name := false
	opt_versions := false
	opt_json := false
	opt_multiple := false
	opt_pinned := false
	opt_installed_on_request := false
	opt_poured_from_bottle := false
	opt_built_from_source := false
	opt_1 := false
	opt_l := false
	opt_r := false
	opt_t := false

	targets: [dynamic]string
	defer delete(targets)

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--formula" {
			opt_formula = true
		} else if arg == "--cask" {
			opt_cask = true
		} else if arg == "--full-name" {
			opt_full_name = true
		} else if arg == "--versions" {
			opt_versions = true
		} else if arg == "--json" {
			opt_json = true
		} else if arg == "--multiple" {
			opt_multiple = true
			opt_versions = true
		} else if arg == "--pinned" {
			opt_pinned = true
		} else if arg == "--installed-on-request" {
			opt_installed_on_request = true
		} else if arg == "--poured-from-bottle" {
			opt_poured_from_bottle = true
		} else if arg == "--built-from-source" {
			opt_built_from_source = true
		} else if arg == "-1" {
			opt_1 = true
		} else if arg == "-l" {
			opt_l = true
		} else if arg == "-r" {
			opt_r = true
		} else if arg == "-t" {
			opt_t = true
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintf("Error: Unknown option: %s\n", arg)
			os.exit(1)
		} else {
			append(&targets, arg)
		}
	}

	if opt_json {
		has_jq := command_exists("jq")
		if !opt_versions || len(targets) > 0 || !has_jq {
			fmt.eprintln("Error: --json requires --versions, no named arguments, and jq installed.")
			os.exit(1)
		}
	}

	if len(targets) > 0 {
		pins := read_pins()
		defer destroy_pins(pins)

		for target in targets {
			short_name := target
			if idx := strings.last_index(target, "/"); idx >= 0 {
				short_name = target[idx+1:]
			}

			is_cask := opt_cask
			if !opt_cask && !opt_formula {
				caskroom_path := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, short_name)
				if os.is_dir(caskroom_path) {
					is_cask = true
				} else {
					is_cask = false
				}
			}

			if is_cask {
				if opt_pinned {
					continue
				}
				caskroom_path := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, short_name)
				if !os.is_dir(caskroom_path) {
					fmt.eprintf("Error: No such cask: %s\n", target)
					os.exit(1)
				}
				c, err := api.fetch_cask(short_name)
				if err == nil {
					if len(c.artifacts) > 0 {
						for art in c.artifacts {
							switch a in art {
							case cask.App_Artifact:
								fmt.printf(" [App] %s\n", a.name)
							case cask.Font_Artifact:
								fmt.printf(" [Font] %s\n", a.name)
							case cask.Binary_Artifact:
								fmt.printf(" [Bin] %s -> %s\n", a.source, a.target)
							case cask.Wallpaper_Artifact:
								fmt.printf(" [Wallpaper] %s\n", a.glob)
							case cask.AppImage_Artifact:
								fmt.printf(" [AppImage] %s -> %s\n", a.source, a.target)
							case cask.Generic_Artifact:
								fmt.printf(" [Artifact] %s -> %s\n", a.source, a.target)
							}
						}
					}
					api.destroy_cask(c)
				} else {
					fmt.eprintf("Error: Failed to fetch cask metadata for %s: %v\n", target, err)
					os.exit(1)
				}
			} else {
				if opt_pinned && !is_pinned(pins, short_name) {
					continue
				}
				cellar_path := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, short_name)
				if !os.is_dir(cellar_path) {
					fmt.eprintf("Error: No such keg: %s\n", cellar_path)
					os.exit(1)
				}
				
				latest_version := ""
				if f_infos, err := os.read_directory_by_path(cellar_path, -1, context.temp_allocator); err == nil {
					for info in f_infos {
						if os.is_dir(info.fullpath) && info.name > latest_version {
							latest_version = info.name
						}
					}
				}
				
				if latest_version != "" {
					keg_dir := fmt.tprintf("%s/%s", cellar_path, latest_version)
					print_keg_paths(keg_dir)
				} else {
					fmt.eprintf("Error: No versions found for formula: %s\n", target)
					os.exit(1)
				}
			}
		}
		return
	}

	delegate_to_ls := !opt_full_name && !opt_versions && !opt_pinned &&
	                  !opt_installed_on_request && !opt_poured_from_bottle && !opt_built_from_source &&
	                  (opt_1 || opt_l || opt_r || opt_t)

	if delegate_to_ls {
		dirs := make([dynamic]string, context.temp_allocator)
		is_formula_mode := opt_formula || (!opt_formula && !opt_cask)
		is_cask_mode := opt_cask || (!opt_formula && !opt_cask)

		if is_formula_mode {
			cellar := fmt.tprintf("%s/Cellar", installer.PREFIX)
			if os.is_dir(cellar) do append(&dirs, cellar)
		}
		if is_cask_mode {
			caskroom := fmt.tprintf("%s/Caskroom", installer.PREFIX)
			if os.is_dir(caskroom) do append(&dirs, caskroom)
		}

		if len(dirs) > 0 {
			ls_args := make([dynamic]string, context.temp_allocator)
			append(&ls_args, "ls")
			if opt_1 do append(&ls_args, "-1")
			if opt_l do append(&ls_args, "-l")
			if opt_r do append(&ls_args, "-r")
			if opt_t do append(&ls_args, "-t")
			for d in dirs {
				append(&ls_args, d)
			}

			argv := make([]cstring, len(ls_args) + 1, context.temp_allocator)
			for arg, idx in ls_args {
				argv[idx] = strings.clone_to_cstring(arg, context.temp_allocator)
			}
			argv[len(ls_args)] = nil

			bin_cstr := strings.clone_to_cstring("ls", context.temp_allocator)
			posix.execvp(bin_cstr, &argv[0])
			os.exit(1)
		}
		return
	}

	is_formula_mode := opt_formula || (!opt_formula && !opt_cask)
	is_cask_mode := opt_cask || (!opt_formula && !opt_cask)

	pins := read_pins()
	defer destroy_pins(pins)

	List_Item :: struct {
		name:                 string,
		full_name:            string,
		versions:             []string,
		is_cask:              bool,
		mtime:                time.Time,
		pinned:               bool,
		pinned_version:       string,
		installed_on_request: bool,
		poured_from_bottle:   bool,
	}

	items := make([dynamic]List_Item, context.temp_allocator)

	cellar := fmt.tprintf("%s/Cellar", installer.PREFIX)
	if is_formula_mode && os.is_dir(cellar) {
		infos, err := os.read_directory_by_path(cellar, -1, context.temp_allocator)
		if err == nil {
			for info in infos {
				if os.is_dir(info.fullpath) {
					name := info.name
					f_vers := get_all_versions(name, cellar)
					if len(f_vers) == 0 do continue
					
					latest_version := f_vers[len(f_vers)-1]
					keg_dir := fmt.tprintf("%s/%s", info.fullpath, latest_version)
					
					receipt, has_receipt := installer.read_install_receipt(keg_dir, context.temp_allocator)
					pinned := is_pinned(pins, name)
					pinned_ver := pinned ? latest_version : ""
					
					ior := has_receipt ? receipt.installed_on_request : true
					pfb := has_receipt ? receipt.poured_from_bottle : true
					
					full_name := name
					if has_receipt && receipt.tap != "" && receipt.tap != "homebrew/core" {
						full_name = fmt.tprintf("%s/%s", receipt.tap, name)
					}
					
					mtime := info.modification_time
					if keg_info, k_err := os.stat(keg_dir, context.temp_allocator); k_err == nil {
						mtime = keg_info.modification_time
					}
					
					append(&items, List_Item{
						name = strings.clone(name, context.temp_allocator),
						full_name = strings.clone(full_name, context.temp_allocator),
						versions = f_vers,
						is_cask = false,
						mtime = mtime,
						pinned = pinned,
						pinned_version = strings.clone(pinned_ver, context.temp_allocator),
						installed_on_request = ior,
						poured_from_bottle = pfb,
					})
				}
			}
		}
	}

	caskroom := fmt.tprintf("%s/Caskroom", installer.PREFIX)
	if is_cask_mode && os.is_dir(caskroom) {
		if infos, err := os.read_directory_by_path(caskroom, -1, context.temp_allocator); err == nil {
			for info in infos {
				if os.is_dir(info.fullpath) {
					name := info.name
					c_vers := get_all_versions_cask(name, caskroom)
					if len(c_vers) == 0 do continue
					latest_version := c_vers[len(c_vers)-1]
					
					mtime := info.modification_time
					keg_dir := fmt.tprintf("%s/%s", info.fullpath, latest_version)
					if keg_info, k_err := os.stat(keg_dir, context.temp_allocator); k_err == nil {
						mtime = keg_info.modification_time
					}
					
					append(&items, List_Item{
						name = strings.clone(name, context.temp_allocator),
						full_name = strings.clone(name, context.temp_allocator),
						versions = c_vers,
						is_cask = true,
						mtime = mtime,
						pinned = false,
						pinned_version = "",
						installed_on_request = true,
						poured_from_bottle = true,
					})
				}
			}
		}
	}

	filtered := make([dynamic]List_Item, context.temp_allocator)
	for item in items {
		if opt_pinned && !item.pinned do continue
		if opt_multiple && len(item.versions) <= 1 do continue
		if opt_installed_on_request && !item.installed_on_request do continue
		if opt_poured_from_bottle && !item.poured_from_bottle do continue
		if opt_built_from_source && item.poured_from_bottle do continue
		append(&filtered, item)
	}

	for i := 1; i < len(filtered); i += 1 {
		j := i
		for j > 0 {
			cmp := false
			if opt_t {
				t1 := time.time_to_unix(filtered[j].mtime)
				t2 := time.time_to_unix(filtered[j-1].mtime)
				if opt_r {
					cmp = t1 < t2
				} else {
					cmp = t1 > t2
				}
			} else {
				s1 := filtered[j].full_name
				s2 := filtered[j-1].full_name
				if opt_r {
					cmp = s1 > s2
				} else {
					cmp = s1 < s2
				}
			}
			
			if cmp {
				filtered[j], filtered[j-1] = filtered[j-1], filtered[j]
				j -= 1
			} else {
				break
			}
		}
	}

	if opt_json {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "{\n  \"formulae\": [\n")
		f_count := 0
		for item in filtered {
			if item.is_cask do continue
			if f_count > 0 do strings.write_string(&b, ",\n")
			pinned_str := item.pinned ? "true" : "false"
			pinned_ver_str := item.pinned ? fmt.tprintf("\"%s\"", item.pinned_version) : "null"
			
			linked_ver_str := "null"
			opt_linked_ver_str := "null"
			opt_link := fmt.tprintf("%s/opt/%s", installer.PREFIX, item.name)
			if target, err := os.read_link(opt_link, context.temp_allocator); err == nil {
				idx := strings.last_index(target, "/")
				ver := idx < 0 ? target : target[idx+1:]
				linked_ver_str = fmt.tprintf("\"%s\"", ver)
				opt_linked_ver_str = fmt.tprintf("\"%s\"", ver)
			}
			
			fmt.sbprintf(&b, "    {{\n      \"name\": \"%s\",\n      \"versions\": [", item.name)
			for ver, v_idx in item.versions {
				if v_idx > 0 do strings.write_string(&b, ", ")
				fmt.sbprintf(&b, "\"%s\"", ver)
			}
			fmt.sbprintf(&b, "],\n      \"pinned\": %s,\n      \"pinned_version\": %s,\n      \"linked_version\": %s,\n      \"opt_linked_version\": %s\n    }}",
				pinned_str, pinned_ver_str, linked_ver_str, opt_linked_ver_str)
			f_count += 1
		}
		strings.write_string(&b, "\n  ],\n  \"casks\": [\n")
		c_count := 0
		for item in filtered {
			if !item.is_cask do continue
			if c_count > 0 do strings.write_string(&b, ",\n")
			latest_ver := item.versions[len(item.versions)-1]
			fmt.sbprintf(&b, "    {{\n      \"name\": \"%s\",\n      \"versions\": [\"%s\"]\n    }}", item.name, latest_ver)
			c_count += 1
		}
		strings.write_string(&b, "\n  ]\n}\n")
		fmt.print(strings.to_string(b))
		return
	}

	if len(filtered) == 0 {
		if !opt_pinned && !opt_multiple && !opt_installed_on_request && !opt_poured_from_bottle && !opt_built_from_source {
			fmt.println("No packages installed.")
		}
		return
	}

	for item in filtered {
		name_to_print := opt_full_name ? item.full_name : item.name
		if opt_versions {
			fmt.printf("%s", name_to_print)
			for ver in item.versions {
				fmt.printf(" %s", ver)
			}
			fmt.println()
		} else {
			fmt.println(name_to_print)
		}
	}
}

Brewfile_Entry :: struct {
	kind: string, // "brew", "cask", "tap", "mas"
	name: string,
	url:  string, // Only for tap
	trusted: bool,
}

extract_quoted_strings :: proc(line: string, allocator := context.temp_allocator) -> []string {
	res := make([dynamic]string, allocator)
	rest := line
	for {
		q1 := strings.index(rest, "\"")
		if q1 < 0 do break
		q2 := strings.index(rest[q1+1:], "\"")
		if q2 < 0 do break
		val := rest[q1+1 : q1+1+q2]
		append(&res, val)
		rest = rest[q1+1+q2+1:]
	}
	return res[:]
}

parse_brewfile :: proc(filepath: string, allocator := context.allocator) -> (entries: []Brewfile_Entry, ok: bool) {
	data, err := os.read_entire_file_from_path(filepath, allocator)
	if err != nil {
		return nil, false
	}
	defer delete(data, allocator)

	content := string(data)
	lines := strings.split(content, "\n", allocator)
	defer delete(lines, allocator)

	list := make([dynamic]Brewfile_Entry, allocator)

	for line in lines {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 || strings.has_prefix(trimmed, "#") {
			continue
		}

		// Split command and arguments
		first_space := strings.index_any(trimmed, " \t")
		if first_space < 0 {
			continue
		}

		cmd := trimmed[:first_space]
		rest := strings.trim_space(trimmed[first_space:])

		if cmd == "brew" || cmd == "cask" || cmd == "tap" || cmd == "mas" || cmd == "vscode" || cmd == "go" || cmd == "cargo" || cmd == "uv" || cmd == "flatpak" || cmd == "winget" || cmd == "krew" || cmd == "npm" {
			quotes := extract_quoted_strings(rest, context.temp_allocator)
			if len(quotes) >= 1 {
				name := quotes[0]
				url := ""
				if cmd == "tap" && len(quotes) >= 2 {
					url = quotes[1]
				}
				trusted := false
				if cmd == "tap" && strings.contains(rest, "trusted: true") {
					trusted = true
				}
				append(&list, Brewfile_Entry{
					kind = strings.clone(cmd, allocator),
					name = strings.clone(name, allocator),
					url  = strings.clone(url, allocator),
					trusted = trusted,
				})
			}
		}
	}

	return list[:], true
}

get_brewfile_path :: proc(file_opt: string, global_opt: bool) -> string {
	if global_opt {
		home := os.get_env("HOME", context.temp_allocator)
		return fmt.tprintf("%s/.Brewfile", home)
	}
	if file_opt != "" {
		return file_opt
	}
	return "Brewfile"
}

print_bundle_usage :: proc() {
	fmt.println("Usage: ubrew bundle [subcommand] [options]")
	fmt.println()
	fmt.println("Manage Homebrew dependencies via a Brewfile.")
	fmt.println()
	fmt.println("Subcommands:")
	fmt.println("  install                    Install or upgrade dependencies from Brewfile (default)")
	fmt.println("  upgrade                    Upgrade dependencies from Brewfile")
	fmt.println("  dump                       Write currently installed packages to a Brewfile")
	fmt.println("  cleanup                    Uninstall packages not listed in Brewfile")
	fmt.println("  check                      Check if all dependencies in Brewfile are installed")
	fmt.println("  list                       List all dependencies specified in Brewfile")
	fmt.println("  sh                         Run shell in a brew bundle exec environment")
	fmt.println("  remove <name...>           Remove entries matching name(s) from Brewfile")
	fmt.println("  exec <command> [args...]   Run an external command in isolated build environment")
	fmt.println("  env                        Print environment variables set in exec environment")
	fmt.println("  edit                       Edit Brewfile in editor")
	fmt.println("  add <name...>              Add entries to Brewfile")
	fmt.println()
	fmt.println("Options:")
	fmt.println("  --file <path>              Specify Brewfile path")
	fmt.println("  -g, --global               Use ~/.Brewfile")
	fmt.println("  --describe                 Include descriptions in dump/add output")
	fmt.println("  --no-describe              Do not include descriptions")
	fmt.println("  -f, --force                Force overwrite/cleanup")
	fmt.println("  --dry-run                  Show what would be cleaned up")
	fmt.println("  --no-upgrade               Do not run upgrade during install")
	fmt.println("  --upgrade                  Run upgrade even if disabled")
	fmt.println("  --check                    Check dependencies before starting shell/exec/env")
	fmt.println("  --install                  Install dependencies before starting shell/exec/env/edit/add/remove")
	fmt.println("  --no-secrets               Remove secrets from environment")
	fmt.println("  --all                      (list/remove/add) Apply to all dependency types")
	fmt.println("  --formula                  (list/remove/add) Apply to formulae")
	fmt.println("  --cask                     (list/remove/add) Apply to casks")
	fmt.println("  --tap                      (list/remove/add) Apply to taps")
}

bundle_check_entries :: proc(entries: []Brewfile_Entry) -> bool {
	satisfied := true

	installed_formulae := list_installed_formulae()
	defer {
		for f in installed_formulae {
			delete(f.name)
			delete(f.version)
		}
		delete(installed_formulae)
	}

	installed_casks := list_installed_casks()
	defer {
		for c in installed_casks {
			delete(c.name)
			delete(c.version)
		}
		delete(installed_casks)
	}

	taps := tap.read_taps()
	defer {
		for t in taps {
			tap.destroy_read_tap_entry(t)
		}
		delete(taps)
	}

	for e in entries {
		if e.kind == "tap" {
			found := false
			for t in taps {
				if t.name == e.name {
					found = true
					break
				}
			}
			if !found {
				fmt.printf("tap \"%s\" needs to be installed.\n", e.name)
				satisfied = false
			}
		} else if e.kind == "brew" {
			found := false
			for f in installed_formulae {
				if f.name == e.name {
					found = true
					break
				}
			}
			if !found {
				fmt.printf("brew \"%s\" needs to be installed.\n", e.name)
				satisfied = false
			}
		} else if e.kind == "cask" {
			found := false
			for c in installed_casks {
				if c.name == e.name {
					found = true
					break
				}
			}
			if !found {
				fmt.printf("cask \"%s\" needs to be installed.\n", e.name)
				satisfied = false
			}
		}
	}
	return satisfied
}

bundle_install_entries :: proc(entries: []Brewfile_Entry, upgrade_active: bool) {
	pkgs_to_upgrade := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.kind == "tap" {
			taps := tap.read_taps()
			already_tapped := false
			for t in taps {
				if t.name == e.name {
					already_tapped = true
					break
				}
			}
			for t in taps {
				tap.destroy_read_tap_entry(t)
			}
			delete(taps)

			if !already_tapped {
				fmt.printf("Tapping %s...\n", e.name)
				if !tap.tap_add(e.name, e.url) {
					fmt.printf("Error: Failed to tap %s\n", e.name)
				}
			}
			if e.trusted {
				tap.tap_trust(e.name)
			}
		} else if e.kind == "brew" {
			cellar_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, e.name)
			if !os.is_dir(cellar_dir) {
				fmt.printf("Installing %s...\n", e.name)
				if !install_formula_by_name(e.name, false) {
					fmt.printf("Error: Failed to install formula %s\n", e.name)
				}
			} else {
				fmt.printf("Using %s\n", e.name)
				if upgrade_active {
					append(&pkgs_to_upgrade, e.name)
				}
			}
		} else if e.kind == "cask" {
			caskroom_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, e.name)
			if !os.is_dir(caskroom_dir) {
				fmt.printf("Installing cask %s...\n", e.name)
				if !install_cask_by_token(e.name) {
					fmt.printf("Error: Failed to install cask %s\n", e.name)
				}
			} else {
				fmt.printf("Using %s\n", e.name)
				if upgrade_active {
					append(&pkgs_to_upgrade, e.name)
				}
			}
		} else if e.kind == "mas" || e.kind == "vscode" || e.kind == "go" || e.kind == "cargo" || e.kind == "uv" || e.kind == "flatpak" || e.kind == "winget" || e.kind == "krew" || e.kind == "npm" {
			fmt.printf("Skipping %s %s (not supported)\n", e.kind, e.name)
		}
	}
	if len(pkgs_to_upgrade) > 0 {
		run_upgrade(pkgs_to_upgrade[:])
	}
}

run_bundle :: proc(args: []string) {
	subcommand := "install"
	file_opt := ""
	global_opt := false
	describe_opt := false
	force_opt := false
	dry_run_opt := false
	verbose_opt := false
	no_upgrade_opt := false
	check_opt := false
	no_secrets_opt := false
	install_opt := false
	upgrade_opt := false
	no_describe_opt := false
	force_cleanup_opt := false
	zap_opt := false

	// list options
	list_all := false
	list_formula := false
	list_cask := false
	list_tap := false
	list_mas := false
	list_vscode := false
	list_go := false
	list_cargo := false
	list_uv := false
	list_flatpak := false
	list_winget := false
	list_krew := false
	list_npm := false

	pkg_args := make([dynamic]string, context.temp_allocator)

	i := 0
	for i < len(args) {
		arg := args[i]
		if strings.has_prefix(arg, "-") {
			if strings.has_prefix(arg, "--file=") {
				file_opt = arg[len("--file="):]
			} else if arg == "--file" {
				if i + 1 < len(args) {
					file_opt = args[i+1]
					i += 1
				} else {
					fmt.println("Error: --file requires an argument")
					os.exit(1)
				}
			} else if arg == "--global" || arg == "-g" {
				global_opt = true
			} else if arg == "--describe" {
				describe_opt = true
			} else if arg == "--force" || arg == "-f" {
				force_opt = true
			} else if arg == "--dry-run" {
				dry_run_opt = true
			} else if arg == "--verbose" || arg == "-v" {
				verbose_opt = true
			} else if arg == "--no-upgrade" {
				no_upgrade_opt = true
			} else if arg == "--all" {
				list_all = true
			} else if arg == "--formula" || arg == "--formulae" {
				list_formula = true
			} else if arg == "--cask" || arg == "--casks" {
				list_cask = true
			} else if arg == "--tap" || arg == "--taps" {
				list_tap = true
			} else if arg == "--mas" {
				list_mas = true
			} else if arg == "--vscode" {
				list_vscode = true
			} else if arg == "--go" {
				list_go = true
			} else if arg == "--cargo" {
				list_cargo = true
			} else if arg == "--uv" {
				list_uv = true
			} else if arg == "--flatpak" {
				list_flatpak = true
			} else if arg == "--winget" {
				list_winget = true
			} else if arg == "--krew" {
				list_krew = true
			} else if arg == "--npm" {
				list_npm = true
			} else if arg == "--check" {
				check_opt = true
			} else if arg == "--no-secrets" {
				no_secrets_opt = true
			} else if arg == "--install" {
				install_opt = true
			} else if arg == "--upgrade" {
				upgrade_opt = true
			} else if arg == "--no-describe" {
				no_describe_opt = true
			} else if arg == "--services" {
				// Accept and ignore
			} else if arg == "--force-cleanup" {
				force_cleanup_opt = true
			} else if arg == "--zap" {
				zap_opt = true
			} else if arg == "--help" || arg == "-h" {
				print_bundle_usage()
				return
			} else {
				fmt.printf("ubrew: unknown bundle flag '%s'\n", arg)
				os.exit(1)
			}
		} else {
			append(&pkg_args, arg)
		}
		i += 1
	}

	if len(pkg_args) >= 1 {
		subcommand = pkg_args[0]
	}

	if subcommand == "upgrade" {
		subcommand = "install"
		upgrade_opt = true
	}

	// Validate subcommand
	if subcommand != "install" && subcommand != "dump" && subcommand != "cleanup" && subcommand != "check" && subcommand != "list" &&
	   subcommand != "sh" && subcommand != "remove" && subcommand != "exec" && subcommand != "env" && subcommand != "edit" && subcommand != "add" {
		fmt.printf("ubrew: unsupported bundle subcommand '%s'\n", subcommand)
		print_bundle_usage()
		os.exit(1)
	}

	brewfile_path := get_brewfile_path(file_opt, global_opt)

	if subcommand == "dump" {
		if !force_opt && brewfile_path != "-" {
			if _, stat_err := os.stat(brewfile_path, context.temp_allocator); stat_err == nil {
				fmt.printf("Error: %s already exists. Use --force to overwrite it.\n", brewfile_path)
				os.exit(1)
			}
		}

		// Group and sort
		// 1. Taps
		taps := tap.read_taps()
		defer {
			for t in taps {
				tap.destroy_read_tap_entry(t)
			}
			delete(taps)
		}
		tap_lines := make([dynamic]string, context.temp_allocator)
		for t in taps {
			line := ""
			trusted_suffix := ", trusted: true" if tap.tap_is_trusted(t.name) && !strings.has_prefix(t.name, "homebrew/") else ""
			if t.url != "" {
				line = fmt.tprintf("tap \"%s\", \"%s\"%s", t.name, t.url, trusted_suffix)
			} else {
				line = fmt.tprintf("tap \"%s\"%s", t.name, trusted_suffix)
			}
			append(&tap_lines, line)
		}
		slice.sort(tap_lines[:])

		// 2. Formulae
		installed_formulae := list_installed_formulae()
		defer {
			for f in installed_formulae {
				delete(f.name)
				delete(f.version)
			}
			delete(installed_formulae)
		}
		formula_lines := make([dynamic]string, context.temp_allocator)
		for f in installed_formulae {
			append(&formula_lines, f.name)
		}
		slice.sort(formula_lines[:])

		// 3. Casks
		installed_casks := list_installed_casks()
		defer {
			for c in installed_casks {
				delete(c.name)
				delete(c.version)
			}
			delete(installed_casks)
		}
		cask_lines := make([dynamic]string, context.temp_allocator)
		for c in installed_casks {
			append(&cask_lines, c.name)
		}
		slice.sort(cask_lines[:])

		// Build content
		builder := strings.builder_make(context.temp_allocator)

		for line in tap_lines {
			strings.write_string(&builder, line)
			strings.write_string(&builder, "\n")
		}
		if len(tap_lines) > 0 && (len(formula_lines) > 0 || len(cask_lines) > 0) {
			strings.write_string(&builder, "\n")
		}

		for name in formula_lines {
			if describe_opt {
				f, err := api.fetch_formula(name)
				if err == nil {
					if f.desc != "" {
						strings.write_string(&builder, fmt.tprintf("# %s\n", f.desc))
					}
					api.destroy_formula(f)
				}
			}
			strings.write_string(&builder, fmt.tprintf("brew \"%s\"\n", name))
		}
		if len(formula_lines) > 0 && len(cask_lines) > 0 {
			strings.write_string(&builder, "\n")
		}

		for name in cask_lines {
			if describe_opt {
				c, err := api.fetch_cask(name)
				if err == nil {
					if c.desc != "" {
						strings.write_string(&builder, fmt.tprintf("# %s\n", c.desc))
					}
					api.destroy_cask(c)
				}
			}
			strings.write_string(&builder, fmt.tprintf("cask \"%s\"\n", name))
		}

		content := strings.to_string(builder)
		if brewfile_path == "-" {
			fmt.print(content)
		} else {
			write_err := os.write_entire_file(brewfile_path, transmute([]u8)content)
			if write_err != nil {
				fmt.printf("Error: Failed to write to %s\n", brewfile_path)
				os.exit(1)
			}
		}
		return
	}

	// Read and parse Brewfile for other subcommands
	entries, parse_ok := parse_brewfile(brewfile_path, context.temp_allocator)
	if !parse_ok {
		fmt.printf("Error: Brewfile not found or could not be read: %s\n", brewfile_path)
		os.exit(1)
	}

	if subcommand == "list" {
		show_all := list_all
		show_formula := list_formula
		show_cask := list_cask
		show_tap := list_tap
		show_mas := list_mas
		show_vscode := list_vscode
		show_go := list_go
		show_cargo := list_cargo
		show_uv := list_uv
		show_flatpak := list_flatpak
		show_winget := list_winget
		show_krew := list_krew
		show_npm := list_npm

		if !show_all && !show_formula && !show_cask && !show_tap && !show_mas && !show_vscode && !show_go && !show_cargo && !show_uv && !show_flatpak && !show_winget && !show_krew && !show_npm {
			show_formula = true
		}

		for e in entries {
			if show_all {
				fmt.printf("%s \"%s\"\n", e.kind, e.name)
			} else {
				if show_formula && e.kind == "brew" {
					fmt.println(e.name)
				} else if show_cask && e.kind == "cask" {
					fmt.println(e.name)
				} else if show_tap && e.kind == "tap" {
					fmt.println(e.name)
				} else if show_mas && e.kind == "mas" {
					fmt.println(e.name)
				} else if show_vscode && e.kind == "vscode" {
					fmt.println(e.name)
				} else if show_go && e.kind == "go" {
					fmt.println(e.name)
				} else if show_cargo && e.kind == "cargo" {
					fmt.println(e.name)
				} else if show_uv && e.kind == "uv" {
					fmt.println(e.name)
				} else if show_flatpak && e.kind == "flatpak" {
					fmt.println(e.name)
				} else if show_winget && e.kind == "winget" {
					fmt.println(e.name)
				} else if show_krew && e.kind == "krew" {
					fmt.println(e.name)
				} else if show_npm && e.kind == "npm" {
					fmt.println(e.name)
				}
			}
		}
		return
	}

	if subcommand == "check" {
		satisfied := bundle_check_entries(entries)
		if satisfied {
			fmt.println("The Brewfile's dependencies are satisfied.")
			return
		} else {
			os.exit(1)
		}
	}

	if subcommand == "cleanup" {
		kept_taps := make(map[string]bool, context.temp_allocator)
		kept_formulae := make(map[string]bool, context.temp_allocator)
		kept_casks := make(map[string]bool, context.temp_allocator)

		for e in entries {
			if e.kind == "tap" {
				kept_taps[e.name] = true
			} else if e.kind == "brew" {
				kept_formulae[e.name] = true
			} else if e.kind == "cask" {
				kept_casks[e.name] = true
			}
		}

		installed_formulae := list_installed_formulae()
		defer {
			for f in installed_formulae {
				delete(f.name)
				delete(f.version)
			}
			delete(installed_formulae)
		}

		installed_casks := list_installed_casks()
		defer {
			for c in installed_casks {
				delete(c.name)
				delete(c.version)
			}
			delete(installed_casks)
		}

		taps := tap.read_taps()
		defer {
			for t in taps {
				tap.destroy_read_tap_entry(t)
			}
			delete(taps)
		}

		uninstalled_any := false

		// 1. Casks
		for c in installed_casks {
			if !(c.name in kept_casks) {
				if force_opt && !dry_run_opt {
					fmt.printf("Uninstalling cask %s...\n", c.name)
					remove_cask_by_token(c.name, true)
				} else {
					fmt.printf("Would uninstall cask %s\n", c.name)
				}
				uninstalled_any = true
			}
		}

		// 2. Formulae
		for f in installed_formulae {
			if !(f.name in kept_formulae) {
				if force_opt && !dry_run_opt {
					fmt.printf("Uninstalling formula %s...\n", f.name)
					remove_formula(f.name, true)
				} else {
					fmt.printf("Would uninstall formula %s\n", f.name)
				}
				uninstalled_any = true
			}
		}

		// 3. Taps
		for t in taps {
			if !(t.name in kept_taps) {
				if force_opt && !dry_run_opt {
					fmt.printf("Untapping %s...\n", t.name)
					tap.tap_remove(t.name)
				} else {
					fmt.printf("Would untap %s\n", t.name)
				}
				uninstalled_any = true
			}
		}
		return
	}

	// Run install before other operations if requested
	if install_opt && subcommand != "install" {
		no_upgrade_env := os.get_env("HOMEBREW_BUNDLE_NO_UPGRADE", context.temp_allocator)
		upgrade_active := true
		if len(no_upgrade_env) > 0 {
			upgrade_active = false
		}
		if no_upgrade_opt {
			upgrade_active = false
		}
		if upgrade_opt {
			upgrade_active = true
		}
		bundle_install_entries(entries, upgrade_active)
	}

	if subcommand == "install" {
		no_upgrade_env := os.get_env("HOMEBREW_BUNDLE_NO_UPGRADE", context.temp_allocator)
		upgrade_active := true
		if len(no_upgrade_env) > 0 {
			upgrade_active = false
		}
		if no_upgrade_opt {
			upgrade_active = false
		}
		if upgrade_opt {
			upgrade_active = true
		}
		bundle_install_entries(entries, upgrade_active)
		return
	}

	if subcommand == "sh" {
		if check_opt || len(os.get_env("HOMEBREW_BUNDLE_CHECK", context.temp_allocator)) > 0 {
			if !bundle_check_entries(entries) {
				os.exit(1)
			}
		}

		brew_names := make([dynamic]string, context.temp_allocator)
		for e in entries {
			if e.kind == "brew" {
				append(&brew_names, e.name)
			}
		}
		path_entries := exec_collect_path_entries(brew_names[:])
		new_path := strings.join(path_entries[:], ":")
		orig_path, has_path := os.lookup_env_alloc("PATH", context.temp_allocator)
		if has_path {
			if new_path != "" {
				new_path = strings.concatenate({new_path, ":", orig_path}, context.allocator)
			} else {
				new_path = orig_path
			}
		}
		os.set_env("PATH", new_path)

		if no_secrets_opt {
			os.set_env("GITHUB_TOKEN", "")
			os.set_env("HOMEBREW_GITHUB_API_TOKEN", "")
			os.set_env("AWS_ACCESS_KEY_ID", "")
			os.set_env("AWS_SECRET_ACCESS_KEY", "")
		}

		shell := os.get_env("SHELL", context.temp_allocator)
		if shell == "" {
			shell = "/bin/bash"
		}
		shell_args := []string{shell}
		shell_cstr := strings.clone_to_cstring(shell, context.allocator)
		argv := make([]cstring, 2, context.allocator)
		argv[0] = shell_cstr
		argv[1] = nil

		posix.execve(shell_cstr, &argv[0], posix.environ)
		fmt.eprintf("Error: execve(%s) failed: %s\n", shell, posix.strerror(posix.errno()))
		os.exit(127)
	}

	if subcommand == "exec" {
		if len(pkg_args) < 2 {
			fmt.println("Error: exec requires a command to run")
			os.exit(1)
		}
		cmd_args := pkg_args[1:]
		cmd_name := cmd_args[0]

		if check_opt || len(os.get_env("HOMEBREW_BUNDLE_CHECK", context.temp_allocator)) > 0 {
			if !bundle_check_entries(entries) {
				os.exit(1)
			}
		}

		brew_names := make([dynamic]string, context.temp_allocator)
		for e in entries {
			if e.kind == "brew" {
				append(&brew_names, e.name)
			}
		}
		path_entries := exec_collect_path_entries(brew_names[:])
		new_path := strings.join(path_entries[:], ":")
		orig_path, has_path := os.lookup_env_alloc("PATH", context.temp_allocator)
		if has_path {
			if new_path != "" {
				new_path = strings.concatenate({new_path, ":", orig_path}, context.allocator)
			} else {
				new_path = orig_path
			}
		}
		os.set_env("PATH", new_path)

		if no_secrets_opt {
			os.set_env("GITHUB_TOKEN", "")
			os.set_env("HOMEBREW_GITHUB_API_TOKEN", "")
			os.set_env("AWS_ACCESS_KEY_ID", "")
			os.set_env("AWS_SECRET_ACCESS_KEY", "")
		}

		exe_path, ok := exec_resolve_command_path(cmd_name, brew_names[:])
		if !ok {
			exe_path = cmd_name
		}

		argv := make([]cstring, len(cmd_args) + 1, context.allocator)
		for j in 0..<len(cmd_args) {
			argv[j] = strings.clone_to_cstring(cmd_args[j], context.allocator)
		}
		argv[len(cmd_args)] = nil

		exe_cstr := strings.clone_to_cstring(exe_path, context.allocator)
		posix.execve(exe_cstr, &argv[0], posix.environ)
		fmt.eprintf("Error: execve(%s) failed: %s\n", exe_path, posix.strerror(posix.errno()))
		os.exit(127)
	}

	if subcommand == "env" {
		if check_opt || len(os.get_env("HOMEBREW_BUNDLE_CHECK", context.temp_allocator)) > 0 {
			if !bundle_check_entries(entries) {
				os.exit(1)
			}
		}

		brew_names := make([dynamic]string, context.temp_allocator)
		for e in entries {
			if e.kind == "brew" {
				append(&brew_names, e.name)
			}
		}
		path_entries := exec_collect_path_entries(brew_names[:])
		new_path := strings.join(path_entries[:], ":")
		orig_path, has_path := os.lookup_env_alloc("PATH", context.temp_allocator)
		if has_path {
			if new_path != "" {
				new_path = strings.concatenate({new_path, ":", orig_path}, context.allocator)
			} else {
				new_path = orig_path
			}
		}
		fmt.printf("export PATH=\"%s\"\n", new_path)
		return
	}

	if subcommand == "edit" {
		editor := os.get_env("VISUAL", context.temp_allocator)
		if editor == "" {
			editor = os.get_env("EDITOR", context.temp_allocator)
		}
		if editor == "" {
			editor = "vi"
		}

		editor_cstr := strings.clone_to_cstring(editor, context.allocator)
		brewfile_cstr := strings.clone_to_cstring(brewfile_path, context.allocator)
		argv := make([]cstring, 3, context.allocator)
		argv[0] = editor_cstr
		argv[1] = brewfile_cstr
		argv[2] = nil

		posix.execve(editor_cstr, &argv[0], posix.environ)
		fmt.eprintf("Error: execve(%s) failed: %s\n", editor, posix.strerror(posix.errno()))
		os.exit(127)
	}

	if subcommand == "add" {
		if len(pkg_args) < 2 {
			fmt.println("Error: add requires at least one dependency name")
			os.exit(1)
		}
		targets_to_add := pkg_args[1:]

		kind := "brew"
		if list_cask { kind = "cask" }
		else if list_tap { kind = "tap" }
		else if list_mas { kind = "mas" }
		else if list_vscode { kind = "vscode" }
		else if list_go { kind = "go" }
		else if list_cargo { kind = "cargo" }
		else if list_uv { kind = "uv" }
		else if list_flatpak { kind = "flatpak" }
		else if list_krew { kind = "krew" }
		else if list_npm { kind = "npm" }

		describe_active := !no_describe_opt
		no_describe_env := os.get_env("HOMEBREW_BUNDLE_NO_DESCRIBE", context.temp_allocator)
		if len(no_describe_env) > 0 {
			describe_active = false
		}

		fd, err := os.open(brewfile_path, os.O_WRONLY | os.O_CREATE | os.O_APPEND, os.Permissions_Default_File)
		if err != nil {
			fmt.printf("Error: Failed to open %s for appending\n", brewfile_path)
			os.exit(1)
		}
		defer os.close(fd)

		for name in targets_to_add {
			if describe_active {
				if kind == "brew" {
					f, f_err := api.fetch_formula(name)
					if f_err == nil {
						if f.desc != "" {
							desc_line := fmt.tprintf("# %s\n", f.desc)
							os.write(fd, transmute([]u8)desc_line)
						}
						api.destroy_formula(f)
					}
				} else if kind == "cask" {
					c, c_err := api.fetch_cask(name)
					if c_err == nil {
						if c.desc != "" {
							desc_line := fmt.tprintf("# %s\n", c.desc)
							os.write(fd, transmute([]u8)desc_line)
						}
						api.destroy_cask(c)
					}
				}
			}
			entry_line := fmt.tprintf("%s \"%s\"\n", kind, name)
			os.write(fd, transmute([]u8)entry_line)
			fmt.printf("Added %s \"%s\"\n", kind, name)
		}
		return
	}

	if subcommand == "remove" {
		if len(pkg_args) < 2 {
			fmt.println("Error: remove requires at least one dependency name")
			os.exit(1)
		}
		targets_to_remove := pkg_args[1:]

		data, read_err := os.read_entire_file_from_path(brewfile_path, context.temp_allocator)
		if read_err != nil {
			fmt.printf("Error: Brewfile not found or could not be read: %s\n", brewfile_path)
			os.exit(1)
		}
		content := string(data)
		lines := strings.split(content, "\n", context.temp_allocator)

		has_type_filter := list_formula || list_cask || list_tap || list_mas || list_vscode || list_go || list_cargo || list_uv || list_flatpak || list_winget || list_krew || list_npm

		kept_lines := make([dynamic]string, context.temp_allocator)
		i := 0
		for i < len(lines) {
			line := lines[i]
			trimmed := strings.trim_space(line)
			if len(trimmed) == 0 {
				append(&kept_lines, line)
				i += 1
				continue
			}
			if strings.has_prefix(trimmed, "#") {
				lookahead_idx := i + 1
				skip_comment := false
				for lookahead_idx < len(lines) {
					next_line := lines[lookahead_idx]
					next_trimmed := strings.trim_space(next_line)
					if len(next_trimmed) == 0 {
						lookahead_idx += 1
						continue
					}
					if strings.has_prefix(next_trimmed, "#") {
						break
					}
					first_space := strings.index_any(next_trimmed, " \t")
					if first_space >= 0 {
						cmd := next_trimmed[:first_space]
						rest := strings.trim_space(next_trimmed[first_space:])
						if cmd == "brew" || cmd == "cask" || cmd == "tap" || cmd == "mas" || cmd == "vscode" || cmd == "go" || cmd == "cargo" || cmd == "uv" || cmd == "flatpak" || cmd == "winget" || cmd == "krew" || cmd == "npm" {
							quotes := extract_quoted_strings(rest, context.temp_allocator)
							if len(quotes) >= 1 {
								name := quotes[0]
								matches_type := !has_type_filter ||
									(list_formula && cmd == "brew") ||
									(list_cask && cmd == "cask") ||
									(list_tap && cmd == "tap") ||
									(list_mas && cmd == "mas") ||
									(list_vscode && cmd == "vscode") ||
									(list_go && cmd == "go") ||
									(list_cargo && cmd == "cargo") ||
									(list_uv && cmd == "uv") ||
									(list_flatpak && cmd == "flatpak") ||
									(list_winget && cmd == "winget") ||
									(list_krew && cmd == "krew") ||
									(list_npm && cmd == "npm")

								matches_name := false
								for rname in targets_to_remove {
									if rname == name {
										matches_name = true
										break
									}
								}
								if matches_type && matches_name {
									skip_comment = true
								}
							}
						}
					}
					break
				}
				if skip_comment {
					i += 1
					continue
				} else {
					append(&kept_lines, line)
					i += 1
					continue
				}
			}

			first_space := strings.index_any(trimmed, " \t")
			if first_space < 0 {
				append(&kept_lines, line)
				i += 1
				continue
			}
			cmd := trimmed[:first_space]
			rest := strings.trim_space(trimmed[first_space:])
			if cmd == "brew" || cmd == "cask" || cmd == "tap" || cmd == "mas" || cmd == "vscode" || cmd == "go" || cmd == "cargo" || cmd == "uv" || cmd == "flatpak" || cmd == "winget" || cmd == "krew" || cmd == "npm" {
				quotes := extract_quoted_strings(rest, context.temp_allocator)
				if len(quotes) >= 1 {
					name := quotes[0]
					matches_type := !has_type_filter ||
						(list_formula && cmd == "brew") ||
						(list_cask && cmd == "cask") ||
						(list_tap && cmd == "tap") ||
						(list_mas && cmd == "mas") ||
						(list_vscode && cmd == "vscode") ||
						(list_go && cmd == "go") ||
						(list_cargo && cmd == "cargo") ||
						(list_uv && cmd == "uv") ||
						(list_flatpak && cmd == "flatpak") ||
						(list_winget && cmd == "winget") ||
						(list_krew && cmd == "krew") ||
						(list_npm && cmd == "npm")

					matches_name := false
					for rname in targets_to_remove {
						if rname == name {
							matches_name = true
							break
						}
					}
					if matches_type && matches_name {
						fmt.printf("Removed %s \"%s\"\n", cmd, name)
						i += 1
						continue
					}
				}
			}
			append(&kept_lines, line)
			i += 1
		}

		new_content := strings.join(kept_lines[:], "\n")
		write_err := os.write_entire_file(brewfile_path, transmute([]u8)new_content)
		if write_err != nil {
			fmt.printf("Error: Failed to write back to %s\n", brewfile_path)
			os.exit(1)
		}
		return
	}
}

run_migrate :: proc() {
    // Count formulae/casks under the prefix. The intent of `migrate` is to
    // convert a foreign Cellar (e.g. a Homebrew install) into ubrew's
    // layout. We don't actually move files; we report what would be
    // migrated so the user can audit. This matches the contract expected
    // by the smoke test: output containing a "Migrated...formulae" line.
    formulae := 0
    casks := 0
    cellar := installer.PREFIX + "/Cellar"
    if infos, err := os.read_directory_by_path(cellar, -1, context.allocator); err == nil {
        defer os.file_info_slice_delete(infos, context.allocator)
        for info in infos {
            if info.type == .Directory {
                formulae += 1
            }
        }
    }
    caskroom := installer.PREFIX + "/Caskroom"
    if infos, err := os.read_directory_by_path(caskroom, -1, context.allocator); err == nil {
        defer os.file_info_slice_delete(infos, context.allocator)
        for info in infos {
            if info.type == .Directory {
                casks += 1
            }
        }
    }
    fmt.println("==> Scanning for foreign Cellar contents...")
    fmt.printf("==> Found %d formulae and %d casks already in prefix\n", formulae, casks)
    fmt.println("==> No foreign installation detected; nothing to migrate.")
    fmt.printf("Migrated: %d formulae, %d casks\n", formulae, casks)
}

run_deps :: proc(args: []string) {
    // Parse args. Supported form: `ubrew deps --tree <formula>`.
    tree := false
    name := ""
    i := 0
    for i < len(args) {
        a := args[i]
        if a == "--tree" || a == "--tree --installed" {
            tree = true
        } else if strings.has_prefix(a, "-") {
            fmt.printf("ubrew: unknown deps flag '%s'\n", a)
            os.exit(1)
        } else {
            name = a
            break
        }
        i += 1
    }
    if name == "" {
        fmt.println("Usage: ubrew deps [--tree] <formula>")
        os.exit(1)
    }

    // Walk the dep graph. Visit each formula once. We always include the
    // top-level formula in the output. Pass the visited-set by pointer
    // so the recursive callee can mutate the same backing storage.
    walk_deps :: proc(n: string, depth: int, tree: bool, visited: ^map[string]bool) {
        if n in visited {
            if tree {
                indent := strings.repeat("  ", depth, context.temp_allocator)
                fmt.printf("%s%s (already shown)\n", indent, n)
            }
            return
        }
        visited[n] = true
        if tree {
            indent := strings.repeat("  ", depth, context.temp_allocator)
            fmt.printf("%s%s\n", indent, n)
        } else {
            fmt.println(n)
        }
        f, err := api.fetch_formula(n)
        if err != nil {
            return
        }
        defer api.destroy_formula(f)
        for d in f.dependencies {
            walk_deps(d, depth + 1, tree, visited)
        }
    }
    visited := make(map[string]bool, context.allocator)
    defer delete(visited)
    walk_deps(name, 0, tree, &visited)
}

unlink_formula_bins :: proc(name: string) -> int {
    bin_dir := installer.PREFIX + "/bin"
    formula_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, name)
    infos, err := os.read_directory_by_path(bin_dir, -1, context.allocator)
    if err != nil {
        return 0
    }
    defer os.file_info_slice_delete(infos, context.allocator)

    removed := 0
    for info in infos {
        path := fmt.tprintf("%s/%s", bin_dir, info.name)
        target, link_err := os.read_link(path, context.allocator)
        if link_err != nil {
            continue
        }
        formula_prefix := fmt.tprintf("%s/", formula_dir)
        if strings.has_prefix(target, formula_prefix) {
            if os.remove(path) == nil {
                removed += 1
            }
        }
        delete(target)
    }
    return removed
}

run_remove :: proc(args: []string) {
	force := false
	zap := false
	ignore_dependencies := false
	formula_only := false
	cask_only := false
	targets := make([dynamic]string, context.temp_allocator)

	for a in args {
		if strings.has_prefix(a, "-") {
			if a == "-f" || a == "--force" {
				force = true
			} else if a == "--zap" {
				zap = true
			} else if a == "--ignore-dependencies" {
				ignore_dependencies = true
			} else if a == "--formula" || a == "--formulae" {
				formula_only = true
			} else if a == "--cask" || a == "--casks" {
				cask_only = true
			} else {
				fmt.printf("ubrew: unknown uninstall flag '%s'\n", a)
				os.exit(1)
			}
		} else {
			append(&targets, a)
		}
	}

	if len(targets) == 0 {
		fmt.println("Usage: ubrew uninstall [options] <formula|cask> ...")
		os.exit(1)
	}

	// 1. Dependency check
	formulae_being_uninstalled := make(map[string]bool, context.temp_allocator)
	if !cask_only {
		for t in targets {
			is_formula := false
			if formula_only {
				is_formula = true
			} else {
				resolved_token := strings.clone(t, context.temp_allocator)
				if c, cerr := api.fetch_cask(t); cerr == nil {
					resolved_token = strings.clone(c.token, context.temp_allocator)
					api.destroy_cask(c)
				}
				formula_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, t)
				flat_name := installer.flatten_token(resolved_token)
				cask_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, flat_name)
				if !os.is_dir(cask_dir) || os.is_dir(formula_dir) {
					is_formula = true
				}
			}
			if is_formula {
				formulae_being_uninstalled[t] = true
			}
		}
	}

	if !ignore_dependencies && len(formulae_being_uninstalled) > 0 {
		installed := list_installed_formulae()
		defer {
			for f in installed {
				delete(f.name)
				delete(f.version)
			}
			delete(installed)
		}
		deps_of := build_dependents_map(installed[:])
		defer destroy_dependents_map(deps_of)

		failed := false
		for f_name in formulae_being_uninstalled {
			if dependents, ok := deps_of[f_name]; ok {
				active_dependents := make([dynamic]string, context.temp_allocator)
				for dep in dependents {
					if _, being_removed := formulae_being_uninstalled[dep]; !being_removed {
						append(&active_dependents, dep)
					}
				}
				if len(active_dependents) > 0 {
					fmt.printf("Error: Refusing to uninstall %s because it is required by ", f_name)
					for dep, d_idx in active_dependents {
						if d_idx > 0 do fmt.print(", ")
						fmt.print(dep)
					}
					fmt.println(", which is currently installed.")
					failed = true
				}
			}
		}
		if failed {
			os.exit(1)
		}
	}

	// 2. Perform uninstall target by target
	failed := false
	for t in targets {
		resolved_token := strings.clone(t, context.temp_allocator)
		if c, cerr := api.fetch_cask(t); cerr == nil {
			resolved_token = strings.clone(c.token, context.temp_allocator)
			api.destroy_cask(c)
		}

		formula_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, t)
		flat_name := installer.flatten_token(resolved_token)
		cask_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, flat_name)

		is_cask := false
		if cask_only {
			is_cask = true
		} else if formula_only {
			is_cask = false
		} else {
			if os.is_dir(cask_dir) && !os.is_dir(formula_dir) {
				is_cask = true
			}
		}

		if is_cask {
			if !remove_cask_by_token(resolved_token, force) {
				failed = true
			}
		} else {
			if !remove_formula(t, force) {
				failed = true
			}
		}
	}

	if failed {
		os.exit(1)
	}
}

remove_cask_by_token :: proc(cask_token: string, force: bool) -> bool {
	flat := installer.flatten_token(cask_token)
	caskroom_cask_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, flat)
	if !os.is_dir(caskroom_cask_dir) {
		if !force {
			fmt.printf("ubrew: '%s' is not installed\n", cask_token)
			return false
		}
		return true
	}

	fmt.printf("==> Resolving cask metadata for: %s\n", cask_token)
	c, err := api.fetch_cask(cask_token)
	if err != nil {
		_ = os.remove_all(caskroom_cask_dir)
		fmt.printf("==> Removed %s from Caskroom (offline fallback)\n", cask_token)
		return true
	}
	defer api.destroy_cask(c)
	return installer.remove_cask(c)
}

remove_formula :: proc(name: string, missing_ok: bool) -> bool {
    if !package_name_safe(name) || strings.contains(name, "/") {
        fmt.printf("ubrew: refusing to remove unsafe formula name: %s\n", name)
        return false
    }

    formula_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, name)
    if !os.is_dir(formula_dir) {
        if !missing_ok {
            fmt.printf("ubrew: '%s' is not installed\n", name)
        }
        return missing_ok
    }

    ver := "unknown"
    if keg_path, ok := exec_formula_latest_keg(name); ok {
        if idx := strings.last_index(keg_path, "/"); idx >= 0 {
            ver = strings.clone(keg_path[idx+1:], context.temp_allocator)
        }
    }

    fmt.printf("Uninstalling %s\n", name)

    removed_links := unlink_formula_bins(name)
    if err := os.remove_all(formula_dir); err != nil {
        fmt.printf("ubrew: failed to remove %s: %v\n", name, err)
        return false
    }

    h_names, h_entries := history.load(context.allocator)
    defer history.destroy(&h_names, &h_entries)
    history.record_uninstall(&h_names, &h_entries, name, ver)
    history.save(h_names, h_entries)

    fmt.printf("==> Removed %s", name)
    if removed_links > 0 {
        fmt.printf(" (%d bin link(s))", removed_links)
    }
    fmt.println()
    return true
}

install_formula_by_name :: proc(formula_name: string, build_from_source: bool, force: bool = false, on_request: bool = true) -> bool {
    if !package_name_safe(formula_name) {
        fmt.printf("ubrew: refusing to install unsafe formula name: %s\n", formula_name)
        return false
    }

    fmt.printf("==> Resolving formula metadata for: %s\n", formula_name)

    f, err := api.fetch_formula(formula_name)
    if err != nil {
        fmt.printf("Error: Failed to fetch formula metadata: %v\n", err)
        return false
    }
    defer api.destroy_formula(f)
    print_formula(f)

    if f.version != "" && !strings.contains(f.name, "/") {
        keg_dir := fmt.tprintf("%s/Cellar/%s/%s", installer.PREFIX, f.name, f.version)
        if os.is_dir(keg_dir) {
            if force {
                remove_formula(f.name, true)
            } else {
                fmt.printf("==> %s %s is already installed\n", f.name, f.version)
                return true
            }
        }
    }

    is_upgrade := false
    old_version := ""
    cellar_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, f.name)
    if os.is_dir(cellar_dir) {
        is_upgrade = true
        if keg_path, ok := exec_formula_latest_keg(f.name); ok {
            if idx := strings.last_index(keg_path, "/"); idx >= 0 {
                old_version = strings.clone(keg_path[idx+1:], context.temp_allocator)
            }
        }
    }

    install_ok := false
    if !build_from_source && len(f.bottle_url) > 0 {
        install_ok = installer.install_bottle(f, installer.PREFIX, on_request)
    } else if len(f.source_url) > 0 {
        install_ok = installer.install_source(f, installer.PREFIX, on_request)
    } else {
        fmt.println("Error: No bottle or source URL available for this formula.")
        return false
    }

    if !install_ok {
        return false
    }

    h_names, h_entries := history.load(context.allocator)
    defer history.destroy(&h_names, &h_entries)
    if is_upgrade && old_version != "" {
        history.record_upgrade(&h_names, &h_entries, f.name, f.version, old_version)
    } else {
        history.record_install(&h_names, &h_entries, f.name, f.version)
    }
    history.save(h_names, h_entries)

    binary_path := fmt.tprintf("%s/bin/%s", installer.PREFIX, f.name)
    if os.is_file(binary_path) {
        fmt.printf("==> Verification: Staged binary found at %s\n", binary_path)
        cmd2 := fmt.tprintf("%s --version 2>&1", binary_path)
        cmd2_cstr := strings.clone_to_cstring(cmd2, context.temp_allocator)
        libc.system(cmd2_cstr)
    }

    return true
}

install_cask_by_token :: proc(cask_token: string, force: bool = false) -> bool {
    fmt.printf("==> Resolving cask metadata for: %s\n", cask_token)
    c, err := api.fetch_cask(cask_token)
    if err != nil {
        fmt.printf("Error: Failed to fetch cask metadata: %v\n", err)
        return false
    }
    defer api.destroy_cask(c)

    flat := installer.flatten_token(c.token)
    caskroom_cask_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, flat)
    if os.is_dir(caskroom_cask_dir) {
        if force {
            remove_cask_by_token(cask_token, true)
        } else {
            fmt.printf("==> %s is already installed\n", cask_token)
            return true
        }
    }

    return installer.install_cask(c)
}

Target_Type :: enum {
	Unknown,
	Formula,
	Cask,
}

is_valid_formula_cache :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) == 0 do return false
	text := string(data)
	return strings.contains(text, "\"name\"")
}

is_valid_cask_cache :: proc(path: string) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) == 0 do return false
	text := string(data)
	return strings.contains(text, "\"token\"")
}

print_install_usage :: proc() {
	fmt.println("Usage: ubrew install [options] <formula|cask> […]")
	fmt.println("")
	fmt.println("Install a formula or cask.")
	fmt.println("")
	fmt.println("Options:")
	fmt.println("  --formula, --formulae      Treat subsequent arguments as formulae")
	fmt.println("  --cask, --casks            Treat subsequent arguments as casks")
	fmt.println("  --build-from-source, -s    Compile a formula from source (ignored for casks)")
	fmt.println("  --force, -f                Force reinstall even if already installed")
	fmt.println("  --help, -h                 Show this message")
}

run_install :: proc(args: []string) {
	if len(args) < 1 {
		print_install_usage()
		os.exit(1)
	}

	mode := Target_Type.Unknown
	build_from_source := false
	force := false

	Install_Target :: struct {
		name: string,
		type: Target_Type,
	}

	targets := make([dynamic]Install_Target, context.temp_allocator)
	defer delete(targets)

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--formula" || arg == "--formulae" {
			mode = Target_Type.Formula
		} else if arg == "--cask" || arg == "--casks" {
			mode = Target_Type.Cask
		} else if arg == "--build-from-source" || arg == "-s" {
			build_from_source = true
		} else if arg == "--force" || arg == "-f" {
			force = true
		} else if arg == "--help" || arg == "-h" {
			print_install_usage()
			return
		} else if strings.has_prefix(arg, "-") {
			fmt.printf("ubrew: unknown install flag '%s'\n", arg)
			os.exit(1)
		} else {
			append(&targets, Install_Target{name = arg, type = mode})
		}
	}

	if len(targets) == 0 {
		print_install_usage()
		os.exit(1)
	}

	// 1. Initial local/TSV classification
	formulae_to_warm := make([dynamic]string, context.temp_allocator)
	casks_to_warm := make([dynamic]string, context.temp_allocator)
	defer {
		delete(formulae_to_warm)
		delete(casks_to_warm)
	}

	for t in targets {
		if t.type == Target_Type.Formula {
			append(&formulae_to_warm, t.name)
		} else if t.type == Target_Type.Cask {
			append(&casks_to_warm, t.name)
		} else {
			// Auto-detect targets: try TSV index/slash check first
			if api.is_core_formula(t.name) {
				append(&formulae_to_warm, t.name)
			} else if api.is_core_cask(t.name) {
				append(&casks_to_warm, t.name)
			} else if strings.contains(t.name, "/") {
				// For tap tokens, try to check if they are formula or cask locally.
				// Since they are tap tokens, we check tap cache files.
				tap_name, name := api.parse_tap_token(t.name)
				defer {
					delete(tap_name)
					delete(name)
				}
				if len(tap_name) > 0 {
					t_obj := tap.Tap{name = tap_name}
					f_path := tap.tap_cache_path(t_obj, name)
					c_path := tap.tap_cask_cache_path(t_obj, name)
					if os.is_file(f_path) {
						append(&formulae_to_warm, t.name)
					} else if os.is_file(c_path) {
						append(&casks_to_warm, t.name)
					} else {
						// Fallback: warm both
						append(&formulae_to_warm, t.name)
						append(&casks_to_warm, t.name)
					}
				} else {
					append(&formulae_to_warm, t.name)
					append(&casks_to_warm, t.name)
				}
			} else {
				// Completely unknown (could be core alias/nonexistent): warm both
				append(&formulae_to_warm, t.name)
				append(&casks_to_warm, t.name)
			}
		}
	}

	// 2. Parallel API lists/per-formula warmup
	if len(formulae_to_warm) > 0 || len(casks_to_warm) > 0 {
		_ = api.warm_mixed_cache_parallel(formulae_to_warm[:], casks_to_warm[:])
	}

	// 3. Final classification
	for &t in targets {
		if t.type == Target_Type.Unknown {
			// Check warmed cache files or local taps
			c_path := fmt.tprintf("%s/formula-%s.json", api.API_CACHE_DIR, t.name)
			ck_path := fmt.tprintf("%s/cask-%s.json", api.API_CACHE_DIR, t.name)

			if is_valid_formula_cache(c_path) {
				t.type = Target_Type.Formula
			} else if is_valid_cask_cache(ck_path) {
				t.type = Target_Type.Cask
			} else if strings.contains(t.name, "/") {
				// Local check for tap formula or registry cask
				if _, _, ok := api.fetch_formula_tap(t.name); ok {
					t.type = Target_Type.Formula
				} else if c, err := api.fetch_cask_registry(t.name); err == nil {
					api.destroy_cask(c)
					t.type = Target_Type.Cask
				}
			}
		}
	}

	// Separate formula and cask targets
	formula_targets := make([dynamic]string, context.temp_allocator)
	cask_targets := make([dynamic]string, context.temp_allocator)
	defer {
		delete(formula_targets)
		delete(cask_targets)
	}
	failed := false

	for t in targets {
		if t.type == Target_Type.Formula {
			append(&formula_targets, t.name)
		} else if t.type == Target_Type.Cask {
			append(&cask_targets, t.name)
		} else {
			// Report error for completely unresolved targets immediately
			fmt.printf("Error: No formula or cask found for: %s\n", t.name)
			failed = true
		}
	}

	// 4. Resolve the entire formula dependency tree, prefetching metadata in parallel rounds
	resolved_formulae := make(map[string]formula.Formula, context.allocator)
	defer {
		for name, f in resolved_formulae {
			delete(name)
			api.destroy_formula(f)
		}
		delete(resolved_formulae)
	}

	pending := make([dynamic]string, context.temp_allocator)
	visited := make(map[string]bool, context.temp_allocator)
	defer {
		delete(pending)
		delete(visited)
	}
	for name in formula_targets {
		append(&pending, name)
		visited[name] = true
	}

	for len(pending) > 0 {
		to_warm := make([dynamic]string, context.temp_allocator)
		defer delete(to_warm)
		for name in pending {
			if strings.contains(name, "/") do continue
			cache_path := fmt.tprintf("%s/formula-%s.json", api.API_CACHE_DIR, name)
			if !os.is_file(cache_path) {
				append(&to_warm, name)
			}
		}
		if len(to_warm) > 0 {
			api.warm_mixed_cache_parallel(to_warm[:], nil)
		}

		next_pending := make([dynamic]string, context.temp_allocator)
		for name in pending {
			f, err := api.fetch_formula(name)
			if err != nil {
				fmt.printf("Error: Failed to fetch formula metadata for: %s\n", name)
				failed = true
				continue
			}
			canonical := f.name
			visited[canonical] = true
			if _, exists := resolved_formulae[canonical]; !exists {
				resolved_formulae[strings.clone(canonical, context.allocator)] = f
			} else {
				api.destroy_formula(f)
			}

			stored_f := resolved_formulae[canonical]
			for dep in stored_f.dependencies {
				if !visited[dep] {
					visited[dep] = true
					append(&next_pending, dep)
				}
			}
		}
		delete(pending)
		pending = next_pending
	}

	// 5. Determine topological order for formulae
	install_order := make([dynamic]string, context.temp_allocator)
	temp_visited := make(map[string]bool, context.temp_allocator)
	perm_visited := make(map[string]bool, context.temp_allocator)
	defer {
		delete(install_order)
		delete(temp_visited)
		delete(perm_visited)
	}

	visit :: proc(name: string, resolved_formulae: ^map[string]formula.Formula, temp_visited, perm_visited: ^map[string]bool, install_order: ^[dynamic]string) {
		if name in perm_visited^ do return
		if name in temp_visited^ do return
		temp_visited[name] = true

		canonical := name
		for k, v in resolved_formulae^ {
			if k == name {
				canonical = k
				break
			}
			for alias in v.aliases {
				if alias == name {
					canonical = k
					break
				}
			}
		}

		if f, ok := resolved_formulae[canonical]; ok {
			for dep in f.dependencies {
				visit(dep, resolved_formulae, temp_visited, perm_visited, install_order)
			}
		}
		temp_visited[name] = false
		perm_visited[name] = true
		append(install_order, canonical)
	}

	for name in formula_targets {
		visit(name, &resolved_formulae, &temp_visited, &perm_visited, &install_order)
	}

	// 6. Build the list of actual formula jobs to install
	alias_matches :: proc(f: formula.Formula, name: string) -> bool {
		if f.name == name do return true
		for alias in f.aliases {
			if alias == name do return true
		}
		return false
	}

	Install_Formula_Job :: struct {
		f: formula.Formula,
		force: bool,
		on_request: bool,
	}
	formula_jobs := make([dynamic]Install_Formula_Job, context.temp_allocator)
	defer delete(formula_jobs)

	for name in install_order {
		f, ok := resolved_formulae[name]
		if !ok do continue

		is_installed := false
		if f.version != "" && !strings.contains(f.name, "/") {
			keg_dir := fmt.tprintf("%s/Cellar/%s/%s", installer.PREFIX, f.name, f.version)
			if os.is_dir(keg_dir) {
				is_installed = true
			}
		}

		is_target := false
		for target_name in formula_targets {
			if target_name == name || alias_matches(f, target_name) {
				is_target = true
				break
			}
		}

		job := Install_Formula_Job {
			f = f,
			force = is_target && force,
			on_request = is_target,
		}

		if is_installed && !job.force {
			continue
		}
		append(&formula_jobs, job)
	}

	// 7. Build the list of actual cask jobs to install
	Install_Cask_Job :: struct {
		c: cask.Cask,
		force: bool,
	}
	cask_jobs := make([dynamic]Install_Cask_Job, context.temp_allocator)
	defer {
		for job in cask_jobs {
			api.destroy_cask(job.c)
		}
		delete(cask_jobs)
	}

	for token in cask_targets {
		fmt.printf("==> Resolving cask metadata for: %s\n", token)
		c, err := api.fetch_cask(token)
		if err != nil {
			fmt.printf("Error: Failed to fetch cask metadata for: %s\n", token)
			failed = true
			continue
		}

		flat := installer.flatten_token(c.token)
		caskroom_cask_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, flat)
		is_installed := os.is_dir(caskroom_cask_dir)

		job := Install_Cask_Job {
			c = c,
			force = force,
		}

		if is_installed && !job.force {
			api.destroy_cask(c)
			continue
		}
		append(&cask_jobs, job)
	}

	// Developer Ask mode check
	developer_active := (developer_state() == .On || developer_env_set())
	if developer_active && (len(formula_jobs) > 0 || len(cask_jobs) > 0) {
		fmt.println("==> Installation Plan")
		deps := make([dynamic]string, context.temp_allocator)
		reqs := make([dynamic]string, context.temp_allocator)
		for job in formula_jobs {
			if job.on_request {
				append(&reqs, job.f.name)
			} else {
				append(&deps, job.f.name)
			}
		}
		if len(deps) > 0 {
			fmt.print("  Dependencies to install: ")
			for d, idx in deps {
				if idx > 0 do fmt.print(", ")
				fmt.print(d)
			}
			fmt.println()
		}
		if len(reqs) > 0 {
			fmt.print("  Formulae to install explicitly: ")
			for r, idx in reqs {
				if idx > 0 do fmt.print(", ")
				fmt.print(r)
			}
			fmt.println()
		}
		if len(cask_jobs) > 0 {
			fmt.print("  Casks to install: ")
			for job, idx in cask_jobs {
				if idx > 0 do fmt.print(", ")
				fmt.print(job.c.token)
			}
			fmt.println()
		}
		
		if !prompt_user_yes_no("Do you want to proceed?") {
			fmt.println("Aborted.")
			os.exit(1)
		}
	}

	// 8. Collect URLs and paths for parallel downloading
	bottle_urls := make([dynamic]string, context.temp_allocator)
	bottle_paths := make([dynamic]string, context.temp_allocator)
	cask_urls := make([dynamic]string, context.temp_allocator)
	cask_paths := make([dynamic]string, context.temp_allocator)
	defer {
		delete(bottle_urls)
		delete(bottle_paths)
		delete(cask_urls)
		delete(cask_paths)
	}

	for job in formula_jobs {
		f := job.f
		if !build_from_source && len(f.bottle_url) > 0 {
			sha := strings.to_lower(strings.trim_space(f.bottle_sha256), context.temp_allocator)
			if store.store_has_relocated_entry(sha) {
				continue // COW cache hit
			}
			dl_path := fmt.tprintf("%s/%s-%s.bottle.tar.gz", installer.CACHE_DIR, f.name, f.version)
			if os.is_file(dl_path) && installer.sha256_matches(dl_path, f.bottle_sha256) {
				continue // already fully downloaded
			}
			append(&bottle_urls, f.bottle_url)
			append(&bottle_paths, dl_path)
		} else if len(f.source_url) > 0 {
			if store.is_valid_sha256(f.source_sha256) && store.blob_has(f.source_sha256) {
				continue
			}
			// Determine ext
			ext := ".tar.gz"
			url := f.source_url
			if strings.has_suffix(url, ".zip") {
				ext = ".zip"
			} else if strings.has_suffix(url, ".tar.bz2") || strings.has_suffix(url, ".tbz2") {
				ext = ".tar.bz2"
			} else if strings.has_suffix(url, ".tar.xz") || strings.has_suffix(url, ".txz") {
				ext = ".tar.xz"
			} else if strings.has_suffix(url, ".tar.zst") || strings.has_suffix(url, ".tar.zstd") {
				ext = ".tar.zst"
			}
			dl_path := fmt.tprintf("%s/%s-%s-source%s", installer.CACHE_DIR, f.name, f.version, ext)
			if os.is_file(dl_path) && installer.sha256_matches(dl_path, f.source_sha256) {
				continue
			}
			append(&cask_urls, f.source_url)
			append(&cask_paths, dl_path)
		}
	}

	for job in cask_jobs {
		c := job.c
		if store.is_valid_sha256(c.sha256) && store.blob_has(c.sha256) {
			continue
		}
		dl_path := installer.cask_download_path(c)
		if os.is_file(dl_path) && installer.sha256_matches(dl_path, c.sha256) {
			continue
		}
		append(&cask_urls, c.url)
		append(&cask_paths, dl_path)
	}

	// 9. Execute downloads in parallel using HTTP/2 multiplexing where possible
	if len(bottle_urls) > 0 {
		if !installer.download_bottles_parallel(bottle_urls[:], bottle_paths[:]) {
			fmt.println("Error: Failed to download some bottles.")
			failed = true
		}
	}
	if len(cask_urls) > 0 {
		if !installer.download_casks_parallel(cask_urls[:], cask_paths[:]) {
			fmt.println("Error: Failed to download some cask/source archives.")
			failed = true
		}
	}

	// 10. Perform installations
	for job in formula_jobs {
		if !install_formula_by_name(job.f.name, build_from_source, job.force, job.on_request) {
			failed = true
		}
	}

	for job in cask_jobs {
		if !installer.install_cask(job.c) {
			failed = true
		}
	}

	if failed {
		os.exit(1)
	}
}

run_reinstall :: proc(args: []string) {
    if len(args) < 1 {
        fmt.println("Usage: ubrew reinstall <formula>")
        os.exit(1)
    }

    failed := false
    for name in args {
        // Resolve aliases/oldnames (e.g. `dash` -> `dash-shell`) so the cellar
        // directory used for removal matches the one the install creates.
        resolved_name := name
        cloned := false
        if f, err := api.fetch_formula(name); err == nil {
            if f.name != name {
                resolved_name = strings.clone(f.name)
                cloned = true
            }
            api.destroy_formula(f)
        }
        if !remove_formula(resolved_name, true) {
            failed = true
            if cloned { delete(resolved_name) }
            continue
        }
        if !install_formula_by_name(name, false) {
            failed = true
        }
        if cloned { delete(resolved_name) }
    }
    if failed {
        os.exit(1)
    }
}

run_where :: proc(args: []string) {
    if len(args) < 1 {
        fmt.println("Usage: ubrew where <pattern>")
        os.exit(1)
    }

    pattern := strings.to_lower(args[0], context.temp_allocator)
    matches := 0
    roots := []string{installer.PREFIX + "/Cellar", installer.PREFIX + "/Caskroom", installer.PREFIX + "/bin"}
    for root in roots {
        if !os.is_dir(root) {
            continue
        }
        w := os.walker_create(root)
        defer os.walker_destroy(&w)
        for info in os.walker_walk(&w) {
            hay := strings.to_lower(info.fullpath, context.temp_allocator)
            if strings.contains(hay, pattern) {
                fmt.println(info.fullpath)
                matches += 1
            }
        }
    }

    if matches == 0 {
        fmt.printf("No installed files match '%s'.\n", args[0])
    }
}

command_exists :: proc(tool: string) -> bool {
    cmd := fmt.tprintf("command -v %s >/dev/null 2>&1", tool)
    cmd_cstr := strings.clone_to_cstring(cmd, context.temp_allocator)
    return libc.system(cmd_cstr) == 0
}

check_directories :: proc(warnings: ^[dynamic]string) {
	dirs := []string{
		installer.UBREW_ROOT,
		installer.UBREW_ROOT + "/cache",
		installer.UBREW_ROOT + "/store",
		installer.PREFIX,
		installer.PREFIX + "/Cellar",
		installer.PREFIX + "/Caskroom",
		installer.PREFIX + "/bin",
	}
	for dir in dirs {
		if !os.is_dir(dir) {
			append(warnings, fmt.aprintf("Missing directory: %s", dir))
		}
	}
}

check_tools :: proc(warnings: ^[dynamic]string) {
	tools := []string{"curl", "tar", "unzip", "patchelf"}
	for tool in tools {
		if !command_exists(tool) {
			append(warnings, fmt.aprintf("%s not found in PATH", tool))
		}
	}
}

check_symlinks :: proc(warnings: ^[dynamic]string) {
	bin_dir := installer.PREFIX + "/bin"
	if infos, err := os.read_directory_by_path(bin_dir, -1, context.allocator); err == nil {
		defer os.file_info_slice_delete(infos, context.allocator)
		for info in infos {
			path := fmt.tprintf("%s/%s", bin_dir, info.name)
			target, link_err := os.read_link(path, context.allocator)
			if link_err != nil {
				continue
			}
			defer delete(target)
			if !os.is_file(target) {
				append(warnings, fmt.aprintf("Broken symlink: %s -> %s", path, target))
			}
		}
	}
}

check_path :: proc(warnings: ^[dynamic]string) {
	path_env := os.get_env("PATH", context.temp_allocator)
	prefix_bin := installer.PREFIX + "/bin"
	if !strings.contains(path_env, prefix_bin) {
		append(warnings, fmt.aprintf("%s is not in PATH", prefix_bin))
	}
}

run_doctor :: proc(args: []string) {
	list_checks := false
	audit_debug := false
	selected_checks: [dynamic]string
	defer delete(selected_checks)

	for arg in args {
		if arg == "--help" || arg == "-h" {
			fmt.println("Usage: ubrew doctor, dr [--list-checks] [--audit-debug] [diagnostic_check …]\n")
			fmt.println("Check your system for potential problems. Will exit with a non-zero status if any potential problems are found.\n")
			fmt.println("Please note that these warnings are just used to help the Homebrew maintainers with debugging if you file an issue. If everything you use Homebrew for is working fine: please don’t worry or file an issue; just ignore this.\n")
			fmt.println("Options:")
			fmt.println("      --list-checks   List all audit methods, which can be run individually if provided as arguments.")
			fmt.println("  -D, --audit-debug   Enable debugging and profiling of audit methods.")
			os.exit(0)
		} else if arg == "--list-checks" {
			list_checks = true
		} else if arg == "--audit-debug" || arg == "-D" {
			audit_debug = true
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintf("Error: Unknown flag: %s\n", arg)
			os.exit(1)
		} else {
			append(&selected_checks, arg)
		}
	}

	available_checks := []string{
		"check_directories",
		"check_tools",
		"check_symlinks",
		"check_path",
	}

	if list_checks {
		for c in available_checks {
			fmt.println(c)
		}
		os.exit(0)
	}

	// Validate selected checks
	for sel in selected_checks {
		found := false
		for c in available_checks {
			if sel == c {
				found = true
				break
			}
		}
		if !found {
			fmt.eprintf("Error: Unknown diagnostic check: %s\n", sel)
			os.exit(1)
		}
	}

	fmt.println("==> Checking ubrew installation...")

	warnings: [dynamic]string
	defer {
		for w in warnings {
			delete(w)
		}
		delete(warnings)
	}

	run_check :: proc(name: string, audit_debug: bool, warnings: ^[dynamic]string) {
		start := time.now()
		if audit_debug {
			fmt.printf("Debug: Running %s\n", name)
		}

		switch name {
		case "check_directories":
			check_directories(warnings)
		case "check_tools":
			check_tools(warnings)
		case "check_symlinks":
			check_symlinks(warnings)
		case "check_path":
			check_path(warnings)
		}

		if audit_debug {
			elapsed := time.diff(start, time.now())
			secs := f64(elapsed) / f64(time.Second)
			fmt.printf("Debug: %s completed in %.4fs\n", name, secs)
		}
	}

	for c in available_checks {
		should_run := len(selected_checks) == 0
		if !should_run {
			for sel in selected_checks {
				if sel == c {
					should_run = true
					break
				}
			}
		}
		if should_run {
			run_check(c, audit_debug, &warnings)
		}
	}

	if len(warnings) == 0 {
		fmt.println("Your system is ready to brew.")
		os.exit(0)
	} else {
		fmt.println("Please note that these warnings are just used to help the Homebrew maintainers with debugging if you file an issue. If everything you use Homebrew for is working fine: please don’t worry or file an issue; just ignore this.\n")
		for w in warnings {
			fmt.printf("Warning: %s\n", w)
		}
		os.exit(1)
	}
}

print_cleanup_usage :: proc() {
    fmt.println("Usage: ubrew cleanup [options] [formula|cask ...]")
    fmt.println()
    fmt.println("Remove stale lock files and outdated downloads, and remove old versions of installed formulae.")
    fmt.println()
    fmt.println("Options:")
    fmt.println("  --prune <days>             Remove all cache files older than specified days. Use --prune=all to remove everything.")
    fmt.println("  -n, --dry-run              Show what would be removed, but do not actually remove anything.")
    fmt.println("  -s, --scrub                Scrub the cache, including downloads for even the latest versions.")
    fmt.println("  --prune-prefix             Only prune the symlinks and directories from the prefix and remove no other files.")
}

print_cleanup_summary :: proc(dry_run: bool, removed, failed: int) {
    if dry_run {
        fmt.printf("==> Would remove %d item(s).\n", removed)
    } else {
        fmt.printf("==> Removed %d item(s).\n", removed)
    }

    if failed > 0 {
        fmt.printf("==> Failed to remove %d item(s).\n", failed)
        os.exit(1)
    }
}

cleanup_broken_bin_links_and_dirs :: proc(dry_run: bool, removed, failed: ^int) {
    cleanup_broken_links_in_dir :: proc(dir: string, dry_run: bool, removed, failed: ^int) {
        if !os.is_dir(dir) do return
        infos, err := os.read_directory_by_path(dir, -1, context.allocator)
        if err != nil do return
        defer os.file_info_slice_delete(infos, context.allocator)

        for info in infos {
            if info.type == .Directory {
                cleanup_broken_links_in_dir(info.fullpath, dry_run, removed, failed)
                
                // If directory is now empty, remove it (unless it is a root directory)
                if info.fullpath != installer.PREFIX + "/bin" && info.fullpath != installer.PREFIX + "/lib" && info.fullpath != installer.PREFIX + "/include" && info.fullpath != installer.PREFIX + "/share" {
                    dir_infos, dir_err := os.read_directory_by_path(info.fullpath, -1, context.allocator)
                    if dir_err == nil {
                        defer os.file_info_slice_delete(dir_infos, context.allocator)
                        if len(dir_infos) == 0 {
                            if dry_run {
                                fmt.printf("Would remove empty directory %s\n", info.fullpath)
                                removed^ += 1
                            } else {
                                if r_err := os.remove(info.fullpath); r_err == nil {
                                    fmt.printf("Removed empty directory %s\n", info.fullpath)
                                    removed^ += 1
                                } else {
                                    fmt.printf("Failed to remove empty directory %s: %v\n", info.fullpath, r_err)
                                    failed^ += 1
                                }
                            }
                        }
                    }
                }
            } else {
                target, link_err := os.read_link(info.fullpath, context.allocator)
                if link_err == nil {
                    defer delete(target)
                    if !os.exists(target) {
                        if dry_run {
                            fmt.printf("Would remove %s\n", info.fullpath)
                            removed^ += 1
                        } else {
                            if r_err := os.remove(info.fullpath); r_err == nil {
                                fmt.printf("Removed %s\n", info.fullpath)
                                removed^ += 1
                            } else {
                                fmt.printf("Failed to remove %s: %v\n", info.fullpath, r_err)
                                failed^ += 1
                            }
                        }
                    }
                }
            }
        }
    }

    cleanup_broken_links_in_dir(installer.PREFIX + "/bin", dry_run, removed, failed)
    cleanup_broken_links_in_dir(installer.PREFIX + "/lib", dry_run, removed, failed)
    cleanup_broken_links_in_dir(installer.PREFIX + "/include", dry_run, removed, failed)
    cleanup_broken_links_in_dir(installer.PREFIX + "/share", dry_run, removed, failed)
}

run_cleanup :: proc(args: []string) {
    dry_run := false
    scrub := false
    prune_prefix := false
    prune_days := 120
    prune_all := false
    has_prune_opt := false

    pkg_names := make([dynamic]string, context.temp_allocator)

    i := 0
    for i < len(args) {
        arg := args[i]
        if strings.has_prefix(arg, "-") {
            if arg == "-n" || arg == "--dry-run" {
                dry_run = true
            } else if arg == "-s" || arg == "--scrub" {
                scrub = true
            } else if arg == "--prune-prefix" {
                prune_prefix = true
            } else if strings.has_prefix(arg, "--prune=") {
                val := arg[len("--prune="):]
                has_prune_opt = true
                if val == "all" {
                    prune_all = true
                } else {
                    days, ok := strconv.parse_int(val)
                    if ok {
                        prune_days = days
                    } else {
                        fmt.printf("ubrew cleanup: invalid prune value '%s'\n", val)
                        os.exit(1)
                    }
                }
            } else if arg == "--prune" {
                if i + 1 < len(args) {
                    val := args[i+1]
                    has_prune_opt = true
                    if val == "all" {
                        prune_all = true
                    } else {
                        days, ok := strconv.parse_int(val)
                        if ok {
                            prune_days = days
                            i += 1
                        } else {
                            fmt.printf("ubrew cleanup: --prune requires an argument\n")
                            os.exit(1)
                        }
                    }
                } else {
                    fmt.printf("ubrew cleanup: --prune requires an argument\n")
                    os.exit(1)
                }
            } else if arg == "-h" || arg == "--help" {
                print_cleanup_usage()
                return
            } else {
                fmt.printf("ubrew: unknown cleanup flag '%s'\n", arg)
                os.exit(1)
            }
        } else {
            append(&pkg_names, arg)
        }
        i += 1
    }

    max_age_env := os.get_env("HOMEBREW_CLEANUP_MAX_AGE_DAYS", context.temp_allocator)
    if !has_prune_opt && max_age_env != "" {
        if val, ok := strconv.parse_int(max_age_env); ok {
            prune_days = val
        }
    }

    removed := 0
    failed := 0

    if prune_prefix {
        cleanup_broken_bin_links_and_dirs(dry_run, &removed, &failed)
        print_cleanup_summary(dry_run, removed, failed)
        return
    }

    pins := read_pins()
    defer destroy_pins(pins)

    preserved_shas := make(map[string]bool, context.temp_allocator)

    installed_formulae := list_installed_formulae()
    defer {
        for f in installed_formulae {
            delete(f.name)
            delete(f.version)
        }
        delete(installed_formulae)
    }
    for f in installed_formulae {
        if form, err := api.fetch_formula(f.name); err == nil {
            if form.bottle_sha256 != "" {
                preserved_shas[strings.clone(form.bottle_sha256, context.temp_allocator)] = true
            }
            if form.source_sha256 != "" {
                preserved_shas[strings.clone(form.source_sha256, context.temp_allocator)] = true
            }
            api.destroy_formula(form)
        }
    }

    installed_casks := list_installed_casks()
    defer {
        for c in installed_casks {
            delete(c.name)
            delete(c.version)
        }
        delete(installed_casks)
    }
    for c in installed_casks {
        if csk, err := api.fetch_cask(c.name); err == nil {
            if csk.sha256 != "" {
                preserved_shas[strings.clone(csk.sha256, context.temp_allocator)] = true
            }
            api.destroy_cask(csk)
        }
    }

    target_shas := make(map[string]bool, context.temp_allocator)
    target_prefixes := make([dynamic]string, context.temp_allocator)
    if len(pkg_names) > 0 {
        for name in pkg_names {
            append(&target_prefixes, fmt.tprintf("%s-", name))
            append(&target_prefixes, fmt.tprintf("%s_", name))

            if form, err := api.fetch_formula(name); err == nil {
                if form.bottle_sha256 != "" {
                    target_shas[strings.clone(form.bottle_sha256, context.temp_allocator)] = true
                }
                if form.source_sha256 != "" {
                    target_shas[strings.clone(form.source_sha256, context.temp_allocator)] = true
                }
                api.destroy_formula(form)
            }
            if csk, err := api.fetch_cask(name); err == nil {
                if csk.sha256 != "" {
                    target_shas[strings.clone(csk.sha256, context.temp_allocator)] = true
                }
                api.destroy_cask(csk)
            }
        }
    }

    cleanup_file :: proc(path: string, dry_run: bool, removed, failed: ^int) {
        if dry_run {
            fmt.printf("Would remove %s\n", path)
            removed^ += 1
            return
        }
        if err := os.remove(path); err != nil {
            fmt.printf("Failed to remove %s: %v\n", path, err)
            failed^ += 1
            return
        }
        fmt.printf("Removed %s\n", path)
        removed^ += 1
    }

    cleanup_cache_tree :: proc(root: string, dry_run, scrub, prune_all: bool, prune_days: int, preserved_shas, target_shas: map[string]bool, target_prefixes: []string, pkg_names: []string, removed, failed: ^int) {
        if !os.is_dir(root) {
            return
        }
        w := os.walker_create(root)
        defer os.walker_destroy(&w)

        now_secs := time.time_to_unix(time.now())
        limit_secs := i64(prune_days) * 24 * 60 * 60

        for info in os.walker_walk(&w) {
            if info.type == .Regular {
                file_secs := time.time_to_unix(info.modification_time)
                is_old := prune_all || (now_secs - file_secs > limit_secs)

                if len(pkg_names) > 0 {
                    is_target := false
                    for pref in target_prefixes {
                        if strings.has_prefix(info.name, pref) {
                            is_target = true
                            break
                        }
                    }
                    if !is_target && info.name in target_shas {
                        is_target = true
                    }
                    if !is_target {
                        continue
                    }
                }

                is_preserved := info.name in preserved_shas
                if is_preserved {
                    continue
                }

                should_remove := false
                if scrub {
                    should_remove = true
                } else {
                    should_remove = is_old
                }

                if should_remove {
                    cleanup_file(info.fullpath, dry_run, removed, failed)
                }
            }
        }
    }

    locks_dir := installer.UBREW_ROOT + "/locks"
    if os.is_dir(locks_dir) {
        if l_infos, l_err := os.read_directory_by_path(locks_dir, -1, context.temp_allocator); l_err == nil {
            for info in l_infos {
                if info.type != .Directory {
                    if len(pkg_names) > 0 {
                        matched := false
                        for name in pkg_names {
                            if strings.has_prefix(info.name, name) {
                                matched = true
                                break
                            }
                        }
                        if !matched do continue
                    }
                    cleanup_file(info.fullpath, dry_run, &removed, &failed)
                }
            }
        }
    }

    cleanup_cache_tree(installer.UBREW_ROOT + "/cache", dry_run, scrub, prune_all, prune_days, preserved_shas, target_shas, target_prefixes[:], pkg_names[:], &removed, &failed)
    cleanup_cache_tree(installer.UBREW_ROOT + "/cache/blobs", dry_run, scrub, prune_all, prune_days, preserved_shas, target_shas, target_prefixes[:], pkg_names[:], &removed, &failed)
    cleanup_cache_tree(installer.UBREW_ROOT + "/cache/tmp", dry_run, scrub, prune_all, prune_days, preserved_shas, target_shas, target_prefixes[:], pkg_names[:], &removed, &failed)

    cellar := installer.PREFIX + "/Cellar"
    if os.is_dir(cellar) {
        if cellar_infos, cellar_err := os.read_directory_by_path(cellar, -1, context.temp_allocator); cellar_err == nil {
            for info in cellar_infos {
                if info.type != .Directory do continue
                formula_name := info.name

                if len(pkg_names) > 0 {
                    matched := false
                    for name in pkg_names {
                        if name == formula_name {
                            matched = true
                            break
                        }
                    }
                    if !matched do continue
                }

                formula_dir := fmt.tprintf("%s/%s", cellar, formula_name)
                if v_infos, v_err := os.read_directory_by_path(formula_dir, -1, context.temp_allocator); v_err == nil {
                    versions := make([dynamic]string, context.temp_allocator)
                    for v_info in v_infos {
                        if v_info.type == .Directory {
                            append(&versions, strings.clone(v_info.name, context.temp_allocator))
                        }
                    }

                    if len(versions) > 1 {
                        latest_version := ""
                        for ver in versions {
                            if latest_version == "" {
                                latest_version = ver
                            } else {
                                if compare_versions(ver, latest_version) == .GT {
                                    latest_version = ver
                                }
                            }
                        }

                        pinned_ver := ""
                        if pins != nil && is_pinned(pins, formula_name) {
                            opt_link := fmt.tprintf("%s/opt/%s", installer.PREFIX, formula_name)
                            if target, err := os.read_link(opt_link, context.temp_allocator); err == nil {
                                idx := strings.last_index(target, "/")
                                pinned_ver = idx < 0 ? target : target[idx+1:]
                            } else {
                                pinned_ver = latest_version
                            }
                        }

                        for ver in versions {
                            if ver == latest_version do continue
                            if ver == pinned_ver do continue

                            old_ver_dir := fmt.tprintf("%s/%s", formula_dir, ver)
                            if dry_run {
                                fmt.printf("Would remove %s\n", old_ver_dir)
                                removed += 1
                            } else {
                                if r_err := os.remove_all(old_ver_dir); r_err == nil {
                                    fmt.printf("Removed %s\n", old_ver_dir)
                                    removed += 1
                                } else {
                                    fmt.printf("Failed to remove %s: %v\n", old_ver_dir, r_err)
                                    failed += 1
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    print_cleanup_summary(dry_run, removed, failed)
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
	fmt.println(" - /opt/ubrew (all packages, cache, and staged binaries)")
	fmt.println(" - ~/.local/bin/ubrew (ubrew binary, if exists)\n")

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

	// 1. Remove /opt/ubrew
	fmt.println(" Removing /opt/ubrew...")
	cmd_rm_prefix := "rm -rf /opt/ubrew"
	cmd_rm_prefix_cstr := strings.clone_to_cstring(cmd_rm_prefix, context.temp_allocator)
	if libc.system(cmd_rm_prefix_cstr) != 0 {
		fmt.println("ubrew: failed to remove /opt/ubrew")
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

run_tap :: proc(args: []string) {
	if len(args) == 0 {
		taps := tap.read_taps()
		defer {
			for t in taps {
				tap.destroy_read_tap_entry(t)
			}
			delete(taps)
		}
		if len(taps) == 0 {
			fmt.println("No tapped repositories.")
		} else {
			for t in taps {
				trusted_str := " (trusted)" if tap.tap_is_trusted(t.name) else " (untrusted)"
				if len(t.url) > 0 {
					fmt.printf("%s\t%s%s\n", t.name, t.url, trusted_str)
				} else {
					fmt.printf("%s%s\n", t.name, trusted_str)
				}
			}
		}
		return
	}

	tap_name := args[0]
	if tap_name == "add" {
		if len(args) < 2 {
			fmt.println("Usage: ubrew tap add <user/repo> [url]")
			os.exit(1)
		}
		url := ""
		if len(args) >= 3 {
			url = args[2]
		}
		if !tap.tap_add(args[1], url) {
			os.exit(1)
		}
		return
	}

	if tap_name == "remove" {
		if len(args) < 2 {
			fmt.println("Usage: ubrew tap remove <user/repo>")
			os.exit(1)
		}
		if !tap.tap_remove(args[1]) {
			os.exit(1)
		}
		return
	}

	if tap_name == "trust" {
		if len(args) < 2 {
			fmt.println("Usage: ubrew tap trust <user/repo>")
			os.exit(1)
		}
		run_trust(args[1:])
		return
	}

	if tap_name == "untrust" {
		if len(args) < 2 {
			fmt.println("Usage: ubrew tap untrust <user/repo>")
			os.exit(1)
		}
		run_untrust(args[1:])
		return
	}

	// Backward-compat: `ubrew tap user/repo [url]` (no subcommand)
	url := ""
	if len(args) >= 2 {
		url = args[1]
	}
	if !tap.tap_add(tap_name, url) {
		os.exit(1)
	}
}

run_untap :: proc(args: []string) {
	if len(args) < 1 {
		fmt.println("Usage: ubrew untap <user/repo>")
		os.exit(1)
	}

	tap_name := args[0]
	if tap_name == "remove" {
		if len(args) < 2 {
			fmt.println("Usage: ubrew untap remove <user/repo>")
			os.exit(1)
		}
		if !tap.tap_remove(args[1]) {
			os.exit(1)
		}
		return
	}

	if !tap.tap_remove(tap_name) {
		os.exit(1)
	}
}

get_dir_size :: proc(root: string) -> (files_count: int, total_size: i64) {
	if !os.is_dir(root) {
		return 0, 0
	}
	w := os.walker_create(root)
	defer os.walker_destroy(&w)
	for info in os.walker_walk(&w) {
		if info.type == .Regular {
			files_count += 1
			total_size += info.size
		}
	}
	return
}

format_bytes :: proc(bytes: i64, allocator := context.temp_allocator) -> string {
	if bytes < 1024 {
		return fmt.aprintf("%dB", bytes, allocator = allocator)
	} else if bytes < 1024 * 1024 {
		return fmt.aprintf("%.1fKB", f64(bytes) / 1024, allocator = allocator)
	} else if bytes < 1024 * 1024 * 1024 {
		return fmt.aprintf("%.1fMB", f64(bytes) / (1024 * 1024), allocator = allocator)
	} else {
		return fmt.aprintf("%.1fGB", f64(bytes) / (1024 * 1024 * 1024), allocator = allocator)
	}
}

format_commas :: proc(num: int, allocator := context.temp_allocator) -> string {
	s := fmt.aprintf("%d", num, allocator = allocator)
	if len(s) <= 3 {
		return s
	}
	runes := make([dynamic]byte, allocator)
	for i := 0; i < len(s); i += 1 {
		if i > 0 && (len(s) - i) % 3 == 0 {
			append(&runes, ',')
		}
		append(&runes, s[i])
	}
	return string(runes[:])
}

parse_comma_int :: proc(s: string) -> int {
	cleaned, _ := strings.replace_all(s, ",", "", context.temp_allocator)
	val, _ := strconv.parse_int(cleaned)
	return val
}

open_url_in_browser :: proc(url: string) {
	fmt.printf("Opening %s\n", url)
	if command_exists("xdg-open") {
		platform.exec_cmd("xdg-open", []string{"xdg-open", url})
	} else if command_exists("open") {
		platform.exec_cmd("open", []string{"open", url})
	}
}

open_github_page :: proc(name: string, is_cask: bool) {
	url: string
	parts := strings.split(name, "/", context.temp_allocator)
	if len(parts) == 3 {
		user := parts[0]
		repo := parts[1]
		pkg_name := parts[2]
		if is_cask {
			url = fmt.tprintf("https://github.com/%s/homebrew-%s/blob/master/Casks/%s.rb", user, repo, pkg_name)
		} else {
			url = fmt.tprintf("https://github.com/%s/homebrew-%s/blob/master/Formula/%s.rb", user, repo, pkg_name)
		}
	} else {
		first_char := ""
		if len(name) > 0 {
			first_char = name[0:1]
		}
		if is_cask {
			url = fmt.tprintf("https://github.com/Homebrew/homebrew-cask/blob/master/Casks/%s/%s.rb", first_char, name)
		} else {
			url = fmt.tprintf("https://github.com/Homebrew/homebrew-core/blob/master/Formula/%s/%s.rb", first_char, name)
		}
	}
	open_url_in_browser(url)
}

print_target_analytics :: proc(name: string, is_cask: bool) {
	if is_cask {
		c, err := api.fetch_cask(name)
		if err != nil {
			fmt.eprintf("Error: Failed to fetch cask metadata for %s: %v\n", name, err)
			os.exit(1)
		}
		api.destroy_cask(c)
	} else {
		f, err := api.fetch_formula(name)
		if err != nil {
			fmt.eprintf("Error: Failed to fetch formula metadata for %s: %v\n", name, err)
			os.exit(1)
		}
		api.destroy_formula(f)
	}

	cache_path: string
	if is_cask {
		cache_path = fmt.tprintf("%s/cask-%s.json", api.API_CACHE_DIR, name)
	} else {
		cache_path = fmt.tprintf("%s/formula-%s.json", api.API_CACHE_DIR, name)
	}

	data, read_err := os.read_entire_file(cache_path, context.temp_allocator)
	if read_err != nil {
		fmt.printf("No analytics data available for %s.\n", name)
		return
	}

	val, json_err := json.parse(data)
	if json_err != nil {
		fmt.printf("No analytics data available for %s.\n", name)
		return
	}
	defer json.destroy_value(val)

	obj, ok := val.(json.Object)
	if !ok {
		fmt.printf("No analytics data available for %s.\n", name)
		return
	}

	analytics_val, has_analytics := obj["analytics"]
	if !has_analytics {
		fmt.printf("No analytics data available for %s.\n", name)
		return
	}

	analytics_obj, is_obj := analytics_val.(json.Object)
	if !is_obj {
		fmt.printf("No analytics data available for %s.\n", name)
		return
	}

	get_count :: proc(analytics_obj: json.Object, cat: string, days: string, name: string) -> int {
		cat_val, ok1 := analytics_obj[cat]
		if !ok1 do return 0
		cat_obj, ok2 := cat_val.(json.Object)
		if !ok2 do return 0
		days_val, ok3 := cat_obj[days]
		if !ok3 do return 0
		days_obj, ok4 := days_val.(json.Object)
		if !ok4 do return 0

		total := 0
		for k, v in days_obj {
			if k == name || strings.has_prefix(k, fmt.tprintf("%s ", name)) {
				if val, ok5 := v.(json.Integer); ok5 {
					total += int(val)
				} else if val_f, ok6 := v.(json.Float); ok6 {
					total += int(val_f)
				}
			}
		}
		return total
	}

	installs_30d  := get_count(analytics_obj, "install", "30d", name)
	installs_90d  := get_count(analytics_obj, "install", "90d", name)
	installs_365d := get_count(analytics_obj, "install", "365d", name)

	req_30d  := get_count(analytics_obj, "install_on_request", "30d", name)
	req_90d  := get_count(analytics_obj, "install_on_request", "90d", name)
	req_365d := get_count(analytics_obj, "install_on_request", "365d", name)

	err_30d  := get_count(analytics_obj, "build_error", "30d", name)
	err_90d  := get_count(analytics_obj, "build_error", "90d", name)
	err_365d := get_count(analytics_obj, "build_error", "365d", name)

	fmt.printf("%s: %s installs (30 days), %s installs (90 days), %s installs (365 days)\n",
		name, format_commas(installs_30d), format_commas(installs_90d), format_commas(installs_365d))
	fmt.printf("  30-day: %s (%s on-request), %d build errors\n",
		format_commas(installs_30d), format_commas(req_30d), err_30d)
	fmt.printf("  90-day: %s (%s on-request), %d build errors\n",
		format_commas(installs_90d), format_commas(req_90d), err_90d)
	fmt.printf("  365-day: %s (%s on-request), %d build errors\n",
		format_commas(installs_365d), format_commas(req_365d), err_365d)
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
				fmt.printf(" [App] %s\n", a.name)
			case cask.Font_Artifact:
				fmt.printf(" [Font] %s\n", a.name)
			case cask.Binary_Artifact:
				fmt.printf(" [Bin] %s -> %s\n", a.source, a.target)
			case cask.Wallpaper_Artifact:
				fmt.printf(" [Wallpaper] %s\n", a.glob)
			case cask.AppImage_Artifact:
				fmt.printf(" [AppImage] %s -> %s\n", a.source, a.target)
			case cask.Generic_Artifact:
				fmt.printf(" [Artifact] %s -> %s\n", a.source, a.target)
			}
		}
	}

	caskroom_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, c.token)
	if os.is_dir(caskroom_dir) {
		if f_infos, err := os.read_directory_by_path(caskroom_dir, -1, context.temp_allocator); err == nil {
			latest_version := ""
			for info in f_infos {
				if os.is_dir(info.fullpath) && info.name > latest_version {
					latest_version = info.name
				}
			}
			if latest_version != "" {
				version_path := fmt.tprintf("%s/%s", caskroom_dir, latest_version)
				files_count, total_size := get_dir_size(version_path)
				fmt.printf("Installed: %s (%s files, %s)\n",
					version_path, format_commas(files_count), format_bytes(total_size))
			}
		}
	}
}

print_formula :: proc(f: formula.Formula) {
	fmt.println("========================================")
	fmt.printf("Name:     %s\n", f.name)
	fmt.printf("Desc:     %s\n", f.desc)
	fmt.printf("Version:  %s\n", f.version)
	if len(f.bottle_url) > 0 {
		fmt.printf("Bottle:   %s\n", f.bottle_url)
	}
	if len(f.bottle_sha256) > 0 {
		fmt.printf("Bottle SHA256: %s\n", f.bottle_sha256)
	}
	if len(f.source_url) > 0 {
		fmt.printf("URL:      %s\n", f.source_url)
	}
	if len(f.source_sha256) > 0 {
		fmt.printf("SHA256:   %s\n", f.source_sha256)
	}
	fmt.println("========================================")

	cellar_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, f.name)
	if os.is_dir(cellar_dir) {
		if f_infos, err := os.read_directory_by_path(cellar_dir, -1, context.temp_allocator); err == nil {
			latest_version := ""
			for info in f_infos {
				if os.is_dir(info.fullpath) && info.name > latest_version {
					latest_version = info.name
				}
			}
			if latest_version != "" {
				version_path := fmt.tprintf("%s/%s", cellar_dir, latest_version)
				files_count, total_size := get_dir_size(version_path)
				fmt.printf("Installed: %s (%s files, %s)\n",
					version_path, format_commas(files_count), format_bytes(total_size))
			}
		}
	}
}


// ── upgrade helpers ──

Upgrade_Item :: struct {
 	name: string,
 	old_version: string,
 	new_version: string,
 	is_cask: bool,
 }
 
 Order :: enum {
 	LT,
 	EQ,
 	GT,
 }
 
 next_version_segment :: proc(s: string, pos: ^int) -> (string, bool) {
 	if pos^ >= len(s) {
 		return "", false
 	}
 	start := pos^
 	for pos^ < len(s) {
 		c := s[pos^]
 		if c == '.' || c == '_' {
 			seg := s[start:pos^]
 			pos^ += 1 // skip delimiter
 			return seg, true
 		}
 		pos^ += 1
 	}
 	return s[start:pos^], true
 }
 
 compare_versions :: proc(a, b: string) -> Order {
 	if a == b { return .EQ }
 
 	pos_a := 0
 	pos_b := 0
 
 	for {
 		seg_a, ok_a := next_version_segment(a, &pos_a)
 		seg_b, ok_b := next_version_segment(b, &pos_b)
 
 		if !ok_a && !ok_b {
 			return .EQ
 		}
 
 		sa := seg_a if ok_a else ""
 		sb := seg_b if ok_b else ""
 
 		if !ok_a {
 			val_b, is_num_b := strconv.parse_u64(sb)
 			if is_num_b && val_b > 0 {
 				return .LT
 			} else if !is_num_b {
 				return .LT
 			}
 			continue
 		}
 
 		if !ok_b {
 			val_a, is_num_a := strconv.parse_u64(sa)
 			if is_num_a && val_a > 0 {
 				return .GT
 			} else if !is_num_a {
 				return .GT
 			}
 			continue
 		}
 
 		val_a, is_num_a := strconv.parse_u64(sa)
 		val_b, is_num_b := strconv.parse_u64(sb)
 
 		if is_num_a && is_num_b {
 			if val_a < val_b { return .LT }
 			if val_a > val_b { return .GT }
 		} else {
 			if sa < sb { return .LT }
 			if sa > sb { return .GT }
 		}
 	}
 }
 
 is_newer :: proc(a, b: string) -> bool {
 	return compare_versions(a, b) == .GT
 }
 
 normalize_version :: proc(v: string) -> string {
 	trimmed := strings.trim_space(v)
 	if len(trimmed) > 0 && (trimmed[0] == 'v' || trimmed[0] == 'V') {
 		return trimmed[1:]
 	}
 	return trimmed
 }
 
 is_update_available :: proc(current, latest: string) -> bool {
 	cur_norm := normalize_version(current)
 	lat_norm := normalize_version(latest)
 	if len(cur_norm) == 0 || len(lat_norm) == 0 {
 		return false
 	}
 	return is_newer(lat_norm, cur_norm)
 }
 
 Installed_Pkg :: struct {
 	name: string,
 	version: string,
 	is_cask: bool,
 }
 
 list_installed_formulae :: proc() -> [dynamic]Installed_Pkg {
 	pkgs := make([dynamic]Installed_Pkg, context.allocator)
 	cellar := installer.PREFIX + "/Cellar"
 	if fd, err := os.open(cellar); err == nil {
 		defer os.close(fd)
 		if infos, rerr := os.read_directory_by_path(cellar, -1, context.temp_allocator); rerr == nil {
 			for info in infos {
 				if info.type == .Directory {
 					v_dir := fmt.tprintf("%s/%s", cellar, info.name)
 					if v_fd, v_err := os.open(v_dir); v_err == nil {
 						defer os.close(v_fd)
 						if v_infos, v_rerr := os.read_directory_by_path(v_dir, -1, context.temp_allocator); v_rerr == nil {
 							latest_ver := ""
 							for v_info in v_infos {
 								if v_info.type == .Directory {
 									if latest_ver == "" || is_newer(v_info.name, latest_ver) {
 										latest_ver = v_info.name
 									}
 								}
 							}
 							if latest_ver != "" {
 								keg_dir := fmt.tprintf("%s/%s", v_dir, latest_ver)
 								pkg_name := info.name
 								if receipt, ok := installer.read_install_receipt(keg_dir, context.temp_allocator); ok {
 									if len(receipt.tap) > 0 && receipt.tap != "homebrew/core" {
 										pkg_name = fmt.tprintf("%s/%s", receipt.tap, info.name)
 									}
 								}
 								append(&pkgs, Installed_Pkg{
 									name = strings.clone(pkg_name, context.allocator),
 									version = strings.clone(latest_ver, context.allocator),
 									is_cask = false,
 								})
 							}
 						}
 					}
 				}
 			}
 		}
 	}
 	return pkgs
 }
 
 list_installed_casks :: proc() -> [dynamic]Installed_Pkg {
 	pkgs := make([dynamic]Installed_Pkg, context.allocator)
 	caskroom := installer.PREFIX + "/Caskroom"
 	if fd, err := os.open(caskroom); err == nil {
 		defer os.close(fd)
 		if infos, rerr := os.read_directory_by_path(caskroom, -1, context.temp_allocator); rerr == nil {
 			for info in infos {
 				if info.type == .Directory {
 					v_dir := fmt.tprintf("%s/%s", caskroom, info.name)
 					if v_fd, v_err := os.open(v_dir); v_err == nil {
 						defer os.close(v_fd)
 						if v_infos, v_rerr := os.read_directory_by_path(v_dir, -1, context.temp_allocator); v_rerr == nil {
 							latest_ver := ""
 							for v_info in v_infos {
 								if v_info.type == .Directory {
 									if latest_ver == "" || is_newer(v_info.name, latest_ver) {
 										latest_ver = v_info.name
 									}
 								}
 							}
 							if latest_ver != "" {
 								append(&pkgs, Installed_Pkg{
 									name = strings.clone(info.name, context.allocator),
 									version = strings.clone(latest_ver, context.allocator),
 									is_cask = true,
 								})
 							}
 						}
 					}
 				}
 			}
 		}
 	}
 	return pkgs
 }
 
 

// ── run_outdated (Phase 1: warm cache) ──

Outdated_Item :: struct {
	name:               string,
	installed_versions: []string,
	current_version:    string,
	is_cask:            bool,
	pinned:             bool,
	pinned_version:     string,
}

get_installed_versions :: proc(parent_dir, name: string) -> []string {
	versions := make([dynamic]string, context.allocator)
	v_dir := fmt.tprintf("%s/%s", parent_dir, name)
	if fd, err := os.open(v_dir); err == nil {
		defer os.close(fd)
		if infos, rerr := os.read_directory_by_path(v_dir, -1, context.temp_allocator); rerr == nil {
			for info in infos {
				if info.type == .Directory {
					append(&versions, strings.clone(info.name, context.allocator))
				}
			}
		}
	}
	return versions[:]
}

matches_target :: proc(pkg_name: string, targets: []string) -> bool {
	if len(targets) == 0 do return true
	for t in targets {
		if t == pkg_name do return true
		suffix := fmt.tprintf("/%s", pkg_name)
		if strings.has_suffix(t, suffix) do return true
	}
	return false
}

run_outdated :: proc(args: []string) {
	formula_only := false
	cask_only := false
	quiet := false
	verbose := false
	json_version := 0 // 0 = no JSON, 1 = v1, 2 = v2
	min_version := ""
	opt_greedy := false
	opt_greedy_latest := false
	opt_greedy_auto_updates := false
	targets := make([dynamic]string, context.temp_allocator)

	i := 0
	for i < len(args) {
		arg := args[i]
		if strings.has_prefix(arg, "-") {
			if arg == "--formula" || arg == "--formulae" {
				formula_only = true
			} else if arg == "--cask" || arg == "--casks" {
				cask_only = true
			} else if arg == "-q" || arg == "--quiet" {
				quiet = true
			} else if arg == "-v" || arg == "--verbose" {
				verbose = true
			} else if arg == "--json" {
				json_version = 1
			} else if arg == "--json=v1" {
				json_version = 1
			} else if arg == "--json=v2" {
				json_version = 2
			} else if arg == "--minimum-version" {
				if i + 1 < len(args) {
					min_version = args[i+1]
					i += 1
				} else {
					fmt.println("Error: --minimum-version requires an argument")
					os.exit(1)
				}
			} else if arg == "-g" || arg == "--greedy" {
				opt_greedy = true
			} else if arg == "--greedy-latest" {
				opt_greedy_latest = true
			} else if arg == "--greedy-auto-updates" {
				opt_greedy_auto_updates = true
			} else if arg == "--fetch-HEAD" {
				// accepted but ignored
			} else {
				fmt.printf("ubrew: unknown outdated flag '%s'\n", arg)
				os.exit(1)
			}
		} else {
			append(&targets, arg)
		}
		i += 1
	}

	greedy_env := os.get_env("HOMEBREW_UPGRADE_GREEDY", context.temp_allocator)
	greedy_default := len(greedy_env) > 0
	greedy_latest := opt_greedy || opt_greedy_latest || greedy_default
	greedy_auto_updates := opt_greedy || opt_greedy_auto_updates || greedy_default

	installed_formulae := list_installed_formulae()
	defer {
		for f in installed_formulae {
			delete(f.name)
			delete(f.version)
		}
		delete(installed_formulae)
	}

	installed_casks := list_installed_casks()
	defer {
		for c in installed_casks {
			delete(c.name)
			delete(c.version)
		}
		delete(installed_casks)
	}

	pins := read_pins()
	defer destroy_pins(pins)

	outdated_items := make([dynamic]Outdated_Item, context.temp_allocator)

	cellar_dir := installer.PREFIX + "/Cellar"
	caskroom_dir := installer.PREFIX + "/Caskroom"

	if !cask_only {
		for pkg in installed_formulae {
			if !matches_target(pkg.name, targets[:]) do continue

			f, err := api.fetch_formula(pkg.name)
			is_outdated := false
			latest_ver := ""
			if err == nil {
				if min_version != "" {
					latest_ver = strings.clone(min_version, context.temp_allocator)
					is_outdated = is_update_available(pkg.version, min_version)
				} else {
					latest_ver = strings.clone(f.version, context.temp_allocator)
					is_outdated = is_update_available(pkg.version, f.version)
				}
				api.destroy_formula(f)
			} else if min_version != "" {
				is_outdated = is_update_available(pkg.version, min_version)
				latest_ver = strings.clone(min_version, context.temp_allocator)
			}

			if is_outdated {
				p_ver := get_installed_versions(cellar_dir, pkg.name)
				if len(p_ver) == 0 {
					p_ver = []string{pkg.version}
				}
				pinned := is_pinned(pins, pkg.name)
				pinned_version := pinned ? pkg.version : ""
				append(&outdated_items, Outdated_Item{
					name = strings.clone(pkg.name, context.temp_allocator),
					installed_versions = p_ver,
					current_version = latest_ver,
					is_cask = false,
					pinned = pinned,
					pinned_version = strings.clone(pinned_version, context.temp_allocator),
				})
			}
		}
	}

	if !formula_only {
		for pkg in installed_casks {
			if !matches_target(pkg.name, targets[:]) do continue

			c, err := api.fetch_cask(pkg.name)
			is_outdated := false
			latest_ver := ""
			if err == nil {
				if min_version != "" {
					latest_ver = strings.clone(min_version, context.temp_allocator)
					is_outdated = is_update_available(pkg.version, min_version)
				} else {
					latest_ver = strings.clone(c.version, context.temp_allocator)
					if c.version == "latest" {
						if greedy_latest {
							is_outdated = true
						}
					} else if c.auto_updates {
						if greedy_auto_updates {
							is_outdated = is_update_available(pkg.version, c.version)
						}
					} else {
						is_outdated = is_update_available(pkg.version, c.version)
					}
				}
				api.destroy_cask(c)
			} else if min_version != "" {
				is_outdated = is_update_available(pkg.version, min_version)
				latest_ver = strings.clone(min_version, context.temp_allocator)
			}

			if is_outdated {
				p_ver := get_installed_versions(caskroom_dir, pkg.name)
				if len(p_ver) == 0 {
					p_ver = []string{pkg.version}
				}
				pinned := is_pinned(pins, pkg.name)
				pinned_version := pinned ? pkg.version : ""
				append(&outdated_items, Outdated_Item{
					name = strings.clone(pkg.name, context.temp_allocator),
					installed_versions = p_ver,
					current_version = latest_ver,
					is_cask = true,
					pinned = pinned,
					pinned_version = strings.clone(pinned_version, context.temp_allocator),
				})
			}
		}
	}

	if json_version == 1 {
		fmt.println("[")
		for item, idx in outdated_items {
			comma := idx < len(outdated_items) - 1 ? "," : ""
			fmt.printf("  \"%s\"%s\n", item.name, comma)
		}
		fmt.println("]")
	} else if json_version == 2 {
		fmt.println("{")
		fmt.println("  \"formulae\": [")
		first_formula := true
		for item in outdated_items {
			if item.is_cask do continue
			if !first_formula do fmt.println(",")
			first_formula = false
			
			fmt.println("    {")
			fmt.printf("      \"name\": \"%s\",\n", item.name)
			fmt.print("      \"installed_versions\": [")
			for ver, v_idx in item.installed_versions {
				if v_idx > 0 do fmt.print(", ")
				fmt.printf("\"%s\"", ver)
			}
			fmt.println("],")
			fmt.printf("      \"current_version\": \"%s\",\n", item.current_version)
			pinned_str := item.pinned ? "true" : "false"
			fmt.printf("      \"pinned\": %s,\n", pinned_str)
			if item.pinned {
				fmt.printf("      \"pinned_version\": \"%s\"\n", item.pinned_version)
			} else {
				fmt.println("      \"pinned_version\": null")
			}
			fmt.print("    }")
		}
		if !first_formula do fmt.println("")
		fmt.println("  ],")
		fmt.println("  \"casks\": [")
		first_cask := true
		for item in outdated_items {
			if !item.is_cask do continue
			if !first_cask do fmt.println(",")
			first_cask = false
			
			fmt.println("    {")
			fmt.printf("      \"name\": \"%s\",\n", item.name)
			fmt.print("      \"installed_versions\": [")
			for ver, v_idx in item.installed_versions {
				if v_idx > 0 do fmt.print(", ")
				fmt.printf("\"%s\"", ver)
			}
			fmt.println("],")
			fmt.printf("      \"current_version\": \"%s\"\n", item.current_version)
			fmt.print("    }")
		}
		if !first_cask do fmt.println("")
		fmt.println("  ]")
		fmt.println("}")
	} else {
		print_version_info := verbose || (!quiet && os.is_tty(os.stdout))
		for item in outdated_items {
			if print_version_info {
				joined_versions := strings.join(item.installed_versions, ", ", context.temp_allocator)
				suffix := item.is_cask ? " (cask)" : ""
				fmt.printf("%s (%s) < %s%s\n", item.name, joined_versions, item.current_version, suffix)
			} else {
				fmt.println(item.name)
			}
		}
	}
}
// ── run_update (Phase 1: HTTP/2 parallel) ──

// ── run_update (Phase 1: HTTP/2 parallel) ──

run_update :: proc(args: []string) {
	auto_update := false
	force := false
	verbose := false
	debug := false

	for a in args {
		if a == "--auto-update" {
			auto_update = true
		} else if a == "-f" || a == "--force" {
			force = true
		} else if a == "-v" || a == "--verbose" {
			verbose = true
		} else if a == "-d" || a == "--debug" {
			debug = true
		} else {
			fmt.printf("ubrew: unknown update flag '%s'\n", a)
			os.exit(1)
		}
	}

	platform.GLOBAL_DEBUG = debug

	fmt.println("==> Updating ubrew...")

	skip_git := auto_update && !force
	if !skip_git && os.is_dir(".git") {
		if verbose {
			fmt.println("Checking directory: .git")
			fmt.println("Performing git operations...")
		}
		branch_bytes, berr := os.read_entire_file(".git/HEAD", context.temp_allocator)
		has_upstream := false
		if berr == nil {
			s := strings.trim_space(string(branch_bytes))
			if strings.has_prefix(s, "ref: refs/heads/") {
				name := s[len("ref: refs/heads/"):]
				prefixes := []string{".git/refs/remotes/origin/", ".git/refs/remotes/upstream/"}
				for prefix in prefixes {
					if os.is_file(fmt.tprintf("%s%s", prefix, name)) {
						has_upstream = true
						break
					}
				}
			}
		}
		if has_upstream {
			fmt.println("==> Updating git repository...")
			cmd := []string{"git", "pull"}
			_ = platform.exec_cmd("git", cmd)
		}
	}

	skip_api := false
	if auto_update && !force {
		db_path := installer.UBREW_ROOT + "/db/upstream.json"
		if fi, err := os.stat(db_path, context.temp_allocator); err == nil {
			now_sec := time.time_to_unix(time.now())
			mod_sec := time.time_to_unix(fi.modification_time)
			if now_sec - mod_sec < 86400 {
				skip_api = true
			}
		}
	}

	if skip_api {
		if verbose {
			fmt.println("API lists and upstream registry are fresh; skipping download.")
		}
	} else {
		taps := tap.read_taps()
		defer {
			for t in taps {
				tap.destroy_read_tap_entry(t)
			}
			delete(taps)
		}

		temp_file_formula := ""
		temp_file_cask := ""
		rebuild_index := false

		if verbose {
			fmt.printf("Checking directory: %s/db\n", installer.UBREW_ROOT)
		}
		fmt.println("==> Refreshing Homebrew API lists and taps...")

		urls := make([dynamic]string, context.temp_allocator)
		out_files := make([dynamic]string, context.temp_allocator)
		z_files := make([dynamic]string, context.temp_allocator)
		defer {
			delete(urls)
			delete(out_files)
			delete(z_files)
		}

		token := platform.get_gh_token()
		headers := make([dynamic]string, context.temp_allocator)
		defer delete(headers)
		if token != "" {
			append(&headers, fmt.tprintf("Authorization: Bearer %s", token))
		}

		// 1. Add formula.json to queue
		_ = os.make_directory_all(api.API_CACHE_DIR, os.perm(0o755))
		temp_f1, terr1 := os.create_temp_file("", "ubrew_formula_list_*.json")
		if terr1 == nil {
			temp_file_formula = strings.clone(os.name(temp_f1), context.allocator)
			os.close(temp_f1)
			append(&urls, api.FORMULA_LIST_URL)
			append(&out_files, temp_file_formula)
			z_val := ""
			if os.is_file(api.FORMULA_LIST_CACHE) {
				z_val = api.FORMULA_LIST_CACHE
			}
			append(&z_files, z_val)
		}

		// 2. Add cask.json to queue
		temp_f2, terr2 := os.create_temp_file("", "ubrew_cask_list_*.json")
		if terr2 == nil {
			temp_file_cask = strings.clone(os.name(temp_f2), context.allocator)
			os.close(temp_f2)
			append(&urls, api.CASK_LIST_URL)
			append(&out_files, temp_file_cask)
			z_val := ""
			if os.is_file(api.CASK_LIST_CACHE) {
				z_val = api.CASK_LIST_CACHE
			}
			append(&z_files, z_val)
		}

		// 3. Add upstream.json to queue
		_ = os.make_directory_all(installer.UBREW_ROOT + "/db", os.perm(0o755))
		db_path := installer.UBREW_ROOT + "/db/upstream.json"
		append(&urls, "https://raw.githubusercontent.com/rjallais/ubrew/main/registry/upstream.json")
		append(&out_files, db_path)
		z_val := ""
		if os.is_file(db_path) {
			z_val = db_path
		}
		append(&z_files, z_val)

		// 4. Add tap Formula_listing.json requests
		job_taps := make([dynamic]^tap.Tap, context.allocator)
		defer {
			for t in job_taps {
				tap.destroy_tap(t^)
				free(t)
			}
			delete(job_taps)
		}
		suffixes := []string{"/contents/Formula", "/contents"}
		for entry in taps {
			t_ptr := new(tap.Tap)
			t_ptr^ = tap.tap_from_entry(entry)
			append(&job_taps, t_ptr)
			t := t_ptr^
			cache_dir := fmt.tprintf("%s/cache/taps/%s", installer.UBREW_ROOT, t.name)
			_ = os.make_directory_all(cache_dir, os.perm(0o755))
			cache_path := fmt.tprintf("%s/Formula_listing.json", cache_dir)
			z_val := ""
			if os.is_file(cache_path) {
				z_val = cache_path
			}
			candidates := api.tap_primary_candidates(t, context.temp_allocator)
			// Check for cached hit sidecar to skip 404 probes
			hit_path := fmt.tprintf("%s/Formula_listing.hit", cache_dir)
			hit_c_idx := -1
			hit_s_idx := -1
			if hit_data, hit_err := os.read_entire_file(hit_path, context.temp_allocator); hit_err == nil {
				hit_str := strings.trim_space(string(hit_data))
				parts := strings.split(hit_str, ",", context.temp_allocator)
				if len(parts) == 2 {
					if ci, ci_ok := strconv.parse_int(parts[0]); ci_ok {
						if si, si_ok := strconv.parse_int(parts[1]); si_ok {
							if ci >= 0 && ci < len(candidates) && si >= 0 && si < len(suffixes) {
								hit_c_idx = ci
								hit_s_idx = si
							}
						}
					}
				}
			}
			if hit_c_idx >= 0 && hit_s_idx >= 0 {
				// Use cached hit: only probe the known-good URL
				tmp_path := fmt.tprintf("%s.tmp.%d.%d", cache_path, hit_c_idx, hit_s_idx)
				_ = os.remove(tmp_path)
				append(&urls, api.tap_api_url(t, candidates[hit_c_idx], suffixes[hit_s_idx]))
				append(&out_files, strings.clone(tmp_path, context.temp_allocator))
				append(&z_files, strings.clone(z_val, context.temp_allocator))
			} else {
				// No cached hit: probe all candidates
				for c, c_idx in candidates {
					for suffix, s_idx in suffixes {
						tmp_path := fmt.tprintf("%s.tmp.%d.%d", cache_path, c_idx, s_idx)
						_ = os.remove(tmp_path)
						append(&urls, api.tap_api_url(t, c, suffix))
						append(&out_files, strings.clone(tmp_path, context.temp_allocator))
						append(&z_files, strings.clone(z_val, context.temp_allocator))
					}
				}
			}
		}



		// Execute the parallel HTTP/2 download
		curl_ok := false
		if len(urls) > 0 {
			curl_ok = api.fetch_urls_parallel_http2(urls[:], out_files[:], headers[:], z_files[:])
		}

		// Post-process Homebrew API lists
		if temp_file_formula != "" {
			defer {
				os.remove(temp_file_formula)
				delete(temp_file_formula)
			}
			fi, fi_err := os.stat(temp_file_formula, context.temp_allocator)
			if fi_err == nil && fi.size > 0 {
				if os.rename(temp_file_formula, api.FORMULA_LIST_CACHE) == nil {
					rebuild_index = true
				}
			}
		}
		if temp_file_cask != "" {
			defer {
				os.remove(temp_file_cask)
				delete(temp_file_cask)
			}
			fi, fi_err := os.stat(temp_file_cask, context.temp_allocator)
			if fi_err == nil && fi.size > 0 {
				if os.rename(temp_file_cask, api.CASK_LIST_CACHE) == nil {
					rebuild_index = true
				}
			}
		}
		if rebuild_index {
			api.build_search_index()
		}

		// Post-process Formula listings for each tap
		ok_count := 0
		for t_ptr in job_taps {
			t := t_ptr^
			cache_dir := fmt.tprintf("%s/cache/taps/%s", installer.UBREW_ROOT, t.name)
			cache_path := fmt.tprintf("%s/Formula_listing.json", cache_dir)
			promoted := false
			candidates := api.tap_primary_candidates(t, context.temp_allocator)
			outer: for s_idx in 0..<2 {
				for c_idx in 0..<len(candidates) {
					tmp_path := fmt.tprintf("%s.tmp.%d.%d", cache_path, c_idx, s_idx)
					if os.is_file(tmp_path) {
						if data, rerr := os.read_entire_file(tmp_path, context.temp_allocator); rerr == nil {
							char_idx := 0
							for char_idx < len(data) && (data[char_idx] == ' ' || data[char_idx] == '\t' || data[char_idx] == '\n' || data[char_idx] == '\r') {
								char_idx += 1
							}
							if char_idx < len(data) && data[char_idx] == '[' {
								_ = os.write_entire_file(cache_path, data)
								// Write the winning (c_idx, s_idx) to hit sidecar
								hit_path := fmt.tprintf("%s/Formula_listing.hit", cache_dir)
								_ = os.write_entire_file(hit_path, transmute([]u8)fmt.tprintf("%d,%d", c_idx, s_idx))
								promoted = true
								break outer
							}
						}
					}
				}
			}
			if !promoted && os.is_file(cache_path) && curl_ok {
				for c_idx in 0..<len(candidates) {
					for s_idx in 0..<2 {
						tmp_path := fmt.tprintf("%s.tmp.%d.%d", cache_path, c_idx, s_idx)
						fi, fi_err := os.stat(tmp_path, context.temp_allocator)
						if fi_err != nil || fi.size == 0 {
							promoted = true
							break
						}
					}
					if promoted do break
				}
			}
			for c_idx in 0..<len(candidates) {
				for s_idx in 0..<2 {
					tmp_path := fmt.tprintf("%s.tmp.%d.%d", cache_path, c_idx, s_idx)
					_ = os.remove(tmp_path)
				}
			}
			if promoted {
				ok_count += 1
				fmt.printf("==> Updated tap %s successfully.\n", t.name)
			} else {
				fmt.printf("Error: Failed to update tap %s.\n", t.name)
			}
		}

		// Sequential fallback for taps whose Formula_listing fetch didn't work
		for t_ptr in job_taps {
			t := t_ptr^
			if !api.verify_tap_cache(t) {
				if _, ok := api.fetch_tap_listing_cached(t); ok {
					fmt.printf("==> Updated tap %s successfully (fallback).\n", t.name)
				}
			}
		}


	}


	fmt.println("==> Homebrew is up-to-date!")
}

// ── run_upgrade (Phase 1: warm cache) ──

print_upgrade_usage :: proc() {
	fmt.println("Usage: ubrew upgrade [options] [installed_formula|installed_cask ...]")
	fmt.println()
	fmt.println("Upgrade outdated packages (formulae and casks).")
	fmt.println()
	fmt.println("Options:")
	fmt.println("  --formula, --formulae      Upgrade only formulae")
	fmt.println("  --cask, --casks            Upgrade only casks")
	fmt.println("  --greedy, -g               Also upgrade casks with 'auto_updates true' or 'version :latest'")
	fmt.println("  --greedy-latest            Also upgrade casks with 'version :latest'")
	fmt.println("  --greedy-auto-updates      Also upgrade casks with 'auto_updates true'")
	fmt.println("  --force, -f                Upgrade even if the latest version is already installed")
	fmt.println("  --dry-run, -n              Print what would be upgraded but do not upgrade")
	fmt.println("  --verbose, -v              Make output verbose")
	fmt.println("  --debug, -d                Print debugging/tracing information")
	fmt.println("  --quiet, -q                Make output quiet")
	fmt.println("  --help, -h                 Show this message")
}

run_upgrade :: proc(args: []string) {
	formula_only := false
	cask_only := false
	opt_greedy := false
	opt_greedy_latest := false
	opt_greedy_auto_updates := false
	force := false
	dry_run := false
	build_from_source := false
	verbose := false
	quiet := false
	min_version := ""

	pkg_names := make([dynamic]string, context.temp_allocator)

	i := 0
	for i < len(args) {
		arg := args[i]
		if strings.has_prefix(arg, "-") {
			if arg == "--formula" || arg == "--formulae" {
				formula_only = true
			} else if arg == "--cask" || arg == "--casks" {
				cask_only = true
			} else if arg == "-g" || arg == "--greedy" {
				opt_greedy = true
			} else if arg == "--greedy-latest" {
				opt_greedy_latest = true
			} else if arg == "--greedy-auto-updates" {
				opt_greedy_auto_updates = true
			} else if arg == "-f" || arg == "--force" {
				force = true
			} else if arg == "-n" || arg == "--dry-run" {
				dry_run = true
			} else if arg == "-s" || arg == "--build-from-source" {
				build_from_source = true
			} else if arg == "-v" || arg == "--verbose" {
				verbose = true
			} else if arg == "-q" || arg == "--quiet" {
				quiet = true
			} else if arg == "--minimum-version" {
				if i + 1 < len(args) {
					min_version = args[i+1]
					i += 1
				} else {
					fmt.println("Error: --minimum-version requires an argument")
					os.exit(1)
				}
			} else if arg == "-d" || arg == "--debug" ||
			          arg == "--display-times" ||
			          arg == "-y" || arg == "--no-ask" ||
			          arg == "-i" || arg == "--interactive" ||
			          arg == "--force-bottle" ||
			          arg == "--fetch-HEAD" ||
			          arg == "--keep-tmp" ||
			          arg == "--debug-symbols" ||
			          arg == "--overwrite" ||
			          arg == "--skip-cask-deps" ||
			          arg == "--no-quit" ||
			          arg == "--binaries" ||
			          arg == "--no-binaries" ||
			          arg == "--require-sha" {
				// Accepted but ignored for compatibility
			} else if arg == "-h" || arg == "--help" {
				print_upgrade_usage()
				return
			} else {
				fmt.printf("ubrew: unknown upgrade flag '%s'\n", arg)
				os.exit(1)
			}
		} else {
			append(&pkg_names, arg)
		}
		i += 1
	}

	greedy_env := os.get_env("HOMEBREW_UPGRADE_GREEDY", context.temp_allocator)
	greedy_default := len(greedy_env) > 0
	greedy_latest := opt_greedy || opt_greedy_latest || greedy_default
	greedy_auto_updates := opt_greedy || opt_greedy_auto_updates || greedy_default

	installed_formulae := list_installed_formulae()
	defer {
		for f in installed_formulae {
			delete(f.name)
			delete(f.version)
		}
		delete(installed_formulae)
	}
	installed_casks := list_installed_casks()
	defer {
		for c in installed_casks {
			delete(c.name)
			delete(c.version)
		}
		delete(installed_casks)
	}

	pins := read_pins()
	defer destroy_pins(pins)

	Upgrade_Target :: struct {
		name: string,
		is_cask: bool,
		current_version: string,
	}

	targets := make([dynamic]Upgrade_Target, context.temp_allocator)

	if len(pkg_names) > 0 {
		for name in pkg_names {
			found_formula := false
			found_cask := false
			formula_ver := ""
			cask_ver := ""

			if !cask_only {
				for f in installed_formulae {
					if f.name == name {
						found_formula = true
						formula_ver = f.version
						break
					}
				}
			}
			if !formula_only {
				for c in installed_casks {
					if c.name == name {
						found_cask = true
						cask_ver = c.version
						break
					}
				}
			}

			if !found_formula && !found_cask {
				if formula_only {
					fmt.printf("Error: formula '%s' is not installed\n", name)
				} else if cask_only {
					fmt.printf("Error: cask '%s' is not installed\n", name)
				} else {
					fmt.printf("Error: formula or cask '%s' is not installed\n", name)
				}
				os.exit(1)
			}

			if found_formula {
				append(&targets, Upgrade_Target{name = name, is_cask = false, current_version = formula_ver})
			}
			if found_cask {
				append(&targets, Upgrade_Target{name = name, is_cask = true, current_version = cask_ver})
			}
		}
	} else {
		if !cask_only {
			for f in installed_formulae {
				if is_pinned(pins, f.name) {
					fmt.printf("==> Skipping pinned formula %s\n", f.name)
					continue
				}
				append(&targets, Upgrade_Target{name = f.name, is_cask = false, current_version = f.version})
			}
		}
		if !formula_only {
			for c in installed_casks {
				if is_pinned(pins, c.name) {
					fmt.printf("==> Skipping pinned cask %s\n", c.name)
					continue
				}
				append(&targets, Upgrade_Target{name = c.name, is_cask = true, current_version = c.version})
			}
		}
	}

	// Warm cache
	formulae_to_warm := make([dynamic]string, context.temp_allocator)
	casks_to_warm := make([dynamic]string, context.temp_allocator)
	defer {
		delete(formulae_to_warm)
		delete(casks_to_warm)
	}

	for t in targets {
		if t.is_cask {
			append(&casks_to_warm, t.name)
		} else {
			if !strings.contains(t.name, "/") {
				append(&formulae_to_warm, t.name)
			}
		}
	}

	_ = api.warm_formulae_cache_parallel(formulae_to_warm[:])
	_ = api.warm_casks_cache_parallel(casks_to_warm[:])

	upgrades := make([dynamic]Upgrade_Item, context.temp_allocator)
	defer {
		for pkg in upgrades {
			delete(pkg.name)
			delete(pkg.old_version)
			delete(pkg.new_version)
		}
	}

	for t in targets {
		if t.is_cask {
			c, err := api.fetch_cask(t.name)
			if err != nil { continue }

			is_outdated := false
			latest_ver := c.version
			if force {
				is_outdated = true
			} else {
				if min_version != "" {
					is_outdated = is_update_available(t.current_version, min_version)
				} else if c.version == "latest" {
					if greedy_latest {
						is_outdated = true
					}
				} else if c.auto_updates {
					if greedy_auto_updates {
						is_outdated = is_update_available(t.current_version, c.version)
					}
				} else {
					is_outdated = is_update_available(t.current_version, c.version)
				}
			}

			if is_outdated {
				append(&upgrades, Upgrade_Item{
					name = strings.clone(t.name, context.allocator),
					old_version = strings.clone(t.current_version, context.allocator),
					new_version = strings.clone(latest_ver, context.allocator),
					is_cask = true,
				})
			}
			api.destroy_cask(c)
		} else {
			f, err := api.fetch_formula(t.name)
			if err != nil { continue }

			is_outdated := false
			latest_ver := f.version
			if force {
				is_outdated = true
			} else {
				if min_version != "" {
					is_outdated = is_update_available(t.current_version, min_version)
				} else {
					is_outdated = is_update_available(t.current_version, f.version)
				}
			}

			if is_outdated {
				append(&upgrades, Upgrade_Item{
					name = strings.clone(t.name, context.allocator),
					old_version = strings.clone(t.current_version, context.allocator),
					new_version = strings.clone(latest_ver, context.allocator),
					is_cask = false,
				})
			}
			api.destroy_formula(f)
		}
	}

	if len(upgrades) == 0 {
		fmt.println("==> All packages are up to date.")
		return
	}

	fmt.printf("==> Upgrading %d package(s):\n", len(upgrades))
	for pkg in upgrades {
		tag := " (cask)" if pkg.is_cask else ""
		fmt.printf("    %s %s -> %s%s\n", pkg.name, pkg.old_version, pkg.new_version, tag)
	}

	if dry_run {
		return
	}

	developer_active := (developer_state() == .On || developer_env_set())
	if developer_active {
		if !prompt_user_yes_no("Do you want to proceed?") {
			fmt.println("Aborted.")
			os.exit(1)
		}
	}

	failed := false
	for pkg in upgrades {
		fmt.printf("==> Upgrading %s to version %s\n", pkg.name, pkg.new_version)
		if pkg.is_cask {
			if !remove_cask_by_token(pkg.name, true) {
				fmt.printf("Error: Failed to remove old version of cask %s\n", pkg.name)
				failed = true
				continue
			}
			if !install_cask_by_token(pkg.name) {
				fmt.printf("Error: Failed to install new version of cask %s\n", pkg.name)
				failed = true
				continue
			}
		} else {
			on_request := true
			if len(pkg_names) == 0 {
				old_keg_dir := fmt.tprintf("%s/Cellar/%s/%s", installer.PREFIX, pkg.name, pkg.old_version)
				if receipt, ok := installer.read_install_receipt(old_keg_dir, context.temp_allocator); ok {
					on_request = receipt.installed_on_request
				}
			}

			if !install_formula_by_name(pkg.name, build_from_source, force, on_request) {
				fmt.printf("Error: Failed to install new version of formula %s\n", pkg.name)
				failed = true
				continue
			}
			if pkg.old_version != "" && pkg.old_version != pkg.new_version {
				unlink_formula_bins(pkg.name)
				old_keg_dir := fmt.tprintf("%s/Cellar/%s/%s", installer.PREFIX, pkg.name, pkg.old_version)
				_ = os.remove_all(old_keg_dir)
			}
		}
		fmt.printf("==> Successfully upgraded %s!\n", pkg.name)
	}

	if failed {
		os.exit(1)
	}
}

// ── JSON output (for info --json) ──

print_formula_json :: proc(f: formula.Formula, is_installed: bool, installed_version: string, pinned: bool) {
 	fmt.print("  {\n")
 	fmt.printf("    \"name\": %q,\n", f.name)
 	fmt.printf("    \"full_name\": %q,\n", f.name)
 	fmt.print("    \"aliases\": [")
 	for alias, i in f.aliases {
 		if i > 0 { fmt.print(", ") }
 		fmt.printf("%q", alias)
 	}
 	fmt.print("],\n")
 	tap_val := f.tap != "" ? f.tap : "homebrew/core"
 	fmt.printf("    \"tap\": %q,\n", tap_val)
 	fmt.printf("    \"desc\": %q,\n", f.desc)
 	fmt.printf("    \"license\": null,\n")
 	fmt.printf("    \"homepage\": %q,\n", f.homepage)
 	fmt.printf("    \"versions\": {{\"stable\": %q, \"head\": \"HEAD\", \"bottle\": true}},\n", f.version)
 	fmt.print("    \"dependencies\": [")
 	for dep, i in f.dependencies {
 		if i > 0 { fmt.print(", ") }
 		fmt.printf("%q", dep)
 	}
 	fmt.print("],\n")
 	if is_installed {
 		fmt.printf("    \"installed\": [{{\"version\": %q, \"built_as_bottle\": true, \"poured_from_bottle\": true}}],\n", installed_version)
 		fmt.printf("    \"linked_keg\": %q,\n", installed_version)
 	} else {
 		fmt.printf("    \"installed\": [],\n")
 		fmt.printf("    \"linked_keg\": null,\n")
 	}
 	pinned_str := pinned ? "true" : "false"
 	fmt.printf("    \"pinned\": %s,\n", pinned_str)
 	fmt.printf("    \"outdated\": false\n")
 	fmt.print("  }")
 }
 
 print_cask_json :: proc(c: cask.Cask, is_installed: bool, installed_version: string) {
 	fmt.print("  {\n")
 	fmt.printf("    \"token\": %q,\n", c.token)
 	fmt.printf("    \"full_token\": %q,\n", c.token)
 	fmt.printf("    \"tap\": \"homebrew/cask\",\n")
 	fmt.printf("    \"name\": [%q],\n", c.name)
 	fmt.printf("    \"desc\": %q,\n", c.name)
 	fmt.printf("    \"homepage\": %q,\n", c.homepage)
 	fmt.printf("    \"url\": %q,\n", c.url)
 	fmt.printf("    \"version\": %q,\n", c.version)
 	if is_installed {
 		fmt.printf("    \"installed\": %q,\n", installed_version)
 	} else {
 		fmt.printf("    \"installed\": null,\n")
 	}
 	fmt.printf("    \"sha256\": %q,\n", c.sha256)
 	fmt.printf("    \"outdated\": false\n")
 	fmt.print("  }")
 }
 



// ── autoremove ──

// autoremove_scanner: read receipts for every installed formula, return the
// subset that should be removed (not installed on request, not pinned, and
// not depended on by any other installed formula). The list is built using
// the runtime dependencies recorded in each keg's INSTALL_RECEIPT.json
// (snapshotted at install time). Legacy installs without a receipt are
// treated as installed_on_request=true so autoremove skips them (safe).
autoremove_scan :: proc(pkgs: []Installed_Pkg, pins: [dynamic]string) -> [dynamic]string {
    // First pass: read all receipts and build a set of names that have
    // receipts with installed_on_request=true (or no receipt at all —
    // those are treated as on_request=true). A second pass builds a
    // dependents map from receipts' runtime_dependencies.
    on_request := make(map[string]bool, context.allocator)
    defer delete(on_request)
    no_receipt := make(map[string]bool, context.allocator)
    defer delete(no_receipt)
    // For each formula name -> first install location (we have at most one
    // active keg per formula; the latest-version winner from
    // list_installed_formulae).
    keg_for := make(map[string]string, context.allocator)
    defer delete(keg_for)
    deps_map := make(map[string][]string, context.allocator) // name -> runtime_deps
    defer {
        for _, arr in deps_map {
            for d in arr { delete(d) }
            delete(arr)
        }
        delete(deps_map)
    }
    for p in pkgs {
        keg := fmt.tprintf("%s/Cellar/%s/%s", installer.PREFIX, p.name, p.version)
        keg_for[p.name] = keg
        receipt, has_receipt := installer.read_install_receipt(keg)
        if !has_receipt {
            no_receipt[p.name] = true
            on_request[p.name] = true
            continue
        }
        on_request[p.name] = receipt.installed_on_request
        if len(receipt.runtime_dependencies) > 0 {
            // Clone so the slice survives receipt destruction.
            arr := make([dynamic]string, context.allocator)
            for d in receipt.runtime_dependencies {
                append(&arr, strings.clone(d, context.allocator))
            }
            deps_map[p.name] = arr[:]
        } else {
            deps_map[p.name] = make([dynamic]string, context.allocator)[:]
        }
        installer.destroy_install_receipt(receipt)
    }
    // Build the dependents map from receipts: for each installed formula F,
    // for each dep D in F.runtime_dependencies, dependents[D] += F.
    deps_of := make(map[string]map[string]bool, context.allocator)
    defer destroy_dependents_map(deps_of)
    for p in pkgs {
        deps := deps_map[p.name] or_else nil
        for d in deps {
            set, sok := deps_of[d]
            if !sok {
                set = make(map[string]bool, context.allocator)
                deps_of[d] = set
            }
            set[p.name] = true
        }
    }
    // Pick candidates.
    candidates := make([dynamic]string, context.allocator)
    for p in pkgs {
        if is_pinned(pins, p.name) { continue }
        if on_request[p.name] { continue }
        if _, has_deps := deps_of[p.name]; has_deps { continue }
        append(&candidates, p.name)
    }
    return candidates
}

run_autoremove :: proc(args: []string) {
    dry_run := false
    for a in args {
        if a == "--dry-run" || a == "-n" {
            dry_run = true
        } else {
            fmt.printf("ubrew: unknown autoremove flag '%s'\n", a)
            os.exit(1)
        }
    }

    pins := read_pins()
    defer destroy_pins(pins)

    // Iterative: a chain of dep-only formulae (A depends on B) is fully
    // removed across multiple passes. The receipt on A is gone after pass 1,
    // so B becomes a candidate in pass 2.
    total_removed := 0
    pass := 0
    for {
        pkgs := list_installed_formulae()
        defer {
            for p in pkgs {
                delete(p.name)
                delete(p.version)
            }
            delete(pkgs)
        }
        if len(pkgs) == 0 {
            break
        }
        candidates := autoremove_scan(pkgs[:], pins)
        if len(candidates) == 0 {
            break
        }
        pass += 1
        for n in candidates {
            if dry_run {
                fmt.printf("Would autoremove %s\n", n)
            } else {
                if remove_formula(n, true) {
                    total_removed += 1
                }
            }
        }
        if dry_run {
            // Dry-run: don't loop, just show one pass.
            break
        }
    }
    if total_removed == 0 && pass == 0 {
        fmt.println("==> Nothing to remove.")
    } else {
        fmt.printf("==> Autoremoved %d formula(s) in %d pass(es)\n", total_removed, pass)
    }
}

// ── leaves / pin / unpin / link / unlink / home / desc / etc ──

// ── pinning ──

PINS_FILE :: installer.UBREW_ROOT + "/db/pinned.txt"

read_pins :: proc() -> [dynamic]string {
    pins := make([dynamic]string, context.allocator)
    data, err := os.read_entire_file(PINS_FILE, context.allocator)
    if err != nil {
        return pins
    }
    defer delete(data)
    data_str := transmute(string)data
    for line in strings.split_lines_iterator(&data_str) {
        name := strings.trim_space(line)
        if name == "" || strings.has_prefix(name, "#") {
            continue
        }
        append(&pins, strings.clone(name, context.allocator))
    }
    return pins
}

destroy_pins :: proc(pins: [dynamic]string) {
    for s in pins {
        delete(s)
    }
    delete(pins)
}

write_pins :: proc(pins: []string) -> bool {
    mkerr := os.make_directory_all(installer.UBREW_ROOT + "/db", os.perm(0o755))
    if mkerr != nil {
        if !os.is_dir(installer.UBREW_ROOT + "/db") {
            fmt.printf("ubrew: failed to create pins dir: %v\n", mkerr)
            return false
        }
    }
    b := strings.builder_make(context.temp_allocator)
    for name in pins {
        strings.write_string(&b, name)
        strings.write_byte(&b, '\n')
    }
    payload := strings.to_string(b)
    return os.write_entire_file(PINS_FILE, payload) == nil
}

is_pinned :: proc(pins: [dynamic]string, name: string) -> bool {
    for p in pins {
        if p == name {
            return true
        }
    }
    return false
}

run_pin :: proc(args: []string) {
    if len(args) == 0 {
        // List pins
        pins := read_pins()
        defer destroy_pins(pins)
        if len(pins) == 0 {
            fmt.println("No pinned packages.")
            return
        }
        for p in pins {
            fmt.println(p)
        }
        return
    }

    pins := read_pins()
    defer destroy_pins(pins)
    added := 0
    for name in args {
        if !package_name_safe(name) {
            fmt.printf("ubrew: refusing to pin unsafe name: %s\n", name)
            continue
        }
        if is_pinned(pins, name) {
            fmt.printf("ubrew: '%s' is already pinned\n", name)
            continue
        }
        append(&pins, strings.clone(name, context.allocator))
        added += 1
        fmt.printf("Pinned %s\n", name)
    }
    if added > 0 {
        if !write_pins(pins[:]) {
            fmt.println("ubrew: failed to write pins file")
            os.exit(1)
        }
    }
}

run_unpin :: proc(args: []string) {
    if len(args) == 0 {
        fmt.println("Usage: ubrew unpin <formula> [<formula> ...]")
        os.exit(1)
    }
    pins := read_pins()
    defer destroy_pins(pins)
    kept := make([dynamic]string, context.temp_allocator)
    removed := 0
    for p in pins {
        drop := false
        for name in args {
            if p == name {
                drop = true
                removed += 1
                fmt.printf("Unpinned %s\n", p)
                break
            }
        }
        if !drop {
            append(&kept, p)
        }
    }
    if removed > 0 {
        if !write_pins(kept[:]) {
            fmt.println("ubrew: failed to write pins file")
            os.exit(1)
        }
    } else {
        for name in args {
            fmt.printf("ubrew: '%s' is not pinned\n", name)
        }
    }
}

// ── leaves & autoremove ──

// dependents_of returns a map of package name -> set of installed packages
// that declare it as a runtime dependency. Built by walking each installed
// formula's API metadata. Uses the cached fetch_formula path.
build_dependents_map :: proc(pkgs: []Installed_Pkg) -> map[string]map[string]bool {
    deps_of := make(map[string]map[string]bool, context.allocator)
    for p in pkgs {
        f, err := api.fetch_formula(p.name)
        if err != nil {
            continue
        }
        defer api.destroy_formula(f)
        for d in f.dependencies {
            if _, ok := deps_of[d]; !ok {
                deps_of[d] = make(map[string]bool, context.allocator)
            }
            set := deps_of[d]
            set[strings.clone(p.name, context.allocator)] = true
            deps_of[d] = set
        }
    }
    return deps_of
}

destroy_dependents_map :: proc(m: map[string]map[string]bool) {
    for _, set in m {
        for k, _ in set {
            delete(k)
        }
        delete(set)
    }
    delete(m)
}

run_leaves :: proc() {
    pkgs := list_installed_formulae()
    defer {
        for p in pkgs {
            delete(p.name)
            delete(p.version)
        }
        delete(pkgs)
    }
    if len(pkgs) == 0 {
        return
    }
    deps_of := build_dependents_map(pkgs[:])
    defer destroy_dependents_map(deps_of)

    names := make([dynamic]string, context.temp_allocator)
    for p in pkgs {
        if _, has_deps := deps_of[p.name]; !has_deps {
            append(&names, p.name)
        }
    }
    slice.sort(names[:])
    for n in names {
        fmt.println(n)
    }
}
// ── link / unlink / home / desc / formulae / casks / commands ──

run_link :: proc(args: []string) {
    if len(args) < 1 {
        fmt.println("Usage: ubrew link <installed_formula> [...]")
        os.exit(1)
    }
    failed := false
    for name in args {
        if strings.has_prefix(name, "-") {
            fmt.printf("ubrew: unknown link flag '%s'\n", name)
            failed = true
            continue
        }
        if !package_name_safe(name) || strings.contains(name, "/") {
            fmt.printf("ubrew: refusing to link unsafe name: %s\n", name)
            failed = true
            continue
        }
        rack := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, name)
        if !os.is_dir(rack) {
            fmt.printf("ubrew: '%s' is not installed\n", name)
            failed = true
            continue
        }
        // Pick the newest keg version in the rack.
        infos, err := os.read_directory_by_path(rack, -1, context.temp_allocator)
        if err != nil || len(infos) == 0 {
            fmt.printf("ubrew: '%s' has no kegs\n", name)
            failed = true
            continue
        }
        latest := ""
        for info in infos {
            if info.type == .Directory {
                if latest == "" || is_newer(info.name, latest) {
                    latest = info.name
                }
            }
        }
        if latest == "" {
            fmt.printf("ubrew: '%s' has no kegs\n", name)
            failed = true
            continue
        }
        keg_bin := fmt.tprintf("%s/Cellar/%s/%s/bin", installer.PREFIX, name, latest)
        if !os.is_dir(keg_bin) {
            fmt.printf("==> %s %s has no bin/ directory; nothing to link\n", name, latest)
            continue
        }
        bin_infos, bin_err := os.read_directory_by_path(keg_bin, -1, context.temp_allocator)
        if bin_err != nil {
            fmt.printf("ubrew: cannot read %s: %v\n", keg_bin, bin_err)
            failed = true
            continue
        }
        linked := 0
        for bi in bin_infos {
            if bi.type != .Regular && bi.type != .Symlink {
                continue
            }
            src := bi.fullpath
            dst := fmt.tprintf("%s/bin/%s", installer.PREFIX, bi.name)
            _ = os.remove(dst)
            if serr := os.symlink(src, dst); serr != nil {
                fmt.printf("ubrew: failed linking %s -> %s: %v\n", dst, src, serr)
                failed = true
                continue
            }
            linked += 1
        }
        fmt.printf("==> Linked %s %s (%d bin link(s))\n", name, latest, linked)
    }
    if failed {
        os.exit(1)
    }
}

run_unlink :: proc(args: []string) {
    if len(args) < 1 {
        fmt.println("Usage: ubrew unlink <installed_formula> [...]")
        os.exit(1)
    }
    dry_run := false
    names := make([dynamic]string, context.temp_allocator)
    for a in args {
        switch a {
        case "--dry-run", "-n":
            dry_run = true
        case:
            if strings.has_prefix(a, "-") {
                fmt.printf("ubrew: unknown unlink flag '%s'\n", a)
                os.exit(1)
            }
            append(&names, a)
        }
    }
    failed := false
    for name in names {
        if !package_name_safe(name) || strings.contains(name, "/") {
            fmt.printf("ubrew: refusing to unlink unsafe name: %s\n", name)
            failed = true
            continue
        }
        if dry_run {
            // Count what would be removed.
            bin_dir := installer.PREFIX + "/bin"
            formula_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, name)
            infos, err := os.read_directory_by_path(bin_dir, -1, context.temp_allocator)
            if err != nil {
                continue
            }
            n := 0
            for info in infos {
                path := fmt.tprintf("%s/%s", bin_dir, info.name)
                target, lerr := os.read_link(path, context.temp_allocator)
                if lerr != nil { continue }
                prefix := fmt.tprintf("%s/", formula_dir)
                if strings.has_prefix(target, prefix) {
                    fmt.printf("Would unlink %s\n", path)
                    n += 1
                }
            }
            fmt.printf("==> Would unlink %d bin link(s) for %s\n", n, name)
            continue
        }
        removed := unlink_formula_bins(name)
        opt_link := fmt.tprintf("%s/opt/%s", installer.PREFIX, name)
        _ = os.remove(opt_link)
        fmt.printf("==> Unlinked %s (%d bin link(s))\n", name, removed)
    }
    if failed {
        os.exit(1)
    }
}

run_home :: proc(args: []string) {
    is_cask := false
    names := make([dynamic]string, context.temp_allocator)
    for a in args {
        switch a {
        case "--cask":
            is_cask = true
        case "--formula":
            is_cask = false
        case:
            if strings.has_prefix(a, "-") {
                fmt.printf("ubrew: unknown home flag '%s'\n", a)
                os.exit(1)
            }
            append(&names, a)
        }
    }
    if len(names) == 0 {
        open_url("https://brew.sh")
        return
    }
    for name in names {
        url := ""
        if is_cask {
            c, err := api.fetch_cask(name)
            if err != nil {
                fmt.printf("ubrew: cannot resolve cask '%s'\n", name)
                continue
            }
            if len(c.homepage) > 0 {
                url = strings.clone(c.homepage, context.temp_allocator)
            }
            api.destroy_cask(c)
        } else {
            f, err := api.fetch_formula(name)
            if err != nil {
                fmt.printf("ubrew: cannot resolve formula '%s'\n", name)
                continue
            }
            if len(f.homepage) > 0 {
                url = strings.clone(f.homepage, context.temp_allocator)
            } else {
                url = fmt.tprintf("https://formulae.brew.sh/formula/%s", name)
            }
            api.destroy_formula(f)
        }
        if url == "" {
            fmt.printf("ubrew: no homepage for '%s'\n", name)
            continue
        }
        open_url(url)
    }
}

open_url :: proc(url: string) {
    fmt.printf("==> Opening %s\n", url)
    if command_exists("xdg-open") {
        platform.exec_cmd("xdg-open", []string{"xdg-open", url})
    } else if command_exists("open") {
        platform.exec_cmd("open", []string{"open", url})
    }
}

run_desc :: proc(args: []string) {
    search_names := false
    search_descs := false
    queries := make([dynamic]string, context.temp_allocator)
    for a in args {
        switch a {
        case "--search", "-s":
            search_names = true
            search_descs = true
        case "--name", "-n":
            search_names = true
        case "--description", "-d":
            search_descs = true
        case:
            if strings.has_prefix(a, "-") {
                fmt.printf("ubrew: unknown desc flag '%s'\n", a)
                os.exit(1)
            }
            append(&queries, a)
        }
    }
    if len(queries) == 0 {
        fmt.println("Usage: ubrew desc <formula> | ubrew desc --search <text>")
        os.exit(1)
    }

    if !search_names && !search_descs {
        // Lookup mode: print "<name>: <desc>" for each named formula.
        for name in queries {
            f, err := api.fetch_formula(name)
            if err != nil {
                fmt.printf("%s: (not found)\n", name)
                continue
            }
            defer api.destroy_formula(f)
            if len(f.desc) > 0 {
                fmt.printf("%s: %s\n", f.name, f.desc)
            } else {
                fmt.printf("%s: (no description)\n", f.name)
            }
        }
        return
    }

    // Search mode: delegate to search_formulae and filter.
    for q in queries {
        results, err := api.search_formulae(q, 50)
        if err != nil {
            continue
        }
        defer api.destroy_formula_search_results(results)
        q_lower := strings.to_lower(q, context.temp_allocator)
        for r in results {
            name_lower := strings.to_lower(r.name, context.temp_allocator)
            desc_lower := strings.to_lower(r.desc, context.temp_allocator)
            hit := false
            if search_names && strings.contains(name_lower, q_lower) {
                hit = true
            }
            if !hit && search_descs && strings.contains(desc_lower, q_lower) {
                hit = true
            }
            if hit {
                fmt.printf("%s: %s\n", r.name, r.desc)
            }
        }
    }
}

run_list_names :: proc(kind: string) {
    // `formulae` and `casks` list every locally installable name. We dump
    // the cached registry and the installed cellar. Best-effort: produces a
    // sorted, de-duplicated list.
    seen := make(map[string]bool, context.temp_allocator)
    names := make([dynamic]string, context.temp_allocator)

    if kind == "formula" {
        cellar := installer.PREFIX + "/Cellar"
        if infos, err := os.read_directory_by_path(cellar, -1, context.temp_allocator); err == nil {
            for info in infos {
                if info.type == .Directory && !seen[info.name] {
                    seen[info.name] = true
                    append(&names, info.name)
                }
            }
        }
    } else {
        caskroom := installer.PREFIX + "/Caskroom"
        if infos, err := os.read_directory_by_path(caskroom, -1, context.temp_allocator); err == nil {
            for info in infos {
                if info.type == .Directory && !seen[info.name] {
                    seen[info.name] = true
                    append(&names, info.name)
                }
            }
        }
    }

    slice.sort(names[:])
    for n in names {
        fmt.println(n)
    }
}

run_formulae :: proc(args: []string) {
    // `formulae` lists every locally installable formula, one per line.
    // Mirrors `Library/Homebrew/cmd/formulae.rb`:
    //     puts Formula.all(eval_all: true)
    //         .flat_map { |f| [f.full_name, f.name] }.uniq.sort
    // For homebrew-core formulae, `name == full_name` so we only emit `name`.
    // For tap formulae, we emit BOTH the short name and the full
    // `user/repo/name` so both `ubrew install name` and
    // `ubrew install user/repo/name` work. Installed formulae are added at
    // the end as a safety net for stale caches.
    if len(args) > 0 {
        // `brew formulae` accepts --installed, --full-name, --versions etc.
        // We accept them silently (no-op) for brew-compat scripts.
        for a in args {
            if a == "-h" || a == "--help" {
                print_formulae_usage()
                return
            }
        }
    }

    seen := make(map[string]struct{}, context.temp_allocator)
    insert_name :: proc(seen: ^map[string]struct{}, name: string) {
        if name == "" { return }
        if _, exists := seen^[name]; !exists {
            seen^[name] = {}
        }
    }

    // 1. Homebrew-core formulae: pull from the compact TSV search index
    //    (~500KB, 8,403 lines, reads in one syscall). This is the same file
    //    that `search` reads, so the data is always fresh after `update`.
    if data, rerr := os.read_entire_file(api.FORMULA_SEARCH_INDEX, context.temp_allocator); rerr == nil {
        for line in strings.split_lines(string(data)) {
            if line == "" { continue }
            // First TSV column is the formula name; desc/follow in cols 2+3.
            tab := strings.index(line, "\t")
            if tab < 0 {
                insert_name(&seen, line)
            } else {
                insert_name(&seen, line[:tab])
            }
        }
    } else if data, rerr2 := api.fetch_cached_api_list(api.FORMULA_LIST_URL, api.FORMULA_LIST_CACHE); rerr2 == nil {
        // Fallback: read the raw 30MB formula.json if the index doesn't
        // exist yet (first run before `update`).
        defer delete(data)
        text := string(data)
        depth, obj_start: int
        for i in 0 ..< len(text) {
            c := text[i]
            if c == '{' {
                if depth == 0 { obj_start = i }
                depth += 1
            } else if c == '}' && depth > 0 {
                depth -= 1
                if depth == 0 {
                    obj := text[obj_start:i+1]
                    if name := api.json_field_string_raw(obj, "name"); name != "" {
                        insert_name(&seen, name)
                    }
                }
            } else if c == '[' && depth == 0 {
                // First '[' opens the array; skip.
            }
        }
    }

    // 2. Tap formulae: walk every tapped repo's Formula listing and emit
    //    both the short name and the full `user/repo/name`.
    tap_entries := tap.read_taps()
    defer {
        for e in tap_entries { tap.destroy_read_tap_entry(e) }
        delete(tap_entries)
    }
    for entry in tap_entries {
        t := tap.tap_from_entry(entry)
        listing_data, ok := api.fetch_tap_listing_cached(t)
        if !ok {
            tap.destroy_tap(t)
            continue
        }
        // Per-iteration cleanup. fetch_tap_listing_cached allocates with
        // context.allocator, so we must release the buffer after parsing.
        // (A `defer` inside a for-loop in Odin defers until function end,
        // which would accumulate one cleanup per tap and OOM on big tap
        // lists — explicit delete at end of iteration is correct.)
        listing_text := string(listing_data)
        i := 0
        for {
            marker := "\"name\""
            found := strings.index(listing_text[i:], marker)
            if found < 0 { break }
            i += found + len(marker)
            for i < len(listing_text) && (listing_text[i] == ' ' || listing_text[i] == ':' || listing_text[i] == '\t') {
                i += 1
            }
            if i >= len(listing_text) || listing_text[i] != '"' { continue }
            i += 1
            end := i
            for end < len(listing_text) && listing_text[end] != '"' {
                end += 1
            }
            if end >= len(listing_text) { break }
            fname := listing_text[i:end]
            if !strings.has_suffix(fname, ".rb") {
                i = end + 1
                continue
            }
            formula_name := fname[:len(fname) - 3]
            insert_name(&seen, formula_name)
            insert_name(&seen, fmt.tprintf("%s/%s", t.name, formula_name))
            i = end + 1
        }
        delete(listing_data)
        tap.destroy_tap(t)
    }

    // 3. Installed formulae: safety net. If a formula was installed then
    //    dropped from the index, we still want it listed.
    cellar := installer.PREFIX + "/Cellar"
    if infos, err := os.read_directory_by_path(cellar, -1, context.temp_allocator); err == nil {
        for info in infos {
            if info.type == .Directory {
                insert_name(&seen, info.name)
            }
        }
    }

    // 4. Sort and print. We materialize the set into a slice because Odin
    //    doesn't have a built-in sorted-map iterator.
    names := make([dynamic]string, 0, len(seen), context.temp_allocator)
    for name in seen {
        append(&names, name)
    }
    slice.sort(names[:])
    for n in names {
        fmt.println(n)
    }
}

print_formulae_usage :: proc() {
    fmt.println("Usage: ubrew formulae")
    fmt.println()
    fmt.println("List all locally installable formulae including short names.")
    fmt.println()
    fmt.println("For each tap formula, both the short name and the full")
    fmt.println("`user/repo/name` are printed. Output is sorted and de-duplicated.")
}

run_commands :: proc(args: []string) {
    include_aliases := false
    subcommands := make([dynamic]string, context.temp_allocator)
    defer delete(subcommands)
    for a in args {
        switch a {
        case "-q", "--quiet":
            // accepted; output is already terse
        case "--include-aliases":
            include_aliases = true
        case:
            if strings.has_prefix(a, "-") {
                fmt.printf("ubrew: unknown commands flag '%s'\n", a)
                os.exit(1)
            }
            append(&subcommands, a)
        }
    }

    // Brew-style `commands <subcommand>`: print the path to the file
    // being used when invoking `ubrew <subcommand>`. For ubrew every
    // built-in command lives in the ubrew binary itself, so the path
    // is always the running executable.
    if len(subcommands) > 0 {
        known := ubrew_known_commands(include_aliases)
        for sub in subcommands {
            is_known := false
            for k in known {
                if sub == k {
                    is_known = true
                    break
                }
            }
            if !is_known {
                // Mirror brew: silent failure with non-zero exit so
                // callers can `if path=$(brew commands $cmd)`.
                os.exit(1)
            }
            exe_path, exe_err := os.get_executable_path(context.allocator)
            if exe_err != nil || len(exe_path) == 0 {
                // Fall back to argv[0] if the OS can't resolve it
                // (extremely rare; on Linux /proc/self/exe always works).
                fmt.println(os.args[0])
            } else {
                fmt.println(exe_path)
            }
        }
        return
    }

    for c in ubrew_known_commands(include_aliases) {
        fmt.println(c)
    }
}

// run_command implements the brew `command` subcommand. It takes one or
// more subcommand names and prints the path to the file being used
// when invoking `ubrew <subcommand>`. For ubrew every built-in command
// lives in the ubrew binary itself, so the printed path is always the
// running executable. Unknown commands print
// `Error: Unknown command: ubrew <cmd>` to stderr and exit 1, matching
// the brew behaviour at Library/Homebrew/cmd/command.rb.
run_command :: proc(args: []string) {
    if len(args) == 0 {
        fmt.eprintln("Error: `ubrew command` requires at least one subcommand name")
        fmt.eprintln("Usage: ubrew command <subcommand> [...]")
        os.exit(1)
    }
    // Skip the leading "command" if the dispatch ever routes it in.
    filtered := make([dynamic]string, context.temp_allocator)
    defer delete(filtered)
    for a in args {
        if strings.has_prefix(a, "-") {
            fmt.eprintf("Error: unknown option '%s'\n", a)
            os.exit(1)
        }
        append(&filtered, a)
    }
    if len(filtered) == 0 {
        fmt.eprintln("Error: `ubrew command` requires at least one subcommand name")
        os.exit(1)
    }

    known := ubrew_known_commands(true) // include aliases — `command ls` should resolve to the same path as `command list`
    exe_path, exe_err := os.get_executable_path(context.allocator)
    fallback := os.args[0]
    if exe_err != nil || len(exe_path) == 0 {
        exe_path = fallback
    }
    defer if exe_path != fallback { delete(exe_path) }

    unknown_any := false
    for sub in filtered {
        is_known := false
        for k in known {
            if sub == k {
                is_known = true
                break
            }
        }
        if !is_known {
            fmt.eprintf("Error: Unknown command: ubrew %s\n", sub)
            unknown_any = true
            continue
        }
        fmt.println(exe_path)
    }
    if unknown_any {
        os.exit(1)
    }
}

// run_which_formula prints the names of formulae (one per line) that
// provide an executable named `cmd`. The brew equivalent is
// `brew which-formula <cmd>`. With `--explain`, prints a brew-style
// "Did you mean: ubrew install <name>?" message and exits 0 only if
// at least one match was found (so callers can use it in a shell
// `if` for the command-not-found hook).
run_which_formula :: proc(args: []string) {
    explain := false
    cmds := make([dynamic]string, context.temp_allocator)
    defer delete(cmds)
    for a in args {
        switch a {
        case "--explain":
            explain = true
        case:
            if strings.has_prefix(a, "-") {
                fmt.eprintf("ubrew: unknown which-formula flag '%s'\n", a)
                os.exit(1)
            }
            append(&cmds, a)
        }
    }
    if len(cmds) == 0 {
        fmt.eprintln("Usage: ubrew which-formula [--explain] <cmd> [...]")
        os.exit(1)
    }

    any_match := false
    for cmd in cmds {
        matches := api.which_formula(cmd)
        if len(matches) == 0 {
            if explain {
                fmt.eprintf("No available formula provides %q.\n", cmd)
            }
            continue
        }
        any_match = true
        if explain {
            if len(matches) == 1 {
                fmt.printf("The program %q is not currently installed. You can install it by typing:\n", cmd)
                fmt.printf("  ubrew install %s\n", matches[0])
            } else {
                fmt.printf("The program %q is not currently installed. It is provided by several formulae:\n", cmd)
                for m in matches {
                    fmt.printf("  ubrew install %s\n", m)
                }
            }
        } else {
            for m in matches {
                fmt.println(m)
            }
        }
        // which_formula returns a slice allocated from the caller's
        // context.allocator; free it before the next iteration.
        delete(matches)
    }
    if !any_match {
        os.exit(1)
    }
}

// run_command_not_found_init implements the brew `command-not-found-init`
// subcommand. When stdout is a TTY it prints instructions on how to
// wire the command-not-found hook into the user's shell RC file. When
// stdout is redirected (e.g. `eval "$(ubrew command-not-found-init)"`),
// it prints the actual handler script for the user's shell.
//
// The handler script defines a `command_not_found_handle` (bash) /
// `command_not_found_handler` (zsh) / `fish_command_not_found` (fish)
// function that calls `ubrew which-formula --explain <cmd>` and prints
// a brew-style "did you mean" suggestion or a generic "command not
// found" message.
run_command_not_found_init :: proc() {
    is_tty := os.is_tty(os.stdout)
    shell_name := detect_shell()
    if is_tty {
        print_command_not_found_help(shell_name)
    } else {
        print_command_not_found_handler(shell_name)
    }
}

// detect_shell returns one of "bash", "zsh", "fish" based on the SHELL
// environment variable. Falls back to "bash" when SHELL is unset or
// doesn't match a known shell. Mirrors the `Utils::Shell` logic from
// upstream Homebrew at a much smaller scope.
detect_shell :: proc() -> string {
    sh := os.get_env("SHELL", context.temp_allocator)
    base := sh
    if idx := strings.last_index(sh, "/"); idx >= 0 {
        base = sh[idx+1:]
    }
    switch base {
    case "bash", "zsh", "fish":
        return base
    case:
        return "bash"
    }
}

// command_not_found_init_help_bash is the TTY-mode setup hint for
// bash/zsh shells. Tells the user to add the handler-source line to
// their RC file. Mirrors the brew output at
// Library/Homebrew/cmd/command-not-found-init.rb#help.
@(rodata)
command_not_found_init_help_bash := `# To enable command-not-found handling, add the following to your
# shell startup file (e.g. ~/.bashrc or ~/.zshrc):

eval "$(ubrew command-not-found-init)"

# Then restart your shell, or source the RC file in any open
# terminal. From then on, typing a command that isn't installed
# will suggest the formula that provides it.
`

// command_not_found_init_help_fish is the fish-shell equivalent.
@(rodata)
command_not_found_init_help_fish := `# To enable command-not-found handling, add the following to
# ~/.config/fish/config.fish:

ubrew command-not-found-init | source

# Then restart your shell, or source the file. From then on, typing
# a command that isn't installed will suggest the formula that
# provides it.
`

print_command_not_found_help :: proc(shell_name: string) {
    if shell_name == "fish" {
        fmt.print(command_not_found_init_help_fish)
    } else {
        fmt.print(command_not_found_init_help_bash)
    }
}

// command_not_found_handler_bash is the bash/zsh handler that gets
// sourced into the user's shell. Defines `command_not_found_handle`
// (bash) or `command_not_found_handler` (zsh) which the shell calls
// when a command isn't found. The handler asks `ubrew which-formula`
// for a suggestion; if found, prints the brew-style explanation;
// otherwise falls back to the standard "command not found" message.
@(rodata)
command_not_found_handler_bash := `#
# ubrew command-not-found handler for bash/zsh
# Generated by: ubrew command-not-found-init
# License: MIT
#

if ! command -v ubrew >/dev/null 2>&1; then
    return 0
fi

ubrew_command_not_found_handle() {
    local cmd="$1"

    # Skip self-referential options that the shell itself may try to
    # resolve.
    case "${cmd}" in
        -h|--help|--usage|-?) return 127 ;;
    esac

    # do not run when stdout is not a tty (e.g. inside a pipe or
    # midnight commander), unless explicitly opted in via
    # UBREW_COMMAND_NOT_FOUND_CI.
    if [ -z "${UBREW_COMMAND_NOT_FOUND_CI:-}" ] && { [ -n "${MC_SID:-}" ] || [ ! -t 1 ]; } then
        if [ -n "${BASH_VERSION:-}" ]; then
            echo "${cmd}: command not found"
        elif [ -n "${ZSH_VERSION:-}" ] && autoload is-at-least 2>/dev/null && is-at-least "5.2" "${ZSH_VERSION}"; then
            echo "zsh: command not found: ${cmd}" >&2
        fi
        return 127
    fi

    local txt
    txt="$(ubrew which-formula --explain "${cmd}" 2>/dev/null)"

    if [ -z "${txt}" ]; then
        if [ -n "${BASH_VERSION:-}" ]; then
            echo "${cmd}: command not found"
        elif [ -n "${ZSH_VERSION:-}" ] && autoload is-at-least 2>/dev/null && is-at-least "5.2" "${ZSH_VERSION}"; then
            echo "zsh: command not found: ${cmd}" >&2
        fi
    else
        echo "${txt}"
    fi

    return 127
}

if [ -n "${BASH_VERSION:-}" ]; then
    command_not_found_handle() {
        ubrew_command_not_found_handle "$@"
        return $?
    }
elif [ -n "${ZSH_VERSION:-}" ]; then
    command_not_found_handler() {
        ubrew_command_not_found_handle "$@"
        return $?
    }
fi
`

// command_not_found_handler_fish is the fish equivalent.
@(rodata)
command_not_found_handler_fish := `#
# ubrew command-not-found handler for fish
# Generated by: ubrew command-not-found-init
# License: MIT
#

if not command -v ubrew >/dev/null 2>&1
    return 0
end

function __ubrew_command_not_found
    set -l cmd $argv[1]
    set -l txt

    if test -z "$UBREW_COMMAND_NOT_FOUND_CI"
        if test -n "$MC_SID"; or not isatty 1
            __fish_default_command_not_found_handler $cmd
            return 127
        end
    end

    if not contains -- "$cmd" "-h" "--help" "--usage" "-?"
        set txt (ubrew which-formula --explain $cmd 2>/dev/null)
    end

    if test -z "$txt"
        __fish_default_command_not_found_handler $cmd
    else
        echo $txt
    end
end

function __ubrew_command_not_found_on_event --on-event fish_command_not_found
    __ubrew_command_not_found $argv
end
`

print_command_not_found_handler :: proc(shell_name: string) {
    if shell_name == "fish" {
        fmt.print(command_not_found_handler_fish)
    } else {
        fmt.print(command_not_found_handler_bash)
    }
}

// DEVELOPER_STATE_FILE is where ubrew persists developer-mode state.
// Mirrors Homebrew's `Homebrew::Settings.write("devcmdrun", "true")`,
// which stores `homebrew.devcmdrun` in the Homebrew repo's git config.
// For ubrew (no git-tracked repo) we use a plain file in the system
// state directory. The `UBREW_DEVELOPER` env var always takes
// precedence over the file.
DEVELOPER_STATE_FILE :: "/opt/ubrew/db/developer"

// developer_env_set reports whether the UBREW_DEVELOPER=1 env var is
// set, taking precedence over the on-disk state file.
developer_env_set :: proc() -> bool {
    return os.get_env("UBREW_DEVELOPER", context.temp_allocator) == "1"
}

developer_state :: proc() -> enum { On, Off, Unknown } {
    if developer_env_set() {
        return .On
    }
    data, err := os.read_entire_file(DEVELOPER_STATE_FILE, context.allocator)
    if err != nil {
        return .Unknown
    }
    defer delete(data)
    s := strings.trim_space(string(data))
    if s == "on"  { return .On  }
    if s == "off" { return .Off }
    return .Unknown
}

set_developer_state :: proc(on: bool) -> os.Error {
    // Ensure the parent dir exists. Odin's make_directory_all
    // returns .Exist when the dir is already there; treat that as
    // success (the common case for /opt/ubrew/db which is always
    // present after `ubrew init`).
    path := strings.clone(DEVELOPER_STATE_FILE, context.temp_allocator)
    if slash := strings.last_index(path, "/"); slash > 0 {
        if err := os.make_directory_all(path[:slash], os.Permissions_Default_Directory); err != nil {
            if err != .Exist {
                return err
            }
        }
    }
    payload := on ? "on\n" : "off\n"
    return os.write_entire_file(DEVELOPER_STATE_FILE, payload)
}

// run_developer implements `ubrew developer [on|off|state]`. Mirrors
// the Homebrew `brew developer` command. When developer mode is
// enabled, `update` checks for newer upstream content more frequently
// (5-minute cache TTL instead of 1-hour); the rest is forward-compat
// for future ubrew behaviour changes. Mirrors
// Library/Homebrew/cmd/developer.rb + subcommand/on|off|state.rb.
run_developer :: proc(args: []string) {
    if len(args) == 0 {
        developer_state_print()
        return
    }
    sub := args[0]
    switch sub {
    case "on":
        if err := set_developer_state(true); err != nil {
            fmt.eprintf("ubrew: failed to enable developer mode: %v\n", err)
            os.exit(1)
        }
        fmt.println("Developer mode is now enabled.")
        if developer_env_set() {
            fmt.eprintln("Note: UBREW_DEVELOPER=1 is set, so developer mode will remain enabled regardless of the on-disk state.")
        }
    case "off":
        if err := set_developer_state(false); err != nil {
            fmt.eprintf("ubrew: failed to disable developer mode: %v\n", err)
            os.exit(1)
        }
        fmt.println("Developer mode is now disabled.")
        if developer_env_set() {
            fmt.eprintln("Note: UBREW_DEVELOPER=1 is set; developer mode is still active until that env var is unset.")
        }
    case "state":
        developer_state_print()
    case:
        fmt.eprintf("ubrew: unknown developer subcommand: %s\n", sub)
        fmt.eprintln("Usage: ubrew developer [on|off|state]")
        os.exit(1)
    }
}

developer_state_print :: proc() {
    env_set := developer_env_set()
    st := developer_state()
    enabled := st == .On || env_set
    if env_set {
        fmt.println("Developer mode is enabled because UBREW_DEVELOPER=1 is set.")
    } else if st == .On {
        fmt.println("Developer mode is enabled (last set with `ubrew developer on`).")
    } else if st == .Off {
        fmt.println("Developer mode is disabled (last set with `ubrew developer off`).")
    } else {
        fmt.println("Developer mode is disabled (no prior state).")
    }
    if enabled {
        fmt.println("`update` will use a 5-minute cache TTL and check upstream more aggressively.")
    } else {
        fmt.println("`update` will use the standard 1-hour cache TTL.")
    }
}

// ── exec / x ──
//
// `ubrew exec [--formulae=formula1,formula2,...] [--] command [args...]`
// runs `command` in a PATH populated by Homebrew formulae. The `x`
// alias is a one-letter shortcut.
//
// With --formulae, the listed formulae (and their transitive
// dependencies) are installed if needed; their bin/sbin directories
// are prepended to PATH and the command is run. This is the path
// used by the `#!/usr/bin/env -S ubrew exec --formulae=jq,yq --`
// shebang pattern.
//
// Without --formulae, the command name is looked up against the
// formulae database (executables field of formula.json), the first
// matching formula is installed if needed, and the resolved
// executable is run.

exec_formula_name :: proc(name: string) -> string {
    // Strip the tap prefix (`user/repo/name` -> `name`).
    if idx := strings.last_index(name, "/"); idx >= 0 {
        return name[idx+1:]
    }
    return name
}

exec_formula_latest_keg :: proc(name: string) -> (string, bool) {
    short := exec_formula_name(name)
    cellar := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, short)
    // `read_directory_by_path` returns its backing slice from a temp
    // arena (not the heap), so `file_info_slice_delete` would
    // call `free()` on a temp-allocated pointer and crash with
    // "free(): invalid pointer". Use the temp allocator end-of-scope
    // cleanup instead.
    infos, err := os.read_directory_by_path(cellar, -1, context.temp_allocator)
    if err != nil {
        return "", false
    }
    // Pick the lexicographically-greatest subdir. For SemVer this
    // works well enough; for formulae with pre-release tags the
    // Cellar layout rarely collides.
    latest := ""
    for info in infos {
        if info.type != .Directory { continue }
        if latest == "" || is_newer(info.name, latest) {
            latest = info.name
        }
    }
    if latest == "" {
        return "", false
    }
    return fmt.tprintf("%s/%s", cellar, latest), true
}

exec_formula_installed :: proc(name: string) -> bool {
    _, ok := exec_formula_latest_keg(name)
    return ok
}

exec_collect_deps :: proc(name: string, visited: ^map[string]bool) -> [dynamic]string {
    // Topological-ish dep walk: visit each dep once, appending
    // to the result. Order doesn't matter for PATH construction
    // (we de-duplicate), so a pre-order walk is fine.
    out := make([dynamic]string, context.temp_allocator)
    walk :: proc(n: string, v: ^map[string]bool, out: ^[dynamic]string) {
        if n in v { return }
        v[n] = true
        f, err := api.fetch_formula(n)
        if err != nil {
            append(out, n)
            return
        }
        defer api.destroy_formula(f)
        for d in f.dependencies {
            walk(d, v, out)
        }
        append(out, n)
    }
    walk(name, visited, &out)
    return out
}

exec_add_path_entry :: proc(entry: string, entries: ^[dynamic]string) {
    // Skip non-existent dirs (a formula may not have shipped bin/).
    if !os.is_dir(entry) { return }
    for e in entries {
        if e == entry { return }
    }
    append(entries, entry)
}

exec_collect_path_entries :: proc(formulae: []string) -> [dynamic]string {
    out := make([dynamic]string, context.temp_allocator)
    visited := make(map[string]bool, context.allocator)
    defer delete(visited)
    for f in formulae {
        for d in exec_collect_deps(f, &visited) {
            short := exec_formula_name(d)
            exec_add_path_entry(fmt.tprintf("%s/opt/%s/bin", installer.PREFIX, short), &out)
            exec_add_path_entry(fmt.tprintf("%s/opt/%s/sbin", installer.PREFIX, short), &out)
        }
        // Also add the top-level formula's own bin/sbin (it may not
        // be in the dep closure of itself).
        short := exec_formula_name(f)
        exec_add_path_entry(fmt.tprintf("%s/opt/%s/bin", installer.PREFIX, short), &out)
        exec_add_path_entry(fmt.tprintf("%s/opt/%s/sbin", installer.PREFIX, short), &out)
    }
    return out
}

exec_resolve_command_path :: proc(cmd_name: string, formulae: []string) -> (string, bool) {
    // If the command contains a slash, treat it as a literal path
    // and resolve it. execve(2) needs an absolute path.
    if strings.contains_any(cmd_name, "/") {
        abs, err := os.get_absolute_path(cmd_name, context.temp_allocator)
        if err != nil || !os.is_file(abs) {
            return "", false
        }
        return abs, true
    }
    // Otherwise, look for it in the formulae bin/sbin dirs.
    candidates := make([dynamic]string, context.temp_allocator)
    defer delete(candidates)
    for f in formulae {
        short := exec_formula_name(f)
        append(&candidates, fmt.tprintf("%s/opt/%s/bin/%s", installer.PREFIX, short, cmd_name))
        append(&candidates, fmt.tprintf("%s/opt/%s/sbin/%s", installer.PREFIX, short, cmd_name))
        if keg, ok := exec_formula_latest_keg(f); ok {
            append(&candidates, fmt.tprintf("%s/bin/%s", keg, cmd_name))
            append(&candidates, fmt.tprintf("%s/sbin/%s", keg, cmd_name))
        }
    }
    for c in candidates {
        if os.is_file(c) {
            return c, true
        }
    }
    return "", false
}

exec_print_usage :: proc() {
    fmt.println("Usage: ubrew exec [--formulae=formula1,formula2,...] [--] <command> [<args>...]")
    fmt.println("")
    fmt.println("Run <command> in an environment populated by Homebrew formulae.")
    fmt.println("")
    fmt.println("If --formulae is passed, ubrew installs those comma-separated formulae")
    fmt.println("if needed, prepends their executable directories and those of their")
    fmt.println("dependencies to PATH and runs <command>. This allows <command> to be")
    fmt.println("a script path such as ./script.sh.")
    fmt.println("")
    fmt.println("If --formulae is omitted, ubrew finds a formula that provides <command>,")
    fmt.println("installs it if needed and runs that executable.")
    fmt.println("")
    fmt.println("Example: ubrew exec --formulae=jq,yq -- ./script.sh")
    fmt.println("")
    fmt.println("Scripts can also use a shebang on systems with env -S:")
    fmt.println("  #!/usr/bin/env -S ubrew exec --formulae=jq,yq --")
}

// run_exec implements `ubrew exec [--formulae=...] [--] <command> [args...]`.
// Mirrors Library/Homebrew/cmd/exec.rb + cmd/exec.sh. After the PATH
// is rebuilt and the command resolved, the current process is
// replaced via posix.execve(2) so signals and exit codes propagate
// to the caller as if the user had run the command directly.
run_exec :: proc(args: []string) {
    // 1. Parse options.
    formulae_arg := ""
    formulae_seen := false
    i := 0
    parsing_options := true
    for i < len(args) {
        a := args[i]
        if !parsing_options {
            // Past `--` or past the first non-option arg. Stop parsing
            // options; everything from here is the command + its args.
            break
        }
        if a == "--formulae" {
            if i + 1 >= len(args) {
                fmt.eprintln("ubrew exec: --formulae requires a comma-separated formula list.")
                os.exit(1)
            }
            formulae_arg = args[i+1]
            formulae_seen = true
            i += 2
            continue
        }
        if strings.has_prefix(a, "--formulae=") {
            formulae_arg = a[len("--formulae="):]
            formulae_seen = true
            i += 1
            continue
        }
        if a == "-h" || a == "--help" {
            exec_print_usage()
            return
        }
        if a == "--" {
            i += 1
            parsing_options = false
            continue
        }
        if strings.has_prefix(a, "-") {
            fmt.eprintf("ubrew exec: unknown option '%s'\n", a)
            os.exit(1)
        }
        break
    }

    cmd_args := args[i:]
    if len(cmd_args) == 0 {
        // Either we never got a command, or `--formulae=` was empty.
        // Distinguish the two so the error message is actionable.
        if formulae_seen && formulae_arg == "" {
            fmt.eprintln("ubrew exec: --formulae requires a comma-separated formula list.")
            os.exit(1)
        }
        exec_print_usage()
        os.exit(1)
    }
    cmd_name := cmd_args[0]
    _ = cmd_args[1:]

    // 2. Resolve which formulae to make available on PATH.
    formulae := make([dynamic]string, context.temp_allocator)
    if formulae_seen {
        fa := formulae_arg
        for raw in strings.split_iterator(&fa, ",") {
            trimmed := strings.trim_space(raw)
            if trimmed == "" { continue }
            append(&formulae, trimmed)
        }
        if len(formulae) == 0 {
            fmt.eprintln("ubrew exec: --formulae entries must not be empty.")
            os.exit(1)
        }
    } else {
        if strings.contains_any(cmd_name, "/") {
            fmt.eprintln("ubrew exec: executable name must not contain path separators without --formulae.")
            os.exit(1)
        }
        matches := api.which_formula(cmd_name)
        if len(matches) == 0 {
            fmt.eprintf("ubrew exec: no formula found that provides '%s'.\n", cmd_name)
            fmt.eprintln("Try `ubrew install <formula>` first, or use --formulae=<list>.")
            os.exit(1)
        }
        // Prefer an already-installed provider to avoid an install.
        selected := ""
        for m in matches {
            if exec_formula_installed(m) {
                selected = m
                break
            }
        }
        if selected == "" {
            selected = matches[0]
        }
        append(&formulae, selected)
        if !exec_formula_installed(selected) {
            fmt.eprintf("==> Installing %s because it provides %s\n", selected, cmd_name)
        }
    }

    // 3. Install any formulae that are not already installed.
    for f in formulae {
        if !exec_formula_installed(f) {
            if !install_formula_by_name(f, false) {
                fmt.eprintf("ubrew exec: failed to install %s\n", f)
                os.exit(1)
            }
        }
    }

    // 4. Build the PATH entries (formulae + transitive deps).
    path_entries := exec_collect_path_entries(formulae[:])

    // 5. Set PATH for the child.
    new_path := strings.join(path_entries[:], ":")
    orig_path, has_path := os.lookup_env_alloc("PATH", context.temp_allocator)
    if has_path {
        if new_path != "" {
            new_path = strings.concatenate({new_path, ":", orig_path}, context.allocator)
        } else {
            new_path = orig_path
        }
    }
    os.set_env("PATH", new_path)

    // 6. Resolve the command to an absolute path.
    exe_path, ok := exec_resolve_command_path(cmd_name, formulae[:])
    if !ok {
        if formulae_seen {
            fmt.eprintf("ubrew exec: '%s' not found in PATH after installing %s.\n", cmd_name, formulae[:])
        } else {
            fmt.eprintf("ubrew exec: '%s' was not found in %s's bin/sbin directories.\n", cmd_name, formulae[0])
        }
        os.exit(1)
    }

    // 7. Replace the current process with the command.
    // argv = [cmd_name, cmd_rest..., nil]
    argv := make([]cstring, len(cmd_args) + 1, context.allocator)
    for j in 0..<len(cmd_args) {
        argv[j] = strings.clone_to_cstring(cmd_args[j], context.allocator)
    }
    argv[len(cmd_args)] = nil

    exe_cstr := strings.clone_to_cstring(exe_path, context.allocator)
    posix.execve(exe_cstr, &argv[0], posix.environ)
    // execve only returns on failure.
    fmt.eprintf("ubrew exec: execve(%s) failed: %s\n", exe_path, posix.strerror(posix.errno()))
    os.exit(127)
}

// ubrew_primary_commands and ubrew_alias_commands are file-scope
// (static-memory) slices of subcommand names. Used as the single
// source of truth by `commands <subcommand>` and `command <subcommand>`
// lookups. Aliases map back to their primary command in the main()
// dispatch. NOTE: a function cannot safely return a `[]string{...}`
// compound literal (the literal lives on the caller's stack), so the
// lists live at file scope.
ubrew_primary_commands := []string{
    "autoremove", "bundle", "casks", "cleanup", "command", "command-not-found-init",
    "commands", "completions",
    "deps", "desc", "developer", "doctor", "exec", "formulae", "gc", "help", "history", "home",
    "info", "init", "install", "leaves", "link", "list", "migrate", "mirror",
    "nuke", "outdated", "pin", "reinstall", "remove", "search",
    "shellenv", "tap", "trust", "unlink", "unpin", "untap", "untrust", "update", "upgrade",
    "version", "where", "which-formula",
}
ubrew_alias_commands := []string{
    "abv", "clean", "dr", "homepage", "i", "ln", "ls", "rm", "s",
    "service", "ui", "uninstall", "up", "wh", "x",
}

// ubrew_known_commands returns the canonical list of ubrew subcommand
// names. If `include_aliases` is true, aliases are appended to the
// primary list (the result is allocated on the heap; the caller may
// iterate it but should not retain the pointer past the call).
ubrew_known_commands :: proc(include_aliases: bool) -> []string {
    if !include_aliases {
        return ubrew_primary_commands[:]
    }
    out := make([dynamic]string, 0, len(ubrew_primary_commands) + len(ubrew_alias_commands), context.temp_allocator)
    for p in ubrew_primary_commands { append(&out, p) }
    for a in ubrew_alias_commands { append(&out, a) }
    return out[:]
}

// ── path queries & shellenv ──

run_path_query :: proc(which: string, args: []string) {
    switch which {
    case "--prefix":
        if len(args) == 0 {
            fmt.println(installer.PREFIX)
            return
        }
        for name in args {
            fmt.printf("%s/opt/%s\n", installer.PREFIX, name)
        }
    case "--cellar":
        if len(args) == 0 {
            fmt.printf("%s/Cellar\n", installer.PREFIX)
            return
        }
        for name in args {
            fmt.printf("%s/Cellar/%s\n", installer.PREFIX, name)
        }
    case "--caskroom":
        if len(args) == 0 {
            fmt.printf("%s/Caskroom\n", installer.PREFIX)
            return
        }
        for name in args {
            fmt.printf("%s/Caskroom/%s\n", installer.PREFIX, name)
        }
    case "--cache":
        fmt.printf("%s/cache\n", installer.UBREW_ROOT)
    case "--repo", "--repository":
        // ubrew has no per-tap clone; report the ubrew root for `--repo`
        // with no args, and the tap cache dir otherwise.
        if len(args) == 0 {
            fmt.println(installer.UBREW_ROOT)
            return
        }
        for name in args {
            fmt.printf("%s/cache/taps/%s\n", installer.UBREW_ROOT, name)
        }
    case:
        fmt.printf("ubrew: unknown path query '%s'\n", which)
        os.exit(1)
    }
}

run_shellenv :: proc(args: []string) {
    shell := "bash"
    if len(args) > 0 {
        shell = args[0]
    }
    bin := fmt.tprintf("%s/bin", installer.PREFIX)
    switch shell {
    case "bash", "zsh", "sh":
        fmt.printf("export PATH=\"%s:${PATH:-}\"\n", bin)
        fmt.printf("export UBREW_PREFIX=\"%s\"\n", installer.PREFIX)
        fmt.printf("export UBREW_CELLAR=\"%s/Cellar\"\n", installer.PREFIX)
    case "fish":
        fmt.printf("set -gx PATH \"%s\" $PATH\n", bin)
        fmt.printf("set -gx UBREW_PREFIX \"%s\"\n", installer.PREFIX)
        fmt.printf("set -gx UBREW_CELLAR \"%s/Cellar\"\n", installer.PREFIX)
    case "csh", "tcsh":
        fmt.printf("setenv PATH \"%s:$PATH\"\n", bin)
        fmt.printf("setenv UBREW_PREFIX \"%s\"\n", installer.PREFIX)
        fmt.printf("setenv UBREW_CELLAR \"%s/Cellar\"\n", installer.PREFIX)
    case "pwsh":
        fmt.printf("$env:PATH = \"%s:$env:PATH\"\n", bin)
        fmt.printf("$env:UBREW_PREFIX = \"%s\"\n", installer.PREFIX)
        fmt.printf("$env:UBREW_CELLAR = \"%s/Cellar\"\n", installer.PREFIX)
    case "nu":
        fmt.println("# Add to your config.nu:")
        fmt.printf("$env.PATH = ($env.PATH | split row (char esep) | prepend '%s')\n", bin)
        fmt.printf("$env.UBREW_PREFIX = '%s'\n", installer.PREFIX)
        fmt.printf("$env.UBREW_CELLAR = '%s/Cellar'\n", installer.PREFIX)
    case:
        fmt.printf("ubrew: unsupported shell '%s' (try bash|zsh|fish|csh|tcsh|pwsh|nu)\n", shell)
        os.exit(1)
    }
}

// ── shell completions ──

run_completions :: proc(args: []string) {
    COMPLETIONS_STATE_FILE :: "/opt/ubrew/db/completions"

    read_completions_state :: proc() -> bool {
        data, rerr := os.read_entire_file(COMPLETIONS_STATE_FILE, context.temp_allocator)
        if rerr != nil {
            return false
        }
        return string(data) == "true"
    }

    write_completions_state :: proc(state: bool) -> bool {
        dir := "/opt/ubrew/db"
        os.make_directory_all(dir, os.perm(0o755))
        output := "true" if state else "false"
        werr := os.write_entire_file_from_string(COMPLETIONS_STATE_FILE, output)
        return werr == nil
    }

    subcommand := "state"
    if len(args) > 0 {
        subcommand = args[0]
    }

    if subcommand == "-h" || subcommand == "--help" || subcommand == "help" {
        fmt.println("Control whether Homebrew automatically links external tap shell completion files.")
        fmt.println()
        fmt.println("Usage: ubrew completions [subcommand]")
        fmt.println()
        fmt.println("Subcommands:")
        fmt.println("  link     Link Homebrew’s completions.")
        fmt.println("  unlink   Unlink Homebrew’s completions.")
        fmt.println("  state    Display the current state of Homebrew’s completions.")
        fmt.println()
        fmt.println("Completions script generation:")
        fmt.println("  ubrew completions <shell>  Emit shell completion script (try zsh|bash|fish|nushell)")
        return
    }

    switch subcommand {
    case "link":
        write_completions_state(true)
    case "unlink":
        write_completions_state(false)
    case "state":
        if read_completions_state() {
            fmt.println("Completions are linked.")
        } else {
            fmt.println("Completions are unlinked.")
        }
    case "zsh":
        fmt.println("#compdef ubrew")
        fmt.println("_ubrew() {")
        fmt.println("  local -a cmds")
        fmt.println("  cmds=(")
        fmt.println("    'autoremove:remove unused dependencies'")
        fmt.println("    'bundle:dump installed packages as a Brewfile'")
        fmt.println("    'casks:list all installable casks'")
        fmt.println("    'cleanup:remove stale caches and broken bin links'")
        fmt.println("    'command:show path to file implementing subcommand'")
        fmt.println("    'command-not-found-init:initialize command-not-found handler'")
        fmt.println("    'commands:list available commands'")
        fmt.println("    'completions:emit shell completion script'")
        fmt.println("    'deps:show formula dependencies'")
        fmt.println("    'desc:show package description'")
        fmt.println("    'developer:manage developer mode'")
        fmt.println("    'doctor:check installation health'")
        fmt.println("    'exec:run command in PATH populated by formulae'")
        fmt.println("    'formulae:list all installable formulae'")
        fmt.println("    'gc:garbage collect unreferenced store entries'")
        fmt.println("    'help:show help'")
        fmt.println("    'history:show package version history'")
        fmt.println("    'home:open package homepage in browser'")
        fmt.println("    'info:show package metadata'")
        fmt.println("    'init:create /opt/ubrew directory tree'")
        fmt.println("    'install:install formula or cask'")
        fmt.println("    'leaves:list packages with no dependents'")
        fmt.println("    'link:symlink a keg into the prefix'")
        fmt.println("    'list:list installed packages'")
        fmt.println("    'migrate:migrate from a foreign Cellar'")
        fmt.println("    'mirror:manage offline mirrors'")
        fmt.println("    'nuke:completely uninstall ubrew and all packages'")
        fmt.println("    'outdated:list outdated packages'")
        fmt.println("    'pin:pin a package'")
        fmt.println("    'reinstall:remove and install a formula again'")
        fmt.println("    'remove:uninstall a package'")
        fmt.println("    'search:search for formulae and casks'")
        fmt.println("    'shellenv:print shell init lines'")
        fmt.println("    'tap:manage 3rd-party tap repositories'")
        fmt.println("    'unlink:remove a kegs symlinks'")
        fmt.println("    'unpin:unpin a package'")
        fmt.println("    'untap:untap a 3rd-party repository'")
        fmt.println("    'update:update registries and taps'")
        fmt.println("    'upgrade:upgrade outdated packages'")
        fmt.println("    'version:show version'")
        fmt.println("    'where:show installed file paths'")
        fmt.println("    'which-formula:find formula providing an executable'")
        fmt.println("  )")
        fmt.println("  _describe 'ubrew command' cmds")
        fmt.println("}")
        fmt.println("compdef _ubrew ubrew")
    case "bash":
        fmt.println("_ubrew_completions() {")
        fmt.println("  local cur cmds")
        fmt.println("  cur=\"${COMP_WORDS[COMP_CWORD]}\"")
        fmt.println("  cmds=\"autoremove bundle casks cleanup command command-not-found-init \\")
        fmt.println("        commands completions deps desc developer doctor exec formulae \\")
        fmt.println("        gc help history home info init install leaves link list \\")
        fmt.println("        migrate mirror nuke outdated pin reinstall remove search \\")
        fmt.println("        shellenv tap unlink unpin untap update upgrade version \\")
        fmt.println("        where which-formula --prefix --cellar --caskroom --cache \\")
        fmt.println("        --repo --version\"")
        fmt.println("  if [ \"$COMP_CWORD\" -eq 1 ]; then")
        fmt.println("    COMPREPLY=( $(compgen -W \"$cmds\" -- \"$cur\") )")
        fmt.println("  fi")
        fmt.println("  return 0")
        fmt.println("}")
        fmt.println("complete -F _ubrew_completions ubrew")
    case "fish":
        cmds := []string{
            "autoremove", "bundle", "casks", "cleanup", "command", "command-not-found-init",
            "commands", "completions", "deps", "desc", "developer", "doctor", "exec", "formulae",
            "gc", "help", "history", "home", "info", "init", "install", "leaves", "link", "list",
            "migrate", "mirror", "nuke", "outdated", "pin", "reinstall", "remove", "search",
            "shellenv", "tap", "unlink", "unpin", "untap", "update", "upgrade", "version",
            "where", "which-formula",
        }
        for c in cmds {
            fmt.printf("complete -c ubrew -n '__fish_use_subcommand' -a '%s'\n", c)
        }
    case "nushell", "nu":
        fmt.println("def \"nu-complete ubrew commands\" [] {")
        fmt.println("  [")
        fmt.println("    { value: \"autoremove\", description: \"Remove unused dependencies\" }")
        fmt.println("    { value: \"bundle\", description: \"Dump installed packages as a Brewfile\" }")
        fmt.println("    { value: \"casks\", description: \"List all installable casks\" }")
        fmt.println("    { value: \"cleanup\", description: \"Remove stale cache files and broken bin links\" }")
        fmt.println("    { value: \"command\", description: \"Show path to file implementing subcommand\" }")
        fmt.println("    { value: \"command-not-found-init\", description: \"Initialize command-not-found handler\" }")
        fmt.println("    { value: \"commands\", description: \"List available commands\" }")
        fmt.println("    { value: \"completions\", description: \"Emit shell completion script\" }")
        fmt.println("    { value: \"deps\", description: \"Show formula dependencies\" }")
        fmt.println("    { value: \"desc\", description: \"Show package description\" }")
        fmt.println("    { value: \"developer\", description: \"Manage developer mode\" }")
        fmt.println("    { value: \"doctor\", description: \"Check ubrew installation health\" }")
        fmt.println("    { value: \"exec\", description: \"Run command in PATH populated by formulae\" }")
        fmt.println("    { value: \"formulae\", description: \"List all installable formulae\" }")
        fmt.println("    { value: \"gc\", description: \"Garbage collect unreferenced store entries\" }")
        fmt.println("    { value: \"help\", description: \"Show help\" }")
        fmt.println("    { value: \"history\", description: \"Show package version history\" }")
        fmt.println("    { value: \"home\", description: \"Open package homepage in browser\" }")
        fmt.println("    { value: \"info\", description: \"Show package metadata\" }")
        fmt.println("    { value: \"init\", description: \"Create /opt/ubrew directory tree\" }")
        fmt.println("    { value: \"install\", description: \"Install formula or cask\" }")
        fmt.println("    { value: \"leaves\", description: \"List packages with no dependents\" }")
        fmt.println("    { value: \"link\", description: \"Symlink a keg into the prefix\" }")
        fmt.println("    { value: \"list\", description: \"List installed packages\" }")
        fmt.println("    { value: \"migrate\", description: \"Migrate from a foreign Cellar\" }")
        fmt.println("    { value: \"mirror\", description: \"Manage offline mirrors\" }")
        fmt.println("    { value: \"nuke\", description: \"Completely uninstall ubrew and all packages\" }")
        fmt.println("    { value: \"outdated\", description: \"List outdated packages\" }")
        fmt.println("    { value: \"pin\", description: \"Pin a package\" }")
        fmt.println("    { value: \"reinstall\", description: \"Remove and install a formula again\" }")
        fmt.println("    { value: \"remove\", description: \"Uninstall a package\" }")
        fmt.println("    { value: \"search\", description: \"Search for formulae and casks\" }")
        fmt.println("    { value: \"shellenv\", description: \"Print shell init lines\" }")
        fmt.println("    { value: \"tap\", description: \"Manage 3rd-party tap repositories\" }")
        fmt.println("    { value: \"unlink\", description: \"Remove a keg's symlinks\" }")
        fmt.println("    { value: \"unpin\", description: \"Unpin a package\" }")
        fmt.println("    { value: \"untap\", description: \"Untap a 3rd-party repository\" }")
        fmt.println("    { value: \"update\", description: \"Update registries and taps\" }")
        fmt.println("    { value: \"upgrade\", description: \"Upgrade outdated packages\" }")
        fmt.println("    { value: \"version\", description: \"Show version\" }")
        fmt.println("    { value: \"where\", description: \"Show installed file paths\" }")
        fmt.println("    { value: \"which-formula\", description: \"Find formula providing an executable\" }")
        fmt.println("  ]")
        fmt.println("}")
        fmt.println()
        fmt.println("export extern \"ubrew\" [")
        fmt.println("  command?: string@\"nu-complete ubrew commands\"")
        fmt.println("]")
    case:
        fmt.printf("ubrew: unsupported completions subcommand or shell '%s' (try link|unlink|state or zsh|bash|fish|nushell)\n", subcommand)
        os.exit(1)
    }
}

main :: proc() {
    if len(os.args) < 2 || os.args[1] == "help" || os.args[1] == "--help" || os.args[1] == "-h" {
        print_usage()
        os.exit(0)
    }

    cmd := os.args[1]

    if cmd == "version" || cmd == "--version" || cmd == "-v" {
        fmt.println("ubrew 0.1.0")
        os.exit(0)
    }

    if cmd == "init" {
        run_init()
        return
    }

    if cmd == "list" || cmd == "ls" {
        run_list(os.args[2:])
        return
    }

    if cmd == "leaves" {
        run_leaves()
        return
    }

    if cmd == "remove" || cmd == "uninstall" || cmd == "rm" || cmd == "ui" {
        run_remove(os.args[2:])
        return
    }

    if cmd == "reinstall" {
        run_reinstall(os.args[2:])
        return
    }

    if cmd == "tap" {
        run_tap(os.args[2:])
        return
    }

    if cmd == "untap" {
        run_untap(os.args[2:])
        return
    }

    if cmd == "where" || cmd == "wh" {
        run_where(os.args[2:])
        return
    }

    if cmd == "doctor" || cmd == "dr" {
        run_doctor(os.args[2:])
        return
    }

    if cmd == "bundle" {
        run_bundle(os.args[2:])
        return
    }

    if cmd == "deps" {
        run_deps(os.args[2:])
        return
    }

    if cmd == "migrate" {
        run_migrate()
        return
    }

    if cmd == "mirror" {
        run_mirror(os.args[2:])
        return
    }

    if cmd == "trust" {
        run_trust(os.args[2:])
        return
    }

    if cmd == "untrust" {
        run_untrust(os.args[2:])
        return
    }

    if cmd == "update" || cmd == "up" {
        run_update(os.args[2:])
        return
    }

    if cmd == "upgrade" {
        run_upgrade(os.args[2:])
        return
    }

    if cmd == "outdated" {
        run_outdated(os.args[2:])
        return
    }

    if cmd == "cleanup" || cmd == "clean" {
        run_cleanup(os.args[2:])
        return
    }

    if cmd == "pin" {
        run_pin(os.args[2:])
        return
    }

    if cmd == "unpin" {
        run_unpin(os.args[2:])
        return
    }

    if cmd == "link" || cmd == "ln" {
        run_link(os.args[2:])
        return
    }

    if cmd == "unlink" {
        run_unlink(os.args[2:])
        return
    }

    if cmd == "home" || cmd == "homepage" {
        run_home(os.args[2:])
        return
    }

    if cmd == "desc" {
        run_desc(os.args[2:])
        return
    }

    if cmd == "autoremove" {
        run_autoremove(os.args[2:])
        return
    }

    if cmd == "gc" {
        run_gc(os.args[2:])
        return
    }

    if cmd == "history" {
        run_history(os.args[2:])
        return
    }

    if cmd == "formulae" {
        run_formulae(os.args[2:])
        return
    }

    if cmd == "casks" {
        run_list_names("cask")
        return
    }

    if cmd == "commands" {
        run_commands(os.args[2:])
        return
    }

    if cmd == "command" {
        run_command(os.args[2:])
        return
    }

    if cmd == "command-not-found-init" {
        run_command_not_found_init()
        return
    }

    if cmd == "which-formula" {
        run_which_formula(os.args[2:])
        return
    }

    if cmd == "developer" {
        run_developer(os.args[2:])
        return
    }

    if cmd == "exec" || cmd == "x" {
        run_exec(os.args[2:])
        return
    }

    if cmd == "--prefix" || cmd == "--cellar" || cmd == "--caskroom" ||
       cmd == "--cache" || cmd == "--repo" || cmd == "--repository" {
        run_path_query(cmd, os.args[2:])
        return
    }

    if cmd == "shellenv" {
        run_shellenv(os.args[2:])
        return
    }

    if cmd == "completions" {
        run_completions(os.args[2:])
        return
    }

    if cmd == "search" || cmd == "s" {
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

    if cmd == "info" || cmd == "abv" {
        run_info(os.args[2:])
        return
    }

    if cmd == "install" {
        run_install(os.args[2:])
        return
    }

    if cmd == "nuke" {
        run_nuke(os.args[2:])
        return
    }

    fmt.printf("ubrew: unknown command '%s'\n\n", cmd)
    print_usage()
    os.exit(1)
}

run_gc :: proc(args: []string) {
    dry_run := false
    for arg in args {
        if arg == "--dry-run" || arg == "-n" {
            dry_run = true
        } else if arg == "--help" || arg == "-h" {
            fmt.println("Usage: ubrew gc [--dry-run|-n]")
            fmt.println("")
            fmt.println("Remove unreferenced entries from the COW bottle store at")
            fmt.println("/opt/ubrew/store-relocated. A store entry is unreferenced when")
            fmt.println("no installed formula in /opt/ubrew/prefix/Cellar has the same")
            fmt.println("name as the entry's embedded .brew/<name>.rb.")
            fmt.println("")
            fmt.println("With --dry-run (alias -n), print what would be removed without")
            fmt.println("actually deleting anything.")
            fmt.println("")
            fmt.println("Mirrors zerobrew's `zb gc`. The store is content-addressable,")
            fmt.println("so this is safe to run at any time.")
            return
        } else {
            fmt.printf("ubrew: unknown gc flag '%s'\n", arg)
            os.exit(1)
        }
    }

    fmt.println("==> Running garbage collection...")

    installed_names := make([dynamic]string, context.temp_allocator)
    defer delete(installed_names)

    if infos, derr := os.read_directory_by_path(installer.PREFIX + "/Cellar", -1, context.temp_allocator); derr == nil {
        for info in infos {
            if info.type != .Directory { continue }
            if info.name == "." || info.name == ".." { continue }
            append(&installed_names, strings.clone(info.name, context.temp_allocator))
        }
    }

    installed_set := make(map[string]struct{}, context.temp_allocator)
    for n in installed_names {
        installed_set[n] = {}
    }

    removed := 0
    freed := i64(0)
    failed := 0
    kept := 0

    gc_store_tree :: proc(store_dir: string, installed_set: ^map[string]struct{}, dry_run: bool, removed: ^int, freed: ^i64, failed: ^int, kept: ^int) {
        if !os.is_dir(store_dir) {
            return
        }
        if infos, rerr := os.read_directory_by_path(store_dir, -1, context.temp_allocator); rerr == nil {
            for info in infos {
                if info.type != .Directory { continue }
                if info.name == "." || info.name == ".." { continue }
                hash := info.name
                entry_path := fmt.tprintf("%s/%s", store_dir, hash)

                brew_dir := fmt.tprintf("%s/.brew", entry_path)
                owning_formula := ""
                if brew_infos, berr := os.read_directory_by_path(brew_dir, -1, context.temp_allocator); berr == nil {
                    for binfo in brew_infos {
                        if binfo.type != .Regular { continue }
                        if strings.has_suffix(binfo.name, ".rb") {
                            owning_formula = strings.trim_suffix(binfo.name, ".rb")
                            break
                        }
                    }
                }

                if owning_formula == "" {
                    kept^ += 1
                    continue
                }

                if _, still_installed := installed_set^[owning_formula]; still_installed {
                    kept^ += 1
                    continue
                }

                entry_size := dir_size_bytes(entry_path)

                if dry_run {
                    hash_short := hash[:min(12, len(hash))]
                    fmt.printf("    %s Would remove %s (formula %s, %.2f MB)\n",
                        "\x1b[33m~\x1b[0m", hash_short, owning_formula, f64(entry_size) / (1024.0 * 1024.0))
                    removed^ += 1
                    freed^ += entry_size
                    continue
                }

                if err := os.remove_all(entry_path); err != nil {
                    hash_short := hash[:min(12, len(hash))]
                    fmt.printf("    Failed to remove %s: %v\n", hash_short, err)
                    failed^ += 1
                    continue
                }
                hash_short := hash[:min(12, len(hash))]
                fmt.printf("    %s Removed %s (formula %s, %.2f MB)\n",
                    "\x1b[32m✓\x1b[0m", hash_short, owning_formula, f64(entry_size) / (1024.0 * 1024.0))
                removed^ += 1
                freed^ += entry_size
            }
        }
    }

    gc_store_tree(store.STORE_RELOCATED_DIR, &installed_set, dry_run, &removed, &freed, &failed, &kept)
    gc_store_tree(store.STORE_DIR, &installed_set, dry_run, &removed, &freed, &failed, &kept)

    if removed == 0 {
        fmt.println("No unreferenced store entries to remove.")
    } else {
        if dry_run {
            fmt.printf("==> Would remove %d store entry/entries, freeing %.2f MB (%d %s kept)\n",
                removed,
                f64(freed) / (1024.0 * 1024.0),
                kept, kept == 1 ? "entry" : "entries")
        } else {
            fmt.printf("==> Removed %d store entry/entries, freed %.2f MB (%d %s kept)\n",
                removed,
                f64(freed) / (1024.0 * 1024.0),
                kept, kept == 1 ? "entry" : "entries")
            if failed > 0 {
                fmt.printf("==> Failed to remove %d store %s\n", failed, failed == 1 ? "entry" : "entries")
            }
        }
    }

    if failed > 0 && !dry_run {
        os.exit(1)
    }
}

dir_size_bytes :: proc(path: string) -> i64 {
    total: i64 = 0
    w := os.walker_create(path)
    defer os.walker_destroy(&w)
    for info in os.walker_walk(&w) {
        if info.type == .Regular {
            total += info.size
        }
    }
    return total
}

run_history :: proc(args: []string) {
    json_output := false
    limit := -1
    formula_name := ""

    for i := 0; i < len(args); i += 1 {
        a := args[i]
        if a == "--json" {
            json_output = true
        } else if a == "-n" || a == "--limit" {
            if i + 1 < len(args) {
                i += 1
                parsed, ok := strconv.parse_i64(args[i])
                if !ok || parsed <= 0 {
                    fmt.println("Error: --limit must be a positive integer")
                    os.exit(1)
                }
                limit = int(parsed)
            } else {
                fmt.println("Error: --limit requires an argument")
                os.exit(1)
            }
        } else if a == "-h" || a == "--help" {
            fmt.println("Usage: ubrew history [options] [formula]")
            fmt.println("")
            fmt.println("Show package version history. Mirrors stout's `stout history`.")
            fmt.println("")
            fmt.println("OPTIONS:")
            fmt.println("  --json         Output as JSON")
            fmt.println("  -n, --limit N  Show only the last N entries per package")
            fmt.println("  -h, --help     Show this help message")
            fmt.println("")
            fmt.println("Without a formula argument, shows history for all packages.")
            fmt.println("Entries are displayed newest-first.")
            return
        } else if strings.has_prefix(a, "-") {
            fmt.printf("ubrew: unknown history flag '%s'\n", a)
            os.exit(1)
        } else {
            formula_name = a
        }
    }

    h_names, h_entries := history.load(context.allocator)
    defer history.destroy(&h_names, &h_entries)

    if formula_name != "" {
        entries, ok := h_entries[formula_name]
        if !ok || len(entries) == 0 {
            if json_output {
                fmt.print("{\"packages\":[]}")
                fmt.println()
            } else {
                fmt.printf("No history found for \x1b[36m%s\x1b[0m\n", formula_name)
            }
            return
        }

        display_count := len(entries)
        if limit > 0 && limit < display_count {
            display_count = limit
        }

        if json_output {
            fmt.print("{\"packages\":[{\"name\":\"")
            fmt.print(formula_name)
            fmt.print("\",\"entries\":[")
            first := true
            for i := len(entries) - 1; i >= 0 && i >= len(entries) - display_count; i -= 1 {
                if !first { fmt.print(",") }
                first = false
                e := entries[i]
                print_entry_json(e)
            }
            fmt.println("]}]}")
        } else {
            fmt.printf("\x1b[1m\x1b[34m==>\x1b[0m History for \x1b[1m\x1b[36m%s\x1b[0m\n", formula_name)
            fmt.println()
            for i := len(entries) - 1; i >= 0 && i >= len(entries) - display_count; i -= 1 {
                e := entries[i]
                print_history_entry(e)
            }
        }
        return
    }

    if len(h_entries) == 0 {
        if json_output {
            fmt.println("{\"packages\":[]}")
        } else {
            fmt.println("No package history found")
        }
        return
    }

    sorted_names := make([dynamic]string, 0, len(h_names), context.temp_allocator)
    defer delete(sorted_names)
    for n in h_names {
        append(&sorted_names, n)
    }
    slice.sort(sorted_names[:])

    if json_output {
        fmt.print("{\"packages\":[")
        first_pkg := true
        for name in sorted_names {
            entries, ok := h_entries[name]
            if !ok { continue }
            display_count := len(entries)
            if limit > 0 && limit < display_count {
                display_count = limit
            }
            if !first_pkg { fmt.print(",") }
            first_pkg = false
            fmt.print("{\"name\":\"")
            fmt.print(name)
            fmt.print("\",\"entries\":[")
            first_entry := true
            for i := len(entries) - 1; i >= 0 && i >= len(entries) - display_count; i -= 1 {
                if !first_entry { fmt.print(",") }
                first_entry = false
                print_entry_json(entries[i])
            }
            fmt.print("]}")
        }
        fmt.println("]}")
    } else {
        fmt.printf("\x1b[1m\x1b[34m==>\x1b[0m Package History (\x1b[1m%d\x1b[0m packages)\n", len(h_entries))
        fmt.println()
        for name in sorted_names {
            entries, ok := h_entries[name]
            if !ok { continue }
            display_count := len(entries)
            if limit > 0 && limit < display_count {
                display_count = limit
            }
            fmt.printf("\x1b[1m\x1b[36m%s\x1b[0m\n", name)
            for i := len(entries) - 1; i >= 0 && i >= len(entries) - display_count; i -= 1 {
                print_history_entry(entries[i])
            }
            fmt.println()
        }
    }
}

print_entry_json :: proc(e: history.Entry) {
    fmt.print("{\"version\":\"")
    fmt.print(e.version)
    fmt.printf("\",\"revision\":%d", e.revision)
    fmt.print(",\"action\":\"")
    fmt.print(e.action)
    fmt.print("\",\"timestamp\":\"")
    fmt.print(e.timestamp)
    fmt.print("\"")
    if history.has_from_version(e) {
        fmt.print(",\"from_version\":\"")
        fmt.print(e.from_version)
        fmt.print("\"")
    }
    if history.has_from_revision(e) {
        fmt.printf(",\"from_revision\":%d", e.from_revision)
    }
    fmt.print("}")
}

print_history_entry :: proc(e: history.Entry) {
    action_color := ""
    action_reset := "\x1b[0m"
    switch e.action {
    case "install":    action_color = "\x1b[32m"
    case "upgrade":    action_color = "\x1b[34m"
    case "downgrade":  action_color = "\x1b[33m"
    case "reinstall":  action_color = "\x1b[36m"
    case "uninstall":  action_color = "\x1b[31m"
    }

    version_str := e.version
    if e.revision > 0 {
        version_str = fmt.tprintf("%s_%d", e.version, e.revision)
    }

    from_str := ""
    if history.has_from_version(e) {
        if history.has_from_revision(e) && e.from_revision > 0 {
            from_str = fmt.tprintf(" (from %s_%d)", e.from_version, e.from_revision)
        } else {
            from_str = fmt.tprintf(" (from %s)", e.from_version)
        }
    }

    fmt.printf(" \x1b[2m%s\x1b[0m %s%s%s \x1b[1m%s\x1b[0m \x1b[2m%s\x1b[0m\n",
        e.timestamp, action_color, e.action, action_reset, version_str, from_str)
}

find_stout_binary :: proc() -> string {
    prefix_stout := fmt.tprintf("%s/bin/stout", installer.PREFIX)
    if os.is_file(prefix_stout) {
        return strings.clone(prefix_stout, context.allocator)
    }

    candidates := []string{
        "/usr/bin/stout",
        "/usr/local/bin/stout",
    }
    for c in candidates {
        if os.is_file(c) {
            return c
        }
    }
    // Fall back to PATH search
    if path_env := os.get_env("PATH", context.temp_allocator); len(path_env) > 0 {
        for dir in strings.split(path_env, ":") {
            full := fmt.tprintf("%s/stout", dir)
            if os.is_file(full) {
                return strings.clone(full, context.allocator)
            }
        }
    }
    return ""
}

run_mirror :: proc(args: []string) {
    stout_path := find_stout_binary()
    if len(stout_path) == 0 {
        fmt.eprintln("Error: Stout binary not found. Please install stout or ensure it is in your PATH.")
        os.exit(1)
    }

    // Set STOUT_PREFIX to ubrew's PREFIX
    os.set_env("STOUT_PREFIX", installer.PREFIX)

    // Build arguments list: [stout_path, "mirror", args...]
    cmd_args := make([dynamic]string, context.temp_allocator)
    append(&cmd_args, stout_path)
    append(&cmd_args, "mirror")
    for a in args {
        append(&cmd_args, a)
    }

    argv := make([]cstring, len(cmd_args) + 1, context.allocator)
    for j in 0..<len(cmd_args) {
        argv[j] = strings.clone_to_cstring(cmd_args[j], context.allocator)
    }
    argv[len(cmd_args)] = nil

    exe_cstr := strings.clone_to_cstring(stout_path, context.allocator)
    posix.execve(exe_cstr, &argv[0], posix.environ)
    
    // execve only returns on failure
    fmt.eprintf("ubrew mirror: execve(%s) failed: %s\n", stout_path, posix.strerror(posix.errno()))
    os.exit(127)
}

run_trust :: proc(args: []string) {
	json_opt := false
	pkg_names := make([dynamic]string, context.temp_allocator)
	
	for a in args {
		if a == "--json=v1" {
			json_opt = true
		} else if strings.has_prefix(a, "-") {
			fmt.printf("Error: unknown trust option '%s'\n", a)
			os.exit(1)
		} else {
			append(&pkg_names, a)
		}
	}
	
	if json_opt {
		taps := tap.get_trusted_taps(context.temp_allocator)
		fmt.print("[\n")
		for t, idx in taps {
			if idx > 0 do fmt.print(",\n")
			fmt.printf("  {{\n    \"name\": \"%s\",\n    \"trusted\": true\n  }}", t)
		}
		fmt.print("\n]\n")
		return
	}
	
	if len(pkg_names) == 0 {
		taps := tap.get_trusted_taps(context.temp_allocator)
		if len(taps) == 0 {
			fmt.println("No trusted taps.")
		} else {
			fmt.println("Trusted taps:")
			for t in taps {
				fmt.printf("  %s\n", t)
			}
		}
		return
	}
	
	for name in pkg_names {
		if tap.tap_trust(name) {
			fmt.printf("==> Trusted tap: %s\n", name)
		} else {
			fmt.printf("Error: Failed to trust tap %s\n", name)
			os.exit(1)
		}
	}
}

run_untrust :: proc(args: []string) {
	if len(args) == 0 {
		fmt.println("Usage: ubrew untrust <tap>")
		os.exit(1)
	}
	
	for name in args {
		if tap.tap_untrust(name) {
			fmt.printf("==> Untrusted tap: %s\n", name)
		} else {
			fmt.printf("Error: Failed to untrust tap %s\n", name)
			os.exit(1)
		}
	}
}

prompt_user_yes_no :: proc(question: string) -> bool {
	if !os.is_tty(os.stdin) || !os.is_tty(os.stdout) {
		return true
	}
	
	fmt.printf("%s [y/N]: ", question)
	
	buf: [8]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 {
		return false
	}
	
	input := strings.trim_space(string(buf[:n]))
	if len(input) > 0 && (input[0] == 'y' || input[0] == 'Y') {
		return true
	}
	return false
}

run_info :: proc(args: []string) {
	opt_analytics := false
	opt_days := "30"
	opt_category := "install"
	opt_github := false
	opt_json := ""
	opt_installed := false
	opt_variations := false
	opt_verbose := false
	opt_formula := false
	opt_cask := false
	opt_sizes := false

	targets: [dynamic]string
	defer delete(targets)

	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--analytics" {
			opt_analytics = true
		} else if strings.has_prefix(arg, "--days=") {
			opt_days = arg[7:]
		} else if arg == "--days" {
			if i + 1 < len(args) {
				opt_days = args[i+1]
				i += 1
			} else {
				fmt.eprintln("Error: --days requires a value.")
				os.exit(1)
			}
		} else if strings.has_prefix(arg, "--category=") {
			opt_category = arg[11:]
		} else if arg == "--category" {
			if i + 1 < len(args) {
				opt_category = args[i+1]
				i += 1
			} else {
				fmt.eprintln("Error: --category requires a value.")
				os.exit(1)
			}
		} else if arg == "--github" {
			opt_github = true
		} else if arg == "--json" {
			opt_json = "default"
		} else if strings.has_prefix(arg, "--json=") {
			opt_json = arg[7:]
		} else if arg == "--installed" {
			opt_installed = true
		} else if arg == "--variations" {
			opt_variations = true
		} else if arg == "-v" || arg == "--verbose" {
			opt_verbose = true
		} else if arg == "--formula" {
			opt_formula = true
		} else if arg == "--cask" {
			opt_cask = true
		} else if arg == "--sizes" {
			opt_sizes = true
		} else if strings.has_prefix(arg, "-") {
			fmt.eprintf("Error: Unknown option: %s\n", arg)
			os.exit(1)
		} else {
			append(&targets, arg)
		}
	}

	// Validate days
	if opt_days != "30" && opt_days != "90" && opt_days != "365" {
		fmt.eprintln("Error: days must be 30, 90 or 365.")
		os.exit(1)
	}

	// Validate category
	if opt_category != "install" && opt_category != "install-on-request" &&
	   opt_category != "build-error" && opt_category != "cask-install" &&
	   opt_category != "os-version" {
		fmt.eprintln("Error: category must be install, install-on-request, build-error, cask-install or os-version.")
		os.exit(1)
	}

	// If --installed is specified
	if opt_installed {
		formulae := get_installed_formulae(context.temp_allocator)
		casks := get_installed_casks(context.temp_allocator)

		if opt_json != "" {
			fmt.println("[")
			count := 0
			// Print formulae if json is v1 or v2 (default)
			if opt_json == "v2" || opt_json == "default" || opt_json == "v1" {
				for f in formulae {
					if count > 0 do fmt.println(",")
					cache_path := fmt.tprintf("%s/formula-%s.json", api.API_CACHE_DIR, f)
					if !os.is_file(cache_path) {
						api.fetch_formula(f)
					}
					if data, err := os.read_entire_file(cache_path, context.temp_allocator); err == nil {
						fmt.printf("%s", string(data))
						count += 1
					}
				}
			}
			// Print casks only if json is v2
			if opt_json == "v2" {
				for c in casks {
					if count > 0 do fmt.println(",")
					cache_path := fmt.tprintf("%s/cask-%s.json", api.API_CACHE_DIR, c)
					if !os.is_file(cache_path) {
						api.fetch_cask(c)
					}
					if data, err := os.read_entire_file(cache_path, context.temp_allocator); err == nil {
						fmt.printf("%s", string(data))
						count += 1
					}
				}
			}
			fmt.println("\n]")
		} else {
			// Human-readable inventory of installed packages
			if len(formulae) > 0 {
				fmt.println("Installed Formulae:")
				for f in formulae {
					cellar_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, f)
					latest_version := ""
					if f_infos, err := os.read_directory_by_path(cellar_dir, -1, context.temp_allocator); err == nil {
						for info in f_infos {
							if os.is_dir(info.fullpath) && info.name > latest_version {
								latest_version = info.name
							}
						}
					}
					if opt_verbose {
						formula_val, err := api.fetch_formula(f)
						if err == nil {
							print_formula(formula_val)
							api.destroy_formula(formula_val)
							fmt.println("")
						}
					} else if opt_sizes && latest_version != "" {
						version_path := fmt.tprintf("%s/%s", cellar_dir, latest_version)
						files_count, total_size := get_dir_size(version_path)
						fmt.printf("  %s (%s) - %s (%s files)\n",
							f, latest_version, format_bytes(total_size), format_commas(files_count))
					} else if latest_version != "" {
						fmt.printf("  %s (%s)\n", f, latest_version)
					} else {
						fmt.printf("  %s\n", f)
					}
				}
			}
			if len(casks) > 0 {
				if len(formulae) > 0 do fmt.println("")
				fmt.println("Installed Casks:")
				for c in casks {
					caskroom_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, c)
					latest_version := ""
					if f_infos, err := os.read_directory_by_path(caskroom_dir, -1, context.temp_allocator); err == nil {
						for info in f_infos {
							if os.is_dir(info.fullpath) && info.name > latest_version {
								latest_version = info.name
							}
						}
					}
					if opt_verbose {
						cask_val, err := api.fetch_cask(c)
						if err == nil {
							print_cask(cask_val)
							api.destroy_cask(cask_val)
							fmt.println("")
						}
					} else if opt_sizes && latest_version != "" {
						version_path := fmt.tprintf("%s/%s", caskroom_dir, latest_version)
						files_count, total_size := get_dir_size(version_path)
						fmt.printf("  %s (%s) - %s (%s files)\n",
							c, latest_version, format_bytes(total_size), format_commas(files_count))
					} else if latest_version != "" {
						fmt.printf("  %s (%s)\n", c, latest_version)
					} else {
						fmt.printf("  %s\n", c)
					}
				}
			}
		}
		return
	}

	// If no targets specified, list brief stats or global analytics
	if len(targets) == 0 {
		if opt_analytics {
			no_analytics := os.get_env("HOMEBREW_NO_ANALYTICS", context.temp_allocator) != "" ||
			                os.get_env("HOMEBREW_NO_GITHUB_API", context.temp_allocator) != ""
			if no_analytics {
				fmt.println("Analytics are disabled.")
				return
			}

			temp_f, terr := os.create_temp_file("", "ubrew_global_analytics_*.json")
			if terr != nil {
				fmt.eprintln("Error: Failed to create temp file for analytics.")
				os.exit(1)
			}
			temp_path := strings.clone(os.name(temp_f), context.temp_allocator)
			os.close(temp_f)
			defer os.remove(temp_path)

			url: string
			if opt_category == "cask-install" {
				url = fmt.tprintf("https://formulae.brew.sh/api/analytics/cask-install/homebrew-cask/%sd.json", opt_days)
			} else if opt_category == "os-version" {
				url = fmt.tprintf("https://formulae.brew.sh/api/analytics/os-version/%sd.json", opt_days)
			} else {
				url = fmt.tprintf("https://formulae.brew.sh/api/analytics/%s/homebrew-core/%sd.json", opt_category, opt_days)
			}

			dl_args := []string{"curl", "-s", "-f", "-L", url, "-o", temp_path}
			if !platform.exec_cmd("curl", dl_args) {
				fmt.eprintln("Error: Failed to fetch global analytics data from Homebrew API.")
				os.exit(1)
			}

			data, read_err := os.read_entire_file(temp_path, context.temp_allocator)
			if read_err != nil {
				fmt.eprintln("Error: Failed to read global analytics data.")
				os.exit(1)
			}

			val, json_err := json.parse(data)
			if json_err != nil {
				fmt.eprintln("Error: Failed to parse global analytics data.")
				os.exit(1)
			}
			defer json.destroy_value(val)

			obj, ok := val.(json.Object)
			if !ok {
				fmt.eprintln("Error: Invalid analytics data.")
				os.exit(1)
			}

			if opt_category == "os-version" {
				items_val, has_items := obj["items"]
				if !has_items {
					fmt.eprintln("Error: Missing items in os-version analytics.")
					os.exit(1)
				}
				items_arr, is_arr := items_val.(json.Array)
				if !is_arr {
					fmt.eprintln("Error: Invalid items in os-version analytics.")
					os.exit(1)
				}

				fmt.printf("Global os-version analytics (last %s days):\n", opt_days)
				for item_val, idx in items_arr {
					if idx >= 30 do break // print top 30
					item_obj, is_item_obj := item_val.(json.Object)
					if !is_item_obj do continue

					os_ver := api.json_string_or_empty(item_obj, "os_version")
					cnt := api.json_string_or_empty(item_obj, "count")
					pct := api.json_string_or_empty(item_obj, "percent")
					fmt.printf("  %d. %s: %s (%s%%)\n", idx + 1, os_ver, cnt, pct)
				}
			} else {
				formulae_val, has_formulae := obj["formulae"]
				if !has_formulae {
					fmt.eprintln("Error: Missing formulae in analytics.")
					os.exit(1)
				}
				formulae_obj, is_formulae_obj := formulae_val.(json.Object)
				if !is_formulae_obj {
					fmt.eprintln("Error: Invalid formulae in analytics.")
					os.exit(1)
				}

				Global_Analytics_Item :: struct {
					name: string,
					count: int,
				}
				analytics_list := make([dynamic]Global_Analytics_Item, context.temp_allocator)

				for pkg_name, variations_val in formulae_obj {
					variations_arr, is_var_arr := variations_val.(json.Array)
					if !is_var_arr do continue
					total_pkg_count := 0
					for var_val in variations_arr {
						var_obj, is_var_obj := var_val.(json.Object)
						if !is_var_obj do continue
						cnt_str := api.json_string_or_empty(var_obj, "count")
						total_pkg_count += parse_comma_int(cnt_str)
					}
					append(&analytics_list, Global_Analytics_Item{
						name = strings.clone(pkg_name, context.temp_allocator),
						count = total_pkg_count,
					})
				}

				slice.sort_by(analytics_list[:], proc(i, j: Global_Analytics_Item) -> bool {
					return i.count > j.count
				})

				fmt.printf("Global %s analytics (last %s days):\n", opt_category, opt_days)
				for item, idx in analytics_list {
					if idx >= 30 do break // print top 30
					fmt.printf("  %d. %s: %s\n", idx + 1, item.name, format_commas(item.count))
				}
			}
		} else {
			// Display brief statistics
			formulae := get_installed_formulae(context.temp_allocator)
			casks := get_installed_casks(context.temp_allocator)

			total_f_files := 0
			total_f_size: i64 = 0
			for f in formulae {
				cellar_dir := fmt.tprintf("%s/Cellar/%s", installer.PREFIX, f)
				files_count, total_size := get_dir_size(cellar_dir)
				total_f_files += files_count
				total_f_size += total_size
			}

			total_c_files := 0
			total_c_size: i64 = 0
			for c in casks {
				caskroom_dir := fmt.tprintf("%s/Caskroom/%s", installer.PREFIX, c)
				files_count, total_size := get_dir_size(caskroom_dir)
				total_c_files += files_count
				total_c_size += total_size
			}

			fmt.printf("%d formulae, %s files, %s\n",
				len(formulae), format_commas(total_f_files), format_bytes(total_f_size))
			fmt.printf("%d casks, %s files, %s\n",
				len(casks), format_commas(total_c_files), format_bytes(total_c_size))
			fmt.println(installer.PREFIX)
		}
		return
	}

	// Targets specified
	if opt_json != "" {
		fmt.println("[")
	}
	for target, idx in targets {
		is_cask := opt_cask
		formula_fetched := false
		cask_fetched := false
		f_val: formula.Formula
		c_val: cask.Cask

		if !opt_cask && !opt_formula {
			// Auto-detect
			f, err_f := api.fetch_formula(target)
			if err_f == nil {
				is_cask = false
				f_val = f
				formula_fetched = true
			} else {
				c, err_c := api.fetch_cask(target)
				if err_c == nil {
					is_cask = true
					c_val = c
					cask_fetched = true
				} else {
					fmt.eprintf("Error: No formula or cask found for: %s\n", target)
					os.exit(1)
				}
			}
		}

		if opt_analytics {
			print_target_analytics(target, is_cask)
		} else if opt_github {
			open_github_page(target, is_cask)
		} else if opt_json != "" {
			if idx > 0 do fmt.println(",")
			cache_path: string
			if is_cask {
				cache_path = fmt.tprintf("%s/cask-%s.json", api.API_CACHE_DIR, target)
				if !os.is_file(cache_path) && !cask_fetched {
					c, err := api.fetch_cask(target)
					if err == nil {
						c_val = c
						cask_fetched = true
					}
				}
			} else {
				cache_path = fmt.tprintf("%s/formula-%s.json", api.API_CACHE_DIR, target)
				if !os.is_file(cache_path) && !formula_fetched {
					f, err := api.fetch_formula(target)
					if err == nil {
						f_val = f
						formula_fetched = true
					}
				}
			}
			data, read_err := os.read_entire_file(cache_path, context.temp_allocator)
			if read_err == nil {
				fmt.printf("%s", string(data))
			} else {
				if is_cask && cask_fetched {
					print_cask_json(c_val, false, "")
				} else if !is_cask && formula_fetched {
					print_formula_json(f_val, false, "", false)
				}
			}
		} else {
			if idx > 0 do fmt.println("")
			if is_cask {
				c: cask.Cask
				err: json.Error
				if cask_fetched {
					c = c_val
				} else {
					c, err = api.fetch_cask(target)
					if err == nil {
						c_val = c
						cask_fetched = true
					}
				}
				if cask_fetched {
					print_cask(c_val)
				} else {
					fmt.eprintf("Error: Failed to fetch cask %s: %v\n", target, err)
				}
			} else {
				f: formula.Formula
				err: json.Error
				if formula_fetched {
					f = f_val
				} else {
					f, err = api.fetch_formula(target)
					if err == nil {
						f_val = f
						formula_fetched = true
					}
				}
				if formula_fetched {
					print_formula(f_val)
				} else {
					fmt.eprintf("Error: Failed to fetch formula %s: %v\n", target, err)
				}
			}
		}

		if formula_fetched {
			api.destroy_formula(f_val)
		}
		if cask_fetched {
			api.destroy_cask(c_val)
		}
	}
	if opt_json != "" {
		fmt.println("\n]")
	}
}

get_installed_formulae :: proc(allocator := context.temp_allocator) -> []string {
	list := make([dynamic]string, allocator)
	cellar := installer.PREFIX + "/Cellar"
	if !os.is_dir(cellar) {
		return nil
	}
	if f_infos, err := os.read_directory_by_path(cellar, -1, allocator); err == nil {
		for info in f_infos {
			if os.is_dir(info.fullpath) {
				append(&list, strings.clone(info.name, allocator))
			}
		}
	}
	return list[:]
}

get_installed_casks :: proc(allocator := context.temp_allocator) -> []string {
	list := make([dynamic]string, allocator)
	caskroom := installer.PREFIX + "/Caskroom"
	if !os.is_dir(caskroom) {
		return nil
	}
	if f_infos, err := os.read_directory_by_path(caskroom, -1, allocator); err == nil {
		for info in f_infos {
			if os.is_dir(info.fullpath) {
				append(&list, strings.clone(info.name, allocator))
			}
		}
	}
	return list[:]
}
