package kernel

import "core:simd"
import "base:intrinsics"

SIMD_WIDTH :: 32 when ODIN_ARCH == .amd64 else 16

Vec :: #simd[SIMD_WIDTH]u8
Bitmask_Type :: u32 when SIMD_WIDTH == 32 else u16

make_splat :: proc(val: u8) -> Vec {
    data: [SIMD_WIDTH]u8
    for i in 0..<SIMD_WIDTH {
        data[i] = val
    }
    return transmute(Vec) data
}

load_chunk :: proc(data: []u8, offset: int) -> Vec {
    tmp: [SIMD_WIDTH]u8
    remaining := len(data) - offset
    n := min(SIMD_WIDTH, remaining)
    for i in 0..<n {
        tmp[i] = data[offset + i]
    }
    return transmute(Vec) tmp
}

to_bitmask :: proc(eq: Vec) -> Bitmask_Type {
    arr: [SIMD_WIDTH]u8 = transmute([SIMD_WIDTH]u8) eq
    mask: Bitmask_Type = 0
    for i in 0..<SIMD_WIDTH {
        if arr[i] != 0 {
            mask |= Bitmask_Type(1) << Bitmask_Type(i)
        }
    }
    return mask
}

find_byte :: proc(haystack: []u8, needle: u8) -> (int, bool) {
    splat := make_splat(needle)
    offset := 0

    for offset + SIMD_WIDTH <= len(haystack) {
        chunk := load_chunk(haystack, offset)
        eq: Vec = simd.lanes_eq(chunk, splat)

        if simd.reduce_or(eq) != 0 {
            mask := to_bitmask(eq)
            ctz := int(intrinsics.count_trailing_zeros(mask))
            return offset + ctz, true
        }
        offset += SIMD_WIDTH
    }

    for offset < len(haystack) {
        if haystack[offset] == needle {
            return offset, true
        }
        offset += 1
    }

    return 0, false
}

count_byte :: proc(haystack: []u8, needle: u8) -> int {
    splat := make_splat(needle)
    count := 0
    offset := 0

    for offset + SIMD_WIDTH <= len(haystack) {
        chunk := load_chunk(haystack, offset)
        eq: Vec = simd.lanes_eq(chunk, splat)
        mask := to_bitmask(eq)
        count += int(intrinsics.count_ones(mask))
        offset += SIMD_WIDTH
    }

    for offset < len(haystack) {
        if haystack[offset] == needle {
            count += 1
        }
        offset += 1
    }

    return count
}

find_substring :: proc(haystack: []u8, needle: []u8) -> (int, bool) {
    if len(needle) == 0 {
        return 0, true
    }
    if len(needle) > len(haystack) {
        return 0, false
    }
    if len(needle) == 1 {
        return find_byte(haystack, needle[0])
    }

    first_splat := make_splat(needle[0])
    last_splat := make_splat(needle[len(needle) - 1])
    offset := 0
    end := len(haystack) - len(needle) + 1

    for offset + SIMD_WIDTH <= end {
        chunk_first := load_chunk(haystack, offset)

        last_tmp: [SIMD_WIDTH]u8
        n := min(SIMD_WIDTH, end - offset)
        for i in 0..<n {
            last_tmp[i] = haystack[offset + i + len(needle) - 1]
        }
        chunk_last := transmute(Vec) last_tmp

        eq_first: Vec = simd.lanes_eq(chunk_first, first_splat)
        eq_last: Vec = simd.lanes_eq(chunk_last, last_splat)

        mask_first := to_bitmask(eq_first)
        mask_last := to_bitmask(eq_last)
        combined := mask_first & mask_last

        if combined != 0 {
            m := combined
            for m != 0 {
                bit_pos := int(intrinsics.count_trailing_zeros(m))
                candidate := offset + bit_pos

                if candidate + len(needle) <= len(haystack) {
                    match := true
                    for i in 0..<len(needle) {
                        if haystack[candidate + i] != needle[i] {
                            match = false
                            break
                        }
                    }
                    if match {
                        return candidate, true
                    }
                }
                m &= m - 1
            }
        }
        offset += SIMD_WIDTH
    }

    for offset < end {
        match := true
        for i in 0..<len(needle) {
            if haystack[offset + i] != needle[i] {
                match = false
                break
            }
        }
        if match {
            return offset, true
        }
        offset += 1
    }

    return 0, false
}

find_line_starts :: proc(haystack: []u8, out: []int) -> int {
    count := 0
    if count < len(out) {
        out[count] = 0
        count += 1
    }

    nl_splat := make_splat(u8('\n'))
    offset := 0

    for offset + SIMD_WIDTH <= len(haystack) {
        chunk := load_chunk(haystack, offset)
        eq: Vec = simd.lanes_eq(chunk, nl_splat)
        mask := to_bitmask(eq)

        for mask != 0 {
            bit_pos := int(intrinsics.count_trailing_zeros(mask))
            nl_offset := offset + bit_pos
            if nl_offset + 1 < len(haystack) && count < len(out) {
                out[count] = nl_offset + 1
                count += 1
            }
            mask &= mask - 1
        }
        offset += SIMD_WIDTH
    }

    for offset < len(haystack) {
        if haystack[offset] == '\n' && offset + 1 < len(haystack) && count < len(out) {
            out[count] = offset + 1
            count += 1
        }
        offset += 1
    }

    return count
}
