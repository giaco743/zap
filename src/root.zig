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
    FlagWithValue,
    Overflow,
    EndOfOptions,
    InvalidCharacter,
    AmbiguousShort,
    FlagAsPositional,
};

pub fn parse(comptime Args: type, args: std.process.Args, allocator: std.mem.Allocator) !Args {
    const argv = try argvToSlices(allocator, args.vector);
    defer allocator.free(argv);
    return try parseArgv(Args, argv[1..], allocator);
}

fn parseArgv(comptime Args: type, argv: []const []const u8, allocator: std.mem.Allocator) !Args {
    var args: Args = undefined;

    const fields = @typeInfo(Args).@"struct".fields;
    const ArrayArgs = arrayArgs(fields);
    var arrayArguments = initArrayArgs(ArrayArgs);
    defer deinitArrayArgs(&arrayArguments, allocator);
    var fieldStates = std.StaticBitSet(fields.len).initEmpty();

    var endOfOptions = false;
    var i: usize = 0;
    next: while (i < argv.len) : (i += 1) {
        const arg = try parseArg(argv[i]);

        switch (arg) {
            .shortWithTail => |short| {
                if (endOfOptions) return ArgParseError.EndOfOptions;
                inline for (fields, 0..) |field, i_fields| {
                    if (comptime getShort(Args, field.name)) |s| {
                        if (s == short.key) {
                            if (fieldStates.isSet(i_fields)) {
                                return ArgParseError.DuplicateArgument;
                            }

                            // if first short is a flag the rest has to be flags as well
                            if (comptime field.type == bool) {
                                @field(args, fields[i_fields].name) = true;
                                fieldStates.set(i_fields);

                                inline for (fields, 0..) |f, j| {
                                    if (comptime getShort(Args, f.name)) |ss| {
                                        if (std.mem.containsAtLeastScalar2(u8, short.tail, 1, ss)) {
                                            if (comptime isFlag(f.type)) {
                                                @field(args, fields[j].name) = true;
                                                fieldStates.set(j);
                                            } else {
                                                return ArgParseError.InvalidShort;
                                            }
                                        }
                                    }
                                }
                            } // otherwise it has to be a value
                            else if (comptime isSlice(field.type)) {
                                var it = std.mem.splitScalar(u8, short.tail, ',');
                                while (it.next()) |value| {
                                    try @field(arrayArguments, field.name).append(allocator, try parseAs(
                                        @typeInfo(field.type).pointer.child,
                                        value,
                                        allocator,
                                        fieldConverter(
                                            Args,
                                            field.name,
                                            @typeInfo(field.type).pointer.child,
                                        ),
                                    ));
                                }
                            } else {
                                @field(args, field.name) = try parseAs(field.type, short.tail, allocator, fieldConverter(
                                    Args,
                                    field.name,
                                    field.type,
                                ));
                                fieldStates.set(i_fields);
                            }
                            continue :next;
                        }
                    }
                }
            },
            // named value with value
            .longWithValue => |named| {
                if (endOfOptions) return ArgParseError.EndOfOptions;
                inline for (fields, 0..) |field, i_fields| {
                    if (std.mem.eql(u8, field.name, named.key)) {
                        if (fieldStates.isSet(i_fields)) {
                            return ArgParseError.DuplicateArgument;
                        }

                        // if first short is a flag the rest has to be flags as well
                        if (comptime field.type == bool) {
                            return ArgParseError.FlagWithValue;
                        } // otherwise it has to be a value
                        else if (comptime isSlice(field.type)) {
                            var it = std.mem.splitScalar(u8, named.value, ',');
                            while (it.next()) |value| {
                                try @field(arrayArguments, field.name).append(allocator, try parseAs(
                                    @typeInfo(field.type).pointer.child,
                                    value,
                                    allocator,
                                    fieldConverter(
                                        Args,
                                        field.name,
                                        @typeInfo(field.type).pointer.child,
                                    ),
                                ));
                            }
                        } else {
                            @field(args, field.name) = try parseAs(field.type, named.value, allocator, fieldConverter(
                                Args,
                                field.name,
                                field.type,
                            ));
                            fieldStates.set(i_fields);
                        }
                        continue :next;
                    }
                }
            },
            // positional argument
            .value => |value| {
                inline for (fields, 0..) |field, i_fields| {
                    if (comptime isPosArg(field.name)) {
                        if (!fieldStates.isSet(i_fields)) {
                            if (comptime isFlag(field.type)) {
                                return ArgParseError.FlagAsPositional;
                            }
                            if (comptime isSlice(field.type)) {
                                try @field(arrayArguments, field.name).append(allocator, try parseAs(
                                    @typeInfo(field.type).pointer.child,
                                    value,
                                    allocator,
                                    fieldConverter(
                                        Args,
                                        field.name,
                                        @typeInfo(field.type).pointer.child,
                                    ),
                                ));

                                while (i + 1 < argv.len and try parseArg(argv[i + 1]) == .value) {
                                    i += 1;
                                    try @field(arrayArguments, field.name).append(allocator, try parseAs(
                                        @typeInfo(field.type).pointer.child,
                                        argv[i], // If it is a .value, we can just take the raw string
                                        allocator,
                                        fieldConverter(
                                            Args,
                                            field.name,
                                            @typeInfo(field.type).pointer.child,
                                        ),
                                    ));
                                }
                            } else {
                                @field(args, field.name) = try parseAs(field.type, value, allocator, fieldConverter(
                                    Args,
                                    field.name,
                                    field.type,
                                ));
                                fieldStates.set(i_fields);
                            }
                            continue :next;
                        }
                    }
                }
            },
            // short flag or named value
            .short => |short| {
                if (endOfOptions) return ArgParseError.EndOfOptions;
                inline for (fields, 0..) |field, i_fields| {
                    if (comptime getShort(Args, field.name)) |s| {
                        if (s == short) {
                            if (fieldStates.isSet(i_fields)) {
                                return ArgParseError.DuplicateArgument;
                            }

                            if (comptime isFlag(field.type)) {
                                @field(args, field.name) = true;
                                fieldStates.set(i_fields);
                            } // otherwise it has to be a value
                            else if (comptime isSlice(field.type)) {
                                while (i + 1 < argv.len and try parseArg(argv[i + 1]) == .value) {
                                    i = i + 1;
                                    try @field(arrayArguments, field.name).append(allocator, try parseAs(
                                        @typeInfo(field.type).pointer.child,
                                        argv[i], // If it is a .value, we can just take the raw string
                                        allocator,
                                        fieldConverter(
                                            Args,
                                            field.name,
                                            @typeInfo(field.type).pointer.child,
                                        ),
                                    ));
                                }
                            } else {
                                if (i + 1 >= argv.len or try parseArg(argv[i + 1]) != .value) return ArgParseError.NamedArgumentMissingValue;
                                i += 1;
                                @field(args, field.name) = try parseAs(field.type, argv[i], allocator, fieldConverter(
                                    Args,
                                    field.name,
                                    field.type,
                                ));
                                fieldStates.set(i_fields);
                            }
                            continue :next;
                        }
                    }
                }
            },
            // flag or named value
            .long => |name| {
                if (endOfOptions) return ArgParseError.EndOfOptions;
                inline for (fields, 0..) |field, i_fields| {
                    if (std.mem.eql(u8, field.name, name)) {
                        if (fieldStates.isSet(i_fields)) {
                            return ArgParseError.DuplicateArgument;
                        }

                        if (comptime isFlag(field.type)) {
                            @field(args, field.name) = true;
                            fieldStates.set(i_fields);
                        } // otherwise it has to be a value
                        else if (comptime isSlice(field.type)) {
                            while (i + 1 < argv.len and try parseArg(argv[i + 1]) == .value) {
                                i = i + 1;
                                try @field(arrayArguments, field.name).append(allocator, try parseAs(
                                    @typeInfo(field.type).pointer.child,
                                    argv[i], // If it is a .value, we can just take the raw string
                                    allocator,
                                    fieldConverter(
                                        Args,
                                        field.name,
                                        @typeInfo(field.type).pointer.child,
                                    ),
                                ));
                            }
                        } else {
                            if (i + 1 >= argv.len) return ArgParseError.NamedArgumentMissingValue;
                            i += 1;
                            @field(args, field.name) = try parseAs(field.type, argv[i], allocator, fieldConverter(
                                Args,
                                field.name,
                                field.type,
                            ));
                            fieldStates.set(i_fields);
                        }
                        continue :next;
                    }
                }
            },
            .endOfOptions => {
                if (endOfOptions) return ArgParseError.EndOfOptions;
                endOfOptions = true;
                continue :next;
            },
        }
        return ArgParseError.UnknownArgument;
    }

    // Check if all mandatory fields are set and handle unset flags and optionals
    // Assign array arguments
    inline for (fields, 0..) |field, i_fields| {
        if (!fieldStates.isSet(i_fields)) {
            if (comptime isFlag(field.type)) {
                @field(args, field.name) = false;
            } else if (comptime isOpt(field.type)) {
                @field(args, field.name) = null;
            } else if (comptime isSlice(field.type)) {
                const owned = try @field(arrayArguments, field.name).toOwnedSlice(allocator);
                @field(args, field.name) = owned;
            } else {
                return ArgParseError.ArgumentMissing;
            }
        }
    }
    return args;
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

fn parseAs(comptime Arg: type, arg: []const u8, allocator: std.mem.Allocator, conversion: ?fn ([]const u8, std.mem.Allocator) ArgParseError!Arg) !Arg {
    // std.debug.print("Parse {s} as  {any}\n", .{ arg, Arg });
    const argType = stripOpt(Arg);
    if (conversion) |convert| {
        return try convert(arg, allocator);
    }
    if (argType == []const u8) {
        return arg;
    }
    switch (@typeInfo(argType)) {
        .int => {
            return try std.fmt.parseInt(argType, arg, 10);
        },
        .float => {
            return try std.fmt.parseFloat(argType, arg);
        },
        else => {
            return ArgParseError.NeedsCustomConversion;
        },
    }
}

fn arrayArgs(comptime fields: anytype) type {
    comptime var size = 0;
    inline for (fields) |field| {
        if (isSlice(field.type)) {
            size += 1;
        }
    }
    var field_names: [size][]const u8 = undefined;
    var field_types: [size]type = undefined;
    var n_fields = 0;
    inline for (fields) |field| {
        if (isSlice(field.type)) {
            field_names[n_fields] = field.name;
            field_types[n_fields] = std.ArrayList(@typeInfo(field.type).pointer.child);
            n_fields += 1;
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

fn setArrayArg(
    comptime Item: type,
    array: *std.ArrayList(Item),
    conversion: ?fn ([]const u8, std.mem.Allocator) ArgParseError!Item,
    values: []const []const u8,
    allocator: std.mem.Allocator,
) !void { // number of additionally handled fields, so I can increment always at the end of the loop with the syntax
    for (values) |value| {
        try array.append(allocator, try parseAs(
            Item,
            value,
            allocator,
            conversion,
        ));
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

fn stripOpt(comptime Type: type) type {
    switch (@typeInfo(Type)) {
        .optional => |opt| return opt.child,
        else => return Type,
    }
}

fn isOpt(comptime Type: type) bool {
    const info = @typeInfo(Type);
    return info == .optional;
}

fn isSlice(comptime Type: type) bool {
    const info = @typeInfo(Type);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child != u8;
}

fn isFlag(comptime Type: type) bool {
    const info = @typeInfo(Type);
    return info == .bool;
}

fn isPosArg(comptime FieldName: []const u8) bool {
    return std.mem.startsWith(u8, FieldName, "_");
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

fn argvToSlices(
    allocator: std.mem.Allocator,
    argv: []const [*:0]const u8,
) ![][]const u8 {
    const result = try allocator.alloc([]const u8, argv.len);

    for (argv, 0..) |arg, i| {
        result[i] = std.mem.span(arg);
    }

    return result;
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
    const short_val = try parseArg("-s10");
    try std.testing.expect(short_val == .shortWithTail);
    try std.testing.expectEqual(short_val.shortWithTail.key, 's');
    try std.testing.expectEqualStrings(short_val.shortWithTail.tail, "10");
    const short = try parseArg("-s");
    try std.testing.expect(short == .short);
    try std.testing.expectEqual(short.short, 's');
    const eoo = try parseArg("--");
    try std.testing.expect(eoo == .endOfOptions);
}

test "get short" {
    const S = struct { short: bool };
    try std.testing.expectEqual(getShort(S, "short"), 's');
}

test "get short null" {
    const S = struct {
        short: bool,
        const short_short = null;
    };
    try std.testing.expectEqual(getShort(S, "short"), null);
}

test "get short rename" {
    const S = struct {
        short: bool,
        const short_short = 'S';
    };
    try std.testing.expectEqual(getShort(S, "short"), 'S');
}

test "parse positional args basic" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
        _text: []const u8,
        _elements: []const f32,
    };

    const args = [_][]const u8{ "42", "hello", "1.1", "2.2", "3.3", "4.4" };
    const result = try parseArgv(S, args[0..], allocator);
    defer allocator.free(result._elements);

    try std.testing.expectEqual(@as(i32, 42), result._int);
    try std.testing.expectEqualStrings("hello", result._text);
    try std.testing.expectEqualSlices(f32, &[4]f32{ 1.1, 2.2, 3.3, 4.4 }, result._elements);
}

test "parse positional args basic array begin" {
    const allocator = std.testing.allocator;

    const S = struct {
        _elements: []const f32,
        int: i32,
        _text: []const u8,
    };

    const args = [_][]const u8{ "1.1", "2.2", "3.3", "4.4", "-i", "42", "hello" };
    const result = try parseArgv(S, args[0..], allocator);
    defer allocator.free(result._elements);

    try std.testing.expectEqual(@as(i32, 42), result.int);
    try std.testing.expectEqualStrings("hello", result._text);
    try std.testing.expectEqualSlices(f32, &[4]f32{ 1.1, 2.2, 3.3, 4.4 }, result._elements);
}

test "named argument parsing" {
    const allocator = std.testing.allocator;

    const S = struct {
        key: []const u8,
    };

    const args = [_][]const u8{"--key=zig"};
    const result = try parseArgv(S, args[0..], allocator);

    try std.testing.expectEqualStrings("zig", result.key);
}

test "boolean flag parsing" {
    const allocator = std.testing.allocator;

    const S = struct {
        flag: bool,
    };

    const args = [_][]const u8{"--flag"};
    const result = try parseArgv(S, args[0..], allocator);

    try std.testing.expect(result.flag);
}

test "unknown argument returns error" {
    const allocator = std.testing.allocator;

    const S = struct {
        _int: i32,
    };

    const args = [_][]const u8{"--something"};
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

    const args = [_][]const u8{"123"};
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

    const args = [_][]const u8{
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

    const args = [_][]const u8{
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

    const args = [_][]const u8{ "99", "world" };
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
        const args = [_][]const u8{ "--int", "1", "2", "3" };
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][]const u8{ "--int", "1", "--int", "2", "3" };
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][]const u8{"--int=1,2,3"};
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][]const u8{ "--int=1,2", "--int", "3" };
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][]const u8{ "--int", "1", "--int=2,3" };
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.int);

        try std.testing.expectEqualSlices(i32, expected[0..], result.int);
    }
    {
        const args = [_][]const u8{ "--int", "1", "--int=2", "--int", "3" };
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
        const args = [_][]const u8{ "--int", "1", "--float=2.3" };
        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = 1, .float = null };
        const args = [_][]const u8{ "--int", "1" };
        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = null, .float = 2.3 };
        const args = [_][]const u8{"--float=2.3"};
        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }

    {
        const expected = S{ .int = null, .float = null };
        const args = [_][]const u8{};
        const result = try parseArgv(S, args[0..], allocator);

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
        const args = [_][]const u8{ "--custom", "1" };
        const result = try parseArgv(S, args[0..], allocator);

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
        const args = [_][]const u8{ "--customArray", "1", "2", "3" };
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.customArray);

        try std.testing.expectEqualSlices(T, expectedArray[0..], result.customArray);
    }

    {
        const args = [_][]const u8{"--customArray=1,2,3"};
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.customArray);

        try std.testing.expectEqualSlices(T, expectedArray[0..], result.customArray);
    }

    {
        const args = [_][]const u8{ "--customArray=1,2", "--customArray", "3" };
        const result = try parseArgv(S, args[0..], allocator);
        defer allocator.free(result.customArray);

        try std.testing.expectEqualSlices(T, expectedArray[0..], result.customArray);
    }

    {
        const args = [_][]const u8{ "--customArray", "1", "--customArray=2,3" };
        const result = try parseArgv(S, args[0..], allocator);
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
        const args = [_][]const u8{ "-n", "1" };
        const result = try parseArgv(S, args[0..], allocator);

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
        const args = [_][]const u8{ "-i", "1", "--int", "2" };
        const result = try parseArgv(S, args[0..], allocator);

        try std.testing.expectEqual(expected, result);
    }
}
