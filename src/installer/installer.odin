package installer

import "core:fmt"
import "core:os"
import "core:c/libc"
import "core:strings"
import "core:crypto/hash"
import "core:encoding/hex"
import "../cask"
import "../formula"
import "../kernel"
import "../store"
import "../platform"

when ODIN_ARCH == .amd64 {
	INTERPRETER :: "/lib64/ld-linux-x86-64.so.2"
} else when ODIN_ARCH == .arm64 {
	INTERPRETER :: "/lib/ld-linux-aarch64.so.1"
} else {
	INTERPRETER :: "/lib64/ld-linux-x86-64.so.2"
}

UBREW_ROOT :: "/opt/ubrew"
PREFIX :: UBREW_ROOT + "/prefix"
CACHE_DIR :: UBREW_ROOT + "/cache"
CASKROOM_DIR :: PREFIX + "/Caskroom"

ensure_dir :: proc(path: string) -> bool {
	if err := os.make_directory_all(path, os.perm(0o755)); err != nil {
		if os.is_dir(path) {
			return true
		}
		fmt.printf("Error: failed to create %s: %v\n", path, err)
		return false
	}
	return true
}

expand_home :: proc(path: string, allocator := context.allocator) -> string {
	home_dir := os.get_env("HOME", context.temp_allocator)
	if home_dir == "" {
		return strings.clone(path, allocator)
	}
	res1, _ := strings.replace_all(path, "~", home_dir, context.temp_allocator)
	res2, _ := strings.replace_all(res1, "$HOME", home_dir, allocator)
	return res2
}

dir_name :: proc(path: string) -> string {
	idx := strings.last_index_byte(path, '/')
	if idx == -1 {
		return "."
	}
	return path[:idx]
}

Desktop_Env :: enum {
	Unknown,
	GNOME,
	KDE,
	Sway,
	Hyprland,
	Cinnamon,
	MATE,
	XFCE,
}

detect_desktop :: proc() -> Desktop_Env {
	desktop := strings.to_lower(os.get_env("XDG_CURRENT_DESKTOP", context.temp_allocator), context.temp_allocator)
	session := strings.to_lower(os.get_env("XDG_SESSION_DESKTOP", context.temp_allocator), context.temp_allocator)
	de := desktop
	if len(de) == 0 {
		de = session
	}

	if strings.contains(de, "gnome") { return .GNOME }
	if strings.contains(de, "kde") || strings.contains(de, "plasma") { return .KDE }
	if strings.contains(de, "sway") { return .Sway }
	if strings.contains(de, "hyprland") { return .Hyprland }
	if strings.contains(de, "cinnamon") { return .Cinnamon }
	if strings.contains(de, "mate") { return .MATE }
	if strings.contains(de, "xfce") { return .XFCE }

	return .Unknown
}

wallpaper_product_name :: proc(token: string) -> string {
	base := os.base(token)
	base = strings.trim_suffix(base, "-wallpapers")
	base = strings.trim_suffix(base, "-wallpapers-extra")
	base = strings.trim_suffix(base, "-extra")
	return base
}

wallpaper_install_dir :: proc(home_dir: string, product: string, de: Desktop_Env) -> string {
	#partial switch de {
	case .KDE:
		return fmt.tprintf("%s/.local/share/wallpapers/%s", home_dir, product)
	}
	return fmt.tprintf("%s/.local/share/backgrounds/%s", home_dir, product)
}

install_bottle :: proc(f: formula.Formula, prefix: string) -> bool {
	fmt.printf("==> Installing bottle: %s %s\n", f.name, f.version)

	if len(f.bottle_url) == 0 {
		fmt.println("Error: No bottle URL available for this platform.")
		return false
	}

	sha := strings.to_lower(strings.trim_space(f.bottle_sha256), context.temp_allocator)

	if store.store_has_entry(sha) {
		fmt.printf("==> Found cached store entry for %s, materializing via COW...\n", sha[:12])
		_ = store.store_ensure_dir()
		if store.store_materialize_from_relocated(sha, f.name, f.version) {
			fmt.printf("==> Materialized %s from store via COW\n", f.name)
			return true
		}
		fmt.println("==> COW materialization failed, falling back to full install")
	}

	if !ensure_dir(CACHE_DIR) || !ensure_dir(PREFIX + "/Cellar") || !ensure_dir(PREFIX + "/bin") {
		fmt.println("Error: run `sudo ubrew init`, then ensure /opt/ubrew is writable by your user.")
		return false
	}

	dl_path := fmt.tprintf("%s/%s-%s.bottle.tar.gz", CACHE_DIR, f.name, f.version)
	fmt.printf("==> Downloading: %s\n", f.bottle_url)

	if !strings.has_prefix(f.bottle_url, "http://") && !strings.has_prefix(f.bottle_url, "https://") {
		fmt.println("Error: Invalid bottle URL scheme.")
		return false
	}

	dl_args := []string{"curl", "-H", "Authorization: Bearer QQ==", "-L", f.bottle_url, "-o", dl_path}
	if !platform.exec_cmd("curl", dl_args) {
		fmt.println("Error: Download failed.")
		return false
	}
	defer os.remove(dl_path)

	fmt.printf("==> Creating prefix: %s\n", prefix)
	if !ensure_dir(prefix) {
		return false
	}

	cellar_dir := PREFIX + "/Cellar"
	keg_dir := fmt.tprintf("%s/%s/%s", cellar_dir, f.name, f.version)
	_ = os.remove_all(keg_dir)

	fmt.printf("==> Unpacking to: %s\n", cellar_dir)
	ex_args := []string{"tar", "-xzf", dl_path, "-C", cellar_dir}
	if !platform.exec_cmd("tar", ex_args) {
		if !ensure_dir(keg_dir) {
			return false
		}
		ex_fallback_args := []string{"tar", "-xzf", dl_path, "--strip-components=2", "-C", keg_dir}
		if !platform.exec_cmd("tar", ex_fallback_args) {
			fmt.println("Error: Extraction failed.")
			return false
		}
	}

	fmt.println("==> Performing native binary relocation...")
	binary_path := fmt.tprintf("%s/bin/%s", keg_dir, f.name)
	if os.is_file(binary_path) {
		chmod_args := []string{"chmod", "+w", binary_path}
		platform.exec_cmd("chmod", chmod_args)

		patch_args := []string{"patchelf", "--set-interpreter", INTERPRETER, binary_path}
		if platform.exec_cmd("patchelf", patch_args) {
			fmt.printf("==> Successfully relocated %s binary interpreter!\n", f.name)
		} else {
			fmt.printf("==> Warning: patchelf failed to relocate %s (may not be dynamically linked or interpreter already correct)\n", f.name)
		}
	}

	// The formula's primary binary may be named differently from the formula token
	// (e.g. `dash-shell` installs a binary called `dash`). Walk the keg bin dir and
	// patchelf every executable so the interpreter is correct before symlinking.
	relocated_bin_count := 0
	keg_bin_dir := fmt.tprintf("%s/bin", keg_dir)
	if os.is_dir(keg_bin_dir) {
		if infos, dir_err := os.read_directory_by_path(keg_bin_dir, -1, context.temp_allocator); dir_err == nil {
			defer os.file_info_slice_delete(infos, context.allocator)
			for info in infos {
				if info.type != .Regular {
					continue
				}
				full := info.fullpath
				if full == binary_path {
					continue
				}
				chmod_args := []string{"chmod", "+w", full}
				platform.exec_cmd("chmod", chmod_args)
				patch_args := []string{"patchelf", "--set-interpreter", INTERPRETER, full}
				if platform.exec_cmd("patchelf", patch_args) {
					relocated_bin_count += 1
				}
			}
			if relocated_bin_count > 0 {
				fmt.printf("==> Relocated %d additional binary interpreter(s)\n", relocated_bin_count)
			}
		}
	}

	bin_dir := fmt.tprintf("%s/bin", keg_dir)
	if os.is_dir(bin_dir) {
		fd, fd_err := os.open(bin_dir)
		if fd_err == nil {
			defer os.close(fd)
			infos, read_err := os.read_directory_by_path(bin_dir, -1, context.temp_allocator)
			if read_err == nil {
				for info in infos {
					if info.type == .Regular {
						src_file := info.fullpath
						dst_file := fmt.tprintf("%s/bin/%s", prefix, info.name)
						os.remove(dst_file)
						sym_err := os.symlink(src_file, dst_file)
						if sym_err != nil {
							fmt.printf("Error linking binary %s: %v\n", info.name, sym_err)
							return false
						}
					}
				}
			} else {
				fmt.println("Error reading binary directory.")
				return false
			}
		} else {
			fmt.println("Error: Linking binaries failed.")
			return false
		}
	}

	if store.is_valid_sha256(sha) {
		_ = store.store_ensure_dir()
		if store.store_save_relocated_entry(sha, f.name, f.version) {
			fmt.printf("==> Saved store entry %s via COW\n", sha[:12])
		}
	}

	fmt.printf("==> Successful installation of %s into %s!\n", f.name, keg_dir)
	return true
}

