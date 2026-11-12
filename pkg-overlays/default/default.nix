# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.zig-purifier`, made with lib.makeScope. The scope holds
# the packages of pkgs/ (the command `.cli` and the default toolchain
# `.toolchain`) and the builder `.buildZigProject`
# (pkgs/build-zig-project/default.nix), a package for callPackage in that scope.
# The builder checks and fetches the lock with the purifier library, which
# this flake lists in `projects`, so its composed library holds it as
# `purifier`. A consumer that lists this flake in `projects` holds this
# overlay as `zig-purifier/default`, which its package sets apply by
# default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "zig-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      zig-purifier = added.zig-purifier.overrideScope (
        scope: _: {
          buildZigProject = scope.callPackage ../../pkgs/build-zig-project/default.nix {
            inherit (closure-lib) purifier;
          };
        }
      );
    };
}
