# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.zig-purifier` (`.cli`, `.toolchain`), and the builder
# `pkgs.buildZigProject` (nix/lib/build-zig-project.nix) beside them, where
# nixpkgs keeps its own builders, so a package written for callPackage
# takes it by name. A consumer that lists this flake in `projects` holds it
# as `zig-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "zig-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildZigProject = final.callPackage ../../nix/lib/build-zig-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
