package api

// Unit tests for search-related helpers and JSON utilities in the api package.
// Run with: odin test src/api
//
// NOTE: Tests that require json.parse are deferred until we figure out the
// correct inline []u8 cast pattern for raw string literals in Odin test files.
// The functions tested here operate on raw JSON text or require no JSON parsing.

import "core:testing"
import "core:strings"

// ---------------------------------------------------------------------------
// json_field_string_raw — raw string field extraction from JSON text
// ---------------------------------------------------------------------------

@(test)
test_json_field_string_raw_extracts :: proc(t: ^testing.T) {
    result := json_field_string_raw(`{"name":"wget","version":"1.21.4"}`, "version")
    testing.expect_value(t, result, "1.21.4")
}

@(test)
test_json_field_string_raw_missing :: proc(t: ^testing.T) {
    result := json_field_string_raw(`{"name":"wget"}`, "version")
    testing.expect_value(t, result, "")
}

@(test)
test_json_field_string_raw_escaped :: proc(t: ^testing.T) {
    result := json_field_string_raw(`{"version":"1.2.3_4"}`, "version")
    testing.expect_value(t, result, "1.2.3_4")
}

// ---------------------------------------------------------------------------
// json_field_array_as_csv
// ---------------------------------------------------------------------------

@(test)
test_json_field_array_as_csv_strings :: proc(t: ^testing.T) {
    result := json_field_array_as_csv(`{"deps":["openssl","zlib","xz"]}`, "deps")
    testing.expect_value(t, result, "openssl,zlib,xz")
}

@(test)
test_json_field_array_as_csv_single :: proc(t: ^testing.T) {
    result := json_field_array_as_csv(`{"deps":["openssl"]}`, "deps")
    testing.expect_value(t, result, "openssl")
}

@(test)
test_json_field_array_as_csv_empty :: proc(t: ^testing.T) {
    result := json_field_array_as_csv(`{"deps":[]}`, "deps")
    testing.expect_value(t, result, "")
}

// ---------------------------------------------------------------------------
// registry_preferred_asset_key — platform key resolution
// ---------------------------------------------------------------------------

@(test)
test_registry_preferred_asset_key_not_empty :: proc(t: ^testing.T) {
    key := registry_preferred_asset_key()
    testing.expectf(t, len(key) > 0, "preferred asset key should not be empty, got %q", key)
}

@(test)
test_registry_preferred_asset_key_contains_os :: proc(t: ^testing.T) {
    key := registry_preferred_asset_key()
    testing.expectf(t,
        strings.contains(key, "linux") || strings.contains(key, "macos") || strings.contains(key, "windows"),
        "expected key %q to contain OS name (linux/macos/windows)", key)
}
