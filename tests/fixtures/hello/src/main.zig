const std = @import("std");
const clap = @import("clap");
const greeting = @import("greeting");

const params = clap.parseParamsComptime(
    \\-h, --help         Print this help.
    \\-n, --name <str>   The name to greet.
    \\
);

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var res = try clap.parse(clap.Help, &params, clap.parsers.default, .{
        .allocator = gpa.allocator(),
    });
    defer res.deinit();

    var buffer: [256]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buffer);
    try greeting.greet(&stdout.interface, res.args.name orelse "world");
    try stdout.interface.flush();
}

test "the parameters parse" {
    try std.testing.expectEqual(@as(usize, 2), params.len);
}
