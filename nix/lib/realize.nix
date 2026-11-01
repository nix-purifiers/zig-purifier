# SPDX-License-Identifier: MIT
#
# The package cache the zig wrapper builds for interactive use. `nix-build`
# of this file fetches and unpacks every locked package, and its out link
# is the GC root that keeps them all alive.
#
# The wrapper evaluates it with nothing but the Nix installation it runs.
{
  # The lockfile, as an absolute path.
  lockFile,
  # The zig-purifier command and the zig executable, as absolute paths
  # into the store.
  cli,
  zig,
  libDir ? ./.,
}:
let
  lock = import (libDir + "/lock.nix") { inherit lockFile; };
  fetch = import (libDir + "/library.nix") { inherit libDir; };

  # A store path as a string with the store object in its context, so the
  # builds that run it may read it.
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
in
(import (libDir + "/packages.nix") {
  inherit lock fetch;
  cli = inStore "zig-purifier command" cli;
  zig = inStore "zig executable" zig;
  system = builtins.currentSystem;
}).farm
