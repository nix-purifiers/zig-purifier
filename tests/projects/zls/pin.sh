# SPDX-License-Identifier: MIT
# shellcheck disable=SC2034 # tests/relock.sh reads these
#
# ZLS, the Zig language server, at its 0.15.1 release, for zig 0.15. Its
# lockfile lives beside this file; tests/default.nix builds it, and
# tests/relock.sh relocks it.
url="https://github.com/zigtools/zls"
rev="f91b2e1e305e5d5bd3725aea90f9f9bfb3dce055"
toolchain="toolchain-zig_0_15"
