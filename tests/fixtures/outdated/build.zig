// SPDX-License-Identifier: MIT
//
// A package whose one dependency is pinned behind its ref, for
// conformance-update. The build never asks for the dependency.
const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});
    _ = b.step("test", "Nothing to test");
}
