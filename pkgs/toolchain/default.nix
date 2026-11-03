# SPDX-License-Identifier: MIT
#
# A zig whose `zig` runs through `zig-purifier zig`, the ZLS of the same
# zig version, and the zig-purifier command, all using this zig. In a
# package with a current lockfile, `zig build` then reads the locked
# packages from the store, offline, and `zig-purifier prefetch` keeps the
# whole toolchain alive with a GC root in the project.
# `.override { zig = zig_0_15; zls = zls_0_15; }` gives the toolchain of
# another zig.
{
  lib,
  stdenv,
  runCommand,
  makeWrapper,
  apple-sdk,
  zig,
  zls,
  cli,
}:
let
  # On macOS, zig links against the SDK `xcrun` names, the host's Xcode
  # unless DEVELOPER_DIR names another. The toolchain's zig, and the zig
  # that ZLS runs, use the SDK of nixpkgs instead, as a Nix build does:
  # zig 0.14 and 0.15 find no symbols in the libSystem of recent Xcode
  # SDKs, which list arm64e but not arm64.
  sdk = lib.optionalString stdenv.hostPlatform.isDarwin " --set DEVELOPER_DIR ${apple-sdk}";
in
runCommand "zig-purifier-toolchain-${zig.version}"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit zig zls cli; };
    # `nix run` of a toolchain runs `zig-purifier`, as in
    # `nix run '…#toolchain-zig_0_15' -- lock`.
    meta.mainProgram = "zig-purifier";
  }
  ''
    makeWrapper ${cli}/bin/zig-purifier $out/bin/zig \
      --set ZIG_PURIFIER_ZIG ${zig}/bin/zig \
      --set ZIG_PURIFIER_TOOLCHAIN $out \
      --add-flags zig${sdk}
    makeWrapper ${cli}/bin/zig-purifier $out/bin/zig-purifier \
      --set ZIG_PURIFIER_ZIG ${zig}/bin/zig \
      --set ZIG_PURIFIER_TOOLCHAIN $out${sdk}
    ${
      if stdenv.hostPlatform.isDarwin then
        "makeWrapper ${zls}/bin/zls $out/bin/zls${sdk}"
      else
        "ln -s ${zls}/bin/zls $out/bin/zls"
    }
  ''
