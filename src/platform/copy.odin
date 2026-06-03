package platform

import "core:c"
import "core:os"
import "core:strings"

when ODIN_OS == .Darwin {
	foreign import libsystem "system:System"

	foreign libsystem {
		@(link_name="clonefile")
		clonefile :: proc "c" (src: [^]c.char, dst: [^]c.char, flags: c.uint) -> c.int ---
	}

	CLONE_NOFOLLOW :: c.uint(0x0001)
	CLONE_NOOWNERCOPY :: c.uint(0x0002)
}

when ODIN_OS == .Linux {
	foreign import libc_ioctl "system:c"

	foreign libc_ioctl {
		@(link_name="ioctl")
		ioctl :: proc "c" (fd: c.int, request: c.int, arg: c.int) -> c.int ---
	}

	FICLONE :: c.int(0x40049409)
}

clone_tree :: proc(src: string, dst: string) -> bool {
	when ODIN_OS == .Darwin {
		src_cstr := strings.clone_to_cstring(src, context.temp_allocator)
		dst_cstr := strings.clone_to_cstring(dst, context.temp_allocator)
		return clonefile(src_cstr, dst_cstr, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0
	} else when ODIN_OS == .Linux {
		return clone_tree_ioctl(src, dst)
	} else {
		return false
	}
}

when ODIN_OS == .Linux {
	clone_tree_ioctl :: proc(src: string, dst: string) -> bool {
		fi, fi_err := os.stat(src, context.temp_allocator)
		if fi_err != nil || fi.type != .Regular {
			return false
		}

		src_f, src_err := os.open(src, os.O_RDONLY)
		if src_err != nil {
			return false
		}
		defer os.close(src_f)

		dst_f, dst_err := os.open(dst, os.O_WRONLY | os.O_CREATE | os.O_TRUNC, os.Permissions_Default_File)
		if dst_err != nil {
			return false
		}
		defer os.close(dst_f)

		src_fd := c.int(os.fd(src_f))
		dst_fd := c.int(os.fd(dst_f))
		result := ioctl(dst_fd, FICLONE, src_fd)
		if result == 0 {
			return true
		}

		os.remove(dst)
		return false
	}
}

import "core:sys/posix"

exec_cmd :: proc(bin: string, args: []string) -> bool {
	// Convention: `args[0]` is the program name (so it shows up in
	// `ps`/error messages as the user expects). We pass `args` directly
	// to execvp. The trailing nil terminates the argv vector.
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for i in 0..<len(args) {
		argv[i] = strings.clone_to_cstring(args[i], context.temp_allocator)
	}
	argv[len(args)] = nil

	bin_cstr := strings.clone_to_cstring(bin, context.temp_allocator)

	pid := posix.fork()
	if pid == 0 {
		posix.execvp(bin_cstr, &argv[0])
		posix.exit(1)
	} else if pid > 0 {
		status: c.int
		posix.waitpid(pid, &status, nil)
		return status == 0
	}
	return false
}

exec_cmd_capture :: proc(bin: string, args: []string, buf: []u8) -> string {
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for i in 0..<len(args) {
		argv[i] = strings.clone_to_cstring(args[i], context.temp_allocator)
	}
	argv[len(args)] = nil

	bin_cstr := strings.clone_to_cstring(bin, context.temp_allocator)

	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK {
		return ""
	}

	pid := posix.fork()
	if pid == 0 {
		// Child: redirect stdout to pipe write end
		posix.close(pipe_fds[0])
		posix.dup2(pipe_fds[1], posix.FD(1))
		posix.close(pipe_fds[1])
		posix.execvp(bin_cstr, &argv[0])
		posix.exit(1)
	} else if pid > 0 {
		posix.close(pipe_fds[1])

		total := 0
		for total < len(buf) - 1 {
			n := posix.read(pipe_fds[0], &buf[total], uint(int(len(buf)) - total))
			if n <= 0 {
				break
			}
			total += int(n)
		}
		posix.close(pipe_fds[0])

		status: c.int
		posix.waitpid(pid, &status, nil)

		return strings.trim_space(string(buf[:total]))
	}
	posix.close(pipe_fds[0])
	posix.close(pipe_fds[1])
	return ""
}

cp_fallback :: proc(src: string, dst: string) -> bool {
	when ODIN_OS == .Linux {
		args := []string{"cp", "--reflink=auto", "-R", src, dst}
		return exec_cmd("cp", args)
	} else {
		args := []string{"cp", "-R", src, dst}
		return exec_cmd("cp", args)
	}
}

cow_copy :: proc(src: string, dst: string) -> bool {
	if clone_tree(src, dst) {
		return true
	}
	return cp_fallback(src, dst)
}
