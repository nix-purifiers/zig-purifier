// A package for zig 0.17, which keeps fetched packages in the project's
// zig-pkg directory rather than the global cache. It installs the README
// of its dependency, so its build compiles no dependency code.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const clap = b.dependency("clap", .{});
    b.getInstallStep().dependOn(&b.addInstallFile(clap.path("README.md"), "share/clap-README.md").step);
}
