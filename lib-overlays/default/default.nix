# SPDX-License-Identifier: MIT
#
# The `zig-purifier` library namespace. It holds nothing: the builder needs
# a package set, so it is the package `buildZigProject` that the default
# package overlay adds.
{ ... }:
{

  overlay = final: prev: {
    zig-purifier = prev.zig-purifier or { };
  };

}
