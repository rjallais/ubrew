// nanobrew — ELF relocator for Linux
//
// Mirrors the Mach-O relocator architecture:
// 1. Detect ELF files (0x7f ELF magic)
// 2. Parse ELF headers natively to check for placeholders
// 3. Use patchelf --set-rpath when changes needed
// 4. Replace placeholders in .pc, .cmake, .la text files
// 5. No codesign step (Linux doesn't need it)
//
// Note: every std.process.run call below threads the caller's `io` rather
// than std.Io.Threaded.global_single_threaded.io(). Zig 0.16's process
// subsystem rejects the unsynchronized singleton with a vtable mismatch
// that surfaces as error.CopyFailed (see issue #276).

const std = @import("std");
const placeholder = @import("../platform/placeholder.zig");
const paths = @import("../platform/paths.zig");

const ELF_DIRS = [_][]const u8{ "bin", "sbin", "lib", "lib64", "libexec" };

// ELF magic: 0x7f 'E' 'L' 'F'
const ELF_MAGIC = [4]u8{ 0x7f, 'E', 'L', 'F' };

// Text config file extensions that may contain placeholders
const TEXT_EXTS = [_][]const u8{ ".pc", ".cmake", ".la", ".sh", ".cfg" };

// Process-wide coordination for the auto-install path. When `nb install`
// fans out parallel workers and patchelf is missing, every worker would
// otherwise race to run `apt-get install` simultaneously — but apt holds
// /var/lib/dpkg/lock-frontend exclusively, so all but one worker would
// fail and skip relocation. We serialize the bootstrap with a mutex and
// memoize the result so subsequent workers find patchelf already present
// (or fail fast without re-running the package manager).
const PatchelfState = enum(u8) { unknown, present, install_failed };
var patchelf_mutex: std.Io.Mutex = .init;
var patchelf_state: PatchelfState = .unknown;

/// Ensure patchelf is available, attempting a one-shot auto-install on
/// first call. Safe to call concurrently — only one caller drives the
/// install; the rest observe the cached outcome. Idempotent on success.
pub fn ensurePatchelf(alloc: std.mem.Allocator, io: std.Io) error{PatchelfNotFound}!void {
    patchelf_mutex.lockUncancelable(io);
    defer patchelf_mutex.unlock(io);

    switch (patchelf_state) {
        .present => return,
        .install_failed => return error.PatchelfNotFound,
        .unknown => {},
    }

    if (hasPatchelf(alloc, io)) |_| {
        patchelf_state = .present;
        return;
    } else |_| {}

    ({
        const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: patchelf not found — attempting auto-install...\n", .{}) catch "";
        defer std.heap.smp_allocator.free(_tmp);
        std.Io.File.stderr().writeStreamingAll(io, _tmp) catch {};
    });

    // Try without sudo first (works in containers/root), then with sudo.
    // Each entry is an optional refresh command (best-effort, e.g.
    // `apt-get update`) followed by the install command. apt in particular
    // requires a refresh on freshly-pulled container images where
    // /var/lib/apt/lists is empty.
    const Step = struct { refresh: ?[]const []const u8, install: []const []const u8 };
    const install_cmds = [_]Step{
        .{ .refresh = &.{ "apt-get", "update" }, .install = &.{ "apt-get", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "dnf", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "yum", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "apk", "add", "--no-cache", "patchelf" } },
        .{ .refresh = &.{ "pacman", "-Sy", "--noconfirm" }, .install = &.{ "pacman", "-S", "--noconfirm", "patchelf" } },
        .{ .refresh = &.{ "sudo", "apt-get", "update" }, .install = &.{ "sudo", "apt-get", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "sudo", "dnf", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "sudo", "yum", "install", "-y", "patchelf" } },
        .{ .refresh = null, .install = &.{ "sudo", "apk", "add", "--no-cache", "patchelf" } },
        .{ .refresh = &.{ "sudo", "pacman", "-Sy", "--noconfirm" }, .install = &.{ "sudo", "pacman", "-S", "--noconfirm", "patchelf" } },
    };
    for (install_cmds) |step| {
        if (step.refresh) |refresh| {
            if (std.process.run(alloc, io, .{ .argv = refresh })) |r| {
                alloc.free(r.stdout);
                alloc.free(r.stderr);
            } else |_| {}
        }
        const result = std.process.run(alloc, io, .{
            .argv = step.install,
        }) catch continue;
        alloc.free(result.stdout);
        alloc.free(result.stderr);
        if (result.term == .exited and result.term.exited == 0) break;
    }

    if (hasPatchelf(alloc, io)) |_| {
        ({
            const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: patchelf installed successfully\n", .{}) catch "";
            defer std.heap.smp_allocator.free(_tmp);
            std.Io.File.stderr().writeStreamingAll(io, _tmp) catch {};
        });
        patchelf_state = .present;
        return;
    } else |_| {
        patchelf_state = .install_failed;
        return error.PatchelfNotFound;
    }
}

