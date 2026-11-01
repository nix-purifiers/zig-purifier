const std = @import("std");

/// Writes a greeting for `name` to `writer`.
pub fn greet(writer: *std.Io.Writer, name: []const u8) !void {
    try writer.print("Hello, {s}!\n", .{name});
}

test "greet" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try greet(&writer, "Nix");
    try std.testing.expectEqualStrings("Hello, Nix!\n", writer.buffered());
}
