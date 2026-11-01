// The hello fixture: a program that parses its arguments with zig-clap and
// greets with the greeting package. -Dgit-clap=true takes zig-clap from
// the lazy git dependency instead of the archive.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const git_clap = b.option(bool, "git-clap", "Take zig-clap from its git dependency") orelse false;

    const clap = if (git_clap)
        (b.lazyDependency("clap_git", .{ .target = target, .optimize = optimize }) orelse return)
    else
        b.dependency("clap", .{ .target = target, .optimize = optimize });
    const greeting = b.dependency("greeting", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "greeting", .module = greeting.module("greeting") },
            },
        }),
    });
    b.installArtifact(exe);
    b.installArtifact(greeting.artifact("greeting"));

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run hello");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run the hello tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
