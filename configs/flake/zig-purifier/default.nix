# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  # The flake publishes the derivations of the scope `pkgs.zig-purifier` as
  # its packages; the scope also holds the builder, which is a function.
  purifier.scope = "zig-purifier";

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope is the `default` entry of this flake's package overlay
    # registry (pkg-overlays/): the package set applies it by default, and
    # the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`.
  };

  # `nix run github:nix-purifiers/zig-purifier -- lock` locks the Zig
  # package in the current directory with the default zig of nixpkgs;
  # `nix run github:nix-purifiers/zig-purifier#toolchain-zig_0_15 -- lock`
  # locks it with zig 0.15.
  #
  # `nix develop github:nix-purifiers/zig-purifier` gives a shell whose
  # `zig` runs against the package's locked downloads.
  perSystem =
    { pkgs, ... }:
    let
      # A toolchain for each zig version the package set provides with a
      # ZLS of the same version.
      zigAttrs = builtins.filter (name: builtins.match "zig_[0-9]+_[0-9]+" name != null) (
        builtins.attrNames pkgs
      );
      zlsOf = name: "zls" + lib.removePrefix "zig" name;
      toolchains = lib.listToAttrs (
        map
          (name: {
            name = "toolchain-${name}";
            value = pkgs.zig-purifier.toolchain.override {
              zig = pkgs.${name};
              zls = pkgs.${zlsOf name};
            };
          })
          (
            builtins.filter (
              name:
              pkgs ? ${zlsOf name}
              && (builtins.tryEval pkgs.${name}.version).success
              && (builtins.tryEval pkgs.${zlsOf name}.version).success
            ) zigAttrs
          )
      );
    in
    {
      packages = {
        default = pkgs.zig-purifier.toolchain;
      }
      // toolchains;
      devShells.default = pkgs.mkShell {
        packages = [ pkgs.zig-purifier.toolchain ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
        perSystem.treefmt.programs.ruff-format.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              overlay = self.overlays.default;
              inherit (self.lib.zig-purifier) readLock;
            };
            treefmt.programs.nixfmt.enable = true;
            treefmt.programs.ruff-format.enable = true;
          };
      };
  };

}
