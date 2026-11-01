# SPDX-License-Identifier: MIT
#
# The zig package cache of a lock: each locked download unpacked into the
# package directory zig would make for it, and a directory linking each
# one under its zig hash, which a build puts where zig looks for packages.
#
# `zig-purifier materialize` unpacks a download the way zig does, and
# checks that `zig fetch` gives the result the hash the lock recorded, so a
# download that differs from what build.zig.zon names fails here.
#
# Needs no nixpkgs: the zig-purifier command is the builder of both
# derivations, so the command and a sandboxed build make the same
# derivations and share their store paths.
{
  # The download entries of the lock, each with its `zigHash`.
  entries,
  # The fetch of one entry: the purifier library's fetchEntry.
  fetch,
  # The zig-purifier command and the zig executable, as store paths with
  # their string context.
  cli,
  zig,
  system,
}:
let
  # A store path name for a zig hash: every character a store path name
  # does not allow becomes "_".
  storeName =
    hash:
    builtins.concatStringsSep "" (
      map (part: if builtins.isList part then "_" else part) (builtins.split "[^A-Za-z0-9+._?=-]" hash)
    );

  materialize =
    entry:
    derivation {
      name = "zig-package-${storeName entry.zigHash}";
      inherit system;
      builder = cli;
      args = [
        "materialize"
        zig
        (fetch entry)
        entry.zigHash
      ];
      preferLocalBuild = true;
    };

  packages = builtins.listToAttrs (
    map (entry: {
      name = entry.zigHash;
      value = materialize entry;
    }) entries
  );

  farm = derivation {
    name = "zig-purifier-packages";
    inherit system;
    builder = cli;
    args = [ "link-farm" ];
    manifest = builtins.concatStringsSep "" (
      builtins.attrValues (builtins.mapAttrs (hash: package: "${hash}\t${package}\n") packages)
    );
    passAsFile = [ "manifest" ];
    preferLocalBuild = true;
    allowSubstitutes = false;
  };
in
{
  inherit packages farm;
}
