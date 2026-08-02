package installer

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "../platform"

Package_Format :: enum {
	Unknown,
	TarGz,
	TarXz,
	TarZst,
	TarBz2,
	Zip,
	SevenZip,
	Deb,
	Rpm,
	AppImage,
}

detect_package_format :: proc(file_path: string) -> Package_Format {
	url_lower := strings.to_lower(file_path, context.temp_allocator)
	if strings.has_suffix(url_lower, ".deb") do return .Deb
	if strings.has_suffix(url_lower, ".rpm") do return .Rpm
	if strings.has_suffix(url_lower, ".appimage") do return .AppImage
	if strings.has_suffix(url_lower, ".7z") do return .SevenZip
	if strings.has_suffix(url_lower, ".tar.gz") || strings.has_suffix(url_lower, ".tgz") do return .TarGz
	if strings.has_suffix(url_lower, ".tar.xz") || strings.has_suffix(url_lower, ".txz") do return .TarXz
	if strings.has_suffix(url_lower, ".tar.zst") || strings.has_suffix(url_lower, ".tar.zstd") do return .TarZst
	if strings.has_suffix(url_lower, ".tar.bz2") || strings.has_suffix(url_lower, ".tbz2") do return .TarBz2
	if strings.has_suffix(url_lower, ".zip") do return .Zip

	// Magic bytes fallback probe
	probe_args := []string{"file", "--brief", file_path}
	probe_buf: [512]u8
	probe_out, _ := platform.exec_cmd_capture("file", probe_args, probe_buf[:])
	probe_lower := strings.to_lower(probe_out, context.temp_allocator)

	if strings.contains(probe_lower, "debian binary package") do return .Deb
	if strings.contains(probe_lower, "rpm") do return .Rpm
	if strings.contains(probe_lower, "appimage") do return .AppImage
	if strings.contains(probe_lower, "7-zip archive") do return .SevenZip
	if strings.contains(probe_lower, "zstandard") || strings.contains(probe_lower, "zstd") do return .TarZst
	if strings.contains(probe_lower, "xz compressed") do return .TarXz
	if strings.contains(probe_lower, "gzip compressed") do return .TarGz
	if strings.contains(probe_lower, "bzip2 compressed") do return .TarBz2
	if strings.contains(probe_lower, "zip archive") do return .Zip

	return .Unknown
}

// rpm_extract_via_cpio implements the equivalent of
//
//	rpm2cpio <file> | (cd <dest> && cpio --no-absolute-filenames -idmv)
//
// using a real pipe between two forked children and execvp — no shell is
// involved, so package paths containing `$`, quotes, or command separators
// cannot inject commands. Paths travel as separate argv elements.
rpm_extract_via_cpio :: proc(file_path, dest_dir: string) -> bool {
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK {
		return false
	}

	make_argv :: proc(args: []string) -> [^]cstring {
		argv := make([]cstring, len(args) + 1, context.temp_allocator)
		for a, i in args {
			argv[i] = strings.clone_to_cstring(a, context.temp_allocator)
		}
		argv[len(args)] = nil
		return &argv[0]
	}

	// Child 1: rpm2cpio -> stdout -> pipe write end
	pid1 := posix.fork()
	if pid1 < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		return false
	}
	if pid1 == 0 {
		posix.close(fds[0])
		posix.dup2(fds[1], posix.FD(1))
		posix.close(fds[1])
		posix.execvp(strings.clone_to_cstring("rpm2cpio", context.temp_allocator), make_argv([]string{"rpm2cpio", file_path}))
		posix.exit(1)
	}

	// Child 2: cpio <- stdin <- pipe read end, chdir to dest_dir
	pid2 := posix.fork()
	if pid2 < 0 {
		posix.close(fds[0])
		posix.close(fds[1])
		status: c.int
		posix.waitpid(pid1, &status, nil)
		return false
	}
	if pid2 == 0 {
		posix.close(fds[1])
		posix.dup2(fds[0], posix.FD(0))
		posix.close(fds[0])
		// If chdir fails, cpio would extract into the inherited working
		// directory instead of dest_dir — fail the child so the parent sees
		// a non-zero status instead of extracting to the wrong place.
		if posix.chdir(strings.clone_to_cstring(dest_dir, context.temp_allocator)) != .OK {
			posix.exit(1)
		}
		posix.execvp(strings.clone_to_cstring("cpio", context.temp_allocator), make_argv([]string{"cpio", "--no-absolute-filenames", "-idmv"}))
		posix.exit(1)
	}

	// Parent: close both ends so the children observe EOF at the right time.
	posix.close(fds[0])
	posix.close(fds[1])

	status1: c.int
	status2: c.int
	posix.waitpid(pid1, &status1, nil)
	posix.waitpid(pid2, &status2, nil)
	return status1 == 0 && status2 == 0
}

extract_package :: proc(file_path, dest_dir: string, format: Package_Format) -> bool {
	switch format {
	case .Deb:
		tmp_dir := fmt.tprintf("%s/.deb_tmp", dest_dir)
		_ = os.make_directory_all(tmp_dir, os.perm(0o755))
		defer os.remove_all(tmp_dir)

		// Extract the .deb contents into tmp_dir using ar. GNU binutils
		// supports --output=; on failure we return false (the previous code
		// had a `cd`-based fallback that we cannot express without shell).
		if !platform.exec_cmd("ar", []string{"ar", "x", file_path, fmt.tprintf("--output=%s", tmp_dir)}) {
			return false
		}

		data_tar := ""
		allocator := context.allocator
		if entries, err := os.read_directory_by_path(tmp_dir, -1, allocator); err == nil {
			defer os.file_info_slice_delete(entries, allocator)
			for entry in entries {
				if strings.has_prefix(entry.name, "data.tar") {
					data_tar = strings.clone(entry.fullpath, context.temp_allocator)
					break
				}
			}
		}
		if data_tar == "" do return false
		return platform.exec_cmd("tar", []string{"tar", "-xf", data_tar, "-C", dest_dir})

	case .Rpm:
		if platform.exec_cmd("bsdtar", []string{"bsdtar", "-xf", file_path, "-C", dest_dir}) {
			return true
		}
		// Fallback for RPMs: rpm2cpio piped to cpio.
		return rpm_extract_via_cpio(file_path, dest_dir)

	case .AppImage:
		target_name := os.base(file_path)
		dest_file := fmt.tprintf("%s/%s", dest_dir, target_name)
		if err := os.copy_file(dest_file, file_path); err != nil do return false
		return platform.exec_cmd("chmod", []string{"chmod", "+x", dest_file})

	case .SevenZip:
		if platform.exec_cmd("7z", []string{"7z", "x", fmt.tprintf("-o%s", dest_dir), file_path}) {
			return true
		}
		return platform.exec_cmd("bsdtar", []string{"bsdtar", "-xf", file_path, "-C", dest_dir})

	case .TarGz, .TarXz, .TarZst, .TarBz2:
		return platform.exec_cmd("tar", []string{"tar", "-xf", file_path, "-C", dest_dir})

	case .Zip:
		return platform.exec_cmd("unzip", []string{"unzip", "-q", file_path, "-d", dest_dir})

	case .Unknown:
		return false
	}
	return false
}