Build_System :: enum {
	CMake,
	Autotools,
	Meson,
	Make,
	Unknown,
}

detect_build_system :: proc(dir: string) -> Build_System {
	cmake_lists := fmt.tprintf("%s/CMakeLists.txt", dir)
	if os.is_file(cmake_lists) {
		return .CMake
	}
	configure := fmt.tprintf("%s/configure", dir)
	if os.is_file(configure) {
		return .Autotools
	}
	meson_build := fmt.tprintf("%s/meson.build", dir)
	if os.is_file(meson_build) {
		return .Meson
	}
	makefile := fmt.tprintf("%s/Makefile", dir)
	if os.is_file(makefile) {
		return .Make
	}
	makefile_lower := fmt.tprintf("%s/makefile", dir)
	if os.is_file(makefile_lower) {
		return .Make
	}
	return .Unknown
}

find_source_root :: proc(build_dir: string) -> string {
	infos, read_err := os.read_directory_by_path(build_dir, -1, context.temp_allocator)
	if read_err != nil {
		return build_dir
	}

	dir_count := 0
	total_count := 0
	first_dir := ""

	for info in infos {
		total_count += 1
		if os.is_dir(info.fullpath) {
			dir_count += 1
			first_dir = info.fullpath
		}
	}

	if total_count == 1 && dir_count == 1 {
		return first_dir
	}
	return build_dir
}

