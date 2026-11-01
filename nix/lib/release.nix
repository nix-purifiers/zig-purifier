# SPDX-License-Identifier: MIT
#
# The release archive of a package, for `zig-purifier publish`: the files
# under the `paths` of build.zig.zon in one directory, as a reproducible
# tar.gz, and in `zig-hash` the hash `zig fetch` gives it. The `release` of
# buildZigProject runs the same builder on the same files.
{
  # The package directory, as an absolute path.
  srcPath,
  # The zig-purifier command and the zig executable, as absolute paths
  # into the store.
  cli,
  zig,
}:
let
  inStore =
    what: path:
    let
      parts = builtins.match "(${builtins.storeDir}/[^/]+)(/.*)?" path;
      rest = builtins.elemAt parts 1;
    in
    if parts == null then
      throw "zig-purifier: the ${what} ${path} is not in the Nix store"
    else
      builtins.storePath (builtins.elemAt parts 0) + (if rest == null then "" else rest);
  src = builtins.path {
    name = "source";
    path = /. + srcPath;
    filter =
      path: type:
      !(builtins.elem (baseNameOf path) [
        ".git"
        ".zig-cache"
        "zig-out"
        "zig-pkg"
        ".zig-purifier"
      ]);
  };
in
derivation {
  name = "zig-release";
  system = builtins.currentSystem;
  builder = inStore "zig-purifier command" cli;
  args = [
    "release"
    (inStore "zig executable" zig)
    "${src}"
  ];
}
