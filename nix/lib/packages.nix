# SPDX-License-Identifier: MIT
#
# The zig package cache of a lockfile: each locked download unpacked by
# `zig fetch` into the package directory zig would make for it, and a
# directory linking each one under its zig hash, which a build puts at
# `$ZIG_GLOBAL_CACHE_DIR/p`.
#
# `zig fetch` of the local copy is how zig itself turns a download into a
# package: it unpacks the archive, keeps the files under the package's
# `paths`, and computes the hash. The builder checks that hash against the
# one the lock recorded, so a download that differs from what build.zig.zon
# names fails here.
#
# Needs no nixpkgs: the zig-purifier command is the builder of both
# derivations, so the zig wrapper and a sandboxed build make the same
# derivations and share their store paths.
{
  lock,
  fetch,
  # The zig-purifier command and the zig executable, as store paths with
  # their string context.
  cli,
  zig,
  system,
}:
let
  materialize =
    artifact:
    derivation {
      name = "zig-package-${lock.storeName artifact.zigHash}";
      inherit system;
      builder = cli;
      args = [
        "materialize"
        zig
        (fetch artifact)
        artifact.zigHash
      ];
      preferLocalBuild = true;
    };

  packages = builtins.listToAttrs (
    map (artifact: {
      name = artifact.zigHash;
      value = materialize artifact;
    }) lock.artifacts
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
