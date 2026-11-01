# SPDX-License-Identifier: MIT
#
# A zig whose `zig` runs through `zig-purifier zig`, and the zig-purifier
# command beside it, both using this zig. In a package with a current
# lockfile, `zig build` then reads the locked packages from the store,
# offline. `.override { zig = zig_0_15; }` gives the toolchain of another
# zig.
{
  runCommand,
  makeWrapper,
  zig,
  cli,
}:
runCommand "zig-purifier-toolchain-${zig.version}"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit zig cli; };
    meta.mainProgram = "zig";
  }
  ''
    makeWrapper ${cli}/bin/zig-purifier $out/bin/zig \
      --set ZIG_PURIFIER_ZIG ${zig}/bin/zig \
      --add-flags zig
    makeWrapper ${cli}/bin/zig-purifier $out/bin/zig-purifier \
      --set ZIG_PURIFIER_ZIG ${zig}/bin/zig
  ''
