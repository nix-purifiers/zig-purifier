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
  runCommand,
  makeWrapper,
  zig,
  zls,
  cli,
}:
runCommand "zig-purifier-toolchain-${zig.version}"
  {
    nativeBuildInputs = [ makeWrapper ];
    passthru = { inherit zig zls cli; };
    meta.mainProgram = "zig";
  }
  ''
    makeWrapper ${cli}/bin/zig-purifier $out/bin/zig \
      --set ZIG_PURIFIER_ZIG ${zig}/bin/zig \
      --set ZIG_PURIFIER_TOOLCHAIN $out \
      --add-flags zig
    makeWrapper ${cli}/bin/zig-purifier $out/bin/zig-purifier \
      --set ZIG_PURIFIER_ZIG ${zig}/bin/zig \
      --set ZIG_PURIFIER_TOOLCHAIN $out
    ln -s ${zls}/bin/zls $out/bin/zls
  ''
