const std = @import("std");

pub const ArgParseError = error{
    ArgumentMissing,
    UnsupportedType,
    DuplicateArgument,
    ValueMissingForNamedField,
    UnknownArgument,
};

pub fn parse(comptime Args: type, args: std.process.Args, allocator: std.mem.Allocator) !Args {
    const argv = args.vector;
    return parseArgv(Args, argv[1..], allocator);
}

fn arrayArgs(comptime fields: anytype) type {
    var field_names: [10][]const u8 = undefined;
    var field_types: [10]type = undefined;
    var n_fields = 0;
    inline for (fields) |field| {
        switch (@typeInfo(field.type)) {
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child != u8) {
                    field_names[n_fields] = field.name;
                    field_types[n_fields] = std.ArrayList(ptr.child);
                    n_fields += 1;
                }
            },
            else => {
                continue;
            },
        }
    }

    return @Struct(.auto, null, field_names[0..n_fields], field_types[0..n_fields], &@splat(.{}));
}

fn initArrayArgs(
    comptime Args: type,
) Args {
    var args: Args = undefined;

    inline for (@typeInfo(Args).@"struct".fields) |field| {
        @field(args, field.name) =
            @TypeOf(@field(args, field.name)).empty;
    }

    return args;
}

fn parseArgv(comptime Args: type, argv: []const [*:0]const u8, allocator: std.mem.Allocator) !Args {
    var args: Args = undefined;
    const fields = @typeInfo(Args).@"struct".fields;
    var fieldArray = initArrayArgs(arrayArgs(fields));
    var fieldStates = std.StaticBitSet(fields.len).initEmpty();
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = std.mem.span(argv[i]);
        const val = parseArg(arg);
        var handled = false;
        std.debug.print("Arg: {s}\n", .{arg});
        switch (val) {
            .optionWithValue => |named| {
                std.debug.print("Named argument\n", .{});
                inline for (fields, 0..) |field, idx| {
                    if (std.mem.eql(u8, field.name, named.key) and !fieldStates.isSet(idx)) {
                        const conversionName = "to_" ++ field.name;
                        const conversion = if (@hasDecl(Args, conversionName))
                            @field(Args, conversionName)
                        else
                            null;
                        const field_type = switch (@typeInfo(field.type)) {
                            .optional => |opt| opt.child,
                            else => field.type,
                        };
                        @field(args, field.name) = try parseAs(field_type, named.value, allocator, conversion);
                        std.debug.print("Field {s} was set to {s}\n", .{ named.key, named.value });
                        fieldStates.set(idx);
                        handled = true;
                    }
                }
            },
            .value => |value| {
                std.debug.print("Positional argument\n", .{});
                var isSet = false;
                inline for (fields, 0..) |field, idx| {
                    if (!isSet and std.mem.startsWith(u8, field.name, "_") and !fieldStates.isSet(idx)) {
                        const conversionName = "to_" ++ field.name[1..];
                        const conversion = if (@hasDecl(Args, conversionName))
                            @field(Args, conversionName)
                        else
                            null;
                        @field(args, field.name) = try parseAs(field.type, value, allocator, conversion);
                        fieldStates.set(idx);
                        isSet = true;
                        handled = true;
                    }
                }
            },
            .option => |name| {
                std.debug.print("Option argument\n", .{});
                inline for (fields, 0..) |field, idx| {
                    if (std.mem.eql(u8, field.name, name)) {
                        const conversionName = "to_" ++ field.name;
                        const conversion = if (@hasDecl(Args, conversionName))
                            @field(Args, conversionName)
                        else
                            null;
                        switch (@typeInfo(field.type)) {
                            .pointer => |pointer| {
                                switch (pointer.size) {
                                    .slice => {
                                        if (pointer.child == u8) {
                                            if (i < (argv.len - 1)) {
                                                i += 1;
                                            }
                                            const next_arg: []const u8 = std.mem.span(argv[i]);
                                            @field(args, field.name) = next_arg;
                                        } else {
                                            var ii: usize = 0;
                                            if (i < (argv.len - 1)) {
                                                i += 1;
                                            }
                                            while (i < argv.len) : ({
                                                i += 1;
                                                ii += 1;
                                            }) {
                                                const next_arg: []const u8 = std.mem.span(argv[i]);
                                                const parsed = parseArg(next_arg);
                                                if (parsed == .value) {
                                                    try @field(fieldArray, field.name).append(allocator, try parseAs(pointer.child, parsed.value, allocator, conversion));
                                                } else {
                                                    i -= 1;
                                                    break;
                                                }
                                            }
                                        }
                                        handled = true;
                                    },
                                    else => {
                                        return ArgParseError.UnsupportedType;
                                    },
                                }
                            },
                            .bool => {
                                @field(args, field.name) = true;
                                handled = true;
                            },
                            else => return ArgParseError.UnsupportedType,
                        }
                        fieldStates.set(idx);
                    }
                }
            },
        }
        if (!handled) {
            return ArgParseError.UnknownArgument;
        }
    }
    inline for (fields, 0..) |field, idx| {
        if (!fieldStates.isSet(idx)) {
            switch (@typeInfo(field.type)) {
                .bool => @field(args, field.name) = false,
                .optional => @field(args, field.name) = null,
                else => {
                    return ArgParseError.ArgumentMissing;
                },
            }
        }
        switch (@typeInfo(field.type)) {
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child != u8) {
                    @field(args, field.name) = @field(fieldArray, field.name).items;
                }
            },
            else => {
                continue;
            },
        }
    }
    return args;
}