install_source :: proc(f: formula.Formula, prefix: string) -> bool {
	fmt.printf("==> Installing %s %s from source\n", f.name, f.version)

	if len(f.source_url) == 0 {
		fmt.println("Error: No source URL available for this formula.")
		return false
	}

	if !ensure_dir(CACHE_DIR) || !ensure_dir(PREFIX + "/Cellar") || !ensure_dir(PREFIX + "/bin") {
		fmt.println("Error: run `sudo ubrew init`, then ensure /opt/ubrew is writable by your user.")
		return false
	}

	// Detect archive extension from source URL
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

	dl_path := fmt.tprintf("%s/%s-%s-source%s", CACHE_DIR, f.name, f.version, ext)
	fmt.printf("==> Downloading source: %s\n", f.source_url)

	if !download_or_cache(f.source_url, f.source_sha256, dl_path) {
		return false
	}

	build_dir := fmt.tprintf("%s/%s-%s-build", CACHE_DIR, f.name, f.version)
	_ = os.remove_all(build_dir)
	_ = os.make_directory_all(build_dir, os.perm(0o755))

	fmt.printf("==> Extracting source to: %s\n", build_dir)
	if ext == ".zip" {
		cmd_ex := fmt.tprintf("unzip -q \"%s\" -d \"%s\"", dl_path, build_dir)
		cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
		if libc.system(cmd_ex_cstr) != 0 {
			fmt.println("Error: unzip failed.")
			return false
		}
	} else if ext == ".tar.gz" {
		cmd_ex := fmt.tprintf("tar -xzf \"%s\" -C \"%s\"", dl_path, build_dir)
		cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
		if libc.system(cmd_ex_cstr) != 0 {
			fmt.println("Error: tar extraction failed.")
			return false
		}
	} else if ext == ".tar.bz2" {
		cmd_ex := fmt.tprintf("tar -xjf \"%s\" -C \"%s\"", dl_path, build_dir)
		cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
		if libc.system(cmd_ex_cstr) != 0 {
			fmt.println("Error: tar extraction failed.")
			return false
		}
	} else if ext == ".tar.xz" {
		cmd_ex := fmt.tprintf("tar -xJf \"%s\" -C \"%s\"", dl_path, build_dir)
		cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
		if libc.system(cmd_ex_cstr) != 0 {
			fmt.println("Error: tar extraction failed.")
			return false
		}
	} else if ext == ".tar.zst" {
		cmd_ex := fmt.tprintf("tar --use-compress-program=unzstd -xf \"%s\" -C \"%s\" 2>/dev/null", dl_path, build_dir)
		cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
		if libc.system(cmd_ex_cstr) != 0 {
			cmd_ex_plain := fmt.tprintf("tar -xf \"%s\" -C \"%s\"", dl_path, build_dir)
			cmd_ex_plain_cstr := strings.clone_to_cstring(cmd_ex_plain, context.temp_allocator)
			if libc.system(cmd_ex_plain_cstr) != 0 {
				fmt.println("Error: zstd tar extraction failed.")
				return false
			}
		}
	}

	src_root := find_source_root(build_dir)
	build_sys := detect_build_system(src_root)
	fmt.printf("==> Detected build system: %v\n", build_sys)

	cellar_dir := PREFIX + "/Cellar"
	keg_dir := fmt.tprintf("%s/%s/%s", cellar_dir, f.name, f.version)
	_ = os.remove_all(keg_dir)
	_ = os.make_directory_all(keg_dir, os.perm(0o755))

	build_ok := false

	#partial switch build_sys {
	case .CMake:
		cmd_config := fmt.tprintf("cd \"%s\" && cmake -B build -DCMAKE_INSTALL_PREFIX=\"%s\"", src_root, keg_dir)
		cmd_config_cstr := strings.clone_to_cstring(cmd_config, context.temp_allocator)
		cmd_build := fmt.tprintf("cd \"%s\" && cmake --build build -j 4", src_root)
		cmd_build_cstr := strings.clone_to_cstring(cmd_build, context.temp_allocator)
		cmd_install := fmt.tprintf("cd \"%s\" && cmake --install build", src_root)
		cmd_install_cstr := strings.clone_to_cstring(cmd_install, context.temp_allocator)

		if libc.system(cmd_config_cstr) == 0 && libc.system(cmd_build_cstr) == 0 && libc.system(cmd_install_cstr) == 0 {
			build_ok = true
		}

	case .Autotools:
		cmd_config := fmt.tprintf("cd \"%s\" && ./configure --prefix=\"%s\"", src_root, keg_dir)
		cmd_config_cstr := strings.clone_to_cstring(cmd_config, context.temp_allocator)
		cmd_build := fmt.tprintf("cd \"%s\" && make -j 4", src_root)
		cmd_build_cstr := strings.clone_to_cstring(cmd_build, context.temp_allocator)
		cmd_install := fmt.tprintf("cd \"%s\" && make install", src_root)
		cmd_install_cstr := strings.clone_to_cstring(cmd_install, context.temp_allocator)

		if libc.system(cmd_config_cstr) == 0 && libc.system(cmd_build_cstr) == 0 && libc.system(cmd_install_cstr) == 0 {
			build_ok = true
		}

	case .Meson:
		cmd_config := fmt.tprintf("cd \"%s\" && meson setup build --prefix=\"%s\"", src_root, keg_dir)
		cmd_config_cstr := strings.clone_to_cstring(cmd_config, context.temp_allocator)
		cmd_build := fmt.tprintf("cd \"%s\" && meson compile -C build", src_root)
		cmd_build_cstr := strings.clone_to_cstring(cmd_build, context.temp_allocator)
		cmd_install := fmt.tprintf("cd \"%s\" && meson install -C build", src_root)
		cmd_install_cstr := strings.clone_to_cstring(cmd_install, context.temp_allocator)

		if libc.system(cmd_config_cstr) == 0 && libc.system(cmd_build_cstr) == 0 && libc.system(cmd_install_cstr) == 0 {
			build_ok = true
		}

	case .Make:
		cmd_build := fmt.tprintf("cd \"%s\" && make PREFIX=\"%s\" -j 4", src_root, keg_dir)
		cmd_build_cstr := strings.clone_to_cstring(cmd_build, context.temp_allocator)
		cmd_install := fmt.tprintf("cd \"%s\" && make PREFIX=\"%s\" install", src_root, keg_dir)
		cmd_install_cstr := strings.clone_to_cstring(cmd_install, context.temp_allocator)

		if libc.system(cmd_build_cstr) == 0 && libc.system(cmd_install_cstr) == 0 {
			build_ok = true
		}

	case .Unknown:
		// Standalone files copy (similar to Nanobrew fallback). We copy
		// everything from the source root into the keg, then if the
		// formula declared any `bin.install "..."` directives we honour
		// them by:
		//   1. Creating a `bin/` subdir in the keg
		//   2. Moving the named files into it
		cmd_cp := fmt.tprintf("cp -R \"%s\"/* \"%s\"/", src_root, keg_dir)
		cmd_cp_cstr := strings.clone_to_cstring(cmd_cp, context.temp_allocator)
		if libc.system(cmd_cp_cstr) == 0 {
			build_ok = true
		}
		// Materialise the bin/ directory requested by bin.install. Each
		// name in f.binaries is the basename of a file that should end up
		// at <keg>/bin/<name>. We use a single shell pipeline that walks
		// the keg (excluding the bin/ subdir itself), finds the named
		// file, and moves it into bin/. This is simpler than per-name
		// popen plumbing in Odin and handles the common case where the
		// file lives at <keg>/<name> directly.
		if build_ok && len(f.binaries) > 0 {
			keg_bin := fmt.tprintf("%s/bin", keg_dir)
			_ = os.make_directory_all(keg_bin, os.perm(0o755))
			for b in f.binaries {
				// Pipeline: find the file (excluding bin/ itself) and mv it.
				// `2>/dev/null` suppresses find errors; `|| true` keeps the
				// pipeline non-fatal if the file isn't found.
				mv_cmd := fmt.tprintf(
					"FOUND=$(find \"%s\" -maxdepth 3 -type f -name \"%s\" -not -path \"%s/*\" 2>/dev/null | head -1); " +
					"if [ -n \"$FOUND\" ]; then mv \"$FOUND\" \"%s/%s\"; fi",
					keg_dir, b, keg_bin, keg_bin, b,
				)
				mv_cstr := strings.clone_to_cstring(mv_cmd, context.temp_allocator)
				_ = libc.system(mv_cstr)
			}
		}
	}

	_ = os.remove_all(build_dir)

	if !build_ok {
		fmt.printf("Error: Build failed for %s from source.\n", f.name)
		_ = os.remove_all(keg_dir)
		return false
	}

	// Link binaries
	bin_dir := fmt.tprintf("%s/bin", keg_dir)
	if os.is_dir(bin_dir) {
		fd, fd_err := os.open(bin_dir)
		if fd_err == nil {
			defer os.close(fd)
			infos, read_err := os.read_directory_by_path(bin_dir, -1, context.temp_allocator)
			if read_err == nil {
				for info in infos {
					if info.type == .Regular {
						src_file := info.fullpath
						dst_file := fmt.tprintf("%s/bin/%s", prefix, info.name)
						os.remove(dst_file)
						sym_err := os.symlink(src_file, dst_file)
						if sym_err != nil {
							fmt.printf("Error linking binary %s: %v\n", info.name, sym_err)
							return false
						}
					}
				}
			} else {
				fmt.println("Error reading binary directory.")
				return false
			}
		} else {
			fmt.println("Error: Linking binaries failed.")
			return false
		}
	}

	// Relocate patched binary if patchelf exists
	binary_path := fmt.tprintf("%s/bin/%s", keg_dir, f.name)
	if os.is_file(binary_path) {
		chmod_args := []string{"chmod", "+w", binary_path}
		platform.exec_cmd("chmod", chmod_args)

		patch_args := []string{"patchelf", "--set-interpreter", INTERPRETER, binary_path}
		platform.exec_cmd("patchelf", patch_args)
	}

	fmt.printf("==> Successful installation of %s into %s!\n", f.name, keg_dir)
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

	mf, ok := kernel.mapped_file_open(path)
	if !ok {
		return false
	}
	defer kernel.mapped_file_close(&mf)

	data := kernel.mapped_file_bytes(&mf)
	digest := hash.hash_bytes(hash.Algorithm.SHA256, data, context.allocator)
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

