#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-offline: after `zig-purifier prefetch`, the everyday loop and
# the editor work with no network. Runs the hello fixture through
# `zig build`, `zig build test` and `zig build run`, and asks the
# toolchain's ZLS for the definition of `@import("clap")`, all behind a
# dead proxy. Needs Nix, so CI runs it as a job on both architectures.
set -euo pipefail
cd "$(dirname "$0")/.."

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

toolchain=$(nix build --no-link --print-out-paths '.#toolchain-zig_0_15')
# ZLS runs the plain zig of the toolchain, from the nixpkgs this flake pins.
zig=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#zig_0_15')/bin/zig
export PATH="$toolchain/bin:$PATH"

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
export ZIG_GLOBAL_CACHE_DIR=$work/zig-global
cp -r tests/fixtures "$work/fixtures"
chmod -R u+w "$work/fixtures"
hello=$work/fixtures/hello

(cd "$hello" && zig-purifier prefetch)
[ -L "$hello/.zig-purifier/packages" ] || fail "prefetch made no GC root for the packages"
[ -L "$hello/.zig-purifier/toolchain" ] || fail "prefetch made no GC root for the toolchain"

# A dead proxy: any download zig or ZLS tries fails.
export https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9

(cd "$hello" && zig build)
(cd "$hello" && zig build test)
(cd "$hello" && zig build run -- --name offline) > "$work/run"
grep -qx 'Hello, offline!' "$work/run" || fail "zig build run printed $(cat "$work/run")"

# ZLS resolves the import into the locked package, from the cache prefetch
# linked.
python=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#python3')/bin/python3
"$python" tests/lsp_client.py "$toolchain/bin/zls" "$zig" "$hello" src/main.zig 1 23 > "$work/definition" || true
cat "$work/definition"
grep -q "zig-global/p/clap-" "$work/definition" || fail "ZLS did not resolve @import(\"clap\") offline"

echo "conformance-offline passed."
