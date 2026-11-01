# SPDX-License-Identifier: MIT
#
# The `zig-purifier` library namespace: readLock (nix/lib/read-lock.nix),
# which reads a lockfile into the lock in memory of the purifier contract,
# and the builder buildZigProject (nix/lib/build-zig-project.nix), which
# takes the package set as `pkgs`. Both fetch and check through the
# purifier library, which this flake lists in `projects`, so the composed
# library holds it as `purifier`.
{ ... }:
{

  overlay = final: prev: {
    zig-purifier = (prev.zig-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix;
      buildZigProject = import ../../nix/lib/build-zig-project.nix {
        lib = final;
        inherit (final) purifier;
      };
    };
  };

}
