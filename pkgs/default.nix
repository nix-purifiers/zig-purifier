# SPDX-License-Identifier: MIT
{ callPackage, ... }:
let
  cli = callPackage ./cli { };
in
{
  # The zig-purifier command.
  inherit cli;
  # The default zig with `zig` running through zig-purifier, and the
  # zig-purifier command beside it.
  toolchain = callPackage ./toolchain { inherit cli; };
}
