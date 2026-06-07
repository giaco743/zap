const std = @import("std");

pub const ArgParseError = error{
    ArgumentMissing,
    DuplicateArgument,
    UnknownArgument,
    NamedArgumentMissingValue,
    NeedsCustomConversion,
    OptionMissing,
    InvalidShort,
    InvalidLong,
    Overflow,
    InvalidCharacter,
    AmbiguousShort,
};

const ArgCursor = struct {
    argv: []const [*:0]const u8,
    index: usize,

    fn init(argv: []const [*:0]const u8) ArgCursor {
        return ArgCursor{ .argv = argv, .index = 0 };
    }
    fn peek(self: *ArgCursor) ?ArgParseError!ArgToken {
        if (self.index >= self.argv.len) {
            return null;
        }
        const arg: []const u8 = std.mem.span(self.argv[self.index]);
        return try parseArg(arg);
    }
    fn next(self: *ArgCursor) ?ArgParseError!ArgToken {
        if (self.peek()) |arg| {
            self.index += 1;
            return arg;
        }
        return null;
    }
};

pub fn parse(comptime Args: type, args: std.process.Args, allocator: std.mem.Allocator) !Args {
    const cursor = ArgCursor.init(args.vector);
    return parseArgv(Args, cursor, allocator);
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
    if (!@hasDecl(Args, conversionName)) {
        return null;
    }

    const f = @field(Args, conversionName);

    const ret = @typeInfo(@TypeOf(f)).@"fn".return_type.?;

    const ok = switch (@typeInfo(ret)) {
        .error_union => |eu| eu.payload == Arg,
        else => false,
    };

    if (!ok) return null;

    return f;
}

fn getShort(comptime Args: type, comptime name: []const u8) ?u8 {
    if (name.len == 0) return null;
    if (std.mem.startsWith(u8, name, "_")) return null;
    const short_decl = "short_" ++ name;
    if (@hasDecl(Args, short_decl)) {
        return @field(Args, short_decl);
    }
    return name[0];
}

