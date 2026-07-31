package main

import "core:fmt"
import "core:os"
import "core:strings"
import "installer"
import "platform"

alias_file :: proc() -> string {
	return fmt.tprintf("%s/db/aliases.txt", installer.UBREW_ROOT)
}

read_aliases :: proc() -> map[string]string {
	m := make(map[string]string, context.allocator)
	data, err := os.read_entire_file(alias_file(), context.allocator)
	if err != nil {
		return m
	}
	defer delete(data, context.allocator)
	data_str := string(data)
	for line in strings.split_lines_iterator(&data_str) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || strings.has_prefix(trimmed, "#") do continue
		parts := strings.split_n(trimmed, "=", 2, context.allocator)
		defer delete(parts)
		if len(parts) == 2 {
			k := strings.clone(strings.trim_space(parts[0]), context.allocator)
			v := strings.clone(strings.trim_space(parts[1]), context.allocator)
			m[k] = v
		}
	}
	return m
}

write_alias :: proc(name, target: string) -> bool {
	dir := fmt.tprintf("%s/db", installer.UBREW_ROOT)
	_ = os.make_directory_all(dir, os.perm(0o755))
	m := read_aliases()
	m[name] = target

	b := strings.builder_make(context.temp_allocator)
	for k, v in m {
		strings.write_string(&b, fmt.tprintf("%s=%s\n", k, v))
	}
	content := strings.to_string(b)
	return os.write_entire_file_from_string(alias_file(), content) == nil
}

run_alias :: proc(args: []string) {
	if len(args) == 0 {
		m := read_aliases()
		if len(m) == 0 {
			fmt.println("No aliases set.")
			return
		}
		for k, v in m {
			fmt.printf("%s=%s\n", k, v)
		}
		return
	}

	arg := args[0]
	if arg == "--edit" {
		editor := os.get_env("EDITOR", context.temp_allocator)
		if editor == "" do editor = "nano"
		platform.exec_cmd(editor, []string{editor, alias_file()})
		return
	}

	if strings.contains(arg, "=") {
		parts := strings.split_n(arg, "=", 2, context.temp_allocator)
		if len(parts) == 2 {
			name := strings.trim_space(parts[0])
			target := strings.trim_space(parts[1])
			if write_alias(name, target) {
				fmt.printf("Alias set: %s -> %s\n", name, target)
			} else {
				fmt.printf("Error writing alias file\n")
			}
		}
		return
	}

	m := read_aliases()
	if val, ok := m[arg]; ok {
		fmt.printf("%s=%s\n", arg, val)
	} else {
		fmt.printf("ubrew alias: '%s' not found\n", arg)
	}
}
