# zap: Zig command line argument parser

zap is a command line argument parser using compile time reflection.
Arguments can be grouped into a struct:

```zig
const CliArgs = struct{
    _file: []const u8,              // positional argument starts with _
    force: bool,                    // flag argument (--force)
    mode: ?u16,                     // named optional argument (--mode 1, --mode=1, -m 1, m1)
    patterns: []const[]const u8     // named list argument (--patterns file_1 file_2 -p file_3 --patterns=file_4,file_5,file_6)
}
```

and then be parsed:

```zig
const args: CliArgs = try zap.parse(CliArgs, init.args, alloc);
```

```shell

> my_app --force -m10 --patterns patternA patternB -- file.txt
