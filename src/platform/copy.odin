package platform

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libsystem "system:System"

	foreign libsystem {
		@(link_name="clonefile")
		clonefile :: proc "c" (src: cstring, dst: cstring, flags: c.uint) -> c.int ---
	}

	CLONE_NOFOLLOW :: c.uint(0x0001)
	CLONE_NOOWNERCOPY :: c.uint(0x0002)
}

when ODIN_OS == .Linux {
	foreign import libc_ioctl "system:c"

	foreign libc_ioctl {
		@(link_name="ioctl")
		ioctl :: proc "c" (fd: c.int, request: c.int, arg: c.int) -> c.int ---
		@(link_name="sendfile")
		sendfile :: proc "c" (out_fd: c.int, in_fd: c.int, offset: rawptr, count: c.size_t) -> c.ssize_t ---
	}

	FICLONE :: c.int(0x40049409)
}

clone_tree :: proc(src: string, dst: string) -> bool {
	when ODIN_OS == .Darwin {
		src_cstr := strings.clone_to_cstring(src, context.temp_allocator)
		dst_cstr := strings.clone_to_cstring(dst, context.temp_allocator)
		return clonefile(src_cstr, dst_cstr, CLONE_NOFOLLOW | CLONE_NOOWNERCOPY) == 0
	} else when ODIN_OS == .Linux {
		fi, err := os.lstat(src, context.temp_allocator)
		if err != nil do return false
		if fi.type == .Directory {
			return clone_dir_reflink(src, dst)
		} else if fi.type == .Regular {
			return clone_tree_ioctl(src, dst)
		}
		return false
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
			posix.fchmod(posix.FD(dst_fd), transmute(posix.mode_t)transmute(u32)fi.mode)
			return true
		}

		// Fallback to in-process sendfile if FICLONE fails
		if fi.size > 0 {
			posix.lseek(posix.FD(src_fd), 0, .SET)
			posix.lseek(posix.FD(dst_fd), 0, .SET)
			remaining := fi.size
			for remaining > 0 {
				chunk := c.size_t(min(remaining, i64(0x7ffff000)))
				copied := sendfile(dst_fd, src_fd, nil, chunk)
				if copied <= 0 {
					os.remove(dst)
					return false
				}
				remaining -= i64(copied)
			}
			posix.fchmod(posix.FD(dst_fd), transmute(posix.mode_t)transmute(u32)fi.mode)
			return true
		} else {
			posix.fchmod(posix.FD(dst_fd), transmute(posix.mode_t)transmute(u32)fi.mode)
			return true
		}

		os.remove(dst)
		return false
	}

	clone_dir_reflink :: proc(src: string, dst: string) -> bool {
		src_stat, stat_err := os.stat(src, context.temp_allocator)
		if stat_err != nil do return false

		if err := os.make_directory(dst, transmute(os.Permissions)transmute(u32)src_stat.mode); err != nil {
			if !os.is_dir(dst) do return false
		}

		csrc := strings.clone_to_cstring(src, context.temp_allocator)
		dirp := posix.opendir(csrc)
		if dirp == nil do return false
		defer posix.closedir(dirp)

		for {
			ent := posix.readdir(dirp)
			if ent == nil do break
			cname := cstring(&ent.d_name[0])
			name := string(cname)
			if name == "." || name == ".." do continue

			sub_src := fmt.tprintf("%s/%s", src, name)
			sub_dst := fmt.tprintf("%s/%s", dst, name)

			d_type := ent.d_type
			if d_type == .UNKNOWN {
				if fi, err := os.lstat(sub_src, context.temp_allocator); err == nil {
					#partial switch fi.type {
					case .Directory: d_type = .DIR
					case .Regular:   d_type = .REG
					case .Symlink:   d_type = .LNK
					}
				}
			}

			if d_type == .DIR {
				if !clone_dir_reflink(sub_src, sub_dst) {
					return false
				}
			} else if d_type == .LNK {
				csub_src := strings.clone_to_cstring(sub_src, context.temp_allocator)
				buf: [posix.PATH_MAX]byte
				len_read := posix.readlink(csub_src, ([^]byte)(&buf[0]), posix.PATH_MAX - 1)
				if len_read > 0 {
					buf[len_read] = 0
					csub_dst := strings.clone_to_cstring(sub_dst, context.temp_allocator)
					ctarget := cstring(&buf[0])
					if posix.symlink(ctarget, csub_dst) != .OK {
						return false
					}
				} else {
					return false
				}
			} else if d_type == .REG {
				if !clone_tree_ioctl(sub_src, sub_dst) {
					return false
				}
			} else {
				if !clone_tree_ioctl(sub_src, sub_dst) {
					return false
				}
			}
		}
		return true
	}
}

GLOBAL_DEBUG: bool = false

exec_cmd :: proc(bin: string, args: []string) -> bool {
	if GLOBAL_DEBUG {
		fmt.print("+ ")
		for arg, idx in args {
			if idx > 0 do fmt.print(" ")
			fmt.print(arg)
		}
		fmt.println()
	}
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

// exec_cmd_async forks + execs without waiting, so callers can run several
// independent subprocesses concurrently and reap them later with
// wait_pid_ok. Identical to exec_cmd except for the non-blocking wait.
// Returns (-1, false) when fork failed.
exec_cmd_async :: proc(bin: string, args: []string) -> (posix.pid_t, bool) {
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
		return pid, true
	}
	return -1, false
}

