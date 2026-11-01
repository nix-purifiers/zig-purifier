# zig-purifier

zig-purifier makes Nix the dependency backend of Zig packages. It records
every package a `build.zig.zon` needs, directly or through other packages,
in a lockfile, so that Nix can build the package in its sandbox. You
commit the lockfile and no generated Nix files.

- **`zig-purifier lock`** walks the `build.zig.zon` of the package, of its
  path dependencies and of every fetched package, lazy dependencies
  included. It records each download in `zig-purifier.lock.json` with a
  Nix hash beside the hash zig gives it. It then builds the package in the
  Nix sandbox with those downloads alone, and records the build's steps and
  the files its install step installs.
- **`buildZigProject`** builds the package from the lockfile in the Nix
  sandbox, offline, and gives each installed file and each step its own
  attribute, all known when Nix evaluates the build.
- **`zig-purifier sync`** links the locked packages where `zig` and ZLS look
  for them, so `zig build` and your editor work without the network.

## Quickstart

In a Zig package (a directory with a `build.zig.zon`):

```zsh
nix run 'github:nix-purifiers/zig-purifier#toolchain-zig_0_15' -- lock
```

Use the toolchain of the zig your package builds with:
`toolchain-zig_0_14`, `toolchain-zig_0_15`, `toolchain-zig_0_16`, or
`toolchain` for the default zig of nixpkgs (0.17). The lock records the
zig version, and the build uses the same one.

Commit `zig-purifier.lock.json`. Then build the package with the flake's
overlay:

```nix
{
  inputs.zig-purifier.url = "github:nix-purifiers/zig-purifier";
  inputs.nixpkgs.follows = "zig-purifier/nixpkgs";

  outputs = { nixpkgs, zig-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ zig-purifier.overlays.default ];
      };
      hello = pkgs.buildZigProject { src = ./.; };
    in
    {
      packages.${system} = {
        default = hello.package;
        # The release archive, with the hash `zig fetch` gives it.
        release = hello.release;
      };
      checks.${system}.test = hello.steps.test;
    };
}
```

`nix build` builds the install step of the package, and `nix flake check`
runs its `test` step.

## What `buildZigProject` gives

```nix
buildZigProject {
  src = ./.;           # the package and its path dependencies
  projectDir = ".";    # where build.zig.zon is, inside src
  lockFile = null;     # default: zig-purifier.lock.json beside build.zig.zon
  zig = null;          # default: the nixpkgs zig of the locked version
  buildFlags = null;   # default: the flags the lock recorded
  doCheck = false;     # whether `package` also runs checkSteps
  checkSteps = [ "test" ];
  fetchurl = pkgs.fetchurl;   # replace for credentials or mirrors
  fetchgit = pkgs.fetchgit;   # replace for private repositories
}
```

The result is an attribute set:

| Attribute | What it is |
|---|---|
| `package` | `zig build install --prefix $out` |
| `files."bin/hello"` | each file the install step installs, by its path under the prefix |
| `executables.hello` | each file under `bin/`, by its name |
| `steps.test` | each other step of `build.zig`, as a build that runs it |
| `release` | the release archive of the package, and in `zig-hash` the hash `zig fetch` gives it |
| `packages` | each dependency, unpacked as zig unpacks it, by its zig hash |
| `cache` | those packages linked by hash |
| `lock` | the lockfile |

Every `zig build` uses the build flags the lock recorded, by default
`--release=safe -Dcpu=baseline`, a release build for the baseline CPU of
the architecture. `zig-purifier lock -- FLAGS` records others, and the
lock decides the installed files with the same flags, so the attributes
match what the build installs.

## Working on the package

`nix develop github:nix-purifiers/zig-purifier` (or one of the toolchains
above, in your own devShell) gives a `zig` that runs `zig-purifier sync`
before each command. With a current lockfile, the locked packages are then
where zig looks for them, and `zig build`, `zig build test` and
`zig build run` need no network.

