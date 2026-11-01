#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks every committed lockfile with the zig it was made with: the
# fixtures, and the pinned real-world projects of tests/projects/, whose
# sources are fetched at their pinned commits first. CI then compares the
# results with the committed lockfiles.
set -euo pipefail
cd "$(dirname "$0")/.."

# relock TOOLCHAIN DIR: relocks DIR with the flake package TOOLCHAIN.
relock() {
  "$(nix build --no-link --print-out-paths ".#$1")/bin/zig-purifier" relock "$2"
}

relock toolchain-zig_0_15 tests/fixtures/hello
relock toolchain tests/fixtures/readme

# The stale fixture keeps the hello lockfile beside a changed build.zig.zon.
cp tests/fixtures/hello/zig-purifier.lock.json tests/fixtures/stale/

for project in tests/projects/*/; do
  name=$(basename "$project")
  # pin.sh sets url, rev and toolchain.
  # shellcheck source=/dev/null
  . "$project/pin.sh"
  work=$(mktemp -d)
  # shellcheck disable=SC2154,SC2016 # pin.sh sets url and rev; sh expands $1 and $2
  source=$(nix shell 'nixpkgs#nix-prefetch-git' 'nixpkgs#jq' --command \
    sh -c 'nix-prefetch-git --quiet "$1" "$2" | jq -r .path' sh "$url" "$rev")
  cp -r "$source" "$work/$name"
  chmod -R u+w "$work/$name"
  # shellcheck disable=SC2154 # pin.sh sets toolchain
  relock "$toolchain" "$work/$name"
  cp "$work/$name/zig-purifier.lock.json" "$project/"
  rm -rf "$work"
done
