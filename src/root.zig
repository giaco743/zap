const std = @import("std");

pub const ArgParseError = error{
    ArgumentMissing,
    UnsupportedType,
    DuplicateArgument,
    ValueMissingForNamedField,
    UnknownArgument,
    NamedArgumentMissingValue,
    NeedsCustomConversion,
};

pub fn parse(comptime Args: type, args: std.process.Args, allocator: std.mem.Allocator) !Args {
    const argv = args.vector;
    return parseArgv(Args, argv[1..], allocator);
}

fn arrayArgs(comptime fields: anytype) type {
    // 100 possible array arguments should be enough?
    var field_names: [100][]const u8 = undefined;
    var field_types: [100]type = undefined;
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

fn deinitArrayArgs(arrayFields: anytype, allocator: std.mem.Allocator) void {
    inline for (@typeInfo(@typeInfo(@TypeOf(arrayFields)).pointer.child).@"struct".fields) |field| {
        @field(arrayFields.*, field.name).deinit(allocator);
    }
}

fn fieldConverter(comptime Args: type, fieldName: []const u8, comptime Arg: type) ?fn ([]const u8, std.mem.Allocator) ArgParseError!Arg {
    const conversionName = "to_" ++ fieldName;
    if (@hasDecl(Args, conversionName)) {
        return @field(Args, conversionName);
    } else return null;
}

fn parseArgv(comptime Args: type, argv: []const [*:0]const u8, allocator: std.mem.Allocator) !Args {
    var args: Args = undefined;

    const fields = @typeInfo(Args).@"struct".fields;
    var arrayFields = initArrayArgs(arrayArgs(fields));
    defer deinitArrayArgs(&arrayFields, allocator);
    var fieldStates = std.StaticBitSet(fields.len).initEmpty();

    var i_args: usize = 0;
    while (i_args < argv.len) : (i_args += 1) {
        const arg: []const u8 = std.mem.span(argv[i_args]);
        const val = parseArg(arg);
        var handled = false;
        switch (val) {
            .optionWithValue => |named| {
                inline for (fields, 0..) |field, i_fields| {
                    if (std.mem.eql(u8, field.name, named.key)) {
                        if (fieldStates.isSet(i_fields)) {
                            return ArgParseError.DuplicateArgument;
                        }
                        const field_type = switch (@typeInfo(field.type)) {
                            .optional => |opt| opt.child,
                            else => field.type,
                        };
                        const info = @typeInfo(field_type);
                        const value = try parseAs(field_type, named.value, allocator, fieldConverter(
                            Args,
                            field.name,
                            field_type,
                        ));
                        if (info == .pointer and info.pointer.size == .slice and info.pointer.child != u8) {
                            defer allocator.free(value);
                            try @field(arrayFields, field.name).appendSlice(allocator, value);
                        } else {
                            @field(args, field.name) = value;
                            fieldStates.set(i_fields);
                        }
                        handled = true;
                    }
                }
            },
            .value => |value| {
                var isSet = false;
                inline for (fields, 0..) |field, i_fields| {
                    if (!isSet and std.mem.startsWith(u8, field.name, "_") and !fieldStates.isSet(i_fields)) {
                        @field(args, field.name) = try parseAs(field.type, value, allocator, fieldConverter(
                            Args,
                            field.name,
                            field.type,
                        ));
                        fieldStates.set(i_fields);
                        isSet = true;
                        handled = true;
                    }
                }
            },
            .option => |name| {
                inline for (fields, 0..) |field, i_fields| {
                    if (std.mem.eql(u8, field.name, name)) {
                        switch (@typeInfo(field.type)) {
                            .pointer => |pointer| {
                                switch (pointer.size) {
                                    .slice => {
                                        if (pointer.child == u8) {
                                            if (fieldStates.isSet(i_fields)) {
                                                return ArgParseError.DuplicateArgument;
                                            }
                                            if (i_args < (argv.len - 1)) {
                                                i_args += 1;
                                            }
                                            const next_arg: []const u8 = std.mem.span(argv[i_args]);
                                            @field(args, field.name) = next_arg;
                                        } else {
                                            if (i_args < (argv.len - 1)) {
                                                i_args += 1;
                                            }
                                            while (i_args < argv.len) : (i_args += 1) {
                                                const next_arg: []const u8 = std.mem.span(argv[i_args]);
                                                const parsed = parseArg(next_arg);
                                                if (parsed == .value) {
                                                    try @field(arrayFields, field.name).append(allocator, try parseAs(pointer.child, parsed.value, allocator, fieldConverter(
                                                        Args,
                                                        field.name,
                                                        pointer.child,
                                                    )));
                                                } else {
                                                    i_args -= 1;
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
                                if (fieldStates.isSet(i_fields)) {
                                    return ArgParseError.DuplicateArgument;
                                }
                                @field(args, field.name) = true;
                                handled = true;
                                fieldStates.set(i_fields);
                            },
                            else => {
                                if (fieldStates.isSet(i_fields)) {
                                    return ArgParseError.DuplicateArgument;
                                }
                                if (i_args < (argv.len - 1)) {
                                    i_args += 1;
                                }
                                const next_arg: []const u8 = std.mem.span(argv[i_args]);
                                const parsed = parseArg(next_arg);
                                const field_type = switch (@typeInfo(field.type)) {
                                    .optional => |opt| opt.child,
                                    else => field.type,
                                };
                                if (parsed == .value) {
                                    @field(args, field.name) = try parseAs(field_type, parsed.value, allocator, fieldConverter(
                                        Args,
                                        field.name,
                                        field_type,
                                    ));
                                    fieldStates.set(i_fields);
                                    handled = true;
                                } else {
                                    return ArgParseError.NamedArgumentMissingValue;
                                }
                            },
                        }
                    }
                }
            },
        }
        if (!handled) {
            return ArgParseError.UnknownArgument;
        }
    }

    // Check if all mandatory fields are set and handle unset flags and optionals
    // Assign array arguments
    inline for (fields, 0..) |field, i_fields| {
        if (!fieldStates.isSet(i_fields)) {
            switch (@typeInfo(field.type)) {
                .bool => @field(args, field.name) = false,
                .optional => @field(args, field.name) = null,
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child != u8) {
                        const owned = try @field(arrayFields, field.name).toOwnedSlice(allocator);
                        @field(args, field.name) = owned;
                    } else {
                        return ArgParseError.ArgumentMissing;
                    }
                },
                else => {
                    return ArgParseError.ArgumentMissing;
                },
            }
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
                    if (pointer.child == u8) {
                        return arg;
                    } else {
                        var list = std.ArrayList(pointer.child).empty;
                        defer list.deinit(allocator);

                        var it = std.mem.splitSequence(u8, arg, ",");
                        var i: u32 = 0;
                        while (it.next()) |item| {
                            try list.append(allocator, try parseAs(pointer.child, item, allocator, null));
                            i += 1;
                        }
                        return list.toOwnedSlice(allocator);
                    }
                },
                else => {
                    return ArgParseError.UnsupportedType;
                },
            }
        },
        else => {
            return ArgParseError.NeedsCustomConversion;
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

test "parse different raw args" {
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

test "parse positional args basic" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
        _text: []const u8,
    };

    const args = [_][*:0]const u8{ "42", "hello" };

    const result = try parseArgv(S, args[0..], allocator);

    try std.testing.expectEqual(@as(i32, 42), result._int);
    try std.testing.expectEqualStrings("hello", result._text);
}

test "named argument parsing" {
    const allocator = std.testing.allocator;

    const S = struct {
        key: []const u8,
    };

    const args = [_][*:0]const u8{"--key=zig"};

    const result = try parseArgv(S, args[0..], allocator);

    try std.testing.expectEqualStrings("zig", result.key);
}

test "boolean flag parsing" {
    const allocator = std.testing.allocator;

    const S = struct {
        flag: bool,
    };

    const args = [_][*:0]const u8{"--flag"};

    const result = try parseArgv(S, args[0..], allocator);

    try std.testing.expect(result.flag);
}

test "unknown argument returns error" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
    };

    const args = [_][*:0]const u8{"--something"};

    const result = parseArgv(S, args[0..], allocator);

    try std.testing.expectError(
        ArgParseError.UnknownArgument,
        result,
    );
}

test "missing required positional argument" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
        _text: []const u8,
    };

    const args = [_][*:0]const u8{"123"};

    const result = parseArgv(S, args[0..], allocator);

    try std.testing.expectError(
        ArgParseError.ArgumentMissing,
        result,
    );
}

