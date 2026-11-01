# SPDX-License-Identifier: MIT
#
# readLock: the lock in memory of the purifier contract, read from a
# zig-purifier.lock.json (Zig has no lockfile of its own).
#
#   {
#     purifier = "zig-purifier";
#     entries  = [ <download entry> ];  # with `zigHash`, the hash zig
#                                       # gives the package
#     outputs  = { <package name> = {
#                    version, zigVersion, buildFlags, steps, installed,
#                    localPackages;
#                  }; };
#     problems = [ <string> ];          # each naming the command to run
#   }
#
# It uses builtins only, so the evaluations of the command, which run with
# no nixpkgs, read the lockfile with it too. With `src` null, the checks
# that need the project's files (staleness, path dependencies) are left to
# the command.
{
  # The project tree, or null.
  src,
  # The directory of the package's build.zig.zon, relative to `src`.
  projectDir ? ".",
  # The lockfile. By default, zig-purifier.lock.json beside build.zig.zon.
  lockFile ? null,
}:
let
  projectSrc = if projectDir == "." then "${src}" else "${src}/${projectDir}";
  path = if lockFile != null then lockFile else "${projectSrc}/zig-purifier.lock.json";
  name = toString path;
  supportedVersion = import ./lock-version.nix;
  relock = "Run `zig-purifier relock` to write it again.";

  exists = builtins.pathExists path;
  text = if exists then builtins.readFile path else "";
  # A parse error of builtins.fromJSON cannot be caught. A lockfile that is
  # not one JSON object, such as a truncated one or one with merge conflict
  # markers, is a problem here instead. Text that looks like one JSON object
  # and does not parse fails evaluation, with the context naming the
  # command that writes the lockfile again; the commands check the file
  # before Nix reads it.
  whole = builtins.match "[[:space:]]*\\{.*}[[:space:]]*" text != null;
  conflicted = builtins.match ".*(<<<<<<<|>>>>>>>).*" text != null;
  parsed = exists && whole && !conflicted;
  raw =
    if parsed then
      builtins.addErrorContext "while reading ${name}, which is not valid JSON. ${relock}" (
        builtins.fromJSON text
      )
    else
      { };

  # The hash `zig-purifier lock` records as `contentHash`, of the lockfile
  # without it, written as builtins.toJSON writes it, which is how the
  # command computes it too.
  contentHash = builtins.hashString "sha256" (builtins.toJSON (removeAttrs raw [ "contentHash" ]));

  # The hash `zig-purifier lock` records as `definitionHash`, of the
  # build.zig.zon files: for each file, sorted by path, its path relative
  # to the project, a newline, its length in bytes, a newline, and its
  # contents.
  definitionHash = builtins.hashString "sha256" (
    builtins.concatStringsSep "" (
      map (
        rel:
        let
          content = builtins.readFile "${projectSrc}/${rel}";
        in
        "${rel}\n${toString (builtins.stringLength content)}\n${content}"
      ) (builtins.sort builtins.lessThan raw.definitionFiles)
    )
  );

  # Whether a path relative to the package climbs above `src`.
  escapes =
    p:
    let
      parts = builtins.filter (s: s != "" && s != "." && builtins.isString s) (
        builtins.split "/" "${projectDir}/${p}"
      );
      depth = builtins.foldl' (
        d: s:
        if d < 0 then
          d
        else if s == ".." then
          d - 1
        else
          d + 1
      ) 0 parts;
    in
    depth < 0;
  outside = builtins.filter escapes (raw.localPackages or [ ]);

  problems =
    if !exists then
      [ "zig-purifier: there is no ${name}. Run `zig-purifier lock` where build.zig.zon is." ]
    else if !parsed then
      [
        "zig-purifier: ${name} is not a valid lockfile${
          if conflicted then " (it has merge conflict markers)" else ""
        }. ${relock}"
      ]
    else if raw.version or null != supportedVersion then
      [
        "zig-purifier: ${name} has lock format version ${
          toString (raw.version or "none")
        }, and this library reads version ${toString supportedVersion}. ${relock}"
      ]
    else if raw.contentHash or null != contentHash then
      [ "zig-purifier: ${name} was edited after `zig-purifier lock` wrote it. ${relock}" ]
    else if src != null && outside != [ ] then
      [
        "zig-purifier: the path dependency ${builtins.head outside} of ${projectDir} lies outside `src`. Make `src` a directory that holds it, and set `projectDir`."
      ]
    # Staleness needs the build.zig.zon files, which a source fetched from
    # elsewhere holds only behind import from derivation.
    else if builtins.isPath src && definitionHash != raw.definitionHash then
      [
        "zig-purifier: the build.zig.zon files under ${toString projectSrc} changed since ${name} was written. Run `zig-purifier lock` there."
      ]
    else
      [ ];
  usable = problems == [ ];
in
{
  purifier = "zig-purifier";
  entries = if usable then raw.artifacts else [ ];
  outputs =
    if usable then
      {
        ${raw.name} = {
          version = raw.packageVersion;
          inherit (raw)
            zigVersion
            buildFlags
            steps
            installed
            localPackages
            ;
        };
      }
    else
      { };
  inherit problems;
}
