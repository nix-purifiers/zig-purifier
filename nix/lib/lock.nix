# SPDX-License-Identifier: MIT
#
# Reads a zig-purifier lockfile (written by `zig-purifier lock`).
#
# Needs no nixpkgs: the zig wrapper evaluates this with nothing but the Nix
# installation it runs. `lockFile` is a path, or an absolute path as a
# string.
{ lockFile }:
let
  lock = builtins.fromJSON (builtins.readFile lockFile);

  supportedVersion = import ./lock-version.nix;

  # A store path name from a tree path. Store path names allow
  # [A-Za-z0-9+._?=-], must not start with a dot, and are at most 211
  # characters; every other character becomes "_", and a long name keeps
  # its end, where the file type is. The zig wrapper and the sandboxed
  # build both name their fetches with this function, so they share store
  # paths.
  storeName =
    path:
    let
      replaced = builtins.concatStringsSep "" (
        map (part: if builtins.isList part then "_" else part) (builtins.split "[^A-Za-z0-9+._?=-]" path)
      );
      length = builtins.stringLength replaced;
      tail = if length > 200 then builtins.substring (length - 200) 200 replaced else replaced;
      undotted = builtins.head (builtins.match "\\.*(.*)" tail);
    in
    if undotted == "" then "file" else undotted;

  # The hash `zig-purifier lock` records as `definitionHash`, of the
  # build.zig.zon files under `dir`: for each file, sorted by path, its path
  # relative to the project, a newline, its length in bytes, a newline, and
  # its contents.
  computeDefinitionHash =
    dir:
    builtins.hashString "sha256" (
      builtins.concatStringsSep "" (
        map (
          rel:
          let
            content = builtins.readFile "${dir}/${rel}";
          in
          "${rel}\n${toString (builtins.stringLength content)}\n${content}"
        ) (builtins.sort builtins.lessThan lock.definitionFiles)
      )
    );
in
assert
  lock.version == supportedVersion
  || throw "zig-purifier: ${toString lockFile} has lock format version ${toString lock.version}; this library reads version ${toString supportedVersion}. Run `zig-purifier relock` with the zig-purifier revision of this library.";
lock
// {
  inherit storeName computeDefinitionHash;
}