test "mixed named and positional args" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
        name: []const u8,
    };

    const args = [_][*:0]const u8{
        "--name=zig",
        "7",
    };

    const result = try parseArgv(S, args[0..], allocator);

    try std.testing.expectEqual(@as(i32, 7), result._int);
    try std.testing.expectEqualStrings("zig", result.name);
}

test "duplicate named argument returns error" {
    const allocator = std.testing.allocator;

    const S = struct {
        key: []const u8,
    };

    const args = [_][*:0]const u8{
        "--key=first",
        "--key=second",
    };

    try std.testing.expectError(ArgParseError.DuplicateArgument, parseArgv(S, args[0..], allocator));
}

test "positional order stability" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
        _text: []const u8,
    };

    const args = [_][*:0]const u8{ "99", "world" };

    const result = try parseArgv(S, args[0..], allocator);

    try std.testing.expectEqual(@as(i32, 99), result._int);
    try std.testing.expectEqualStrings("world", result._text);
}

test "allocated arrays" {
    const allocator = std.testing.allocator;

    const S = struct {
        int: []i32,
    };

    const expected = [_]i32{ 1, 2, 3 };
    {
        const args = [_][*:0]const u8{ "--int", "1", "2", "3" };

        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{"--int=1,2,3"};

        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{ "--int=1,2", "--int", "3" };

        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{ "--int", "1", "--int=2,3" };

        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{ "--int", "1", "--int=2", "--int", "3" };

        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
}

test "optional values" {
    const allocator = std.testing.allocator;

    const S = struct { int: ?i32, float: ?f32 };

    {
        const expected = S{ .int = 1, .float = 2.3 };
        const args = [_][*:0]const u8{ "--int", "1", "--float=2.3" };

        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = 1, .float = null };
        const args = [_][*:0]const u8{ "--int", "1" };

        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = null, .float = 2.3 };
        const args = [_][*:0]const u8{"--float=2.3"};

        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = null, .float = null };
        const args = [_][*:0]const u8{};

        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }
}