fn parseArgv(comptime Args: type, cursor: *ArgCursor, allocator: std.mem.Allocator) !Args {
    var args: Args = undefined;

    const fields = @typeInfo(Args).@"struct".fields;
    var arrayFields = initArrayArgs(arrayArgs(fields));
    defer deinitArrayArgs(&arrayFields, allocator);
    var fieldStates = std.StaticBitSet(fields.len).initEmpty();

    while (cursor.next()) |arg| {
        var handled = false;
        switch (try arg) {
            .shortWithTail => |short| {
                inline for (fields, 0..) |field, i_fields| {
                    if (getShort(Args, field.name)) |s| {
                        if (s == short.key) {
                            // if first short is a flag the rest has to be flags as well
                            if (field.type == bool) {
                                if (fieldStates.isSet(i_fields)) {
                                    return ArgParseError.DuplicateArgument;
                                }
                                @field(args, fields[i_fields].name) = true;
                                fieldStates.set(i_fields);
                                handled = true;

                                inline for (fields, 0..) |f, i| {
                                    if (getShort(Args, f.name)) |ss| {
                                        if (std.mem.containsAtLeastScalar2(u8, short.tail, 1, ss)) {
                                            if (field.type != bool) return ArgParseError.InvalidShort;
                                            @field(args, fields[i].name) = true;
                                            fieldStates.set(i);
                                        }
                                    }
                                }
                            } // otherwise it has to be a value
                            else {
                                const field_type = switch (@typeInfo(field.type)) {
                                    .optional => |opt| opt.child,
                                    else => field.type,
                                };
                                const info = @typeInfo(field_type);
                                // is array
                                if (info == .pointer and info.pointer.size == .slice and info.pointer.child != u8) {
                                    var argIt = std.mem.splitScalar(u8, short.tail, ',');
                                    while (argIt.next()) |a| {
                                        const value = try parseAs(info.pointer.child, a, allocator, fieldConverter(
                                            Args,
                                            field.name,
                                            info.pointer.child,
                                        ));
                                        try @field(arrayFields, field.name).append(allocator, value);
                                    }
                                } else {
                                    if (fieldStates.isSet(i_fields)) {
                                        return ArgParseError.DuplicateArgument;
                                    }
                                    const value = try parseAs(field_type, short.tail, allocator, fieldConverter(
                                        Args,
                                        field.name,
                                        field_type,
                                    ));
                                    @field(args, field.name) = value;
                                    fieldStates.set(i_fields);
                                }
                                handled = true;
                            }
                        }
                    }
                }
            },
            // named value with value
            .longWithValue => |named| {
                inline for (fields, 0..) |field, i_fields| {
                    if (std.mem.eql(u8, field.name, named.key)) {
                        const field_type = switch (@typeInfo(field.type)) {
                            .optional => |opt| opt.child,
                            else => field.type,
                        };
                        const info = @typeInfo(field_type);
                        // is array
                        if (info == .pointer and info.pointer.size == .slice and info.pointer.child != u8) {
                            var argIt = std.mem.splitScalar(u8, named.value, ',');
                            while (argIt.next()) |a| {
                                const value = try parseAs(info.pointer.child, a, allocator, fieldConverter(
                                    Args,
                                    field.name,
                                    info.pointer.child,
                                ));
                                try @field(arrayFields, field.name).append(allocator, value);
                            }
                        } else {
                            if (fieldStates.isSet(i_fields)) {
                                return ArgParseError.DuplicateArgument;
                            }
                            const value = try parseAs(field_type, named.value, allocator, fieldConverter(
                                Args,
                                field.name,
                                field_type,
                            ));
                            @field(args, field.name) = value;
                            fieldStates.set(i_fields);
                        }
                        handled = true;
                    }
                }
            },
            // positional argument
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
            .short => |short| {
                inline for (fields, 0..) |field, i_fields| {
                    if (getShort(Args, field.name)) |s| {
                        if (s == short) {
                            if (@typeInfo(field.type) == .bool) {
                                if (fieldStates.isSet(i_fields)) {
                                    return ArgParseError.DuplicateArgument;
                                }
                                @field(args, field.name) = true;
                                fieldStates.set(i_fields);
                            } else {
                                const field_type = switch (@typeInfo(field.type)) {
                                    .optional => |opt| opt.child,
                                    else => field.type,
                                };
                                const info = @typeInfo(field_type);
                                // is array
                                if (info == .pointer and info.pointer.size == .slice and info.pointer.child != u8) {
                                    // check if next arg
                                    if (cursor.peek()) |next| {
                                        if (try next != .value) {
                                            return ArgParseError.NamedArgumentMissingValue;
                                        }
                                    } else {
                                        return ArgParseError.NamedArgumentMissingValue;
                                    }
                                    while (cursor.next()) |argument| {
                                        const next_arg = try argument;
                                        try @field(arrayFields, field.name).append(allocator, try parseAs(info.pointer.child, next_arg.value, allocator, fieldConverter(
                                            Args,
                                            field.name,
                                            info.pointer.child,
                                        )));
                                        if (cursor.peek()) |next| {
                                            if (try next != .value) {
                                                break;
                                            }
                                        }
                                    }
                                } else {
                                    if (fieldStates.isSet(i_fields)) {
                                        return ArgParseError.DuplicateArgument;
                                    }
                                    const next_arg = cursor.next() orelse {
                                        return ArgParseError.NamedArgumentMissingValue;
                                    };
                                    const parsed = try next_arg;
                                    if (parsed == .value) {
                                        @field(args, field.name) = try parseAs(field_type, parsed.value, allocator, fieldConverter(
                                            Args,
                                            field.name,
                                            field_type,
                                        ));
                                        fieldStates.set(i_fields);
                                    } else {
                                        return ArgParseError.NamedArgumentMissingValue;
                                    }
                                }
                            }
                            handled = true;
                        }
                    }
                }
            },
            // flag or named value
            .long => |name| {
                inline for (fields, 0..) |field, i_fields| {
                    if (std.mem.eql(u8, field.name, name)) {
                        if (@typeInfo(field.type) == .bool) {
                            if (fieldStates.isSet(i_fields)) {
                                return ArgParseError.DuplicateArgument;
                            }
                            @field(args, field.name) = true;
                            fieldStates.set(i_fields);
                        } else {
                            const field_type = switch (@typeInfo(field.type)) {
                                .optional => |opt| opt.child,
                                else => field.type,
                            };
                            const info = @typeInfo(field_type);
                            // is array
                            if (info == .pointer and info.pointer.size == .slice and info.pointer.child != u8) {
                                // check if next arg
                                if (cursor.peek()) |next| {
                                    if (try next != .value) {
                                        return ArgParseError.NamedArgumentMissingValue;
                                    }
                                } else {
                                    return ArgParseError.NamedArgumentMissingValue;
                                }
                                while (cursor.next()) |argument| {
                                    const next_arg = try argument;
                                    try @field(arrayFields, field.name).append(allocator, try parseAs(info.pointer.child, next_arg.value, allocator, fieldConverter(
                                        Args,
                                        field.name,
                                        info.pointer.child,
                                    )));
                                    if (cursor.peek()) |next| {
                                        if (try next != .value) {
                                            break;
                                        }
                                    }
                                }
                            } else {
                                if (fieldStates.isSet(i_fields)) {
                                    return ArgParseError.DuplicateArgument;
                                }
                                const next_arg = cursor.next() orelse {
                                    return ArgParseError.NamedArgumentMissingValue;
                                };
                                const parsed = try next_arg;
                                if (parsed == .value) {
                                    @field(args, field.name) = try parseAs(field_type, parsed.value, allocator, fieldConverter(
                                        Args,
                                        field.name,
                                        field_type,
                                    ));
                                    fieldStates.set(i_fields);
                                } else {
                                    return ArgParseError.NamedArgumentMissingValue;
                                }
                            }
                        }
                        handled = true;
                    }
                }
            },
            .endOfOptions => {
                unreachable;
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
        else => {
            return ArgParseError.NeedsCustomConversion;
        },
    }
}

const ArgToken = union(enum) {
    longWithValue: struct { key: []const u8, value: []const u8 },
    long: []const u8,
    value: []const u8,
    shortWithTail: struct { key: u8, tail: []const u8 },
    short: u8,
    endOfOptions,
};

fn parseArg(arg: []const u8) !ArgToken {
    if (std.mem.startsWith(u8, arg, "--")) {
        if (arg.len == 2) {
            return .endOfOptions;
        }
        const is = std.mem.findPos(u8, arg, 2, "=");
        if (is) |pos| {
            if (pos == 2) {
                return ArgParseError.InvalidLong;
            }
            return .{ .longWithValue = .{ .key = arg[2..pos], .value = arg[pos + 1 ..] } };
        }

        return .{ .long = arg[2..] };
    }
    if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
        if (arg.len == 2) {
            return .{ .short = arg[1] };
        } else if (arg.len > 2) {
            return .{ .shortWithTail = .{ .key = arg[1], .tail = arg[2..] } };
        }
    }
    return .{ .value = arg };
}

test "parse different raw args" {
    const pos_arg = try parseArg("positional");
    try std.testing.expect(pos_arg == .value);
    try std.testing.expectEqualStrings(pos_arg.value, "positional");
    const flag_arg = try parseArg("--flag");
    try std.testing.expect(flag_arg == .long);
    try std.testing.expectEqualStrings(flag_arg.long, "flag");
    const named_arg = try parseArg("--key=value");
    try std.testing.expect(named_arg == .longWithValue);
    try std.testing.expectEqualStrings(named_arg.longWithValue.key, "key");
    try std.testing.expectEqualStrings(named_arg.longWithValue.value, "value");
}

test "parse positional args basic" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
        _text: []const u8,
    };

    const args = [_][*:0]const u8{ "42", "hello" };
    var cursor = ArgCursor.init(args[0..]);
    const result = try parseArgv(S, &cursor, allocator);

    try std.testing.expectEqual(@as(i32, 42), result._int);
    try std.testing.expectEqualStrings("hello", result._text);
}