- **Your editor.** Run `zig-purifier sync` once after a lock. ZLS then
  finds every package where zig would, also offline. Zig up to 0.15 looks
  for a package at `p/<hash>` in its global cache (`zig env` names it), and
  zig 0.16 and later at `zig-pkg/<hash>` in the project. `sync` links each
  locked package there, and a link is the package itself, since zig names
  a package by the hash of its contents.
- **Adding or upgrading a dependency.** Use `zig fetch --save <url>` as
  usual, then `zig-purifier lock`. Until you relock, the wrapper warns that
  the lock is stale and zig fetches the usual way.
- **The GC root.** `sync` keeps the packages alive with one GC root at
  `.zig-cache/zig-purifier/packages`. Deleting `.zig-cache` lets
  `nix-collect-garbage` remove them, and the next `sync` fetches them again.

## What the lock covers

| Dependency | Recorded as |
|---|---|
| `.url` of an archive (`.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar`, `.zip`) | a file entry `{ path, url, mirrors, hash }` |
| `.url` of `git+https://…#<commit>` | a git entry `{ path, git = { url, rev, submodules = false, leaveDotGit = false, commitObject = null }, hash }` |
| `.url` of `git+ssh://…#<commit>` | a git entry for the same repository over HTTPS |
| `.path` | part of `src`; its `build.zig.zon` counts toward the lock's freshness |
| `.lazy = true` | locked like any other, so every build option builds offline |

Zig's git fetcher checks out no submodules and keeps no `.git`, so a git
entry never asks for either. The Nix sandbox has no SSH keys, so an SSH
dependency is recorded over HTTPS. For a private repository, pass a
`fetchgit` that carries credentials.

A `file:` URL names a path on one machine, so the lock refuses it and
asks for a `.path` dependency inside the project. A git URL whose fragment
names a branch or tag instead of a commit is refused too, because the lock
could not reproduce it. `zig fetch --save` always writes the commit.

The lock run downloads and unpacks the packages itself, and checks that
`zig fetch` gives each the hash `build.zig.zon` names. It runs no build
code of the package outside the sandbox. Its last step, which records the
steps and installed files, builds the package in the Nix sandbox with the
locked packages alone, so a missing dependency fails the lock and not a
later build.

## Common mistakes

| Mistake | What you see |
|---|---|
| `build.zig.zon` changed since the lock | the wrapper warns and zig fetches the usual way; `buildZigProject` stops with "changed since … Run `zig-purifier lock` there." |
| a dependency missing from the lock | the Nix build fails with "zig tried to fetch a package that … does not hold. Run `zig-purifier relock`" |
| a hand-edited hash | the fetch fails with Nix's hash mismatch, naming the entry |
| a lockfile that is not valid JSON | the command says so and to run `zig-purifier relock` |
| a path dependency outside `src` | `buildZigProject` says to make `src` hold it and set `projectDir` |

## Releasing a package

Zig has no package registry. A package is published by putting an archive
at a URL that others name in their `build.zig.zon`, with the hash
`zig fetch` gives the archive. `zig-purifier package` writes that archive
to `zig-out/release` and prints its hash, and `release` builds it in Nix.
The archive holds the files under `paths`, in one directory, with fixed
owners, modes and times, so the same tree always makes the same bytes, and
the command checks that zig gives the archive the hash of the package
tree.

## Zig versions

The lock and the build work with zig 0.14, 0.15, 0.16 and 0.17, the
versions nixpkgs provides. The tests build a package with zig 0.15 and
another with zig 0.17.

## Tried on real projects

- [ZLS](https://github.com/zigtools/zls), the Zig language server, at its
  0.15.1 release (`f91b2e1e`), with zig 0.15: four archive dependencies,
  one of them lazy. CI builds it from the lockfile in `tests/projects/zls`.

## Development

`nix flake check` builds the fixtures and ZLS from their lockfiles, the
command with its unit tests, and the formatting. `tests/cli.sh` drives the
command as a developer does, and `tests/relock.sh` relocks every lockfile,
which CI then compares with the committed ones.

## Credit

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), and zig-purifier
follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).

## License

MIT
