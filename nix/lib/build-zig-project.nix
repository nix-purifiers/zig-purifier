# SPDX-License-Identifier: MIT
#
# buildZigProject: builds a Zig package and its locked dependencies in the
# Nix sandbox, from the package's zig-purifier.lock.json alone.
#
#   (buildZigProject { src = ./.; }).package
#
# The result is an attribute set:
#
#   package      the install step: `zig build install --prefix $out`
#   files        each file the install step installs, by its path under
#                the prefix, as `files."bin/hello"`
#   executables  each file under bin/, by its name
#   steps        each other step of build.zig, by its name, as a build that
#                runs it and succeeds when it does (`steps.test`)
#   release      the release archive, and in `zig-hash` the hash that
#                `zig fetch` reports for it
#   packages     the dependencies, each unpacked as zig unpacks it, by hash
#   cache        those packages linked by hash: the `p` of a zig cache
#   lock         the lockfile
#
# The lock run records the steps and the installed files, so every
# attribute is known when Nix evaluates the build, without building it.
{
  lib,
  stdenv,
  pkgs,
  zig-purifier,
}:
{
  # The source: the package, and every package its path dependencies name.
  src,
  # The directory of the package's build.zig.zon, relative to `src`.
  projectDir ? ".",
  # The lockfile. By default, zig-purifier.lock.json beside build.zig.zon;
  # a lockfile kept apart from a source fetched from elsewhere goes here.
  lockFile ? null,
  # The zig. By default, the nixpkgs zig of the version the lock was made
  # with.
  zig ? null,
  # The flags of every `zig build`. By default, the flags the lock run
  # used, which also decided the installed files the lock records.
  buildFlags ? null,
  # Whether the package build also runs `checkSteps`.
  doCheck ? false,
  checkSteps ? [ "test" ],
  # Replace the fetchers of the locked downloads, for credentials or more
  # mirrors (see nix/lib/fetch.nix).
  fetchurl ? pkgs.fetchurl,
  fetchgit ? pkgs.fetchgit,
}:
let
  projectSrc = if projectDir == "." then "${src}" else "${src}/${projectDir}";
  lockFile' = if lockFile != null then lockFile else "${projectSrc}/zig-purifier.lock.json";
  lock = import ./lock.nix { lockFile = lockFile'; };

  # A lock made from other build.zig.zon files would build other
  # dependencies than the source names. A source that is a path in the
  # repository is checked here; other sources would need their files read
  # through import from derivation.
  freshness =
    if !(builtins.isPath src) || lock.computeDefinitionHash projectSrc == lock.definitionHash then
      true
    else
      throw "zig-purifier: the build.zig.zon files under ${toString projectSrc} changed since ${toString lockFile'} was written. Run `zig-purifier lock` there.";

  # Path dependencies must lie inside the source, or the build cannot see
  # them.
  # Whether a path relative to the package climbs above `src`.
  escapes =
    p:
    let
      parts = builtins.filter (s: s != "" && s != ".") (lib.splitString "/" "${projectDir}/${p}");
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
  inside = builtins.all (
    p:
    !(escapes p)
    || throw "zig-purifier: the path dependency ${p} of ${projectDir} lies outside `src`. Make `src` a directory that holds it, and set `projectDir`."
  ) lock.localPackages;

  majorMinor = lib.versions.majorMinor lock.zigVersion;
  zigAttr = "zig_${lib.replaceStrings [ "." ] [ "_" ] majorMinor}";
  zig' =
    if zig != null then
      zig
    else if pkgs ? ${zigAttr} then
      pkgs.${zigAttr}
    else if lib.versions.majorMinor pkgs.zig.version == majorMinor then
      pkgs.zig
    else
      throw "zig-purifier: the lock was made with zig ${lock.zigVersion}, and this package set has no ${zigAttr}. Pass `zig`.";

  flags = if buildFlags != null then buildFlags else lock.buildFlags;

  cli = "${zig-purifier.cli}/bin/zig-purifier";
  zigBin = "${zig'}/bin/zig";

  fetch = import ./fetch.nix { inherit lock fetchurl fetchgit; };
  inherit
    (import ./packages.nix {
      inherit lock fetch cli;
      zig = zigBin;
      inherit (stdenv.buildPlatform) system;
    })
    packages
    farm
    ;

  # The shell lines that copy the source and make the locked packages
  # visible to zig. Zig up to 0.15 looks for a package at `p/<hash>` in the
  # global cache, and zig 0.16 and later at `zig-pkg/<hash>` in the
  # project, so both get a link to each package.
  setup = ''
    export HOME=$TMPDIR
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-global
    cp -r ${src} $TMPDIR/source
    chmod -R u+w $TMPDIR/source
    cd $TMPDIR/source/${projectDir}
    mkdir -p $ZIG_GLOBAL_CACHE_DIR/p zig-pkg
    for package in ${farm}/*; do
      name=$(basename "$package")
      ln -s "$(readlink "$package")" "$ZIG_GLOBAL_CACHE_DIR/p/$name"
      if [ ! -e "zig-pkg/$name" ]; then
        ln -s "$(readlink "$package")" "zig-pkg/$name"
      fi
    done
  '';

  # `zig build` with the build flags. When zig fails because it tried to
  # fetch a package, the lock lacks a dependency, which the error names.
  zigBuild =
    args: shellArgs:
    let
      command = "${
        lib.escapeShellArgs (
          [
            "zig"
            "build"
          ]
          ++ args
          ++ flags
        )
      } ${shellArgs}";
    in
    ''
      if ! ${command} 2> >(tee $TMPDIR/zig-errors >&2); then
        if grep -qiE 'fetch|connection|name ?server|unable to download|hash mismatch' $TMPDIR/zig-errors; then
          echo "zig-purifier: zig tried to fetch a package that ${toString lockFile'} does not hold. Run \`zig-purifier relock\` where build.zig.zon is." >&2
        fi
        exit 1
      fi
    '';

  # The path dependencies come first: the freshness check reads their
  # build.zig.zon files.
  checked = builtins.seq inside (builtins.seq freshness true);

  package =
    assert checked;
    stdenv.mkDerivation {
      pname = lock.name;
      version = lock.packageVersion;
      nativeBuildInputs = [ zig' ];
      dontUnpack = true;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${setup}
        ${zigBuild [ "install" ] "--prefix $out"}
        runHook postBuild
      '';
      inherit doCheck;
      checkPhase = ''
        runHook preCheck
        ${lib.concatMapStringsSep "\n" (step: zigBuild [ step ] "") checkSteps}
        runHook postCheck
      '';
      dontInstall = true;
      passthru = {
        inherit lock;
      };
    };

  step =
    name:
    assert checked;
    stdenv.mkDerivation {
      name = "${lock.name}-step-${name}";
      nativeBuildInputs = [ zig' ];
      dontUnpack = true;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${setup}
        ${zigBuild [ name ] ""}
        runHook postBuild
      '';
      installPhase = "touch $out";
    };

  release = derivation {
    name = "${lock.name}-${lock.packageVersion}-release";
    inherit (stdenv.buildPlatform) system;
    builder = cli;
    args = [
      "release"
      zigBin
      projectSrc
    ];
  };

  binaries = builtins.filter (f: lib.hasPrefix "bin/" f) lock.installed;
in
{
  inherit
    package
    packages
    release
    lock
    ;
  cache = farm;
  files = lib.genAttrs lock.installed (f: "${package}/${f}");
  executables = lib.listToAttrs (
    map (f: {
      name = lib.removePrefix "bin/" f;
      value = "${package}/${f}";
    }) binaries
  );
  steps = lib.genAttrs (lib.subtractLists [
    "install"
    "uninstall"
  ] lock.steps) step;
}