test "named argument parsing" {
    const allocator = std.testing.allocator;

    const S = struct {
        key: []const u8,
    };

    const args = [_][*:0]const u8{"--key=zig"};
    var cursor = ArgCursor.init(args[0..]);
    const result = try parseArgv(S, &cursor, allocator);

    try std.testing.expectEqualStrings("zig", result.key);
}

test "boolean flag parsing" {
    const allocator = std.testing.allocator;

    const S = struct {
        flag: bool,
    };

    const args = [_][*:0]const u8{"--flag"};
    var cursor = ArgCursor.init(args[0..]);
    const result = try parseArgv(S, &cursor, allocator);

    try std.testing.expect(result.flag);
}

test "unknown argument returns error" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
    };

    const args = [_][*:0]const u8{"--something"};
    var cursor = ArgCursor.init(args[0..]);
    const result = parseArgv(S, &cursor, allocator);

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
    var cursor = ArgCursor.init(args[0..]);
    const result = parseArgv(S, &cursor, allocator);

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
    var cursor = ArgCursor.init(args[0..]);
    const result = try parseArgv(S, &cursor, allocator);

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
    var cursor = ArgCursor.init(args[0..]);
    try std.testing.expectError(ArgParseError.DuplicateArgument, parseArgv(S, &cursor, allocator));
}