download_or_cache :: proc(url: string, sha256: string, dl_path: string) -> bool {
	if store.is_valid_sha256(sha256) && store.blob_has(sha256) {
		buf: [512]u8
		cached := store.blob_path(sha256, buf[:])
		if os.is_file(cached) {
			cmd_cp := fmt.tprintf("cp '%s' '%s'", cached, dl_path)
			cmd_cp_cstr := strings.clone_to_cstring(cmd_cp, context.temp_allocator)
			if libc.system(cmd_cp_cstr) == 0 {
				fmt.printf("==> Using cached blob for %s\n", sha256[:12])
				return true
			}
		}
	}

	fmt.printf("==> Downloading: %s\n", url)
	cmd_dl := fmt.tprintf("curl -sfSL \"%s\" -o \"%s\"", url, dl_path)
	cmd_dl_cstr := strings.clone_to_cstring(cmd_dl, context.temp_allocator)
	if libc.system(cmd_dl_cstr) != 0 {
		fmt.println("Error: Download failed.")
		return false
	}

	if !sha256_matches(dl_path, sha256) {
		fmt.println("Error: SHA256 verification failed.")
		return false
	}

	if store.is_valid_sha256(sha256) {
		_ = store.blob_ensure_dir()
		buf: [512]u8
		cached := store.blob_path(sha256, buf[:])
		cmd_cache := fmt.tprintf("cp '%s' '%s'", dl_path, cached)
		cmd_cache_cstr := strings.clone_to_cstring(cmd_cache, context.temp_allocator)
		if libc.system(cmd_cache_cstr) == 0 {
			fmt.printf("==> Cached blob %s\n", sha256[:12])
		}
	}

	return true
}

install_cask :: proc(c: cask.Cask) -> bool {
	for art in c.artifacts {
		if _, ok := art.(cask.Font_Artifact); ok {
			return install_font_cask(c)
		}
	}
	for art in c.artifacts {
		if _, ok := art.(cask.Wallpaper_Artifact); ok {
			return install_wallpaper_cask(c)
		}
	}
	for art in c.artifacts {
		if _, ok := art.(cask.AppImage_Artifact); ok {
			return install_appimage_cask(c)
		}
	}
	for art in c.artifacts {
		if _, ok := art.(cask.Binary_Artifact); ok {
			return install_binary_cask(c)
		}
		if _, ok := art.(cask.Generic_Artifact); ok {
			return install_binary_cask(c)
		}
	}

	fmt.println("Error: Only font, wallpaper, AppImage, binary, and generic artifact casks are currently supported by ubrew.")
	return false
}

