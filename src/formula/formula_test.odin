package formula

import "core:testing"

@(test)
test_format_bytes_human_units :: proc(t: ^testing.T) {
	// Basic unit selection.
	testing.expect_value(t, format_bytes_human(0), "N/A")
	testing.expect_value(t, format_bytes_human(512), "512 B")
	testing.expect_value(t, format_bytes_human(1024), "1.0 KB")
	testing.expect_value(t, format_bytes_human(1024 * 1024), "1.0 MB")
	testing.expect_value(t, format_bytes_human(1024 * 1024 * 1024), "1.00 GB")
}

@(test)
test_format_bytes_human_boundary_promotion :: proc(t: ^testing.T) {
	// 1024*1024 - 1 bytes is 1023.999... KB: with one decimal it would
	// round to "1024.0 KB", so it must be promoted to MB instead.
	kb_boundary := 1024 * 1024 - 1
	mb_out := format_bytes_human(i64(kb_boundary))
	testing.expectf(t, mb_out == "1.00 MB", "1024*1024-1 bytes: expected %q, got %q", "1.00 MB", mb_out)

	// Same for the MB -> GB boundary.
	mb_boundary := 1024 * 1024 * 1024 - 1
	gb_out := format_bytes_human(i64(mb_boundary))
	testing.expectf(t, gb_out == "1.00 GB", "1024*1024*1024-1 bytes: expected %q, got %q", "1.00 GB", gb_out)
}