fn parseAs(comptime Arg: type, arg: []const u8, allocator: std.mem.Allocator, conversion: ?fn ([]const u8, std.mem.Allocator) ArgParseError!Arg) !Arg {
    if (conversion) |convert| {
        return try convert(arg, allocator);
    }
    if (Arg == []const u8) {
        return arg;
    }
    switch (@typeInfo(Arg)) {
        .int => {
            return try std.fmt.parseInt(Arg, arg, 10);
        },
        .float => {
            return try std.fmt.parseFloat(Arg, arg);
        },
        .pointer => |pointer| {
            switch (pointer.size) {
                .slice => {
                    var buf = try allocator.alloc(pointer.child, 100);
                    var it = std.mem.splitSequence(u8, arg, ",");
                    var i: u32 = 0;
                    while (it.next()) |item| {
                        buf[i] = try parseAs(pointer.child, item, allocator, null);
                        i += 1;
                    }
                    return buf[0..i];
                },
                else => {
                    return ArgParseError.UnsupportedType;
                },
            }
        },
        else => {
            @panic("Type not supported");
        },
    }
}

const Argument = union(enum) {
    optionWithValue: struct { key: []const u8, value: []const u8 },
    value: []const u8,
    option: []const u8,
};

fn parseArg(arg: []const u8) Argument {
    if (std.mem.startsWith(u8, arg, "--")) {
        const is = std.mem.findPos(u8, arg, 2, "=");
        if (is) |pos| {
            return .{ .optionWithValue = .{ .key = arg[2..pos], .value = arg[pos + 1 ..] } };
        }
        return .{ .option = arg[2..] };
    }
    return .{ .value = arg };
}

test "parse different args" {
    const pos_arg = parseArg("positional");
    try std.testing.expect(pos_arg == .value);
    try std.testing.expectEqualStrings(pos_arg.value, "positional");
    const flag_arg = parseArg("--flag");
    try std.testing.expect(flag_arg == .option);
    try std.testing.expectEqualStrings(flag_arg.option, "flag");
    const named_arg = parseArg("--key=value");
    try std.testing.expect(named_arg == .optionWithValue);
    try std.testing.expectEqualStrings(named_arg.optionWithValue.key, "key");
    try std.testing.expectEqualStrings(named_arg.optionWithValue.value, "value");
}
