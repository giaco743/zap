const std = @import("std");
const Io = std.Io;

const zap = @import("zap");

const Args = struct {
    string: []const u8,
    int: u32,
    float: f16,
    flag: bool,
    intArray: []i32,
    optInt: ?i32,
    _pos1: i32,
    _pos2: i32,
};

pub fn main(init: std.process.Init.Minimal) !void {
    const alloc = std.heap.smp_allocator;
    const args = try zap.parse(Args, init.args, alloc);
    std.debug.print("String: {s}, int: {}, float: {}, flag {}, pos1: {}, pos2: {}, optInt: {any}, intArray: {any}\n", .{
        args.string,
        args.int,
        args.float,
        args.flag,
        args._pos1,
        args._pos2,
        args.optInt,
        args.intArray,
        // args._intSlice,
        // args._strSlice,
        // args._secret,
    });
}