install_binary_cask :: proc(c: cask.Cask) -> bool {
	if len(c.url) == 0 {
		fmt.println("Error: Cask has no download URL.")
		return false
	}

	home_dir := os.get_env("HOME", context.temp_allocator)
	if home_dir == "" {
		fmt.println("Error: $HOME is not set.")
		return false
	}

	bin_dir := fmt.tprintf("%s/.local/bin", home_dir)
	_ = os.make_directory_all(bin_dir, os.perm(0o755))

	cache_dir := CACHE_DIR
	_ = os.make_directory_all(cache_dir, os.perm(0o755))

	flat := flatten_token(c.token)
	ver := c.version
	if ver == "" {
		ver = "latest"
	}
	ver_flat, _ := strings.replace_all(ver, "/", "-", context.temp_allocator)

	// Determine extension/type from URL
	ext := ""
	url := c.url
	if strings.has_suffix(url, ".zip") {
		ext = ".zip"
	} else if strings.has_suffix(url, ".tar.gz") || strings.has_suffix(url, ".tgz") {
		ext = ".tar.gz"
	} else if strings.has_suffix(url, ".tar.bz2") || strings.has_suffix(url, ".tbz2") {
		ext = ".tar.bz2"
	} else if strings.has_suffix(url, ".tar.xz") || strings.has_suffix(url, ".txz") {
		ext = ".tar.xz"
	} else if strings.has_suffix(url, ".tar.zst") || strings.has_suffix(url, ".tar.zstd") {
		ext = ".tar.zst"
	}

	dl_path := ext == "" ? fmt.tprintf("%s/%s-%s", cache_dir, flat, ver_flat) : fmt.tprintf("%s/%s-%s%s", cache_dir, flat, ver_flat, ext)
	fmt.printf("==> Downloading binary cask: %s\n", c.token)

	if !download_or_cache(c.url, c.sha256, dl_path) {
		return false
	}

	extract_root := CASKROOM_DIR
	_ = os.make_directory_all(extract_root, os.perm(0o755))

	extract_dir := fmt.tprintf("%s/%s/%s", extract_root, flat, ver_flat)
	_ = os.remove_all(extract_dir)
	_ = os.make_directory_all(extract_dir, os.perm(0o755))

	if ext == "" {
		// Probe the downloaded file to detect archive type via file magic
		probe_args := []string{"file", "--brief", dl_path}
		probe_buf: [512]u8
		probe_out := platform.exec_cmd_capture("file", probe_args, probe_buf[:])
		probe_lower := strings.to_lower(probe_out, context.temp_allocator)

		if strings.contains(probe_lower, "gzip") {
			ext = ".tar.gz"
		} else if strings.contains(probe_lower, "xz") {
			ext = ".tar.xz"
		} else if strings.contains(probe_lower, "bzip2") {
			ext = ".tar.bz2"
		} else if strings.contains(probe_lower, "zstandard") || strings.contains(probe_lower, "zstd") {
			ext = ".tar.zst"
		} else if strings.contains(probe_lower, "zip archive") {
			ext = ".zip"
		}
	}

	if ext == "" {
		// Single standalone binary
		// Stage into Caskroom
		stage_dst := fmt.tprintf("%s/%s", extract_dir, os.base(url))
		if err := os.copy_file(stage_dst, dl_path); err != nil {
			fmt.printf("Error: failed staging binary to Caskroom: %v\n", err)
			return false
		}
	} else {
		// Archive — extract to Caskroom
		fmt.printf("==> Extracting to: %s\n", extract_dir)
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
			cmd_ex := fmt.tprintf("tar --use-compress-program=unzstd -xf \"%s\" -C \"%s\" 2>/dev/null", dl_path, extract_dir)
			cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
			if libc.system(cmd_ex_cstr) != 0 {
				cmd_ex_plain := fmt.tprintf("tar -xf \"%s\" -C \"%s\"", dl_path, extract_dir)
				cmd_ex_plain_cstr := strings.clone_to_cstring(cmd_ex_plain, context.temp_allocator)
				if libc.system(cmd_ex_plain_cstr) != 0 {
					fmt.println("Error: zstd tar extraction failed.")
					return false
				}
			}
		}
	}

	// Copy binary artifacts to target
	installed := 0
	for art in c.artifacts {
		if ba, ok := art.(cask.Binary_Artifact); ok {
			src_rel := ba.source
			if src_rel == "" {
				src_rel = ba.target
			}
			if src_rel == "" {
				src_rel = os.base(url)
			}
			target_name := ba.target
			if target_name == "" {
				target_name = os.base(src_rel)
			}

			src := fmt.tprintf("%s/%s", extract_dir, src_rel)
			if !os.is_file(src) {
				// Try finding by basename in extract_dir
				base := os.base(src_rel)
				if p, ok := find_file_by_basename(extract_dir, base); ok {
					src = p
				} else {
					fmt.printf("==> Missing binary artifact: %s\n", src_rel)
					continue
				}
			}

			dst := fmt.tprintf("%s/%s", bin_dir, target_name)
			_ = os.remove(dst)

			chmod_src := fmt.tprintf("chmod +x \"%s\"", src)
			chmod_src_cstr := strings.clone_to_cstring(chmod_src, context.temp_allocator)
			_ = libc.system(chmod_src_cstr)

			if err := os.symlink(src, dst); err != nil {
				fmt.printf("Error: failed symlinking binary to %s: %v\n", dst, err)
				return false
			}
			installed += 1
		}
	}

	// Copy generic artifacts to target
	for art in c.artifacts {
		if ga, ok := art.(cask.Generic_Artifact); ok {
			src_rel := ga.source
			target_path := ga.target

			resolved_target := expand_home(target_path, context.temp_allocator)

			src := fmt.tprintf("%s/%s", extract_dir, src_rel)
			if !os.is_file(src) && !os.is_dir(src) {
				// Try finding by basename in extract_dir
				base := os.base(src_rel)
				if p, ok := find_file_by_basename(extract_dir, base); ok {
					src = p
				} else {
					fmt.printf("==> Missing generic artifact: %s\n", src_rel)
					continue
				}
			}

			// Ensure parent directory of resolved_target exists
			parent_dir := dir_name(resolved_target)
			_ = os.make_directory_all(parent_dir, os.perm(0o755))

			if os.is_dir(src) {
				// Copy directory recursively
				if !platform.cp_fallback(src, resolved_target) {
					fmt.printf("Error: failed copying generic directory artifact to %s\n", resolved_target)
					return false
				}
			} else {
				if err := os.copy_file(resolved_target, src); err != nil {
					fmt.printf("Error: failed copying generic artifact file to %s: %v\n", resolved_target, err)
					return false
				}
			}

			// Apply post-copy adjustments for 1Password compatibility
			if strings.has_suffix(resolved_target, ".desktop") {
				if contents, err := os.read_entire_file_from_path(resolved_target, context.temp_allocator); err == nil {
					text := string(contents)
					bin_path := fmt.tprintf("%s/1password", bin_dir)
					new_text, _ := strings.replace_all(text, "/opt/1Password/1password", bin_path, context.temp_allocator)
					_ = os.write_entire_file_from_string(resolved_target, new_text)
				}
			}
			if strings.has_suffix(resolved_target, "custom_allowed_browsers") {
				if contents, err := os.read_entire_file_from_path(resolved_target, context.temp_allocator); err == nil {
					text := string(contents)
					new_text := fmt.tprintf("%s\nflatpak-session-helper\n", text)
					_ = os.write_entire_file_from_string(resolved_target, new_text)
				}
			}

			installed += 1
		}
	}

	// VS Code-specific post-install hooks
	if strings.contains(c.token, "visual-studio-code") {
		// 1. Disable built-in auto-update by neutralizing updateUrl in product.json
		product_json, pj_ok := find_file_by_basename(extract_dir, "product.json")
		if pj_ok {
			if pj_data, pj_err := os.read_entire_file_from_path(product_json, context.temp_allocator); pj_err == nil {
				pj_text := string(pj_data)
				if strings.contains(pj_text, "\"updateUrl\"") {
					new_pj, _ := strings.replace_all(pj_text, "\"updateUrl\"", "\"_updateUrl\"", context.temp_allocator)
					_ = os.write_entire_file_from_string(product_json, new_pj)
					fmt.println("==> Disabled VS Code built-in auto-update (updateUrl neutralized)")
				}
			}
		}

		// 2. Generate .desktop files dynamically
		apps_dir := fmt.tprintf("%s/.local/share/applications", home_dir)
		_ = os.make_directory_all(apps_dir, os.perm(0o755))

		// Detect VS Code icon path inside the extracted archive
		icon_path := fmt.tprintf("%s/code", bin_dir) // fallback
		// Walk extract_dir to find code.png under resources/app/resources/linux/
		icon_w := os.walker_create(extract_dir)
		for icon_info in os.walker_walk(&icon_w) {
			if icon_info.type == .Regular && icon_info.name == "code.png" && strings.contains(icon_info.fullpath, "resources/linux") {
				icon_path = strings.clone(icon_info.fullpath, context.temp_allocator)
				break
			}
		}
		os.walker_destroy(&icon_w)

		code_bin := fmt.tprintf("%s/code", bin_dir)

		// code.desktop
		desktop_content := fmt.tprintf(
			"[Desktop Entry]\nName=Visual Studio Code\nComment=Code Editing. Redefined.\nGenericName=Text Editor\nExec=%s --unity-launch %%F\nIcon=%s\nType=Application\nStartupNotify=false\nStartupWMClass=Code\nCategories=TextEditor;Development;IDE;\nMimeType=application/x-code-workspace;\nActions=new-empty-window;\nKeywords=vscode;\n\n[Desktop Action new-empty-window]\nName=New Empty Window\nExec=%s --new-window %%F\nIcon=%s\n",
			code_bin, icon_path, code_bin, icon_path,
		)
		desktop_path := fmt.tprintf("%s/code.desktop", apps_dir)
		_ = os.write_entire_file_from_string(desktop_path, desktop_content)

		// code-url-handler.desktop
		url_handler_content := fmt.tprintf(
			"[Desktop Entry]\nName=Visual Studio Code - URL Handler\nComment=Code Editing. Redefined.\nGenericName=Text Editor\nExec=%s --open-url %%U\nIcon=%s\nType=Application\nNoDisplay=true\nStartupNotify=true\nCategories=Utility;TextEditor;Development;IDE;\nMimeType=x-scheme-handler/vscode;\nKeywords=vscode;\n",
			code_bin, icon_path,
		)
		url_handler_path := fmt.tprintf("%s/code-url-handler.desktop", apps_dir)
		_ = os.write_entire_file_from_string(url_handler_path, url_handler_content)

		fmt.println("==> Generated VS Code desktop shortcuts")
		installed += 2
	}

	if installed == 0 {
		fmt.println("Error: No artifacts were installed.")
		return false
	}

	fmt.printf("==> Installed %d artifact(s)\n", installed)
	return true
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

    cache_dir := CACHE_DIR
    _ = os.make_directory_all(cache_dir, os.perm(0o755))

    flat := flatten_token(c.token)
    fonts_dir := fmt.tprintf("%s/.local/share/fonts/ubrew/%s", home_dir, flat)
    _ = os.make_directory_all(fonts_dir, os.perm(0o755))
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

	if !download_or_cache(c.url, c.sha256, dl_path) {
		return false
	}

    extract_root := CASKROOM_DIR
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
        cmd_ex := fmt.tprintf("tar --use-compress-program=unzstd -xf \"%s\" -C \"%s\" 2>/dev/null", dl_path, extract_dir)
        cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
        if libc.system(cmd_ex_cstr) != 0 {
            // CDNs may decompress .zstd in transit — fall back to plain tar
            cmd_ex_plain := fmt.tprintf("tar -xf \"%s\" -C \"%s\"", dl_path, extract_dir)
            cmd_ex_plain_cstr := strings.clone_to_cstring(cmd_ex_plain, context.temp_allocator)
            if libc.system(cmd_ex_plain_cstr) != 0 {
                fmt.println("Error: zstd tar extraction failed.")
                return false
            }
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
        #partial switch a in art {
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
	case cask.Binary_Artifact:
	case cask.Wallpaper_Artifact:
	case cask.AppImage_Artifact:
	}
}

