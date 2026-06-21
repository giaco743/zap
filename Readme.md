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

When calling the program with additional arguments, the struct gets populated automagically with the help of compile time reflection.

```shell
 my_app --force -m10 --patterns patternA patternB -- file.txt
```

## Providing a shorthand notation

By default the first letter is used for an options shorthand notation. This behaviour can be overwritten, by defining a `u8` constant in the struct with the field name `short_<MY_FIELD>` . When providing `null` as the shorthand the option explicitely doesn't have a shorthand notation.

```zig
const CliArgs = struct{
    force: bool,                    // implicit shorthand notation '-f'
    mode: u16,                      // explicitely provided shorthand '-M'
    file: []const u8,               // shorthand notation disabled

    pub short_mode = 'M';
    pub short_file = null;
}
```

## Displaying the '--help' text

`zap` automagically generates a help text for you according to the struct layout. As with the shorthand notation addditional information is provided by the means of constant struct members.

|                     |     |
|---------------------|-----|
| `descripion` |  Provide a short description what the program does |
| `<OPT>_description` |  Provide a short description what the option does  |

This struct:

```zig
const Args = struct {
    _file: []const u8,
    string: []const u8,
    int: u32,
    float: f16,

    pub const description = "This program does stuff";
    pub const float_description = "An ordinary float";
    pub const short_float = null;
};
```

produces following ouput

```shell
user@PC:~/projects/zap$ zig build run -- --help
Usage: args [OPTION]... FILE
This program does stuff
FILE

  -s,  string              
  -i,  int                 
       float                An ordinary float
```