test "positional order stability" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
        _text: []const u8,
    };

    const args = [_][*:0]const u8{ "99", "world" };
    var cursor = ArgCursor.init(args[0..]);
    const result = try parseArgv(S, &cursor, allocator);

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
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{"--int=1,2,3"};
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{ "--int=1,2", "--int", "3" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{ "--int", "1", "--int=2,3" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][*:0]const u8{ "--int", "1", "--int=2", "--int", "3" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
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
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = 1, .float = null };
        const args = [_][*:0]const u8{ "--int", "1" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = null, .float = 2.3 };
        const args = [_][*:0]const u8{"--float=2.3"};
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = null, .float = null };
        const args = [_][*:0]const u8{};
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);

        try std.testing.expectEqual(expected, result);
    }
}

test "conversion provided" {
    const allocator = std.testing.allocator;

    const T = struct { int: u32 };
    const S = struct {
        custom: T,
        fn to_custom(arg: []const u8, _: std.mem.Allocator) !T {
            const val = try std.fmt.parseInt(u32, arg, 10);
            return T{ .int = 69 + val };
        }
    };

    {
        const expected = S{ .custom = T{ .int = 70 } };
        const args = [_][*:0]const u8{ "--custom", "1" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);

        try std.testing.expectEqual(expected, result);
    }
}

test "conversion provided for array" {
    const allocator = std.testing.allocator;

    const T = struct { int: u32 };
    const S = struct {
        customArray: []T,
        fn to_customArray(arg: []const u8, _: std.mem.Allocator) !T {
            const val = try std.fmt.parseInt(u32, arg, 10);
            return T{ .int = 69 + val };
        }
    };

    const expectedArray = [_]T{ T{ .int = 70 }, T{ .int = 71 }, T{ .int = 72 } };
    {
        const args = [_][*:0]const u8{ "--customArray", "1", "2", "3" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.customArray);

        try std.testing.expectEqualSlices(T, expectedArray[0..], result.customArray);
    }

    {
        const args = [_][*:0]const u8{"--customArray=1,2,3"};
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.customArray);

        try std.testing.expectEqualSlices(T, expectedArray[0..], result.customArray);
    }

    {
        const args = [_][*:0]const u8{ "--customArray=1,2", "--customArray", "3" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.customArray);

        try std.testing.expectEqualSlices(T, expectedArray[0..], result.customArray);
    }

    {
        const args = [_][*:0]const u8{ "--customArray", "1", "--customArray=2,3" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);
        defer allocator.free(result.customArray);

        try std.testing.expectEqualSlices(T, expectedArray[0..], result.customArray);
    }
}

test "short provided" {
    const allocator = std.testing.allocator;

    const S = struct {
        int: u32,
        const short_int: ?u8 = 'n';
    };

    {
        const expected = S{ .int = 1 };
        const args = [_][*:0]const u8{ "-n", "1" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);

        try std.testing.expectEqual(expected, result);
    }
}

test "short disabled" {
    const allocator = std.testing.allocator;

    const S = struct {
        int: u32,
        integer: u32,
        const short_int: ?u8 = null;
    };

    {
        const expected = S{ .int = 2, .integer = 1 };
        const args = [_][*:0]const u8{ "-i", "1", "--int", "2" };
        var cursor = ArgCursor.init(args[0..]);
        const result = try parseArgv(S, &cursor, allocator);

        try std.testing.expectEqual(expected, result);
    }
}
