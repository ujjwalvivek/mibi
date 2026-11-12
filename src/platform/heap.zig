//! The process allocator.
//!
//! Unix links libc for termios anyway, so `malloc` is there and costs
//! nothing. Windows links no libc; the process heap does the same job. Both
//! are real small-block allocators: an editor makes many small allocations,
//! and a page per allocation (`std.heap.page_allocator`) is the wrong tool.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const allocator: Allocator = if (builtin.os.tag == .windows) process_heap else std.heap.c_allocator;

const process_heap: Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
} };

const k32 = struct {
    extern "kernel32" fn GetProcessHeap() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn HeapAlloc(heap: *anyopaque, flags: u32, bytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn HeapReAlloc(heap: *anyopaque, flags: u32, mem: *anyopaque, bytes: usize) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn HeapFree(heap: *anyopaque, flags: u32, mem: *anyopaque) callconv(.winapi) i32;
    const REALLOC_IN_PLACE_ONLY: u32 = 0x10;
};

/// What `HeapAlloc` guarantees: two pointers' worth.
const natural: usize = 2 * @sizeOf(usize);

/// Stricter alignments over-allocate and keep the block's real address in
/// the word before the aligned one.
fn alloc(_: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
    const heap = k32.GetProcessHeap() orelse return null;
    const al = alignment.toByteUnits();
    if (al <= natural) return @ptrCast(k32.HeapAlloc(heap, 0, @max(len, 1)));
    const total = std.math.add(usize, len, al + @sizeOf(usize)) catch return null;
    const base: [*]u8 = @ptrCast(k32.HeapAlloc(heap, 0, total) orelse return null);
    const aligned = std.mem.alignForward(usize, @intFromPtr(base) + @sizeOf(usize), al);
    @as(*usize, @ptrFromInt(aligned - @sizeOf(usize))).* = @intFromPtr(base);
    return @ptrFromInt(aligned);
}

fn resize(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) bool {
    if (new_len <= memory.len) return true;
    if (alignment.toByteUnits() > natural) return false;
    const heap = k32.GetProcessHeap() orelse return false;
    return k32.HeapReAlloc(heap, k32.REALLOC_IN_PLACE_ONLY, memory.ptr, new_len) != null;
}

fn remap(_: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > natural) return if (new_len <= memory.len) memory.ptr else null;
    const heap = k32.GetProcessHeap() orelse return null;
    return @ptrCast(k32.HeapReAlloc(heap, 0, memory.ptr, @max(new_len, 1)));
}

fn free(_: *anyopaque, memory: []u8, alignment: Alignment, _: usize) void {
    const heap = k32.GetProcessHeap() orelse return;
    const base: *anyopaque = if (alignment.toByteUnits() <= natural)
        memory.ptr
    else
        @ptrFromInt(@as(*usize, @ptrFromInt(@intFromPtr(memory.ptr) - @sizeOf(usize))).*);
    _ = k32.HeapFree(heap, 0, base);
}

test "allocations of every alignment round-trip" {
    const a = allocator;
    var list = std.ArrayList(u8).empty;
    defer list.deinit(a);
    for (0..5000) |i| try list.append(a, @truncate(i));
    for (list.items, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(i)), b);

    const wide = try a.alignedAlloc(u8, .@"64", 100);
    defer a.free(wide);
    try std.testing.expect(@intFromPtr(wide.ptr) % 64 == 0);
    @memset(wide, 7);

    const words = try a.alloc(u64, 3);
    const more = try a.realloc(words, 300);
    defer a.free(more);
    more[299] = 1;
}
