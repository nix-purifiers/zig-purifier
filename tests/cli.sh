#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Drives zig-purifier as a developer does, outside the sandbox: lock a
# package, build it offline through the zig wrapper, change it, and make
# the common mistakes, checking that each says what went wrong and what to
# run. Runs Nix and needs the network, so CI runs it as a job of its own.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# expect_failure PATTERN COMMAND...: COMMAND fails and prints PATTERN.
expect_failure() {
  local pattern=$1
  shift
  if "$@" > "$work/out" 2>&1; then
    cat "$work/out" >&2
    fail "$* succeeded"
  fi
  grep -qE "$pattern" "$work/out" || {
    cat "$work/out" >&2
    fail "$* did not print /$pattern/"
  }
}

toolchain=$(nix build --no-link --print-out-paths '.#toolchain-zig_0_15')
export PATH="$toolchain/bin:$PATH"

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
# A global cache of the test's own, so the test leaves the user's alone.
export ZIG_GLOBAL_CACHE_DIR=$work/zig-global

# build_package DIR: builds the hello package in DIR with buildZigProject.
build_package() {
  nix build --no-link --print-out-paths --impure --expr "
    let
      flake = builtins.getFlake \"git+file://$repo\";
      pkgs = import flake.inputs.nixpkgs {
        system = builtins.currentSystem;
        overlays = [ flake.overlays.default ];
      };
    in (pkgs.buildZigProject { src = /. + \"$1\"; projectDir = \"hello\"; }).package"
}

cp -r tests/fixtures "$work/fixtures"
chmod -R u+w "$work/fixtures"
hello=$work/fixtures/hello

echo "== The quickstart: lock, then build offline through the wrapper"
rm "$hello/zig-purifier.lock.json"
(cd "$hello" && zig-purifier lock)
cmp "$hello/zig-purifier.lock.json" tests/fixtures/hello/zig-purifier.lock.json ||
  fail "a fresh lock differs from the committed lockfile"
(cd "$hello" && zig-purifier lock) | grep -q 'is up to date' || fail "lock relocked an up-to-date lockfile"

echo "== sync links every locked package into the global cache"
(cd "$hello" && zig-purifier sync)
for package_hash in $(grep -o '"zigHash": "[^"]*"' "$hello/zig-purifier.lock.json" | cut -d'"' -f4); do
  link=$ZIG_GLOBAL_CACHE_DIR/p/$package_hash
  [ -L "$link" ] || fail "sync did not link $package_hash"
  case $(readlink "$link") in /nix/store/*) ;; *) fail "$link does not point into the store" ;; esac
done

echo "== zig build, test and run work with no network"
# A dead proxy: any download zig tries fails.
(cd "$hello" && https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 zig build test)
(cd "$hello" && https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 zig build run -- --name dev) |
  grep -qx 'Hello, dev!' || fail "zig build run printed something else"

echo "== The Nix build of the package"
"$(build_package "$work/fixtures")/bin/hello" --name nix | grep -qx 'Hello, nix!' || fail "the Nix build printed something else"

echo "== A stale lock: the wrapper warns, and the Nix build says to relock"
printf '// an edit\n' >> "$hello/build.zig.zon"
(cd "$hello" && zig-purifier zig version) > "$work/out" 2>&1
grep -q 'zig-purifier lock' "$work/out" || fail "the wrapper did not warn about the stale lock"
expect_failure 'changed since .* Run `zig-purifier lock`' build_package "$work/fixtures"
cp tests/fixtures/hello/build.zig.zon "$hello/build.zig.zon"

echo "== Adding a dependency with zig fetch --save, then relocking"
(cd "$hello" && zig fetch --save=clap_release 'git+https://github.com/Hejsil/zig-clap#9cfa61596cd44ef7be35f8d2e108d2025e09868e')
(cd "$hello" && zig-purifier lock) | grep -q 'wrote .*: 3 downloads' || fail "lock did not lock the new dependency"
"$(build_package "$work/fixtures")/bin/hello" > /dev/null || fail "the package did not build after the new dependency"
cp tests/fixtures/hello/build.zig.zon "$hello/build.zig.zon"
(cd "$hello" && zig-purifier lock) > /dev/null
cmp "$hello/zig-purifier.lock.json" tests/fixtures/hello/zig-purifier.lock.json ||
  fail "removing the dependency again did not restore the lockfile"

echo "== A tampered hash fails the fetch"
lock=$hello/zig-purifier.lock.json
cp "$lock" "$work/lock.orig"
sed -i '0,/"hash": "sha256-[^"]*"/s//"hash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="/' "$lock"
expect_failure 'hash mismatch' build_package "$work/fixtures"
cp "$work/lock.orig" "$lock"

echo "== A missing entry: the Nix build says the lock lacks a package"
nix shell 'nixpkgs#jq' --command jq '.artifacts |= map(select(.path | startswith("archives/") | not))' "$work/lock.orig" > "$lock"
expect_failure 'does not hold. Run `zig-purifier relock`' build_package "$work/fixtures"
cp "$work/lock.orig" "$lock"

echo "== A malformed lockfile: the command says to relock"
printf '{ "version": 1, ' > "$lock"
expect_failure 'not valid JSON.*zig-purifier relock' sh -c "cd '$hello' && zig-purifier sync"
cp "$work/lock.orig" "$lock"

echo "== The release archive"
(cd "$hello" && zig-purifier package) > "$work/package"
[ -f "$(head -1 "$work/package")" ] || fail "package wrote no archive"
grep -q '^hello-0.0.1-' "$work/package" || fail "package printed no zig hash"

echo "All zig-purifier CLI tests passed."
