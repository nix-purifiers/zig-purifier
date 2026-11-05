# zig-purifier

zig-purifier keeps Zig's development workflow on locked,
Nix-resolved dependencies. Use the normal build and test commands in your
working tree; building the project itself in the Nix sandbox is an
optional next step.

## Quickstart

From the project root:

```zsh
nix shell 'github:nix-purifiers/zig-purifier#toolchain-zig_0_15'
zig-purifier lock
zig build
zig build test
```

Commit the lockfiles that the lock command writes, including the build
tool's own lockfile when it has one. Keep using the project's usual build,
test and editor commands with this setup. Nix provides the locked
dependencies; the development commands above run outside the Nix sandbox.
No project Nix files are needed for this workflow.

Choose the toolchain that matches your project; this example uses Zig
0.15. Other toolchain choices are documented below.

Sandboxed builds of the whole project are an optional
[next step](#building-the-project-with-nix).

The shell provides the `zig` wrapper. Use it for the locked
development workflow. With no purifier lockfile, it warns on standard
error and runs the ordinary tool with impure resolution.

For persistent use, add these packages through your usual Nix configuration.


## Development loop

`nix shell 'github:nix-purifiers/zig-purifier#toolchain-zig_0_15'`, or a toolchain package in
your usual environment, puts three programs on the PATH:

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

A flake that keeps the lockfile outside the tree, such as one that builds
a package published by someone else, passes its path to the commands as
`--lockfile PATH`, or sets `ZIG_PURIFIER_LOCKFILE`, which the `zig`
wrapper reads too. Its dev shell can set the variable to the path it
passes to the builder as `lockFile`.

To publish a release, run `zig-purifier publish TAG`. Zig has no package
registry: a package is published as an archive at a URL that others name
in their `build.zig.zon` with the hash `zig fetch` gives it. `publish`
builds the `release` of the package with Nix, uploads the archive to a
GitHub release with `gh release create`, and prints the `.url` and `.hash`
lines to put in a `build.zig.zon`. `--dry-run` prints the commands instead
of running them. The archive holds the files under `paths`, with fixed
owners, modes and times, so the same tree always makes the same bytes.

## Building the project with Nix

Once the native development workflow is working, you can also build and
test the whole project in the Nix sandbox. For this step, keep a flake or
another Nix build definition in the project's repository, or maintain an
external packaging repository that points at its sources and lockfiles.
The builder consumes the same lockfiles as the development workflow.

`packages.hello` is the install step of the package, under the name in
its `build.zig.zon`. The flake's overlay adds one attribute to the package
set, the scope `zig-purifier`, which holds the builder `buildZigProject`
beside the command and the toolchain. Commit `zig-purifier.lock.json`, so
that the build finds it beside `build.zig.zon`.

A package whose authors want a flake can ship one, in the repository of
the package or in another one. The flake applies the overlay and calls the
builder:

```nix
{
  inputs.zig-purifier.url =
    "github:nix-purifiers/zig-purifier";
  inputs.nixpkgs.follows = "zig-purifier/nixpkgs";

  outputs =
    { nixpkgs, zig-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ zig-purifier.overlays.default ];
      };
      hello = pkgs.zig-purifier.buildZigProject {
        src = ./.;
      };
    in
    {
      packages.${system}.default = hello.packages.hello;
      checks.${system}.test = hello.tests;
    };
}
```

`nix build` builds the install step of the package, and `nix flake check`
runs its `test` step.

The builder takes these arguments:

```nix
buildZigProject {
  inherit src; # the package and its path dependencies
  projectDir = "."; # where build.zig.zon is, inside src
  # default: zig-purifier.lock.json beside build.zig.zon
  lockFile = null;
  # fetchurl or fetchgit with credentials or a mirror
  fetchers = { };
  # default: the nixpkgs zig of the locked version
  zig = null;
  # default: the flags the lock recorded
  buildFlags = null;
  checkSteps = [ "test" ];
}
```

`buildZigProject` takes `fetchurl`, `fetchgit`, the zigs and the `cli`
of the scope by name. `zig-purifier.buildZigProject.override` replaces any
of them, and `zig-purifier.overrideScope` replaces what everything in the
scope shares.

Zig has no lockfile of its own, so `buildZigProject`, `readLock` and the
commands take no argument for one. `build.zig.zon` is the manifest of the
package, which the build reads from `src` with the rest of the package.

We recommend committing `zig-purifier.lock.json` to the package's
repository, beside `build.zig.zon`, where the builder and the commands look
for it by default. A flake can instead keep it outside the tree and pass
it as `lockFile`, which the build then uses in place of any copy in `src`.

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

### One-off builds without a project Nix file

For an ad hoc build, the builder can also be evaluated directly from the
project root. Replace the example package name with one from your project:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/zig-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.zig-purifier.buildZigProject { src = ./.; })
.packages.hello'
```

This uses the purifier's pinned nixpkgs, matching the lock command above.
To build with ambient `<nixpkgs>` from your Nix search path instead,
replace `import purifier.inputs.nixpkgs` with `import <nixpkgs>`.
Both forms need no Nix files in your project. The build tool and language
versions must match the lockfile; with ambient nixpkgs, lock with the
purifier from that package set or pass a compatible toolchain to the builder.

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
x86_64-linux, aarch64-linux and aarch64-darwin.

## Examples

For day-to-day work on these projects, use the native-tool setup and
commands in [Quickstart](#quickstart) and [Development loop](#development-loop).
The Nix expressions below show optional sandboxed packaging of those
projects.

[ZLS](https://github.com/zigtools/zls), the Zig language server, builds
with zig 0.15 at its 0.15.1 release. To build it with Nix, lock it in a
checkout of that release:

```zsh
nix shell 'github:nix-purifiers/zig-purifier#toolchain-zig_0_15'
git clone --branch 0.15.1 https://github.com/zigtools/zls
cd zls
zig-purifier lock
```

Then build it from the same directory:

```zsh
nix build --impure --expr 'let
  purifier = builtins.getFlake "github:nix-purifiers/zig-purifier";
  pkgs = import purifier.inputs.nixpkgs {
    system = builtins.currentSystem;
    overlays = [ purifier.overlays.default ];
  };
