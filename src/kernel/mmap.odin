package kernel

import "core:os"
import "core:c"
import "core:sys/posix"

Mapped_File :: struct {
	data: rawptr,
	len: i64,
}

mapped_file_open :: proc(path: string) -> (Mapped_File, bool) {
	f, err := os.open(path)
	if err != nil {
		return Mapped_File{}, false
	}
	defer os.close(f)

	fi, fi_err := os.fstat(f, context.temp_allocator)
	if fi_err != nil {
		return Mapped_File{}, false
	}
	size := fi.size

	if size == 0 {
		return Mapped_File{}, false
	}

	prot: posix.Prot_Flags = {.READ}
	flags: posix.Map_Flags = {.PRIVATE}
	fd := posix.FD(os.fd(f))

	ptr := posix.mmap(nil, c.size_t(size), prot, flags, fd, 0)
	if ptr == posix.MAP_FAILED {
		return Mapped_File{}, false
	}

	posix.posix_madvise(ptr, c.size_t(size), .SEQUENTIAL)

	return Mapped_File{data = ptr, len = size}, true
}

mapped_file_bytes :: proc(mf: ^Mapped_File) -> []u8 {
	if mf.data == nil || mf.len == 0 {
		return nil
	}
	return (cast([^]u8)mf.data)[:mf.len]
}

mapped_file_close :: proc(mf: ^Mapped_File) {
	if mf.data != nil {
		posix.munmap(mf.data, c.size_t(mf.len))
		mf.data = nil
		mf.len = 0
	}
}
