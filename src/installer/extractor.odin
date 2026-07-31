package installer

import "core:c/libc"
import "core:fmt"
import "core:os"
import "core:strings"
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

extract_package :: proc(file_path, dest_dir: string, format: Package_Format) -> bool {
	switch format {
	case .Deb:
		tmp_dir := fmt.tprintf("%s/.deb_tmp", dest_dir)
		_ = os.make_directory_all(tmp_dir, os.perm(0o755))
		defer os.remove_all(tmp_dir)

		cmd_ar := fmt.tprintf("ar x \"%s\" --output=\"%s\"", file_path, tmp_dir)
		if libc.system(strings.clone_to_cstring(cmd_ar, context.temp_allocator)) != 0 {
			cmd_ar = fmt.tprintf("cd \"%s\" && ar x \"%s\"", tmp_dir, file_path)
			if libc.system(strings.clone_to_cstring(cmd_ar, context.temp_allocator)) != 0 do return false
		}

		data_tar := ""
		if entries, err := os.read_directory_by_path(tmp_dir, -1, context.temp_allocator); err == nil {
			for entry in entries {
				if strings.has_prefix(entry.name, "data.tar") {
					data_tar = entry.fullpath
					break
				}
			}
		}
		if data_tar == "" do return false
		cmd_tar := fmt.tprintf("tar -xf \"%s\" -C \"%s\"", data_tar, dest_dir)
		return libc.system(strings.clone_to_cstring(cmd_tar, context.temp_allocator)) == 0

	case .Rpm:
		cmd_bsdtar := fmt.tprintf("bsdtar -xf \"%s\" -C \"%s\"", file_path, dest_dir)
		if libc.system(strings.clone_to_cstring(cmd_bsdtar, context.temp_allocator)) == 0 do return true
		cmd_cpio := fmt.tprintf("rpm2cpio \"%s\" | (cd \"%s\" && cpio -idmv)", file_path, dest_dir)
		return libc.system(strings.clone_to_cstring(cmd_cpio, context.temp_allocator)) == 0

	case .AppImage:
		target_name := os.base(file_path)
		dest_file := fmt.tprintf("%s/%s", dest_dir, target_name)
		if err := os.copy_file(dest_file, file_path); err != nil do return false
		platform.exec_cmd("chmod", []string{"chmod", "+x", dest_file})
		return true

	case .SevenZip:
		cmd_7z := fmt.tprintf("7z x -o\"%s\" \"%s\"", dest_dir, file_path)
		if libc.system(strings.clone_to_cstring(cmd_7z, context.temp_allocator)) == 0 do return true
		cmd_bsd := fmt.tprintf("bsdtar -xf \"%s\" -C \"%s\"", file_path, dest_dir)
		return libc.system(strings.clone_to_cstring(cmd_bsd, context.temp_allocator)) == 0

	case .TarGz, .TarXz, .TarZst, .TarBz2:
		cmd_tar := fmt.tprintf("tar -xf \"%s\" -C \"%s\"", file_path, dest_dir)
		return libc.system(strings.clone_to_cstring(cmd_tar, context.temp_allocator)) == 0

	case .Zip:
		cmd_unzip := fmt.tprintf("unzip -q \"%s\" -d \"%s\"", file_path, dest_dir)
		return libc.system(strings.clone_to_cstring(cmd_unzip, context.temp_allocator)) == 0

	case .Unknown:
		return false
	}
	return false
}
