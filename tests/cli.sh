#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Drives zig-purifier as a developer does, outside the sandbox: lock a
# package, prefetch it, build it through the zig wrapper, keep the lockfile
# outside the project, change the package, and publish it, checking that
# each mistake says what to run. Runs Nix and needs the network, so CI runs
# it as a job of its own. tests/offline.sh covers the loop with no network,
# and the flake's conformance checks the broken lockfiles.
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

# build_package DIR [LOCKFILE]: builds the hello package under DIR with
# buildZigProject, from LOCKFILE when given.
build_package() {
  local lock_arg=""
  if [ $# -gt 1 ]; then
    lock_arg="lockFile = /. + \"$2\";"
  fi
  nix build --no-link --print-out-paths --impure --expr "
    let
      flake = builtins.getFlake \"git+file://$repo\";
      pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
    in (flake.lib.zig-purifier.buildZigProject {
      inherit pkgs; src = /. + \"$1\"; projectDir = \"hello\"; $lock_arg
    }).packages.hello"
}

cp -r tests/fixtures "$work/fixtures"
chmod -R u+w "$work/fixtures"
hello=$work/fixtures/hello

echo "== The quickstart: lock, prefetch, and build through the wrapper"
rm "$hello/zig-purifier.lock.json"
(cd "$hello" && zig-purifier lock)
cmp "$hello/zig-purifier.lock.json" tests/fixtures/hello/zig-purifier.lock.json ||
  fail "a fresh lock differs from the committed lockfile"
(cd "$hello" && zig-purifier lock) | grep -q 'is up to date' || fail "lock relocked an up-to-date lockfile"
(cd "$hello" && zig-purifier prefetch)
for package_hash in $(grep -o '"zigHash": "[^"]*"' "$hello/zig-purifier.lock.json" | cut -d'"' -f4); do
  link=$ZIG_GLOBAL_CACHE_DIR/p/$package_hash
  [ -L "$link" ] || fail "prefetch did not link $package_hash"
  case $(readlink "$link") in /nix/store/*) ;; *) fail "$link does not point into the store" ;; esac
done
(cd "$hello" && zig build run -- --name dev) > "$work/run"
grep -qx 'Hello, dev!' "$work/run" || fail "zig build run printed something else"
"$(build_package "$work/fixtures")/bin/hello" --name nix | grep -qx 'Hello, nix!' ||
  fail "the Nix build printed something else"

echo "== A lockfile kept outside the project"
mkdir "$work/external"
mv "$hello/zig-purifier.lock.json" "$work/external/zig-purifier.lock.json"
expect_failure 'Run `zig-purifier lock`' sh -c "cd '$hello' && zig-purifier prefetch"
(cd "$hello" && zig-purifier prefetch --lockfile "$work/external/zig-purifier.lock.json")
[ -L "$work/external/.zig-purifier/packages" ] || fail "the GC root is not beside the external lockfile"
(cd "$hello" && ZIG_PURIFIER_LOCKFILE=$work/external/zig-purifier.lock.json zig build test)
"$(build_package "$work/fixtures" "$work/external/zig-purifier.lock.json")/bin/hello" > /dev/null ||
  fail "the Nix build did not build from the external lockfile"
mv "$work/external/zig-purifier.lock.json" "$hello/zig-purifier.lock.json"

echo "== A stale lock stops zig build and the Nix build, naming zig-purifier lock"
printf '// an edit\n' >> "$hello/build.zig.zon"
expect_failure 'Run `zig-purifier lock`' sh -c "cd '$hello' && zig build"
expect_failure 'changed since .* Run `zig-purifier lock`' build_package "$work/fixtures"
cp tests/fixtures/hello/build.zig.zon "$hello/build.zig.zon"

echo "== Adding a dependency with zig fetch --save, then relocking"
(cd "$hello" && zig fetch --save=clap_release 'git+https://github.com/Hejsil/zig-clap#9cfa61596cd44ef7be35f8d2e108d2025e09868e')
(cd "$hello" && zig-purifier lock) > "$work/out"
grep -q 'wrote .*: 3 downloads' "$work/out" || fail "lock did not lock the new dependency"
"$(build_package "$work/fixtures")/bin/hello" > /dev/null || fail "the package did not build after the new dependency"
cp tests/fixtures/hello/build.zig.zon "$hello/build.zig.zon"
(cd "$hello" && zig-purifier lock) > /dev/null
cmp "$hello/zig-purifier.lock.json" tests/fixtures/hello/zig-purifier.lock.json ||
  fail "removing the dependency again did not restore the lockfile"

echo "== An edited lockfile: the command says to relock"
cp "$hello/zig-purifier.lock.json" "$work/lock.orig"
sed -i '0,/"hash": "sha256-[^"]*"/s//"hash": "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="/' "$hello/zig-purifier.lock.json"
expect_failure 'edited after .*zig-purifier relock' sh -c "cd '$hello' && zig-purifier prefetch"
expect_failure 'edited after .*zig-purifier relock' build_package "$work/fixtures"
cp "$work/lock.orig" "$hello/zig-purifier.lock.json"

echo "== Publishing: the release Nix builds, and what to put in build.zig.zon"
(cd "$hello" && zig-purifier publish v0.0.1 --repo example/hello --dry-run) > "$work/publish"
cat "$work/publish"
grep -q '^would run: gh release create v0.0.1 .*hello-0.0.1.tar.gz' "$work/publish" || fail "publish would upload no archive"
grep -q '^.url = "https://github.com/example/hello/releases/download/v0.0.1/hello-0.0.1.tar.gz",' "$work/publish" ||
  fail "publish printed no URL"
grep -q '^.hash = "hello-0.0.1-' "$work/publish" || fail "publish printed no zig hash"

echo "All zig-purifier CLI tests passed."
