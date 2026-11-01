# SPDX-License-Identifier: MIT
#
# The outputs of a package, for the lock run: the steps of its build.zig,
# and the files its install step installs. `zig-purifier lock` builds this
# with nix-build after it has locked the downloads, and records the result
# in the lockfile.
#
# The project's build.zig runs here, in the Nix sandbox, offline, with the
# locked packages alone, so the lock run runs no build code of the project
# outside the sandbox, and a dependency the lock missed fails here as it
# would in the build.
{
  # The lockfile so far: the downloads and the build flags.
  lockFile,
  # The directory holding the project and its path dependencies, as an
  # absolute path, and the project's directory inside it.
  srcPath,
  projectDir,
  # The zig-purifier command and the zig executable, as absolute paths
  # into the store.
  cli,
  zig,
  libDir ? ./.,
}:
let
  lock = import (libDir + "/lock.nix") { inherit lockFile; };
  fetch = import (libDir + "/fetch.nix") { inherit lock; };
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
  cli' = inStore "zig-purifier command" cli;
  zig' = inStore "zig executable" zig;
  system = builtins.currentSystem;
  inherit
    (import (libDir + "/packages.nix") {
      inherit lock fetch system;
      cli = cli';
      zig = zig';
    })
    farm
    ;
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
      ]);
  };
in
derivation {
  name = "zig-purifier-outputs";
  inherit system;
  builder = cli';
  args = [
    "outputs"
    zig'
    "${farm}"
    "${src}"
    projectDir
    (builtins.toJSON lock.buildFlags)
  ];
}
