# SPDX-License-Identifier: MIT
#
# The zig-purifier command: a Python program with no dependencies beyond
# the standard library, and the Nix library it runs, under
# share/zig-purifier/nix. Its build runs the unit tests, which lock a
# package served from a local HTTP server and so need zig. They run with
# zig 0.15, which builds their small packages in seconds, where zig 0.17
# recompiles its build runner for each one; the readme fixture covers zig
# 0.17.
{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  nix-prefetch-git,
  git,
  zig_0_15,
}:
let
  # The purifier library and the nixpkgs library that this flake pins,
  # which pkgs/cli/library.nix fetches for the evaluations without nixpkgs.
  lockNodes = (builtins.fromJSON (builtins.readFile ../../flake.lock)).nodes;
  libraries = builtins.toJSON {
    purifier = lockNodes.purifier.locked;
    nixpkgsLib = lockNodes.nixpkgs-lib.locked;
  };
in
stdenvNoCC.mkDerivation {
  pname = "zig-purifier";
  inherit libraries;
  passAsFile = [ "libraries" ];
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ./src
      ../../lib-overlays/default
      ../build-zig-project
      ./library.nix
      ./outputs.nix
      ./realize.nix
      ./release.nix
    ];
  };

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [
    python3
    zig_0_15
  ];

  dontConfigure = true;
  dontBuild = true;

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export HOME=$TMPDIR
    (cd pkgs/cli/src && python3 -m unittest -v test_zig_purifier)
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/libexec/zig-purifier $out/share/zig-purifier/pkgs/cli
    cp pkgs/cli/src/zon.py pkgs/cli/src/zig_purifier.py $out/libexec/zig-purifier/
    mkdir -p $out/share/zig-purifier/lib-overlays
    cp -r lib-overlays/default $out/share/zig-purifier/lib-overlays/default
    cp -r pkgs/build-zig-project $out/share/zig-purifier/pkgs/build-zig-project
    cp pkgs/cli/{library,outputs,realize,release}.nix $out/share/zig-purifier/pkgs/cli/
    cp $librariesPath $out/share/zig-purifier/pkgs/cli/libraries.json
    makeWrapper ${lib.getExe python3} $out/bin/zig-purifier \
      --add-flags $out/libexec/zig-purifier/zig_purifier.py \
      --set ZIG_PURIFIER_NIX_LIB $out/share/zig-purifier/pkgs/cli \
      --set ZIG_PURIFIER_CLI $out/bin/zig-purifier \
      --prefix PATH : ${
        lib.makeBinPath [
          nix-prefetch-git
          git
        ]
      }
    runHook postInstall
  '';

  meta = {
    description = "Nix as the dependency backend of Zig packages";
    license = lib.licenses.mit;
    mainProgram = "zig-purifier";
  };
}
