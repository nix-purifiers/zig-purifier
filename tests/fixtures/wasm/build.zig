const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .wasm32, .os_tag = .freestanding },
    });
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addExecutable(.{
        .name = "proof",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    module.entry = .disabled;
    module.rdynamic = true;
    module.import_symbols = true;
    b.installArtifact(module);
}
