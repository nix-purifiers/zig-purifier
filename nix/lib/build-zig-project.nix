# SPDX-License-Identifier: MIT
#
# buildZigProject: builds a Zig package and its locked dependencies in the
# Nix sandbox, from the package's zig-purifier.lock.json alone.
#
#   (lib.zig-purifier.buildZigProject { inherit pkgs; src = ./.; }).packages.hello
#
# The result is an attribute set:
#
#   packages.<name>  the install step, `zig build install --prefix $out`,
#                    under the name of the package in build.zig.zon
#   tests            the `test` step of build.zig (or `checkSteps`), run
#   release          the release archive `zig-purifier publish` uploads,
#                    and in `zig-hash` the hash `zig fetch` gives it
#   fetches          the purifier library entries of the lock
#   files            each file the install step installs, by its path under
#                    the prefix, as `files."bin/hello"`
#   executables      each file under bin/, by its name
#   steps            each step of build.zig but install and uninstall, by
#                    its name, as a build that runs it
#   dependencies     the dependencies, each unpacked as zig unpacks it, by
#                    its zig hash
#   lock             the lock in memory (nix/lib/read-lock.nix)
#
# The lock run records the steps and the installed files, so every
# attribute is known when Nix evaluates the build, without building it.
{
  lib,
  # The purifier library (github:nix-purifiers/purifier), which checks the
  # lock and fetches its download entries.
  purifier,
}:
{
  pkgs,
  # The source: the package, and every package its path dependencies name.
  src,
  # The directory of the package's build.zig.zon, relative to `src`.
  projectDir ? ".",
  # The lockfile. By default, zig-purifier.lock.json beside build.zig.zon.
  # A lockfile outside `src` takes the place of any lockfile in it.
  lockFile ? null,
  # Fetchers for the purifier library's fetchEntry, such as a fetchurl
  # with credentials or a company mirror. Each takes the arguments the
  # nixpkgs fetcher of the same name takes.
  fetchers ? { },
  # The zig. By default, the nixpkgs zig of the version the lock was made
  # with.
  zig ? null,
  # The flags of every `zig build`. By default, the flags the lock run
  # used, which also decided the installed files the lock records.
  buildFlags ? null,
  # The steps `tests` runs.
  checkSteps ? [ "test" ],
}:
let
  inherit (pkgs) stdenv;
  inherit (stdenv.buildPlatform) system;

  lock = import ./read-lock.nix { inherit src projectDir lockFile; };
  checked = purifier.checkLock lock;
  name = builtins.head (builtins.attrNames checked.outputs);
  output = checked.outputs.${name};
  entries = purifier.entriesFor system checked;
  lockName = toString (
    if lockFile != null then lockFile else "${src}/${projectDir}/zig-purifier.lock.json"
  );

  majorMinor = lib.versions.majorMinor output.zigVersion;
  zigAttr = "zig_${lib.replaceStrings [ "." ] [ "_" ] majorMinor}";
  zig' =
    if zig != null then
      zig
    else if pkgs ? ${zigAttr} then
      pkgs.${zigAttr}
    else if lib.versions.majorMinor pkgs.zig.version == majorMinor then
      pkgs.zig
    else
      throw "zig-purifier: the lock was made with zig ${output.zigVersion}, and this package set has no ${zigAttr}. Pass `zig`.";

  flags = if buildFlags != null then buildFlags else output.buildFlags;

  cli = "${pkgs.callPackage ../../pkgs/cli { }}/bin/zig-purifier";
  zigBin = "${zig'}/bin/zig";

  fetch = purifier.fetchEntry ({ inherit pkgs; } // fetchers);
  inherit
    (import ./packages.nix {
      inherit
        entries
        fetch
        cli
        system
        ;
      zig = zigBin;
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
    ${lib.optionalString (lockFile != null) ''
      # A lockfile given outside `src` replaces any copy in it.
      cp ${lockFile} zig-purifier.lock.json
    ''}
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
          echo "zig-purifier: zig tried to fetch a package that ${lockName} does not hold. Run \`zig-purifier lock\` where build.zig.zon is." >&2
        fi
        exit 1
      fi
    '';

  package = stdenv.mkDerivation {
    pname = name;
    inherit (output) version;
    nativeBuildInputs = [ zig' ];
    dontUnpack = true;
    dontConfigure = true;
    buildPhase = ''
      runHook preBuild
      ${setup}
      ${zigBuild [ "install" ] "--prefix $out"}
      runHook postBuild
    '';
    dontInstall = true;
  };

  # A build that runs `steps` of build.zig and succeeds when they do.
  run =
    runName: steps:
    stdenv.mkDerivation {
      name = runName;
      nativeBuildInputs = [ zig' ];
      dontUnpack = true;
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        ${setup}
        ${lib.concatMapStringsSep "\n" (step: zigBuild [ step ] "") steps}
        runHook postBuild
      '';
      installPhase = "touch $out";
    };

  release = derivation {
    name = "${name}-${output.version}-release";
    inherit system;
    builder = cli;
    args = [
      "release"
      zigBin
      (if projectDir == "." then "${src}" else "${src}/${projectDir}")
    ];
  };

  binaries = builtins.filter (f: lib.hasPrefix "bin/" f) output.installed;
in
{
  packages.${name} = package;
  tests = run "${name}-tests" (builtins.filter (s: builtins.elem s output.steps) checkSteps);
  inherit release;
  lock = checked;
  fetches = checked.entries;
  dependencies = packages;
  files = lib.genAttrs output.installed (f: "${package}/${f}");
  executables = lib.listToAttrs (
    map (f: {
      name = lib.removePrefix "bin/" f;
      value = "${package}/${f}";
    }) binaries
  );
  steps = lib.genAttrs (lib.subtractLists [
    "install"
    "uninstall"
  ] output.steps) (step: run "${name}-step-${step}" [ step ]);
}
