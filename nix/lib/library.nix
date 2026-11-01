# SPDX-License-Identifier: MIT
#
# The fetch of the purifier library (github:nix-purifiers/purifier), for
# the two evaluations that run with no nixpkgs: the package cache that
# `zig-purifier sync` builds, and the outputs step of the lock run. The
# zig-purifier package writes libraries.json beside this file with the
# library and the nixpkgs library that this flake's lockfile pins, and
# Nix has both in its store already, from running the command.
#
# Without nixpkgs, the library fetches a file entry with Nix's built-in
# fetcher, at the store path nixpkgs' fetchurl gives it. A git entry goes
# to builtins.fetchGit, which checks the same NAR hash nix-prefetch-git
# reports for a checkout without its .git directory.
{
  libDir ? ./.,
}:
let
  pins = builtins.fromJSON (builtins.readFile (libDir + "/libraries.json"));
  fetchPinned = locked: builtins.fetchTree (removeAttrs locked [ "lastModified" ]);
  lib = import "${fetchPinned pins.nixpkgsLib}/lib";
  purifier = import (fetchPinned pins.purifier) { inherit lib; };

  fetchgit =
    {
      url,
      rev,
      hash,
      fetchSubmodules,
      leaveDotGit,
      ...
    }:
    assert !leaveDotGit;
    builtins.fetchGit {
      inherit url rev;
      narHash = hash;
      submodules = fetchSubmodules;
      allRefs = true;
    };
  fetchEntry = purifier.fetchEntry { inherit fetchgit; };
in
# The library asks for `pkgs` for a git entry even when it has its own
# fetchgit, so a git entry goes to fetchgit here, with the arguments the
# library would pass.
entry:
if entry ? git then
  fetchgit {
    inherit (entry.git) url rev leaveDotGit;
    inherit (entry) hash;
    fetchSubmodules = entry.git.submodules;
  }
else
  fetchEntry entry
