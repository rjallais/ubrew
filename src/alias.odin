package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "installer"
import "platform"

alias_file :: proc() -> string {
	return fmt.tprintf("%s/db/aliases.txt", installer.UBREW_ROOT)
}

// alias_lock acquires an exclusive advisory lock (fcntl F_SETLKW) on a lock
// file next to the alias file, so concurrent `ubrew alias` processes
// serialize their read-modify-write cycle. Closing the returned fd releases
// the lock.
alias_lock :: proc() -> (posix.FD, bool) {
	dir := fmt.tprintf("%s/db", installer.UBREW_ROOT)
	_ = os.make_directory_all(dir, os.perm(0o755))
	lock_path := strings.clone_to_cstring(fmt.tprintf("%s/aliases.lock", dir), context.temp_allocator)
	fd := posix.open(lock_path, {.RDWR, .CREAT}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
	if fd == -1 {
		return -1, false
	}
	fl := posix.flock {
		l_start  = 0,
		l_len    = 0,
		l_pid    = 0,
		l_type   = posix.Lock_Type.WRLCK,
		l_whence = c.short(0), // SEEK_SET
	}
	if posix.fcntl(fd, posix.FCNTL_Cmd.SETLKW, &fl) != 0 {
		posix.close(fd)
		return -1, false
	}
	return fd, true
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
	if name == "" || strings.contains(name, "\n") || strings.contains(target, "\n") {
		return false
	}
	// Refuse to let an alias shadow a built-in command: a routine
	// `ubrew <cmd>` must never dispatch to something else (e.g. a
	// destructive command) through an alias entry.
	for k in ubrew_known_commands(true) {
		if name == k {
			fmt.printf("ubrew: refusing to alias built-in command '%s'\n", name)
			return false
		}
	}
	dir := fmt.tprintf("%s/db", installer.UBREW_ROOT)
	_ = os.make_directory_all(dir, os.perm(0o755))

	// Hold the lock across read, mutation, and replacement so two `ubrew
	// alias` processes cannot silently drop each other's updates.
	lock_fd, lock_ok := alias_lock()
	if !lock_ok {
		return false
	}
	defer posix.close(lock_fd)

	m := read_aliases()
	m[name] = target

	b := strings.builder_make(context.temp_allocator)
	for k, v in m {
		strings.write_string(&b, fmt.tprintf("%s=%s\n", k, v))
	}
	content := strings.to_string(b)

	// Write to a temporary file and rename it into place while the lock is
	// held, so the alias file is never observed partially written.
	tmp := fmt.tprintf("%s.tmp", alias_file())
	if err := os.write_entire_file_from_string(tmp, content); err != nil {
		_ = os.remove(tmp)
		return false
	}
	if err := os.rename(tmp, alias_file()); err != os.ERROR_NONE {
		_ = os.remove(tmp)
		return false
	}
	return true
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
