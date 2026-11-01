#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# conformance-update: `zig-purifier update` moves the outdated fixture's
# dependency, pinned to a commit before its ref, to the commit the ref
# names, and leaves build.zig.zon and the purifier lockfile both passing
# the stale check. Needs the network, so CI runs it as a job.
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$PWD

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

toolchain=$(nix build --no-link --print-out-paths '.#toolchain-zig_0_15')
export PATH="$toolchain/bin:$PATH"

work=$(mktemp -d)
trap 'chmod -R u+w "$work"; rm -rf "$work"' EXIT
export ZIG_GLOBAL_CACHE_DIR=$work/zig-global
cp -r tests/fixtures/outdated "$work/outdated"
chmod -R u+w "$work/outdated"

(cd "$work/outdated" && zig-purifier update clap)

# The tag 0.11.0 of zig-clap is the commit 5289e07.
grep -q '?ref=0.11.0#5289e0753cd274d65344bef1c114284c633536ea"' "$work/outdated/build.zig.zon" ||
  fail "update did not move clap to the commit of its ref"
grep -q '"rev": "5289e0753cd274d65344bef1c114284c633536ea"' "$work/outdated/zig-purifier.lock.json" ||
  fail "update did not lock the new commit"

# The stale check passes for both: zig accepts build.zig.zon offline with
# the packages prefetch links, and readLock reports no problems.
(cd "$work/outdated" && zig-purifier lock) | grep -q 'is up to date' || fail "the lockfile is stale after update"
(cd "$work/outdated" && zig-purifier prefetch)
(cd "$work/outdated" && https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 zig build test)
problems=$(nix eval --impure --json --expr "
  (builtins.getFlake \"git+file://$repo\").lib.zig-purifier.readLock {
    src = /. + \"$work/outdated\";
  }" --apply 'lock: lock.problems')
[ "$problems" = "[]" ] || fail "readLock reports $problems"

echo "conformance-update passed."
