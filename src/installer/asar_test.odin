package installer

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_extract_asar_icon :: proc(t: ^testing.T) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if len(tmp) == 0 {
		tmp = "/tmp"
	}
	test_dir := fmt.tprintf("%s/ubrew-asar-test", tmp)
	_ = os.remove_all(test_dir)
	_ = os.make_directory_all(test_dir, os.perm(0o755))
	defer os.remove_all(test_dir)

	asar_path := fmt.tprintf("%s/test.asar", test_dir)
	out_icon := fmt.tprintf("%s/extracted.png", test_dir)

	// Build a valid synthetic ASAR archive with an icon.png
	fake_icon_data := "FAKE_PNG_ICON_CONTENT_12345"
	json_hdr := fmt.tprintf(
		"{{\"files\":{{\"icon.png\":{{\"size\":%d,\"offset\":\"0\"}}}}}}",
		len(fake_icon_data),
	)

	json_len := len(json_hdr)
	// Padded to 4-byte boundary
	padded_len := (json_len + 3) & ~int(3)

	// Header buffer: 16 bytes header + padded JSON + payload
	buf := make([dynamic]u8, context.temp_allocator)
	defer delete(buf)

	// Fixed header (16 bytes)
	u32_to_bytes :: proc(val: u32) -> [4]u8 {
		return [4]u8{
			u8(val & 0xFF),
			u8((val >> 8) & 0xFF),
			u8((val >> 16) & 0xFF),
			u8((val >> 24) & 0xFF),
		}
	}

	h0 := u32_to_bytes(4)
	h4 := u32_to_bytes(u32(padded_len + 8))
	h8 := u32_to_bytes(u32(padded_len + 4))
	h12 := u32_to_bytes(u32(json_len))

	for b in h0 { append(&buf, b) }
	for b in h4 { append(&buf, b) }
	for b in h8 { append(&buf, b) }
	for b in h12 { append(&buf, b) }

	for i in 0..<json_len {
		append(&buf, json_hdr[i])
	}
	for i in json_len..<padded_len {
		append(&buf, 0)
	}

	for i in 0..<len(fake_icon_data) {
		append(&buf, fake_icon_data[i])
	}

	testing.expect(t, os.write_entire_file(asar_path, buf[:]) == nil, "write synthetic asar")

	ok := extract_asar_icon(asar_path, out_icon, "icon.png")
	testing.expect(t, ok, "extract_asar_icon should succeed")

	extracted_bytes, rerr := os.read_entire_file(out_icon, context.temp_allocator)
	testing.expect(t, rerr == nil, "read extracted icon")
	defer delete(extracted_bytes, context.temp_allocator)
	testing.expect_value(t, string(extracted_bytes), fake_icon_data)
}

@(test)
test_extract_asar_real_if_present :: proc(t: ^testing.T) {
	real_asar := "/home/linuxbrew/.linuxbrew/Caskroom/antigravity-linux/2.12.2,6298742303883264/Antigravity-x64/resources/app.asar"
	if !os.exists(real_asar) {
		return
	}
	out_icon := "/tmp/ubrew-test-real-extracted.png"
	defer os.remove(out_icon)
	ok := extract_asar_icon(real_asar, out_icon, "icon.png")
	testing.expect(t, ok, "extract_asar_icon from real app.asar should succeed")
	if ok {
		fi, err := os.stat(out_icon, context.temp_allocator)
		testing.expect(t, err == nil, "stat extracted icon")
		testing.expect(t, fi.size > 1000, "icon size should be reasonable")
	}
}

create_synthetic_asar :: proc(asar_path, icon_name, payload_str: string) -> bool {
	json_hdr := fmt.tprintf(
		"{{\"files\":{{\"%s\":{{\"size\":%d,\"offset\":\"0\"}}}}}}",
		icon_name,
		len(payload_str),
	)
	json_len := len(json_hdr)
	padded_len := (json_len + 3) & ~int(3)

	buf := make([dynamic]u8, context.temp_allocator)
	defer delete(buf)

	u32_to_bytes :: proc(val: u32) -> [4]u8 {
		return [4]u8{
			u8(val & 0xFF),
			u8((val >> 8) & 0xFF),
			u8((val >> 16) & 0xFF),
			u8((val >> 24) & 0xFF),
		}
	}

	h0 := u32_to_bytes(4)
	h4 := u32_to_bytes(u32(padded_len + 8))
	h8 := u32_to_bytes(u32(padded_len + 4))
	h12 := u32_to_bytes(u32(json_len))

	for b in h0 { append(&buf, b) }
	for b in h4 { append(&buf, b) }
	for b in h8 { append(&buf, b) }
	for b in h12 { append(&buf, b) }

	for i in 0..<json_len {
		append(&buf, json_hdr[i])
	}
	for i in json_len..<padded_len {
		append(&buf, 0)
	}
	for i in 0..<len(payload_str) {
		append(&buf, payload_str[i])
	}

	parent := dir_name(asar_path)
	_ = os.make_directory_all(parent, os.perm(0o755))
	return os.write_entire_file(asar_path, buf[:]) == nil
}

@(test)
test_find_and_extract_asar_icon_named_target :: proc(t: ^testing.T) {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if len(tmp) == 0 {
		tmp = "/tmp"
	}
	test_dir := fmt.tprintf("%s/ubrew-asar-named-test", tmp)
	_ = os.remove_all(test_dir)
	_ = os.make_directory_all(test_dir, os.perm(0o755))
	defer os.remove_all(test_dir)

	// An unrelated loose icon exists in a subpackage
	unrelated_dir := fmt.tprintf("%s/node_modules/some-pkg", test_dir)
	_ = os.make_directory_all(unrelated_dir, os.perm(0o755))
	_ = os.write_entire_file_from_string(fmt.tprintf("%s/app.png", unrelated_dir), "UNRELATED_PKG_ICON")

	// Real icon is in app.asar under resources/
	asar_path := fmt.tprintf("%s/resources/app.asar", test_dir)
	ok_create := create_synthetic_asar(asar_path, "app.png", "REAL_APP_ASAR_ICON")
	testing.expect(t, ok_create, "create synthetic asar")

	// Extract requested icon
	ok := find_and_extract_asar_icon(test_dir, "app.png")
	testing.expect(t, ok, "find_and_extract_asar_icon should succeed")

	// Verify the extracted file in extract_dir has the real ASAR content, not the unrelated one
	extracted_path := fmt.tprintf("%s/app.png", test_dir)
	data, rerr := os.read_entire_file(extracted_path, context.temp_allocator)
	testing.expect(t, rerr == nil, "read extracted app.png")
	testing.expect_value(t, string(data), "REAL_APP_ASAR_ICON")

	// Also verify icon.png copy was created
	icon_copy := fmt.tprintf("%s/icon.png", test_dir)
	cdata, cerr := os.read_entire_file(icon_copy, context.temp_allocator)
	testing.expect(t, cerr == nil, "read icon.png copy")
	testing.expect_value(t, string(cdata), "REAL_APP_ASAR_ICON")
}


