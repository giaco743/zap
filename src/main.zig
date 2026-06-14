const std = @import("std");
const Io = std.Io;

const zap = @import("zap");

const Args = struct {
    _files: []const []const u8,
    string: []const u8,
    int: u32,
    afloat: f16,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.smp_allocator;
    const args = try zap.parse(Args, init.args, alloc);
    defer alloc.free(args._files);
    std.debug.print("String: {s}, int: {}, float: {}, array {any}\n", .{
        args.string,
        args.int,
        args.afloat,
        args._files,
    });
}