/// Relocate all ELF files and text configs in a keg.
pub fn relocateKeg(alloc: std.mem.Allocator, io: std.Io, name: []const u8, version: []const u8) !void {
    ensurePatchelf(alloc, io) catch {
        ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: {s}: could not install patchelf — ELF binary relocation skipped\n", .{name}) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stderr().writeStreamingAll(io, _tmp) catch {}; });
        ({ const _tmp = std.fmt.allocPrint(std.heap.smp_allocator, "nb: install patchelf manually (e.g. apt install patchelf) and re-run: nb reinstall {s}\n", .{name}) catch ""; defer std.heap.smp_allocator.free(_tmp); std.Io.File.stderr().writeStreamingAll(io, _tmp) catch {}; });
        return error.PatchelfNotFound;
    };

    var keg_buf: [512]u8 = undefined;
    const keg_dir = std.fmt.bufPrint(&keg_buf, "{s}/{s}/{s}", .{ paths.CELLAR_DIR, name, version }) catch return error.PathTooLong;

    // Walk standard directories for ELF binaries
    for (ELF_DIRS) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocate(alloc, io, sub_path) catch {};
    }

    // Also relocate text config files in lib/pkgconfig, lib/cmake, etc.
    const text_dirs = [_][]const u8{ "lib/pkgconfig", "lib/cmake", "share/pkgconfig", "lib64/pkgconfig" };
    for (text_dirs) |subdir| {
        var sub_buf: [512]u8 = undefined;
        const sub_path = std.fmt.bufPrint(&sub_buf, "{s}/{s}", .{ keg_dir, subdir }) catch continue;
        walkAndRelocateText(io, sub_path) catch {};
    }

    // Also check .la files in lib/ directly
    var lib_buf: [512]u8 = undefined;
    const lib_path = std.fmt.bufPrint(&lib_buf, "{s}/lib", .{keg_dir}) catch return;
    relocateLaFiles(io, lib_path) catch {};
}

fn hasPatchelf(alloc: std.mem.Allocator, io: std.Io) !void {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "patchelf", "--version" },
    }) catch return error.PatchelfNotFound;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        return error.PatchelfNotFound;
    }
}

fn walkAndRelocate(alloc: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        var child_buf: [2048]u8 = undefined;
        const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;

        switch (entry.kind) {
            .directory => walkAndRelocate(alloc, io, child_path) catch {},
            .file => relocateFile(alloc, io, child_path),
            else => {},
        }
    }
}

fn walkAndRelocateText(io: std.Io, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            var child_buf: [2048]u8 = undefined;
            const child_path = std.fmt.bufPrint(&child_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
            walkAndRelocateText(io, child_path) catch {};
            continue;
        }
        if (entry.kind != .file) continue;

        for (TEXT_EXTS) |ext| {
            if (std.mem.endsWith(u8, entry.name, ext)) {
                var path_buf: [2048]u8 = undefined;
                const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch break;
                _ = placeholder.relocateTextFile(io, file_path);
                break;
            }
        }
    }
}

fn relocateLaFiles(io: std.Io, dir_path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iter = dir.iterate();
    while (iter.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".la")) continue;
        var path_buf: [2048]u8 = undefined;
        const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        _ = placeholder.relocateTextFile(io, file_path);
    }
}

fn relocateFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return;
    defer file.close(io);

    // Read ELF header to detect format
    var header: [16]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return;
    if (n < 16) return;
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) return;

    // Always attempt interpreter fixup — bottles may have hardcoded
    // /home/linuxbrew/.linuxbrew/ paths without @@HOMEBREW markers
    patchInterpreter(alloc, io, path);

    // Only do rpath/needed if placeholders are present (saves subprocess cost)
    if (!elfContainsPlaceholder(io, file)) return;

    patchelfRelocateRpathAndNeeded(alloc, io, path);
}

