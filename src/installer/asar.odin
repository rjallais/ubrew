package installer

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:strconv"
import "core:strings"
import "../platform"

// extract_asar_icon parses an Electron ASAR package, locates the icon
// (defaulting to "icon.png"), and writes it directly to out_path.
// Implements the Electron ASAR binary header specification:
//   offset 8:  uint32_le (padded header size + 4)
//   offset 12: uint32_le (true JSON header length)
//   offset 16: JSON header payload
//   payload begins at offset 16 + padded_size
extract_asar_icon :: proc(asar_path: string, out_path: string, target_icon_name: string = "icon.png") -> bool {
	f, err := os.open(asar_path, os.O_RDONLY)
	if err != os.ERROR_NONE {
		return false
	}
	defer os.close(f)

	// Read 16-byte fixed header
	hdr_buf: [16]u8
	n, rerr := os.read(f, hdr_buf[:])
	if rerr != os.ERROR_NONE || n < 16 {
		return false
	}

	raw_padded := u32(hdr_buf[8]) | (u32(hdr_buf[9]) << 8) | (u32(hdr_buf[10]) << 16) | (u32(hdr_buf[11]) << 24)
	raw_true   := u32(hdr_buf[12]) | (u32(hdr_buf[13]) << 8) | (u32(hdr_buf[14]) << 16) | (u32(hdr_buf[15]) << 24)

	padded_size := i64(raw_padded) - 4
	true_size := i64(raw_true)

	if padded_size < 0 || true_size <= 0 || true_size > 50 * 1024 * 1024 {
		return false
	}

	// Read the JSON header
	json_buf := make([]u8, int(true_size), context.temp_allocator)
	defer delete(json_buf, context.temp_allocator)

	jn, jerr := os.read(f, json_buf)
	if jerr != os.ERROR_NONE || i64(jn) < true_size {
		return false
	}

	val, parse_err := json.parse(json_buf, json.DEFAULT_SPECIFICATION, false, context.allocator)
	if parse_err != nil {
		return false
	}
	defer json.destroy_value(val, context.allocator)

	root_obj, is_obj := val.(json.Object)
	if !is_obj {
		return false
	}

	files_val, has_files := root_obj["files"]
	if !has_files {
		return false
	}
	files_obj, files_is_obj := files_val.(json.Object)
	if !files_is_obj {
		return false
	}

	icon_obj, has_icon := find_asar_file_entry(files_obj, target_icon_name)
	if !has_icon {
		return false
	}

	size_val, has_size := icon_obj["size"]
	offset_val, has_offset := icon_obj["offset"]
	if !has_size || !has_offset {
		return false
	}

	file_size: i64 = 0
	#partial switch v in size_val {
	case json.Integer:
		file_size = i64(v)
	case json.Float:
		file_size = i64(v)
	}

	file_offset: i64 = 0
	#partial switch v in offset_val {
	case json.String:
		parsed, ok := strconv.parse_i64(string(v))
		if !ok {
			return false
		}
		file_offset = parsed
	case json.Integer:
		file_offset = i64(v)
	}

	if file_size <= 0 || file_size > 100 * 1024 * 1024 {
		return false
	}

	abs_offset := 16 + padded_size + file_offset
	_, seek_err := os.seek(f, abs_offset, io.Seek_From.Start)
	if seek_err != os.ERROR_NONE {
		return false
	}

	payload := make([]u8, int(file_size), context.temp_allocator)
	defer delete(payload, context.temp_allocator)

	pn, perr := os.read(f, payload)
	if perr != os.ERROR_NONE || i64(pn) < file_size {
		return false
	}

	// Ensure parent dir of out_path exists
	parent_dir := dir_name(out_path)
	_ = os.make_directory_all(parent_dir, os.perm(0o755))

	werr := os.write_entire_file(out_path, payload)
	return werr == nil
}

// find_and_extract_asar_icon searches extract_dir for app.asar, and if
// found, extracts the icon to extract_dir/out_filename.
find_and_extract_asar_icon :: proc(extract_dir, out_filename: string) -> bool {
	asar_path, ok := find_file_by_basename(extract_dir, "app.asar")
	if !ok {
		return false
	}

	target_path := fmt.tprintf("%s/%s", extract_dir, out_filename)
	if extract_asar_icon(asar_path, target_path, "icon.png") {
		fmt.printf("==> Extracted app icon from ASAR to %s\n", out_filename)
		// Also create a copy as "icon.png" in extract_dir if different name
		if out_filename != "icon.png" {
			icon_copy := fmt.tprintf("%s/icon.png", extract_dir)
			if !os.is_file(icon_copy) {
				_ = platform.cp_fallback(target_path, icon_copy)
			}
		}
		return true
	}

	return false
}

find_asar_file_entry :: proc(dir_obj: json.Object, target_name: string) -> (json.Object, bool) {
	// Direct match
	if val, ok := dir_obj[target_name]; ok {
		if obj, is_obj := val.(json.Object); is_obj {
			if _, has_size := obj["size"]; has_size {
				return obj, true
			}
		}
	}
	// Fallback to "icon.png"
	if target_name != "icon.png" {
		if val, ok := dir_obj["icon.png"]; ok {
			if obj, is_obj := val.(json.Object); is_obj {
				if _, has_size := obj["size"]; has_size {
					return obj, true
				}
			}
		}
	}
	// Direct .png match in current directory
	for k, val in dir_obj {
		if strings.has_suffix(strings.to_lower(k, context.temp_allocator), ".png") {
			if obj, is_obj := val.(json.Object); is_obj {
				if _, has_size := obj["size"]; has_size {
					return obj, true
				}
			}
		}
	}
	// Recurse into subdirectories (entries that have a "files" object)
	for _, val in dir_obj {
		if obj, is_obj := val.(json.Object); is_obj {
			if sub_files, has_sub := obj["files"]; has_sub {
				if sub_obj, sub_is_obj := sub_files.(json.Object); sub_is_obj {
					if entry, found := find_asar_file_entry(sub_obj, target_name); found {
						return entry, true
					}
				}
			}
		}
	}
	return nil, false
}

