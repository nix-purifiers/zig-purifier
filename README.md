# zig-purifier

zig-purifier makes Nix the dependency backend of Zig packages. Zig has no
lockfile of its own: `build.zig.zon` names each direct dependency by URL
and hash, and the dependencies of those live in their own `build.zig.zon`
files. `zig-purifier lock` records every package a build needs, directly
or through other packages, in `zig-purifier.lock.json`, so that Nix can
build the package in its sandbox. You commit the lockfile, and the Nix
build reads it as it stands.

zig-purifier is one of the [nix-purifiers](https://nix-purifiers.github.io),
which share a contract: the same builder arguments, commands, checks and
README sections in every ecosystem.

## Quickstart

In a Zig package (a directory with a `build.zig.zon`), lock it with the
toolchain of the zig it builds with:

```zsh
nix run 'github:nix-purifiers/zig-purifier#toolchain-zig_0_15' -- lock
```

The toolchains are `toolchain-zig_0_14`, `toolchain-zig_0_15`,
`toolchain-zig_0_16`, and `toolchain` for the default zig of nixpkgs
(0.17). The lock records the zig version, and the build uses the same one.

Commit `zig-purifier.lock.json`. The flake's overlay adds the builder
`buildZigProject` to the package set, and a package for `callPackage`
takes it by name:

```nix
# package.nix
{ buildZigProject }:
(buildZigProject { src = ./.; }).packages.hello
```

```nix
# flake.nix
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
    in
    {
      packages.${system}.default = pkgs.callPackage ./package.nix { };
      checks.${system}.test = (pkgs.buildZigProject { src = ./.; }).tests;
    };
}
```

`nix build` builds the install step of the package, and `nix flake check`
runs its `test` step.

The builder takes these arguments:

```nix
buildZigProject {
  src;                   # the package and its path dependencies
  projectDir = ".";      # where build.zig.zon is, inside src
  lockFile = null;       # default: zig-purifier.lock.json beside build.zig.zon
  fetchers = { };        # fetchurl or fetchgit with credentials or a mirror
  zig = null;            # default: the nixpkgs zig of the locked version
  buildFlags = null;     # default: the flags the lock recorded
  checkSteps = [ "test" ];
}
```

`buildZigProject` takes `fetchurl`, `fetchgit`, the zigs and the
zig-purifier package scope from the package set by name, and
`buildZigProject.override` replaces any of them.

Its result is an attribute set, and every name in it is known when Nix
evaluates the build, without building it:

| Attribute | What it is |
|---|---|
| `packages.<name>` | `zig build install --prefix $out`, under the name in `build.zig.zon` |
| `tests` | the `checkSteps` of `build.zig`, run in the sandbox |
| `release` | the release archive that `zig-purifier publish` uploads, and in `zig-hash` the hash `zig fetch` gives it |
| `fetches` | the download entries of the lock, in the format of the [purifier](https://github.com/nix-purifiers/purifier) library |
| `files."bin/hello"` | each file the install step installs, by its path under the prefix |
| `executables.hello` | each file under `bin/`, by its name |
| `steps.<step>` | each other step of `build.zig`, as a build that runs it |
| `dependencies` | each dependency, unpacked as zig unpacks it, by its zig hash |
| `lock` | the lock as `readLock` reads it |

`lib.zig-purifier.readLock { src, projectDir ? ".", lockFile ? null }`
reads a lockfile into the shape every purifier shares,
`{ purifier, entries, outputs, problems }`, which SBOM, license and
vulnerability tools can read. `problems` lists what makes the lockfile
unusable, each with the command that fixes it.

Every `zig build` uses the build flags the lock recorded, by default
`--release=safe -Dcpu=baseline`, a release build for the baseline CPU of
the architecture. `zig-purifier lock -- FLAGS` records other flags. The
lock decides the installed files with the same flags, so the attributes
match what the build installs.

## Development loop

`nix develop github:nix-purifiers/zig-purifier`, or a toolchain package in
your own dev shell, puts three programs on the PATH:

- `zig`, which runs `zig-purifier prefetch` before each `zig build`, and
  passes every other command to zig unchanged;
- `zig-purifier`;
- `zls`, the Zig language server of the same zig version.

Zig has no plugin mechanism, so zig-purifier is a command of its own,
and the `zig` of the toolchain is a wrapper that runs it before
`zig build`.

You work with zig's own commands. `zig build`, `zig build test` and
`zig build run` use the locked packages. To add a dependency, run
`zig fetch --save <url>` as usual, then `zig-purifier lock`. Until you
lock, `zig build` stops with a message naming `zig-purifier lock`.

To move dependencies to newer versions, run `zig-purifier update`, or
`zig-purifier update NAME...` for some of them. Zig has no command that
updates dependencies, so `update` fetches each dependency of
`build.zig.zon` again with `zig fetch --save`, which records the new URL
and hash there, and then locks. A git dependency moves to the newest commit of the ref it was
fetched at, which `zig fetch --save` records as `?ref=` in its URL. A git
dependency without a ref moves to the newest commit of its default
branch, and an archive URL is fetched again as it stands. Dependencies of
dependencies are pinned by the `build.zig.zon` of the package that names
them, so they move only when that package does. `zig-purifier lock`
leaves `build.zig.zon` as it is.

To keep the lockfile outside the project, as for a package whose
`build.zig.zon` belongs to someone else, pass `--lockfile PATH` to the
commands, or set `ZIG_PURIFIER_LOCKFILE` (which the `zig` wrapper reads
too), and pass the same path to the builder as `lockFile`.

To publish a release, run `zig-purifier publish TAG`. Zig has no package
registry: a package is published as an archive at a URL that others name
in their `build.zig.zon` with the hash `zig fetch` gives it. `publish`
builds the `release` of the package with Nix, uploads the archive to a
GitHub release with `gh release create`, and prints the `.url` and `.hash`
lines to put in a `build.zig.zon`. `--dry-run` prints the commands instead
of running them. The archive holds the files under `paths`, with fixed
owners, modes and times, so the same tree always makes the same bytes.

## Working offline

`zig-purifier prefetch` builds every locked package in the Nix store and
links each where zig looks for it: at `p/<hash>` in the global cache for
zig up to 0.15 (`zig env` names that directory), and at `zig-pkg/<hash>`
in the project for zig 0.16 and later. A link is the package itself, since
zig names a package by the hash of its contents. `prefetch` also realizes
the toolchain. After it, `zig build`, its tests and the editor work with
the network cut off.

`prefetch` keeps the packages and the toolchain alive with GC roots in
`.zig-purifier/` beside the lockfile. Deleting that directory lets
`nix-collect-garbage` remove them, and the next `prefetch` fetches them
again.

## Editor

The toolchains include ZLS. After a `prefetch`, ZLS finds every package
where zig would, also offline, so go-to-definition on an `@import` of a
dependency opens the locked package. Point the editor at the `zls` of the
toolchain, so it matches the zig version of the lock.

## Troubleshooting

Each of these fails in the command and in the Nix evaluation, with a
message that names the command to run:

| Problem | Message | Fix |
|---|---|---|
| `build.zig.zon` changed since the lock | "the build.zig.zon files … changed since … was written" | `zig-purifier lock` |
| no lockfile | "there is no …zig-purifier.lock.json" | `zig-purifier lock` |
| a lockfile edited by hand | "… was edited after `zig-purifier lock` wrote it" | `zig-purifier relock` |
| a lockfile that is not valid, such as one with merge conflict markers | "… is not a valid lockfile" | `zig-purifier relock` |
| a lockfile of an older format | "… has lock format version …" | `zig-purifier relock` |
| a dependency missing from the lock | "zig tried to fetch a package that … does not hold" | `zig-purifier lock` |
| a path dependency outside `src` | "the path dependency … lies outside `src`" | make `src` a directory that holds it, and set `projectDir` |

## Supported language repositories

| Dependency in `build.zig.zon` | Recorded as |
|---|---|
| `.url` of an archive (`.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar`, `.zip`) | a file entry `{ path, url, mirrors, hash }` |
| `.url` of `git+https://…#<commit>` | a git entry `{ path, git = { url, rev, submodules = false, leaveDotGit = false, commitObject = null }, hash }` |
| `.url` of `git+ssh://…#<commit>` | a git entry for the same repository over HTTPS |
| `.path` | part of `src`; its `build.zig.zon` counts toward the freshness of the lock |
| `.lazy = true` | locked like any other, so every build option builds offline |

The [purifier](https://github.com/nix-purifiers/purifier) library, which
the nix-purifiers share, fetches the entries. A git entry holds the files
of the commit, as zig's git fetcher checks them out: the files git tracks
in that commit, without the contents of submodules or a `.git` directory. The Nix build fetches git over HTTPS,
so an SSH dependency is recorded as the same repository over HTTPS. For a
private repository or a company mirror, pass `fetchers.fetchgit` or
`fetchers.fetchurl` with credentials to the builder.

The lock takes a dependency inside the project as a `.path` dependency,
and a git dependency at a commit, as `zig fetch --save` records it. A
`file:` URL or a git URL whose fragment names a branch or tag stops the
lock with a message that names the form to use.

The lock run downloads and unpacks the packages itself, and checks that
`zig fetch` gives each one the hash `build.zig.zon` names. The build code
of the package runs in the Nix sandbox: the last step of the lock run
records the steps and installed files by building the package there with
the locked packages alone, so a missing dependency fails the lock rather
than a later build.

The lock and the build work with zig 0.14, 0.15, 0.16 and 0.17, the
versions nixpkgs provides. The flake provides its toolchains for
x86_64-linux and aarch64-linux.

## Examples

[ZLS](https://github.com/zigtools/zls), the Zig language server, builds
with zig 0.15 at its 0.15.1 release. To build it with Nix, lock it in a
checkout of that release:

```zsh
git clone --branch 0.15.1 https://github.com/zigtools/zls
cd zls
nix run 'github:nix-purifiers/zig-purifier#toolchain-zig_0_15' -- lock
```

Then add a `package.nix` and a `flake.nix` beside its `build.zig.zon`:

```nix
# package.nix
{ buildZigProject }:
(buildZigProject { src = ./.; }).packages.zls
```

```nix
# flake.nix
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
    in
    {
      packages.${system}.default = pkgs.callPackage ./package.nix { };
      devShells.${system}.default = pkgs.mkShell {
        packages = [ zig-purifier.packages.${system}.toolchain-zig_0_15 ];
      };
    };
}
```

Nix reads a flake in a git repository from the files git tracks, so add
the new files, then build:

```zsh
git add package.nix flake.nix zig-purifier.lock.json
nix build
./result/bin/zls --version
```

`nix develop` then gives the `zig` and `zls` of the toolchain, and
`zig build` in that shell uses the locked packages.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo), and zig-purifier
follows the design of
[sbt-purifier](https://github.com/nix-purifiers/sbt-purifier).

## Development

To work on zig-purifier itself, run `nix flake check` for the checks
that run in the Nix sandbox, and the scripts in `tests/` for the checks
that need the network.

## License

MIT