fn elfContainsPlaceholder(io: std.Io, file: std.Io.File) bool {
    var buf: [65536]u8 = undefined;
    var overlap: usize = 0;
    const needle = "@@HOMEBREW";
    while (true) {
        if (overlap > 0) {
            const src = buf[buf.len - overlap ..];
            std.mem.copyForwards(u8, buf[0..overlap], src);
        }
        const n = file.readStreaming(io, &.{buf[overlap..]}) catch return false;
        if (n == 0) break;
        const total = overlap + n;
        if (std.mem.indexOf(u8, buf[0..total], needle) != null) return true;
        overlap = @min(needle.len - 1, total);
    }
    return false;
}

fn patchelfRelocateRpathAndNeeded(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    // 1. Fix RPATH
    const rpath_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--print-rpath", path } }) catch return;
    defer alloc.free(rpath_result.stderr);
    defer alloc.free(rpath_result.stdout);

    if (rpath_result.term == .exited and rpath_result.term.exited == 0) {
        const current_rpath = std.mem.trim(u8, rpath_result.stdout, " \t\n\r");
        if (current_rpath.len > 0 and placeholder.hasPlaceholder(current_rpath)) {
            const new_rpath = placeholder.replacePlaceholders(alloc, current_rpath) catch return;
            defer alloc.free(new_rpath);

            const set_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--set-rpath", new_rpath, path } }) catch return;
            alloc.free(set_result.stdout);
            alloc.free(set_result.stderr);
        }
    }

    // 2. Fix DT_NEEDED entries with placeholders
    const needed_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--print-needed", path } }) catch return;
    defer alloc.free(needed_result.stderr);

    var lines_iter = std.mem.splitScalar(u8, needed_result.stdout, '\n');
    while (lines_iter.next()) |line| {
        const lib = std.mem.trim(u8, line, " \t\r");
        if (lib.len == 0) continue;
        if (placeholder.hasPlaceholder(lib)) {
            const new_lib = placeholder.replacePlaceholders(alloc, lib) catch continue;
            defer alloc.free(new_lib);
            const replace_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--replace-needed", lib, new_lib, path } }) catch continue;
            alloc.free(replace_result.stdout);
            alloc.free(replace_result.stderr);
        }
    }
    alloc.free(needed_result.stdout);
}

fn patchInterpreter(alloc: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--print-interpreter", path } }) catch return;
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);

    if (result.term != .exited or result.term.exited != 0) return; // not an executable (shared lib)

    const current = std.mem.trim(u8, result.stdout, " \t\n\r");
    if (!placeholder.hasPlaceholder(current)) {
        // Also fix hardcoded Linuxbrew interpreter paths (no @@HOMEBREW marker)
        const linuxbrew_prefix = "/home/linuxbrew/.linuxbrew/";
        if (!std.mem.startsWith(u8, current, linuxbrew_prefix)) return;
        // Fall through to detectInterpreter for the correct system path
    } else if (placeholder.replacePlaceholders(alloc, current)) |resolved| {
        defer alloc.free(resolved);
        if (std.Io.Dir.accessAbsolute(io, resolved, .{})) |_| {
            const set_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--set-interpreter", resolved, path } }) catch return;
            alloc.free(set_result.stdout);
            alloc.free(set_result.stderr);
            return;
        } else |_| {}
    } else |_| {}

    const new_interp = detectInterpreter(io, path) orelse return;

    const set_result = std.process.run(alloc, io, .{ .argv = &.{ "patchelf", "--set-interpreter", new_interp, path } }) catch return;
    alloc.free(set_result.stdout);
    alloc.free(set_result.stderr);
}

/// Read the ELF e_machine field to pick the correct dynamic linker for the
/// binary's actual architecture (not the architecture nb was compiled for).
fn detectInterpreter(io: std.Io, path: []const u8) ?[]const u8 {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);

    var header: [20]u8 = undefined;
    const n = file.readPositionalAll(io, &header, 0) catch return null;
    if (n < 20) return null;
    if (!std.mem.eql(u8, header[0..4], &ELF_MAGIC)) return null;

    // e_machine is at offset 18, little-endian u16
    const e_machine = std.mem.readInt(u16, header[18..20], .little);
    return switch (e_machine) {
        0xB7 => "/lib/ld-linux-aarch64.so.1", // EM_AARCH64
        0x3E => "/lib64/ld-linux-x86-64.so.2", // EM_X86_64
        0x03 => "/lib/ld-linux.so.2", // EM_386
        else => null,
    };
}
