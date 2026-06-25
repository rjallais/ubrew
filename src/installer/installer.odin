package installer

import "core:fmt"
import "core:os"
import "core:io"
import "core:c/libc"
import "core:strings"
import "core:crypto/hash"
import "core:encoding/hex"
import "core:encoding/json"
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

// is_safe_binary_name returns true if the name contains only characters
// that are safe to interpolate into a shell command (alphanumeric, '-',
// '_', '.', '/').
is_safe_binary_name :: proc(name: string) -> bool {
	for c in name {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			 (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '/') {
			return false
		}
	}
	return len(name) > 0
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

	p := path
	expanded := false
	if p == "~" {
		p = home_dir
		expanded = true
	} else if strings.has_prefix(p, "~/") {
		p = strings.concatenate({home_dir, p[1:]}, context.temp_allocator)
		expanded = true
	}

	if p == "$HOME" {
		p = home_dir
		expanded = true
	} else if strings.has_prefix(p, "$HOME/") {
		p = strings.concatenate({home_dir, p[5:]}, context.temp_allocator)
		expanded = true
	}

	if expanded {
		return strings.clone(p, allocator)
	}
	return strings.clone(path, allocator)
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

is_elf_file :: proc(path: string) -> bool {
	f, err := os.open(path, os.O_RDONLY)
	if err != nil {
		return false
	}
	defer os.close(f)

	buf: [4]u8
	n, read_err := os.read(f, buf[:])
	if read_err != nil || n != 4 {
		return false
	}

	return buf[0] == 0x7f && buf[1] == 'E' && buf[2] == 'L' && buf[3] == 'F'
}

is_macho_file :: proc(path: string) -> bool {
	f, err := os.open(path, os.O_RDONLY)
	if err != nil {
		return false
	}
	defer os.close(f)

	buf: [4]u8
	n, read_err := os.read(f, buf[:])
	if read_err != nil || n != 4 {
		return false
	}

	magic := (u32(buf[0]) << 24) | (u32(buf[1]) << 16) | (u32(buf[2]) << 8) | u32(buf[3])
	magic_le := (u32(buf[3]) << 24) | (u32(buf[2]) << 16) | (u32(buf[1]) << 8) | u32(buf[0])

	// 0xFEEDFACE, 0xFEEDFACF, 0xCAFEBABE
	if magic == 0xFEEDFACE || magic == 0xFEEDFACF || magic == 0xCAFEBABE {
		return true
	}
	if magic_le == 0xFEEDFACE || magic_le == 0xFEEDFACF || magic_le == 0xCAFEBABE {
		return true
	}
	return false
}

// ELF constant for program header type "interpreter request".
PT_INTERP :: 3

// Read the file's ELF header and program headers in a single syscall pair
// and return true iff the file is an ELF executable (or PIE) that carries
// a PT_INTERP segment. Shared objects and statically-linked binaries
// return false. We use this to skip `patchelf --set-interpreter` on
// binaries that have no interpreter to rewrite — calling patchelf on
// such files prints a noisy "cannot find section '.interp'" warning
// and forks a child process for nothing.
elf_has_interp :: proc(path: string) -> bool {
	f, err := os.open(path, os.O_RDONLY)
	if err != nil {
		return false
	}
	defer os.close(f)

	// 64-byte ELF identification + a few fields we need from the header.
	// For 64-bit ELF: e_phoff is at offset 32, e_phentsize at 54,
	// e_phnum at 56. Each 64-bit Phdr is 56 bytes; p_type is at 0.
	ident: [16]u8
	n, read_err := os.read(f, ident[:])
	if read_err != nil || n != 16 {
		return false
	}
	if ident[0] != 0x7f || ident[1] != 'E' || ident[2] != 'L' || ident[3] != 'F' {
		return false
	}
	is_64 := ident[4] == 2
	is_le  := ident[5] == 1
	if !is_64 {
		// We only build for 64-bit Linux; 32-bit ELFs are out of scope.
		return false
	}
	if !is_le {
		return false
	}

	// Read the rest of the ELF header (up through e_phnum). For 64-bit,
	// the header is 64 bytes total; we already consumed 16.
	rest: [48]u8
	n2, read_err2 := os.read(f, rest[:])
	if read_err2 != nil || n2 != 48 {
		return false
	}

	read_u16 :: proc(b: []u8, off: int) -> u16 {
		return u16(b[off]) | (u16(b[off+1]) << 8)
	}
	read_u64 :: proc(b: []u8, off: int) -> u64 {
		v: u64 = 0
		for i in 0..<8 {
			v |= u64(b[off+i]) << (u8(i) * 8)
		}
		return v
	}

	// Layout of the 64-byte ELF64 header (offsets in the spec):
	//   0  e_ident[16]
	//  16  e_type (2), e_machine (2), e_version (4), e_entry (8)
	//  32  e_phoff (8)
	//  40  e_shoff (8)
	//  48  e_flags (4), e_ehsize (2)
	//  54  e_phentsize (2)
	//  56  e_phnum (2), e_shentsize (2), e_shnum (2), e_shstrndx (2)
	// `rest` is what comes after the 16-byte ident, so its index 0 is
	// header offset 16. The fields we need start at rest[16], rest[38],
	// rest[40].
	e_phoff     := read_u64(rest[:], 16)  // header offset 32
	e_phentsize := read_u16(rest[:], 38)  // header offset 54
	e_phnum     := read_u16(rest[:], 40)  // header offset 56

	if e_phnum == 0 || e_phentsize != 56 {
		return false
	}
	// Guard against absurd header tables (corrupt or maliciously small
	// files claiming a huge table). 1024 program headers is more than
	// any real Linux binary has.
	if e_phnum > 1024 {
		return false
	}

	// Seek to e_phoff and walk program headers.
	if _, seek_err := os.seek(f, i64(e_phoff), io.Seek_From.Start); seek_err != nil {
		return false
	}

	phdr: [56]u8
	for _ in 0..<int(e_phnum) {
		n3, perr := os.read(f, phdr[:])
		if perr != nil || n3 != 56 {
			return false
		}
		p_type := u32(phdr[0]) | (u32(phdr[1]) << 8) | (u32(phdr[2]) << 16) | (u32(phdr[3]) << 24)
		if p_type == PT_INTERP {
			return true
		}
	}
	return false
}

relocate_keg_binaries :: proc(dir: string, relocated_count: ^int) {
	if fd, fd_err := os.open(dir); fd_err == nil {
		defer os.close(fd)
		if infos, read_err := os.read_directory_by_path(dir, -1, context.temp_allocator); read_err == nil {
			for info in infos {
				if info.type == .Directory {
					relocate_keg_binaries(info.fullpath, relocated_count)
				} else if info.type == .Regular {
					is_exec := .Execute_User in info.mode || .Execute_Group in info.mode || .Execute_Other in info.mode
					if is_exec && elf_has_interp(info.fullpath) {
						// Probe the current interpreter. patchelf forks a
						// child process to print it; if it already matches
						// the target we skip the write entirely. This
						// eliminates redundant writes for x86_64 Linux
						// bottles that ship with the right ld.so path
						// (which is most of them, since Homebrew targets
						// the same path on x86_64 Linux).
						print_buf: [512]u8
						print_args := []string{"patchelf", "--print-interpreter", info.fullpath}
						current, _ := platform.exec_cmd_capture("patchelf", print_args, print_buf[:])
						current = strings.trim_space(current)
						if current == INTERPRETER {
							continue
						}
						chmod_args := []string{"chmod", "+w", info.fullpath}
						platform.exec_cmd("chmod", chmod_args)
						patch_args := []string{"patchelf", "--set-interpreter", INTERPRETER, info.fullpath}
						if platform.exec_cmd("patchelf", patch_args) {
							relocated_count^ += 1
						}
					}
				}
			}
		}
	}
}

relocate_single_file :: proc(path: string) {
	// 1. If it's a symlink
	target, read_link_err := os.read_link(path, context.temp_allocator)
	if read_link_err == nil {
		if strings.contains(target, "@@HOMEBREW_PREFIX@@") || strings.contains(target, "@@HOMEBREW_CELLAR@@") {
			new_target, _ := strings.replace_all(target, "@@HOMEBREW_CELLAR@@", PREFIX + "/Cellar", context.temp_allocator)
			new_target, _ = strings.replace_all(new_target, "@@HOMEBREW_PREFIX@@", PREFIX, context.temp_allocator)
			os.remove(path)
			os.symlink(new_target, path)
		}
		return
	}

	// 2. If it's a regular file
	if is_elf_file(path) {
		rpath_buf: [2048]u8
		rpath_args := []string{"patchelf", "--print-rpath", path}
		rpath, rpath_truncated := platform.exec_cmd_capture("patchelf", rpath_args, rpath_buf[:], true)
		rpath = strings.trim_space(rpath)
		// Skip the rpath rewrite if the captured output was truncated —
		// writing back a clipped rpath would corrupt the binary's RUNPATH.
		// Long rpaths are rare in practice; the caller can reinstall with
		// a larger buffer if needed.
		if !rpath_truncated && (strings.contains(rpath, "@@HOMEBREW_PREFIX@@") || strings.contains(rpath, "@@HOMEBREW_CELLAR@@")) {
			new_rpath, _ := strings.replace_all(rpath, "@@HOMEBREW_CELLAR@@", PREFIX + "/Cellar", context.temp_allocator)
			new_rpath, _ = strings.replace_all(new_rpath, "@@HOMEBREW_PREFIX@@", PREFIX, context.temp_allocator)
			chmod_args := []string{"chmod", "+w", path}
			platform.exec_cmd("chmod", chmod_args)
			set_args := []string{"patchelf", "--set-rpath", new_rpath, path}
			platform.exec_cmd("patchelf", set_args)
		} else if rpath_truncated {
			fmt.eprintf("Warning: rpath for %s exceeded buffer; skipping rpath rewrite\n", path)
		}
	} else if is_macho_file(path) {
		// Skip Mach-O files to avoid byte shifting / binary corruption
	} else {
		data, read_err := os.read_entire_file(path, context.temp_allocator)
		if read_err == nil && len(data) > 0 {
			content := string(data)
			if strings.contains(content, "@@HOMEBREW_PREFIX@@") || strings.contains(content, "@@HOMEBREW_CELLAR@@") {
				new_content, _ := strings.replace_all(content, "@@HOMEBREW_CELLAR@@", PREFIX + "/Cellar", context.temp_allocator)
				new_content, _ = strings.replace_all(new_content, "@@HOMEBREW_PREFIX@@", PREFIX, context.temp_allocator)
				chmod_args := []string{"chmod", "+w", path}
				platform.exec_cmd("chmod", chmod_args)
				_ = os.write_entire_file_from_string(path, new_content)
			}
		}
	}
}

relocate_keg_placeholders :: proc(dir: string) {
	if fd, fd_err := os.open(dir); fd_err == nil {
		defer os.close(fd)
		if infos, read_err := os.read_directory_by_path(dir, -1, context.temp_allocator); read_err == nil {
			for info in infos {
				if info.type == .Directory {
					relocate_keg_placeholders(info.fullpath)
				} else {
					relocate_single_file(info.fullpath)
				}
			}
		}
	}
}

install_bottle :: proc(f: formula.Formula, prefix: string, on_request: bool) -> bool {
	fmt.printf("==> Installing bottle: %s %s\n", f.name, f.version)

	if len(f.bottle_url) == 0 {
		fmt.println("Error: No bottle URL available for this platform.")
		return false
	}

	sha := strings.to_lower(strings.trim_space(f.bottle_sha256), context.temp_allocator)

	if store.store_has_relocated_entry(sha) {
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
	already_downloaded := os.is_file(dl_path) && sha256_matches(dl_path, f.bottle_sha256)

	if !already_downloaded {
		fmt.printf("==> Downloading: %s\n", f.bottle_url)

		if !strings.has_prefix(f.bottle_url, "http://") && !strings.has_prefix(f.bottle_url, "https://") {
			fmt.println("Error: Invalid bottle URL scheme.")
			return false
		}

		dl_args := []string{"curl", "-#", "-H", "Authorization: Bearer QQ==", "-L", f.bottle_url, "-o", dl_path}
		if !platform.exec_cmd("curl", dl_args) {
			fmt.println("Error: Download failed.")
			return false
		}
	} else {
		fmt.printf("==> Already downloaded: %s\n", dl_path)
	}
	defer os.remove(dl_path)

	if !sha256_matches(dl_path, f.bottle_sha256) {
		fmt.println("Error: SHA256 verification failed for bottle.")
		return false
	}

	if !os.is_dir(prefix) {
		fmt.printf("==> Creating prefix: %s\n", prefix)
	}
	if !ensure_dir(prefix) {
		return false
	}

	cellar_dir := PREFIX + "/Cellar"
	keg_dir := fmt.tprintf("%s/%s/%s", cellar_dir, f.name, f.version)
	formula_cellar_dir := fmt.tprintf("%s/%s", cellar_dir, f.name)
	_ = os.remove_all(formula_cellar_dir)

	fmt.printf("==> Unpacking to: %s\n", cellar_dir)
	ex_args := []string{"tar", "-xzf", dl_path, "-C", cellar_dir}
	if platform.exec_cmd("tar", ex_args) {
		if fd, fd_err := os.open(formula_cellar_dir); fd_err == nil {
			defer os.close(fd)
			if infos, read_err := os.read_directory_by_path(formula_cellar_dir, -1, context.temp_allocator); read_err == nil {
				for info in infos {
					if info.type == .Directory {
						if info.name != f.version {
							src_path := info.fullpath
							dst_path := fmt.tprintf("%s/%s", formula_cellar_dir, f.version)
							if rename_err := os.rename(src_path, dst_path); rename_err != nil {
								fmt.printf("Warning: Failed to rename unpacked directory from %s to %s: %v\n", info.name, f.version, rename_err)
							}
						}
						break
					}
				}
			}
		}
	} else {
		if !ensure_dir(keg_dir) {
			return false
		}
		ex_fallback_args := []string{"tar", "-xzf", dl_path, "--strip-components=2", "-C", keg_dir}
		if !platform.exec_cmd("tar", ex_fallback_args) {
			fmt.println("Error: Extraction failed.")
			return false
		}
	}

	relocated_bin_count := 0
	relocate_keg_binaries(keg_dir, &relocated_bin_count)
	if relocated_bin_count > 0 {
		fmt.printf("==> Relocated %d binary interpreter(s)!\n", relocated_bin_count)
	}
	relocate_keg_placeholders(keg_dir)

	bin_dir := fmt.tprintf("%s/bin", keg_dir)
	if os.is_dir(bin_dir) {
		fd, fd_err := os.open(bin_dir)
		if fd_err == nil {
			defer os.close(fd)
			infos, read_err := os.read_directory_by_path(bin_dir, -1, context.temp_allocator)
			if read_err == nil {
				for info in infos {
					if info.type == .Regular || info.type == .Symlink {
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

	// Create opt symlink
	opt_dir := fmt.tprintf("%s/opt", prefix)
	_ = os.make_directory_all(opt_dir, os.perm(0o755))
	opt_link := fmt.tprintf("%s/%s", opt_dir, f.name)
	_ = os.remove(opt_link)
	opt_target := fmt.tprintf("../Cellar/%s/%s", f.name, f.version)
	_ = os.symlink(opt_target, opt_link)

	// Write install receipt so `autoremove` can distinguish requested
	// installs from dep-only installs.
	receipt := Install_Receipt{
		name                = strings.clone(f.name, context.allocator),
		version             = strings.clone(f.version, context.allocator),
		installed_on_request = on_request,
		poured_from_bottle   = true,
		tap                  = strings.clone(f.tap, context.allocator),
		runtime_dependencies = nil,
	}
	defer destroy_install_receipt(receipt)
	if len(f.dependencies) > 0 {
		deps := make([dynamic]string, context.allocator)
		for d in f.dependencies {
			append(&deps, strings.clone(d, context.allocator))
		}
		receipt.runtime_dependencies = deps[:]
	}
	_ = write_install_receipt(keg_dir, receipt)

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

install_source :: proc(f: formula.Formula, prefix: string, on_request: bool) -> bool {
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
	is_archive := true
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
	} else {
		is_archive = false
		last_dot := strings.last_index_byte(url, '.')
		last_slash := strings.last_index_byte(url, '/')
		if last_dot > last_slash {
			ext = url[last_dot:]
		} else {
			ext = ""
		}
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
	if !is_archive {
		filename := url
		last_slash := strings.last_index_byte(url, '/')
		if last_slash >= 0 {
			filename = url[last_slash + 1:]
		}
		dest := fmt.tprintf("%s/%s", build_dir, filename)
		cp_args := []string{"cp", dl_path, dest}
		if !platform.exec_cmd("cp", cp_args) {
			fmt.println("Error: Failed to copy single source file to build directory.")
			return false
		}
	} else if ext == ".zip" {
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
				if !is_safe_binary_name(b) {
					fmt.eprintf("Warning: skipping binary %q (unsafe name)\n", b)
					continue
				}
				// Pipeline: find the file (excluding bin/ itself) and mv it.
				// `2>/dev/null` suppresses find errors; `|| true` keeps the
				// pipeline non-fatal if the file isn't found.
				mv_cmd := fmt.tprintf(
					"FOUND=$(find \"%s\" -maxdepth 3 -type f -name \"%s\" -not -path \"%s/*\" 2>/dev/null | head -1); " +
					"if [ -z \"$FOUND\" ]; then FOUND=$(find \"%s\" -maxdepth 3 -type f -name \"%s*\" -not -path \"%s/*\" 2>/dev/null | head -1); fi; " +
					"if [ -z \"$FOUND\" ]; then FOUND=$(find \"%s\" -maxdepth 3 -type f -name \"*%s*\" -not -path \"%s/*\" 2>/dev/null | head -1); fi; " +
					"if [ -n \"$FOUND\" ]; then mv \"$FOUND\" \"%s/%s\" && chmod +x \"%s/%s\"; fi",
					keg_dir, b, keg_bin,
					keg_dir, b, keg_bin,
					keg_dir, b, keg_bin,
					keg_bin, b, keg_bin, b,
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
					if info.type == .Regular || info.type == .Symlink {
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

	relocate_keg_placeholders(keg_dir)

	// Create opt symlink
	opt_dir := fmt.tprintf("%s/opt", prefix)
	_ = os.make_directory_all(opt_dir, os.perm(0o755))
	opt_link := fmt.tprintf("%s/%s", opt_dir, f.name)
	_ = os.remove(opt_link)
	opt_target := fmt.tprintf("../Cellar/%s/%s", f.name, f.version)
	_ = os.symlink(opt_target, opt_link)

	// Write install receipt so `autoremove` can distinguish requested
	// installs from dep-only installs.
	receipt := Install_Receipt{
		name                = strings.clone(f.name, context.allocator),
		version             = strings.clone(f.version, context.allocator),
		installed_on_request = on_request,
		poured_from_bottle   = false,
		tap                  = strings.clone(f.tap, context.allocator),
		runtime_dependencies = nil,
	}
	defer destroy_install_receipt(receipt)
	if len(f.dependencies) > 0 {
		deps := make([dynamic]string, context.allocator)
		for d in f.dependencies {
			append(&deps, strings.clone(d, context.allocator))
		}
		receipt.runtime_dependencies = deps[:]
	}
	_ = write_install_receipt(keg_dir, receipt)

	fmt.printf("==> Successful installation of %s into %s!\n", f.name, keg_dir)
	return true
}

flatten_token :: proc(token: string) -> string {
    out, _ := strings.replace_all(token, "/", "-", context.temp_allocator)
    return out
}

resolve_arch_placeholders :: proc(s: string, allocator := context.temp_allocator) -> string {
	arch_str := "x64"
	when ODIN_ARCH == .arm64 {
		arch_str = "arm64"
	}
	out, _ := strings.replace_all(s, "{arch}", arch_str, allocator)
	return out
}

cask_download_path :: proc(c: cask.Cask) -> string {
	flat := flatten_token(c.token)
	ver := c.version
	if ver == "" {
		ver = "latest"
	}
	ver_flat, _ := strings.replace_all(ver, "/", "-", context.temp_allocator)

	is_font := false
	is_wallpaper := false
	if len(c.artifacts) > 0 {
		for art in c.artifacts {
			#partial switch _ in art {
			case cask.Font_Artifact:
				is_font = true
			case cask.Wallpaper_Artifact:
				is_wallpaper = true
			}
		}
	}

	is_appimage := strings.contains(strings.to_lower(c.url), "appimage")

	if is_appimage {
		return fmt.tprintf("%s/%s-%s.AppImage", CACHE_DIR, flat, ver_flat)
	}

	ext := ""
	url := c.url

	if is_font {
		// Font defaults to .zip
		ext = ".zip"
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
	} else if is_wallpaper {
		// Wallpaper defaults to .tar.gz
		ext = ".tar.gz"
		if strings.has_suffix(url, ".zip") {
			ext = ".zip"
		} else if strings.has_suffix(url, ".tar.bz2") || strings.has_suffix(url, ".tbz2") {
			ext = ".tar.bz2"
		} else if strings.has_suffix(url, ".tar.xz") || strings.has_suffix(url, ".txz") {
			ext = ".tar.xz"
		} else if strings.has_suffix(url, ".tar.zst") || strings.has_suffix(url, ".tar.zstd") {
			ext = ".tar.zst"
		}
	} else {
		// Binary cask: no default extension if not matched
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
	}

	return fmt.tprintf("%s/%s-%s%s", CACHE_DIR, flat, ver_flat, ext)
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

	if os.is_file(dl_path) && sha256_matches(dl_path, sha256) {
		fmt.printf("==> Already downloaded: %s\n", dl_path)
		if store.is_valid_sha256(sha256) {
			_ = store.blob_ensure_dir()
			buf: [512]u8
			cached := store.blob_path(sha256, buf[:])
			if !os.is_file(cached) {
				cmd_cache := fmt.tprintf("cp '%s' '%s'", dl_path, cached)
				cmd_cache_cstr := strings.clone_to_cstring(cmd_cache, context.temp_allocator)
				if libc.system(cmd_cache_cstr) == 0 {
					fmt.printf("==> Cached blob %s\n", sha256[:12])
				}
			}
		}
		return true
	}

	fmt.printf("==> Downloading: %s\n", url)
	cmd_dl := fmt.tprintf("curl -sfL \"%s\" -o \"%s\"", url, dl_path)
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

	dl_path := cask_download_path(c)
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
		probe_out, _ := platform.exec_cmd_capture("file", probe_args, probe_buf[:])
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
			src_rel := resolve_arch_placeholders(ba.source)
			if src_rel == "" {
				src_rel = resolve_arch_placeholders(ba.target)
			}
			if src_rel == "" {
				src_rel = os.base(url)
			}
			target_name := resolve_arch_placeholders(ba.target)
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
			src_rel := resolve_arch_placeholders(ga.source)
			target_path := resolve_arch_placeholders(ga.target)

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

	dl_path := cask_download_path(c)
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

	dl_path := cask_download_path(c)
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
	dl_path := cask_download_path(c)
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
			src_rel := resolve_arch_placeholders(a.source)
			target_name := resolve_arch_placeholders(a.target)
			if target_name == "" {
				target_name = os.base(src_rel)
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
			name_resolved := resolve_arch_placeholders(a.name)
			if name_resolved == "" {
				continue
			}
			src := fmt.tprintf("%s/%s", squashfs_dir, name_resolved)
			if !os.is_file(src) {
				continue
			}
			dst := fmt.tprintf("%s/.local/share/applications/%s", home_dir, os.base(name_resolved))
			_ = os.make_directory_all(fmt.tprintf("%s/.local/share/applications", home_dir), os.perm(0o755))
			if err := os.copy_file(dst, src); err != nil {
				fmt.printf("==> Warning: failed copying desktop file %s\n", name_resolved)
			}
		case cask.Binary_Artifact:
			if a.source == "" {
				continue
			}
			src_rel := resolve_arch_placeholders(a.source)
			src := fmt.tprintf("%s/%s", squashfs_dir, src_rel)
			if !os.is_file(src) {
				continue
			}
			target_name := resolve_arch_placeholders(a.target)
			if target_name == "" {
				target_name = os.base(src_rel)
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
				target_name := resolve_arch_placeholders(a.target)
				src_rel := resolve_arch_placeholders(a.source)
				if target_name == "" {
					target_name = os.base(src_rel)
				}
				dst := fmt.tprintf("%s/%s", appimage_dir, target_name)
				_ = os.remove(dst)
			case cask.Binary_Artifact:
				target_name := resolve_arch_placeholders(a.target)
				src_rel := resolve_arch_placeholders(a.source)
				if target_name == "" {
					target_name = os.base(src_rel)
				}
				dst := fmt.tprintf("%s/%s", appimage_dir, target_name)
				_ = os.remove(dst)
			case cask.App_Artifact:
				name_resolved := resolve_arch_placeholders(a.name)
				if name_resolved != "" {
					dst := fmt.tprintf("%s/.local/share/applications/%s", home_dir, os.base(name_resolved))
					_ = os.remove(dst)
				}
			}
		}
	}

	if is_binary {
		bin_dir := fmt.tprintf("%s/.local/bin", home_dir)
		for art in c.artifacts {
			if ba, ok := art.(cask.Binary_Artifact); ok {
				target_name := resolve_arch_placeholders(ba.target)
				if target_name == "" {
					src_rel := resolve_arch_placeholders(ba.source)
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
			target_resolved := resolve_arch_placeholders(ga.target)
			resolved_target := expand_home(target_resolved, context.temp_allocator)
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

// Install_Receipt records the intent and the resolved runtime dependencies at
// the moment a formula was installed. It is written to
// `<keg>/INSTALL_RECEIPT.json` and consumed by `autoremove` to distinguish
// user-requested installs from dep-only installs.
Install_Receipt :: struct {
	name:                string,
	version:             string,
	installed_on_request: bool,
	poured_from_bottle:   bool,
	tap:                 string,
	runtime_dependencies: []string,
}

destroy_install_receipt :: proc(r: Install_Receipt) {
	delete(r.name)
	delete(r.version)
	delete(r.tap)
	for d in r.runtime_dependencies {
		delete(d)
	}
	delete(r.runtime_dependencies)
}

write_install_receipt :: proc(keg_dir: string, r: Install_Receipt) -> bool {
	// Use the Odin core json marshaller. Field names in the struct match
	// the desired JSON keys; `json.marshal` produces RFC8259-compliant
	// output with proper string escaping (unlike `fmt.tprintf("%q", ...)`
	// which emits Odin string-literal syntax).
	payload, merr := json.marshal(r)
	if merr != nil {
		fmt.printf("Warning: failed to marshal install receipt for %s: %v\n", r.name, merr)
		return false
	}
	defer delete(payload)
	receipt_path := fmt.tprintf("%s/INSTALL_RECEIPT.json", keg_dir)
	werr := os.write_entire_file(receipt_path, payload)
	if werr != nil {
		fmt.printf("Warning: failed to write install receipt to %s: %v\n", receipt_path, werr)
		return false
	}
	return true
}

// read_install_receipt returns the receipt for the given keg directory.
// ok=false if no receipt is on disk (legacy install). When a receipt is
// missing, the caller should treat the formula as `installed_on_request=true`
// to be safe (autoremove will skip it).
read_install_receipt :: proc(keg_dir: string, allocator := context.allocator) -> (r: Install_Receipt, ok: bool) {
	path := fmt.tprintf("%s/INSTALL_RECEIPT.json", keg_dir)
	data, rerr := os.read_entire_file(path, allocator)
	if rerr != nil {
		return r, false
	}
	defer delete(data)
	val, perr := json.parse(data)
	if perr != nil {
		return r, false
	}
	defer json.destroy_value(val)
	root, is_obj := val.(json.Object)
	if !is_obj {
		return r, false
	}
	if name_val, present := root["name"]; present {
		if s, is_str := name_val.(json.String); is_str {
			r.name = strings.clone(s, allocator)
		}
	}
	if ver_val, present := root["version"]; present {
		if s, is_str := ver_val.(json.String); is_str {
			r.version = strings.clone(s, allocator)
		}
	}
	if ior_val, present := root["installed_on_request"]; present {
		if b, is_bool := ior_val.(json.Boolean); is_bool {
			r.installed_on_request = bool(b)
		}
	}
	if pfb_val, present := root["poured_from_bottle"]; present {
		if b, is_bool := pfb_val.(json.Boolean); is_bool {
			r.poured_from_bottle = bool(b)
		}
	}
	if tap_val, present := root["tap"]; present {
		if s, is_str := tap_val.(json.String); is_str {
			r.tap = strings.clone(s, allocator)
		}
	}
	if deps_val, present := root["runtime_dependencies"]; present {
		if arr, is_arr := deps_val.(json.Array); is_arr {
			deps := make([dynamic]string, allocator)
			for d in arr {
				if s, is_str := d.(json.String); is_str {
					append(&deps, strings.clone(s, allocator))
				}
			}
			r.runtime_dependencies = deps[:]
		}
	}
	return r, true
}

download_bottles_parallel :: proc(urls, paths: []string) -> bool {
	if len(urls) == 0 do return true

	// Create cache directory if needed
	_ = os.make_directory_all(CACHE_DIR, os.perm(0o755))

	if len(urls) == 1 {
		fmt.printf("==> Downloading: %s\n", urls[0])
		args := []string{"curl", "-#", "-L", "--compressed", "-H", "Authorization: Bearer QQ==", "-o", paths[0], urls[0]}
		return platform.exec_cmd("curl", args)
	}

	args := make([dynamic]string, context.temp_allocator)
	defer delete(args)
	append(&args, "curl")
	append(&args, "-sL")
	append(&args, "--compressed")
	append(&args, "--no-progress-meter")
	append(&args, "--http2")
	append(&args, "--parallel")
	append(&args, "-H")
	append(&args, "Authorization: Bearer QQ==")

	for i in 0..<len(urls) {
		append(&args, "-o")
		append(&args, paths[i])
		append(&args, urls[i])
	}

	fmt.printf("==> Downloading %d bottle(s) in parallel...\n", len(urls))
	return platform.exec_cmd("curl", args[:])
}

download_casks_parallel :: proc(urls, paths: []string) -> bool {
	if len(urls) == 0 do return true

	// Create cache directory if needed
	_ = os.make_directory_all(CACHE_DIR, os.perm(0o755))

	if len(urls) == 1 {
		fmt.printf("==> Downloading: %s\n", urls[0])
		args := []string{"curl", "-#", "-L", "--compressed", "-o", paths[0], urls[0]}
		return platform.exec_cmd("curl", args)
	}

	args := make([dynamic]string, context.temp_allocator)
	defer delete(args)
	append(&args, "curl")
	append(&args, "-sL")
	append(&args, "--compressed")
	append(&args, "--no-progress-meter")
	append(&args, "--http2")
	append(&args, "--parallel")

	for i in 0..<len(urls) {
		append(&args, "-o")
		append(&args, paths[i])
		append(&args, urls[i])
	}

	fmt.printf("==> Downloading %d cask/source archive(s) in parallel...\n", len(urls))
	return platform.exec_cmd("curl", args[:])
}