if installed == 0 {
	fmt.println("Error: No fonts were installed (no font artifacts found).")
	return false
}

    // Refresh font cache if available
    platform.exec_cmd("fc-cache", []string{"fc-cache", "-f"})

    fmt.printf("==> Installed %d font file(s) to %s\n", installed, fonts_dir)
    return true
}

glob_matches :: proc(name: string, glob: string) -> bool {
    // Simple glob: "*.ext" matches if name ends with ".ext"
    if strings.has_prefix(glob, "*.") {
        ext := glob[1:]  // e.g. ".png"
        return strings.has_suffix(strings.to_lower(name, context.temp_allocator), strings.to_lower(ext, context.temp_allocator))
    }
    // "*" matches everything
    if glob == "*" {
        return true
    }
    // Exact match fallback
    return name == glob
}

IMAGE_EXTENSIONS :: []string{".png", ".jpg", ".jpeg", ".webp", ".svg", ".heic", ".heif", ".avif", ".bmp", ".tif", ".tiff", ".jxl"}

is_image_file :: proc(name: string) -> bool {
    lower := strings.to_lower(name, context.temp_allocator)
    for ext in IMAGE_EXTENSIONS {
        if strings.has_suffix(lower, ext) {
            return true
        }
    }
    return false
}

install_wallpaper_cask :: proc(c: cask.Cask) -> bool {
	if len(c.url) == 0 {
		fmt.println("Error: Cask has no download URL.")
		return false
	}

	home_dir := os.get_env("HOME", context.temp_allocator)
	if home_dir == "" {
		fmt.println("Error: $HOME is not set.")
		return false
	}

	de := detect_desktop()
	flat := flatten_token(c.token)
	product := wallpaper_product_name(c.token)
	wallpaper_dir := wallpaper_install_dir(home_dir, product, de)
	_ = os.make_directory_all(wallpaper_dir, os.perm(0o755))

	fmt.printf("==> Detected desktop: %s\n", de)

    cache_dir := CACHE_DIR
    _ = os.make_directory_all(cache_dir, os.perm(0o755))

    ver := c.version
    if ver == "" {
        ver = "latest"
    }
    ver_flat, _ := strings.replace_all(ver, "/", "-", context.temp_allocator)

    // Detect archive extension from URL
    ext := ".tar.gz"
    url := c.url
    if strings.has_suffix(url, ".zip") {
        ext = ".zip"
    } else if strings.has_suffix(url, ".tar.bz2") || strings.has_suffix(url, ".tbz2") {
        ext = ".tar.bz2"
    } else if strings.has_suffix(url, ".tar.xz") || strings.has_suffix(url, ".txz") {
        ext = ".tar.xz"
    } else if strings.has_suffix(url, ".tar.zst") || strings.has_suffix(url, ".tar.zstd") {
        ext = ".tar.zst"
    }

	dl_path := fmt.tprintf("%s/%s-%s%s", cache_dir, flat, ver_flat, ext)
	fmt.printf("==> Downloading wallpaper cask: %s\n", c.token)

	if !download_or_cache(c.url, c.sha256, dl_path) {
		return false
	}
    extract_root := CASKROOM_DIR
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
        cmd_ex := fmt.tprintf("tar --use-compress-program=unzstd -xf \"%s\" -C \"%s\" 2>/dev/null", dl_path, extract_dir)
        cmd_ex_cstr := strings.clone_to_cstring(cmd_ex, context.temp_allocator)
        if libc.system(cmd_ex_cstr) != 0 {
            // CDNs may decompress .zstd in transit — fall back to plain tar
            cmd_ex_plain := fmt.tprintf("tar -xf \"%s\" -C \"%s\"", dl_path, extract_dir)
            cmd_ex_plain_cstr := strings.clone_to_cstring(cmd_ex_plain, context.temp_allocator)
            if libc.system(cmd_ex_plain_cstr) != 0 {
                fmt.println("Error: zstd tar extraction failed.")
                return false
            }
        }
    }

    // Collect globs from wallpaper artifacts
    globs := make([dynamic]string, context.temp_allocator)
    for art in c.artifacts {
        if wa, ok := art.(cask.Wallpaper_Artifact); ok {
            append(&globs, wa.glob)
        }
    }

    // Walk the extracted tree and copy matching image files
    installed := 0
    w := os.walker_create(extract_dir)
    defer os.walker_destroy(&w)

    gnome_properties_dir := fmt.tprintf("%s/.local/share/gnome-background-properties", home_dir)

    for info in os.walker_walk(&w) {
        if info.type != .Regular {
            continue
        }

        // Handle GNOME XML properties
        if de == .GNOME && strings.has_suffix(strings.to_lower(info.name, context.temp_allocator), ".xml") {
            data, read_err := os.read_entire_file(info.fullpath, context.temp_allocator)
            if read_err == nil {
                contents := string(data)
                // Replace both "~" and old hardcoded path with home_dir
                new_contents, _ := strings.replace_all(contents, "~", home_dir, context.temp_allocator)
                
                _ = os.make_directory_all(gnome_properties_dir, os.perm(0o755))
                dst_xml := fmt.tprintf("%s/%s", gnome_properties_dir, info.name)
                if os.write_entire_file(dst_xml, transmute([]byte)new_contents) == nil {
                    installed += 1
                } else {
                    fmt.printf("Error: failed writing GNOME background property XML to %s\n", dst_xml)
                }
            }
            continue
        }

        if !is_image_file(info.name) {
            continue
        }

        matched := false
        if len(globs) == 0 {
            // No explicit globs — copy all image files
            matched = true
        } else {
            for g in globs {
                if glob_matches(info.name, g) {
                    matched = true
                    break
                }
            }
        }

        if !matched {
            continue
        }

        // Preserve relative path of files from extract_dir to support structured themes (especially for KDE)
        pattern := fmt.tprintf("%s/%s/", flat, ver_flat)
        idx := strings.index(info.fullpath, pattern)
        rel_path: string
        if idx != -1 {
            rel_path = info.fullpath[idx + len(pattern):]
        } else {
            rel_path = info.fullpath[len(extract_dir):]
            if len(rel_path) > 0 && rel_path[0] == '/' {
                rel_path = rel_path[1:]
            }
        }
        dst := fmt.tprintf("%s/%s", wallpaper_dir, rel_path)
        
        // Ensure destination parent directory exists
        dst_parent := os.dir(dst)
        _ = os.make_directory_all(dst_parent, os.perm(0o755))

        if err := os.copy_file(dst, info.fullpath); err != nil {
            fmt.printf("Error: failed copying wallpaper %s to %s: %v\n", info.name, dst, err)
            continue
        }
        installed += 1
    }

    if installed == 0 {
        fmt.println("Error: No wallpaper images were installed.")
        return false
    }

	fmt.printf("==> Installed %d wallpaper(s) to %s\n", installed, wallpaper_dir)
	return true
}

