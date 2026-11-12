# SPDX-License-Identifier: MIT
#
# The `zig-purifier` library namespace: readLock (lib-overlays/default/read-lock.nix),
# which reads a lockfile into the lock shape of the purifier contract. The
# builder is the package `buildZigProject`, which the default package
# overlay adds.
{ ... }:
{

  overlay = final: prev: {
    zig-purifier = (prev.zig-purifier or { }) // {
      readLock = import ./read-lock.nix;
    };
  };

}
