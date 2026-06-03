package mem

import "core:mem"

Scratch_Arena :: struct {
	buffer: []u8,
	offset: int,
	backing: mem.Allocator,
}

scratch_arena_init :: proc(backing: mem.Allocator, size: int) -> (Scratch_Arena, mem.Allocator_Error) {
	buf, err := mem.alloc_bytes(size, 16, backing)
	if err != nil {
		return Scratch_Arena{}, err
	}
	return Scratch_Arena{
		buffer = buf,
		offset = 0,
		backing = backing,
	}, nil
}

scratch_arena_deinit :: proc(arena: ^Scratch_Arena) {
	mem.free_bytes(arena.buffer, arena.backing)
	arena.buffer = nil
	arena.offset = 0
}

scratch_arena_alloc :: proc(arena: ^Scratch_Arena, size, alignment: int) -> ([]u8, bool) {
	base_addr := uintptr(raw_data(arena.buffer))
	current_addr := base_addr + uintptr(arena.offset)
	aligned_addr := mem.align_forward_uintptr(current_addr, uintptr(alignment))
	aligned_offset := int(aligned_addr - base_addr)
	end := aligned_offset + int(size)
	if end > len(arena.buffer) {
		return nil, false
	}
	arena.offset = end
	return arena.buffer[aligned_offset:end], true
}

scratch_arena_reset :: proc(arena: ^Scratch_Arena) {
	arena.offset = 0
}

scratch_arena_remaining :: proc(arena: ^Scratch_Arena) -> int {
	return len(arena.buffer) - arena.offset
}

scratch_arena_used :: proc(arena: ^Scratch_Arena) -> int {
	return arena.offset
}

Ring_Buffer :: struct($T: typeid, $Cap: int) {
	buffer: [Cap]T,
	head: int,
	tail: int,
	count: int,
}

ring_push :: proc(rb: ^Ring_Buffer($T, $Cap), item: T) {
	rb.buffer[rb.tail] = item
	rb.tail = (rb.tail + 1) % Cap
	if rb.count < Cap {
		rb.count += 1
	} else {
		rb.head = (rb.head + 1) % Cap
	}
}

ring_pop :: proc(rb: ^Ring_Buffer($T, $Cap)) -> (T, bool) {
	if rb.count == 0 {
		return T{}, false
	}
	item := rb.buffer[rb.head]
	rb.head = (rb.head + 1) % Cap
	rb.count -= 1
	return item, true
}

ring_peek :: proc(rb: ^Ring_Buffer($T, $Cap)) -> (T, bool) {
	if rb.count == 0 {
		return T{}, false
	}
	return rb.buffer[rb.head], true
}

ring_is_full :: proc(rb: ^Ring_Buffer($T, $Cap)) -> bool {
	return rb.count >= Cap
}
