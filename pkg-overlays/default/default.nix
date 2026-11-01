# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.zig-purifier`: the command (`.cli`) and the default toolchain
# (`.toolchain`). The builder is in the library, as
# `lib.zig-purifier.buildZigProject`. A consumer that lists this flake in
# `projects` holds this overlay as `zig-purifier/default`, which its
# package sets apply by default.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "zig-purifier";
}