install_appimage_cask :: proc(c: cask.Cask) -> bool {
	if len(c.url) == 0 {
		fmt.println("Error: Cask has no download URL.")
		return false
	}

	home_dir := os.get_env("HOME", context.temp_allocator)
	if home_dir == "" {
		fmt.println("Error: $HOME is not set.")
		return false
	}

	appimage_dir := fmt.tprintf("%s/.local/bin", home_dir)
	_ = os.make_directory_all(appimage_dir, os.perm(0o755))

	cache_dir := CACHE_DIR
	_ = os.make_directory_all(cache_dir, os.perm(0o755))

	flat := flatten_token(c.token)
	ver := c.version
	if ver == "" {
		ver = "latest"
	}
	ver_flat, _ := strings.replace_all(ver, "/", "-", context.temp_allocator)

	appimage_url := c.url
	dl_path := fmt.tprintf("%s/%s-%s.AppImage", cache_dir, flat, ver_flat)
	fmt.printf("==> Downloading AppImage cask: %s\n", c.token)

	if !download_or_cache(appimage_url, c.sha256, dl_path) {
		return false
	}

	extract_root := CASKROOM_DIR
	_ = os.make_directory_all(extract_root, os.perm(0o755))

	extract_dir := fmt.tprintf("%s/%s/%s", extract_root, flat, ver_flat)
	_ = os.remove_all(extract_dir)
	_ = os.make_directory_all(extract_dir, os.perm(0o755))

	chmod_cmd := fmt.tprintf("chmod +x \"%s\"", dl_path)
	chmod_cstr := strings.clone_to_cstring(chmod_cmd, context.temp_allocator)
	_ = libc.system(chmod_cstr)

	fmt.printf("==> Extracting AppImage to: %s\n", extract_dir)
	extract_cmd := fmt.tprintf("cd \"%s\" && \"%s\" --appimage-extract 2>/dev/null", extract_dir, dl_path)
	extract_cstr := strings.clone_to_cstring(extract_cmd, context.temp_allocator)
	extract_ok := libc.system(extract_cstr)

	squashfs_dir := fmt.tprintf("%s/squashfs-root", extract_dir)
	if extract_ok != 0 || !os.is_dir(squashfs_dir) {
		fmt.println("==> AppImage extraction failed, installing as standalone binary")
		for art in c.artifacts {
			if ai, ok := art.(cask.AppImage_Artifact); ok {
				target := ai.target
				if target == "" {
					target = ai.source
				}
				target_base := os.base(target)
				dst := fmt.tprintf("%s/%s", appimage_dir, target_base)
				if err := os.copy_file(dst, dl_path); err != nil {
					fmt.printf("Error: failed copying AppImage to %s\n", dst)
					return false
				}
				chmod2 := fmt.tprintf("chmod +x \"%s\"", dst)
				chmod2_cstr := strings.clone_to_cstring(chmod2, context.temp_allocator)
				_ = libc.system(chmod2_cstr)
				fmt.printf("==> Installed AppImage: %s\n", dst)
				return true
			}
		}
		fmt.println("Error: No AppImage artifact target found.")
		return false
	}

	installed := 0
	for art in c.artifacts {
		#partial switch a in art {
		case cask.AppImage_Artifact:
			src_rel := a.source
			target_name := a.target
			if target_name == "" {
				target_name = os.base(a.source)
			}

			src := fmt.tprintf("%s/%s", squashfs_dir, src_rel)
			if !os.is_file(src) {
				base := os.base(src_rel)
				if p, ok := find_file_by_basename(squashfs_dir, base); ok {
					src = p
				} else {
					fmt.printf("==> Missing AppImage artifact: %s\n", src_rel)
					continue
				}
			}

			dst := fmt.tprintf("%s/%s", appimage_dir, target_name)
			_ = os.remove(dst)

			chmod_src := fmt.tprintf("chmod +x \"%s\"", src)
			chmod_src_cstr := strings.clone_to_cstring(chmod_src, context.temp_allocator)
			_ = libc.system(chmod_src_cstr)

			if err := os.symlink(src, dst); err != nil {
				fmt.printf("Error: failed symlinking AppImage artifact %s: %v\n", dst, err)
				return false
			}
			installed += 1
		case cask.App_Artifact:
			if a.name == "" {
				continue
			}
			src := fmt.tprintf("%s/%s", squashfs_dir, a.name)
			if !os.is_file(src) {
				continue
			}
			dst := fmt.tprintf("%s/.local/share/applications/%s", home_dir, os.base(a.name))
			_ = os.make_directory_all(fmt.tprintf("%s/.local/share/applications", home_dir), os.perm(0o755))
			if err := os.copy_file(dst, src); err != nil {
				fmt.printf("==> Warning: failed copying desktop file %s\n", a.name)
			}
		case cask.Binary_Artifact:
			if a.source == "" {
				continue
			}
			src := fmt.tprintf("%s/%s", squashfs_dir, a.source)
			if !os.is_file(src) {
				continue
			}
			target_name := a.target
			if target_name == "" {
				target_name = os.base(a.source)
			}
			dst := fmt.tprintf("%s/%s", appimage_dir, target_name)
			_ = os.remove(dst)

			chmod_src := fmt.tprintf("chmod +x \"%s\"", src)
			chmod_src_cstr := strings.clone_to_cstring(chmod_src, context.temp_allocator)
			_ = libc.system(chmod_src_cstr)

			if err := os.symlink(src, dst); err != nil {
				fmt.printf("==> Warning: failed symlinking binary %s: %v\n", a.source, err)
			} else {
				installed += 1
			}
		case cask.Font_Artifact:
		case cask.Wallpaper_Artifact:
		}
	}

	if installed == 0 {
		fmt.println("Error: No AppImage binaries were installed.")
		return false
	}

	fmt.printf("==> Installed %d binary(s) from AppImage to %s\n", installed, appimage_dir)
	return true
}