in
(pkgs.zig-purifier.buildZigProject { src = ./.; }).packages.zls'
./result/bin/zls --version
```

To work on ZLS with the locked packages, open a shell with the toolchain.
The `zig` in it fetches the locked packages before each `zig build`, and
`zig-purifier prefetch` does the same for the editor:

```zsh
nix shell 'github:nix-purifiers/zig-purifier#toolchain-zig_0_15'
zig-purifier prefetch
zig build test
```

## Native library projections

Declare installed shared libraries with `nativeLibraries = {
proof = "lib/libproof.so"; };` on `buildZigProject`. Each path must occur in the
lock's installed-file inventory. For portable packaging, use
`pkgs.stdenv.hostPlatform.extensions.sharedLibrary` for the suffix. Optional
`nativeIncludeDirectories` records installed header directories.

The build result and its package expose `projections.native`, `python-ffi`, and
`java-ffi`, with the shared binary validation, catalog and ctypes/Java loading
interfaces. The catalog retains the selected Zig compiler version and producer
identity. Explicit selection does not establish symbol signatures or convert
Zig's native types to a C ABI; export deliberate C-callable functions and retain
runtime libraries in the producer closure. Static/executable outputs have no
foreign projections unless selected, and the binary check rejects them.

A small shared-library fixture builds through the actual purifier and returns
42 through ordinary Python ctypes and Java FFM. Its platform-specific installed
file inventories are committed source fixture locks, requiring no build during
evaluation. Java 21 uses preview FFM flags; no JNI bindings are generated.

## Core WebAssembly projections

Select a locked installed Wasm output explicitly:

```nix
wasmModules.proof = {
  path = "bin/proof.wasm";
  imports = [ { module = "provider"; name = "base"; kind = "function"; } ];
};
```

The native `build.zig` and locked build flags select the compiler target; for
example `-Dtarget=wasm32-freestanding`. Each selected path must occur in the
installed-file inventory. The result and compiled package expose
`projections.wasm.modules.<name>` and a catalog of actual imports/exports,
byte digests and the pinned validator version. Resource/web/Java-resource views
provide `.directory`, `.documentRoot`, and `.classPath`. The existing native
shared-library selection remains separate.

The shared helper validates core binary modules and matches explicitly declared
import names/kinds; it does not infer function signatures or provide host
imports. The check compiles an actual Zig Wasm target, supplies a native host
function in ordinary Node, observes answer42, rejects a missing provider, and
checks HTTP/Java resource bytes. It does not execute a browser or claim WASI,
component/WIT, generated bindings, npm packaging or other compiler versions.

## Credits

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).

## Development

To work on zig-purifier itself, run `nix flake check` for the checks
that run in the Nix sandbox, and the scripts in `tests/` for the checks
that need the network.

## License

MIT
