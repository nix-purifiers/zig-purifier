// A package that the hello fixture takes as a path dependency. It exports
// the module "greeting" and installs it as a static library.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("greeting", .{
        .root_source_file = b.path("src/greeting.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "greeting",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{ .root_module = mod });
    const test_step = b.step("test", "Run the greeting tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
