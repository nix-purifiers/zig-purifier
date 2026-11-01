# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The packages are the `default` entry of this flake's package overlay
    # registry (pkg-overlays/): the package set applies it by default, and
    # the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`.
    nixpkgs = {
      packages.export.enabled = true;
    };
  };

  # `nix run github:nix-purifiers/zig-purifier -- lock` locks the Zig
  # package in the current directory with the default zig of nixpkgs;
  # `nix run github:nix-purifiers/zig-purifier#toolchain-zig_0_15 -- lock`
  # locks it with zig 0.15.
  #
  # `nix develop github:nix-purifiers/zig-purifier` gives a shell whose
  # `zig` runs against the package's locked downloads.
  perSystem =
    { config, pkgs, ... }:
    let
      # A toolchain for each zig version the package set provides.
      zigAttrs = builtins.filter (name: builtins.match "zig_[0-9]+_[0-9]+" name != null) (
        builtins.attrNames pkgs
      );
      toolchains = lib.listToAttrs (
        map (name: {
          name = "toolchain-${name}";
          value = config.packages.toolchain.override { zig = pkgs.${name}; };
        }) (builtins.filter (name: (builtins.tryEval pkgs.${name}.version).success) zigAttrs)
      );
    in
    {
      packages = {
        default = config.packages.toolchain;
      }
      // toolchains;
      devShells.default = pkgs.mkShell {
        packages = [ config.packages.toolchain ];
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
            };
            treefmt.programs.nixfmt.enable = true;
            treefmt.programs.ruff-format.enable = true;
          };
      };
  };

}