remove_cask :: proc(c: cask.Cask) -> bool {
	home_dir := os.get_env("HOME", context.temp_allocator)
	if home_dir == "" {
		fmt.println("Error: $HOME is not set.")
		return false
	}

	flat := flatten_token(c.token)
	ver := c.version
	if ver == "" {
		ver = "latest"
	}
	ver_flat, _ := strings.replace_all(ver, "/", "-", context.temp_allocator)

	fmt.printf("==> Uninstalling cask: %s\n", c.token)

	// Determine cask type and perform specific cleanup
	is_font := false
	is_wallpaper := false
	is_appimage := false
	is_binary := false

	for art in c.artifacts {
		#partial switch a in art {
		case cask.Font_Artifact:
			is_font = true
		case cask.Wallpaper_Artifact:
			is_wallpaper = true
		case cask.AppImage_Artifact:
			is_appimage = true
		case cask.Binary_Artifact:
			is_binary = true
		}
	}

	if is_font {
		fonts_dir := fmt.tprintf("%s/.local/share/fonts/ubrew/%s", home_dir, flat)
		if os.is_dir(fonts_dir) {
			_ = os.remove_all(fonts_dir)
		}
		// Refresh font cache
		platform.exec_cmd("fc-cache", []string{"fc-cache", "-f"})
	}

	if is_wallpaper {
		de := detect_desktop()
		product := wallpaper_product_name(c.token)
		wallpaper_dir := wallpaper_install_dir(home_dir, product, de)
		if os.is_dir(wallpaper_dir) {
			_ = os.remove_all(wallpaper_dir)
		}

		// If GNOME, also remove matching XML files from ~/.local/share/gnome-background-properties/
		if de == .GNOME {
			gnome_properties_dir := fmt.tprintf("%s/.local/share/gnome-background-properties", home_dir)
			extract_dir := fmt.tprintf("%s/%s/%s", CASKROOM_DIR, flat, ver_flat)
			w := os.walker_create(extract_dir)
			defer os.walker_destroy(&w)
			for info in os.walker_walk(&w) {
				if info.type == .Regular && strings.has_suffix(strings.to_lower(info.name, context.temp_allocator), ".xml") {
					dst_xml := fmt.tprintf("%s/%s", gnome_properties_dir, info.name)
					_ = os.remove(dst_xml)
				}
			}
		}
	}

	if is_appimage {
		appimage_dir := fmt.tprintf("%s/.local/bin", home_dir)
		for art in c.artifacts {
			#partial switch a in art {
			case cask.AppImage_Artifact:
				target_name := a.target
				if target_name == "" {
					target_name = os.base(a.source)
				}
				dst := fmt.tprintf("%s/%s", appimage_dir, target_name)
				_ = os.remove(dst)
			case cask.Binary_Artifact:
				target_name := a.target
				if target_name == "" {
					target_name = os.base(a.source)
				}
				dst := fmt.tprintf("%s/%s", appimage_dir, target_name)
				_ = os.remove(dst)
			case cask.App_Artifact:
				if a.name != "" {
					dst := fmt.tprintf("%s/.local/share/applications/%s", home_dir, os.base(a.name))
					_ = os.remove(dst)
				}
			}
		}
	}

	if is_binary {
		bin_dir := fmt.tprintf("%s/.local/bin", home_dir)
		for art in c.artifacts {
			if ba, ok := art.(cask.Binary_Artifact); ok {
				target_name := ba.target
				if target_name == "" {
					src_rel := ba.source
					if src_rel == "" {
						src_rel = os.base(c.url)
					}
					target_name = os.base(src_rel)
				}
				dst := fmt.tprintf("%s/%s", bin_dir, target_name)
				_ = os.remove(dst)
			}
		}
	}

	// Clean up generic artifacts target paths
	for art in c.artifacts {
		if ga, ok := art.(cask.Generic_Artifact); ok {
			resolved_target := expand_home(ga.target, context.temp_allocator)
			if os.is_dir(resolved_target) {
				_ = os.remove_all(resolved_target)
			} else {
				_ = os.remove(resolved_target)
			}
		}
	}

	// Clean up VS Code dynamically generated desktop files
	if strings.contains(c.token, "visual-studio-code") {
		apps_dir := fmt.tprintf("%s/.local/share/applications", home_dir)
		_ = os.remove(fmt.tprintf("%s/code.desktop", apps_dir))
		_ = os.remove(fmt.tprintf("%s/code-url-handler.desktop", apps_dir))
	}

	// Remove Caskroom staged files
	caskroom_cask_dir := fmt.tprintf("%s/%s", CASKROOM_DIR, flat)
	if os.is_dir(caskroom_cask_dir) {
		_ = os.remove_all(caskroom_cask_dir)
	}

	fmt.printf("==> Uninstalled cask: %s\n", c.token)
	return true
}
