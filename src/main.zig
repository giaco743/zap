const std = @import("std");
const Io = std.Io;

const zap = @import("zap");

const Args = struct {
    _file: []const u8,
    string: []const u8,
    int: u32,
    float: f16,

    pub const description = "This program does stuff";
    pub const float_description = "An ordinary float";
    pub const short_float = null;
};

pub fn main(init: std.process.Init.Minimal) void {
    const alloc = std.heap.smp_allocator;
    const args = zap.parse(Args, init.args, alloc);
    std.debug.print("String: {s}, int: {}, float: {}, file {s}\n", .{
        args.string,
        args.int,
        args.float,
        args._file,
    });
}
