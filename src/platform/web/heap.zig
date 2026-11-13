//! The allocator for the WebAssembly build. Zig's wasm allocator is a small
//! bump allocator over the module's linear memory; there is no libc and no
//! page allocator to choose from.

const std = @import("std");

pub const allocator: std.mem.Allocator = std.heap.wasm_allocator;
