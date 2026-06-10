const std = @import("std");
const Io = std.Io;

const zap = @import("zap");

const Args = struct {
    string: []const u8,
    int: u32,
    float: f16,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.smp_allocator;
    const args = try zap.parse(Args, init.args, alloc);
    std.debug.print("String: {s}, int: {}, float: {}\n", .{
        args.string,
        args.int,
        args.float,
    });
}
