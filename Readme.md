# zap: Zig command line argument parser

zap is a command line argument parser using compile time reflection.
Arguments can be grouped into a struct:

```zig
const CliArgs = struct{
    _file: []const u8,  // positional argument starts with _
    force: bool,        // flag argument (--force)
    mode: ?u16,         // named optional argument (--mode 1, --mode=1)
}
```

and then be parsed:

```zig
const args: CliArgs = try zap.parse(CliArgs, init.args, alloc);
```
