package addons

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:text/regex"

Capture_Error :: enum {
	None,
	No_Capture,
}

Regex_Error :: union #shared_nil {
	Capture_Error,
	regex.Error,
}

@(private)
match_and_return_capture :: proc(pattern: string, str: string) -> (string, Regex_Error) {
	defer free_all(context.temp_allocator)
	regexp, err := regex.create(pattern, permanent_allocator = context.temp_allocator)
	if err != nil {
		return "", err
	}

	capture, ok := regex.match_and_allocate_capture(regexp, str, context.temp_allocator)
	if !ok {
		return "", .No_Capture
	}


	return strings.clone(capture.groups[1]), nil
}

@(test)
match_and_return_capture_test__no_capture :: proc(t: ^testing.T) {
	capture, err := match_and_return_capture(`\<(.*)\>`, "hello world")
	testing.expect_value(t, err, Capture_Error.No_Capture)
}

@(test)
match_and_return_capture_test__malformed_regex :: proc(t: ^testing.T) {
	capture, err := match_and_return_capture(`?\<(.*)\>`, "<hello world>")
	testing.expect(t, err != nil)
}

@(test)
match_and_return_capture_test :: proc(t: ^testing.T) {
	capture, err := match_and_return_capture(`\<(.*)\>`, "<hello world>")
	testing.expect(t, err == nil)
	testing.expect(t, capture == "hello world")
	delete(capture)
}
