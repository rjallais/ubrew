package history

// Unit tests for the history package.
// Run with: odin test src/history

import "core:strings"
import "core:testing"
import "core:time"

// ---------------------------------------------------------------------------
// action_string
// ---------------------------------------------------------------------------

@(test)
test_action_string_install :: proc(t: ^testing.T) {
    testing.expect_value(t, action_string(.Install), "install")
}

@(test)
test_action_string_upgrade :: proc(t: ^testing.T) {
    testing.expect_value(t, action_string(.Upgrade), "upgrade")
}

@(test)
test_action_string_downgrade :: proc(t: ^testing.T) {
    testing.expect_value(t, action_string(.Downgrade), "downgrade")
}

@(test)
test_action_string_reinstall :: proc(t: ^testing.T) {
    testing.expect_value(t, action_string(.Reinstall), "reinstall")
}

@(test)
test_action_string_uninstall :: proc(t: ^testing.T) {
    testing.expect_value(t, action_string(.Uninstall), "uninstall")
}

// ---------------------------------------------------------------------------
// has_from_version / has_from_revision
// ---------------------------------------------------------------------------

@(test)
test_has_from_version_true :: proc(t: ^testing.T) {
    e := Entry{from_version = "1.2.3"}
    testing.expect(t, has_from_version(e), "has from_version 1.2.3")
}

@(test)
test_has_from_version_false :: proc(t: ^testing.T) {
    e := Entry{from_version = ""}
    testing.expect(t, !has_from_version(e), "no from_version")
}

@(test)
test_has_from_revision_true :: proc(t: ^testing.T) {
    e := Entry{from_revision = 42}
    testing.expect(t, has_from_revision(e), "has from_revision 42")
}

@(test)
test_has_from_revision_false :: proc(t: ^testing.T) {
    e := Entry{from_revision = NO_FROM_REVISION}
    testing.expect(t, !has_from_revision(e), "NO_FROM_REVISION")
}

// ---------------------------------------------------------------------------
// iso8601_now — basic format check
// ---------------------------------------------------------------------------

@(test)
test_iso8601_now_format :: proc(t: ^testing.T) {
    result := iso8601_now()
    defer delete(result)
    // Expected format: 2026-07-03T12:34:56Z
    testing.expectf(t, len(result) == 20, "expected length 20, got %d: %q", len(result), result)
    testing.expectf(t, result[10] == 'T', "expected T at position 10, got %c", result[10])
    testing.expectf(t, result[19] == 'Z', "expected Z at end, got %c", result[19])
    for i := 0; i < 10; i += 1 {
        if i == 4 || i == 7 {
            testing.expectf(t, result[i] == '-', "expected - at position %d, got %c", i, result[i])
        }
    }
}

// ---------------------------------------------------------------------------
// json_escape
// ---------------------------------------------------------------------------

@(test)
test_json_escape_noop :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    json_escape(&b, "hello")
    result := strings.to_string(b)
    testing.expect_value(t, result, "hello")
}

@(test)
test_json_escape_quotes :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    json_escape(&b, `say "hello"`)
    result := strings.to_string(b)
    testing.expect_value(t, result, `say \"hello\"`)
}

@(test)
test_json_escape_backslash :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    json_escape(&b, `a\b`)
    result := strings.to_string(b)
    testing.expect_value(t, result, `a\\b`)
}

@(test)
test_json_escape_newline :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    json_escape(&b, "line1\nline2")
    result := strings.to_string(b)
    testing.expect_value(t, result, "line1\\nline2")
}

@(test)
test_json_escape_tab :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    json_escape(&b, "col1\tcol2")
    result := strings.to_string(b)
    testing.expect_value(t, result, "col1\\tcol2")
}

@(test)
test_json_escape_mixed :: proc(t: ^testing.T) {
    b: strings.Builder
    strings.builder_init(&b)
    defer strings.builder_destroy(&b)

    json_escape(&b, "tab\there\r\nquote\"and\\back")
    result := strings.to_string(b)
    testing.expect_value(t, result, "tab\\there\\r\\nquote\\\"and\\\\back")
}