// wait_pid_ok reaps a pid spawned by exec_cmd_async and reports whether it
// exited cleanly (status 0). Blocking, like exec_cmd's internal wait.
wait_pid_ok :: proc(pid: posix.pid_t) -> bool {
	status: c.int
	posix.waitpid(pid, &status, nil)
	return status == 0
}

exec_cmd_capture :: proc(bin: string, args: []string, buf: []u8, suppress_stderr := true) -> (output: string, truncated: bool) {
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for i in 0..<len(args) {
		argv[i] = strings.clone_to_cstring(args[i], context.temp_allocator)
	}
	argv[len(args)] = nil

	bin_cstr := strings.clone_to_cstring(bin, context.temp_allocator)

	pipe_fds: [2]posix.FD
	if posix.pipe(&pipe_fds) != .OK {
		return "", false
	}

	pid := posix.fork()
	if pid == 0 {
		// Child: redirect stdout to pipe write end
		posix.close(pipe_fds[0])
		posix.dup2(pipe_fds[1], posix.FD(1))
		posix.close(pipe_fds[1])

		// Redirect stderr to /dev/null to suppress noisy warnings/errors from captured commands
		if suppress_stderr {
			null_handle, open_err := os.open("/dev/null", os.O_WRONLY)
			if open_err == nil {
				null_fd := posix.FD(os.fd(null_handle))
				posix.dup2(null_fd, posix.FD(2))
				posix.close(null_fd)
			}
		}

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
		// If we filled the buffer, the child may have written more that we
		// couldn't fit. Probe with one more read; if it returns >0 the
		// output was definitely truncated. The read blocks until data or EOF.
		truncated = false
		if total >= len(buf) - 1 {
			extra: [1]u8
			n := posix.read(pipe_fds[0], &extra[0], 1)
			if n > 0 {
				truncated = true
			}
		}
		posix.close(pipe_fds[0])

		status: c.int
		posix.waitpid(pid, &status, nil)
		if status != 0 {
			return "", false
		}

		return strings.trim_space(string(buf[:total])), truncated
	}
	posix.close(pipe_fds[0])
	posix.close(pipe_fds[1])
	return "", false
}

exec_cmd_in_dir :: proc(dir, bin: string, args: []string) -> bool {
	if GLOBAL_DEBUG {
		fmt.printf("+ (in %s) ", dir)
		for arg, idx in args {
			if idx > 0 do fmt.print(" ")
			fmt.print(arg)
		}
		fmt.println()
	}
	argv := make([]cstring, len(args)+1, context.temp_allocator)
	for i in 0..<len(args) {
		argv[i] = strings.clone_to_cstring(args[i], context.temp_allocator)
	}
	argv[len(args)] = nil
	bin_cstr := strings.clone_to_cstring(bin, context.temp_allocator)
	dir_cstr := strings.clone_to_cstring(dir, context.temp_allocator)
	pid := posix.fork()
	if pid == 0 {
		if posix.chdir(dir_cstr) != .OK {
			posix.exit(127)
		}
		posix.execvp(bin_cstr, &argv[0])
		posix.exit(1)
	} else if pid > 0 {
		status: c.int
		posix.waitpid(pid, &status, nil)
		return status == 0
	}
	return false
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
	if os.exists(dst) {
		_ = os.remove_all(dst)
	}
	return cp_fallback(src, dst)
}

@(private="file")
_gh_token: string
@(private="file")
_gh_token_fetched: bool

find_gh_binary :: proc() -> string {
	// Try common absolute paths first. The child of `posix.execvp` does NOT
	// search PATH for a relative name in some environments, so we need to
	// resolve `gh` to a full path before calling exec.
	candidates := []string{
		"/usr/bin/gh",
		"/usr/local/bin/gh",
		"/opt/homebrew/bin/gh",
		"/home/linuxbrew/.linuxbrew/bin/gh",
	}
	for c in candidates {
		if os.is_file(c) {
			return c
		}
	}
	// Fall back to PATH search.
	if path_env := os.get_env("PATH", context.temp_allocator); len(path_env) > 0 {
		for dir in strings.split(path_env, ":", context.temp_allocator) {
			full := fmt.tprintf("%s/gh", dir)
			if os.is_file(full) {
				return strings.clone(full, context.allocator)
			}
		}
	}
	return ""
}

get_gh_token :: proc() -> string {
	if !_gh_token_fetched {
		_gh_token_fetched = true
		buf: [512]u8
		gh_path := find_gh_binary()
		if len(gh_path) > 0 {
			args := []string{"gh", "auth", "token"}
			token, was_truncated := exec_cmd_capture(gh_path, args, buf[:])
			if !was_truncated && len(token) > 0 {
				_gh_token = token
			}
		}
		if _gh_token == "" {
			_gh_token = os.get_env("GITHUB_TOKEN", context.temp_allocator)
		}
		if _gh_token != "" {
			_gh_token = strings.clone(_gh_token, context.allocator)
		}
	}
	return _gh_token
}
