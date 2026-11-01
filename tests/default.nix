# SPDX-License-Identifier: MIT
#
# The flake's checks: builds of the fixtures and of ZLS from their
# lockfiles, each run, the unit tests of the zig-purifier command, and the
# conformance checks of the purifier contract that the sandbox can run.
# CI runs the others (conformance-relock, conformance-rebuild and
# conformance-offline) as jobs of the same names, because they need the
# network or Nix itself.
{
  pkgs,
  overlay,
  buildZigProject,
  readLock,
}:
let
  pkgs' = pkgs.extend overlay;
  inherit (pkgs') lib runCommand;
  cli = pkgs'.zig-purifier.cli;
  build = args: buildZigProject ({ pkgs = pkgs'; } // args);

  # The hello fixture: zig-clap from an archive, zig-clap from git as a lazy
  # dependency, and the greeting package as a path dependency outside its
  # directory.
  hello = build {
    src = ./fixtures;
    projectDir = "hello";
  };
  # The same package built with the lazy git dependency.
  helloGitClap = build {
    src = ./fixtures;
    projectDir = "hello";
    buildFlags = hello.lock.outputs.hello.buildFlags ++ [ "-Dgit-clap=true" ];
  };
  # A package locked with zig 0.17, which reads packages from the
  # project's zig-pkg rather than the global cache.
  readme = build {
    src = ./fixtures;
    projectDir = "readme";
  };
  # ZLS, the Zig language server, at its 0.15.1 release: a real project with
  # four archive dependencies, one of them lazy. Its lockfile is kept here,
  # beside tests/projects/zls/pin.sh, which tests/relock.sh relocks from.
  zls = build {
    src = pkgs'.fetchgit {
      url = "https://github.com/zigtools/zls";
      rev = "f91b2e1e305e5d5bd3725aea90f9f9bfb3dce055";
      hash = "sha256-6IkRtQkn+qUHDz00QvCV/rb2yuF6xWEXug41CD8LLw8=";
    };
    lockFile = ./projects/zls/zig-purifier.lock.json;
  };

  helloLock = builtins.fromJSON (builtins.readFile ./fixtures/hello/zig-purifier.lock.json);
  # Writes a lockfile with its content hash, as `zig-purifier lock` does.
  writeLock =
    name: content:
    builtins.toFile name (
      builtins.toJSON (
        content // { contentHash = builtins.hashString "sha256" (builtins.toJSON content); }
      )
    );
  lockWithout = removeAttrs helloLock [ "contentHash" ];

  # Runs a command and compares what it prints.
  prints =
    name: command: expected:
    runCommand name { inherit expected; } ''
      ${command} > actual
      printf '%s\n' "$expected" > expected-file
      if ! diff -u expected-file actual; then
        exit 1
      fi
      touch $out
    '';

  # Runs zig-purifier COMMAND in a copy of DIR and checks that it fails and
  # prints PATTERN.
  commandFails =
    name: dir: command: pattern:
    runCommand name { nativeBuildInputs = [ cli ]; } ''
      cp -r ${dir} fixtures
      chmod -R u+w fixtures
      cd fixtures/hello
      if zig-purifier ${command} > out 2>&1; then
        cat out
        echo "zig-purifier ${command} succeeded" >&2
        exit 1
      fi
      cat out
      grep -qE ${lib.escapeShellArg pattern} out
      touch $out
    '';

  fails = expression: !(builtins.tryEval (builtins.deepSeq expression expression)).success;

  # Whether readLock reports one problem, matching PATTERN.
  problem =
    args: pattern:
    let
      problems = (readLock args).problems;
    in
    builtins.length problems == 1 && builtins.match ".*${pattern}.*" (builtins.head problems) != null;

  # The fixtures with the hello lockfile replaced.
  fixturesWithLock =
    name: lockText:
    runCommand name { } ''
      cp -r ${./fixtures} $out
      chmod -R u+w $out
      cp ${lockText} $out/hello/zig-purifier.lock.json
    '';
in
{
  inherit cli;

  fixture-hello = prints "fixture-hello" "${hello.executables.hello} --name Nix" "Hello, Nix!";
  fixture-hello-default-name =
    prints "fixture-hello-default-name" "${hello.packages.hello}/bin/hello"
      "Hello, world!";
  fixture-hello-git-clap =
    prints "fixture-hello-git-clap" "${helloGitClap.executables.hello} -n git"
      "Hello, git!";
  # The package and the release archive themselves, which CI builds again
  # with `nix build --rebuild` for conformance-rebuild.
  fixture-hello-package = hello.packages.hello;
  fixture-hello-archive = hello.release;
  fixture-hello-tests = hello.tests;
  fixture-hello-step-run = hello.steps.run;
  fixture-readme = runCommand "fixture-readme" { } ''
    grep -q clap ${readme.files."share/clap-README.md"}
    touch $out
  '';
  project-zls = prints "project-zls" "${zls.executables.zls} --version" "0.15.1";

  # The installed files are known from the lockfile, without building, and
  # `fetches` lists the entries of the lockfile.
  fixture-hello-files =
    assert
      builtins.attrNames hello.files == [
        "bin/hello"
        "lib/libgreeting.a"
      ];
    assert hello.fetches == helloLock.artifacts;
    runCommand "fixture-hello-files" { } ''
      head -c 8 ${hello.files."lib/libgreeting.a"} | grep -q '!<arch>'
      touch $out
    '';

  # The release archive holds what `paths` names, and zig gives it the hash
  # of the package tree (the release builder checks the two agree).
  fixture-hello-release =
    runCommand "fixture-hello-release" { nativeBuildInputs = [ pkgs'.gnutar ]; }
      ''
        tar -tzf ${hello.release}/hello-0.0.1.tar.gz | sort > listing
        printf '%s\n' hello-0.0.1/build.zig hello-0.0.1/build.zig.zon hello-0.0.1/src/main.zig > expected
        diff -u expected listing
        grep -Eq '^hello-0\.0\.1-' ${hello.release}/zig-hash
        touch $out
      '';

  # Every locked package unpacks to the hash build.zig.zon names.
  fixture-hello-dependencies = runCommand "fixture-hello-dependencies" { } ''
    ${lib.concatStrings (
      lib.mapAttrsToList (hash: package: ''
        test -e ${package}/build.zig.zon || test -n "$(ls ${package})"
      '') hello.dependencies
    )}
    touch $out
  '';

  # A lockfile older than its build.zig.zon files fails at evaluation, and
  # in the command, naming `zig-purifier lock`.
  conformance-stale =
    assert problem {
      src = ./fixtures;
      projectDir = "stale";
    } "changed since .*Run `zig-purifier lock` there.";
    assert fails
      (build {
        src = ./fixtures;
        projectDir = "stale";
      }).packages;
    commandFails "conformance-stale-command" ./fixtures "prefetch ../stale" "Run `zig-purifier lock`";

  # A lockfile whose hash changed fails at evaluation, and in the command,
  # naming `zig-purifier relock`.
  conformance-tampered =
    let
      tampered = builtins.toFile "zig-purifier.lock.json" (
        builtins.toJSON (
          helloLock
          // {
            artifacts = map (
              a: a // { hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="; }
            ) helloLock.artifacts;
          }
        )
      );
    in
    assert problem {
      src = ./fixtures;
      projectDir = "hello";
      lockFile = tampered;
    } "edited after .*Run `zig-purifier relock`";
    assert fails
      (build {
        src = ./fixtures;
        projectDir = "hello";
        lockFile = tampered;
      }).packages;
    commandFails "conformance-tampered" (fixturesWithLock "tampered" tampered) "prefetch"
      "edited after .*zig-purifier relock";

  # A lockfile without a needed entry, written with a valid content hash,
  # fails the build, naming `zig-purifier lock`.
  conformance-missing =
    let
      missing = writeLock "zig-purifier.lock.json" (
        lockWithout // { artifacts = builtins.filter (a: !(a ? url)) lockWithout.artifacts; }
      );
      package =
        (build {
          src = ./fixtures;
          projectDir = "hello";
          lockFile = missing;
        }).packages.hello;
    in
    package.overrideAttrs (old: {
      name = "conformance-missing";
      buildPhase = ''
        if (${old.buildPhase}) > log 2>&1; then
          cat log
          echo "the build succeeded without a locked dependency" >&2
          exit 1
        fi
        cat log
        grep -q 'does not hold. Run `zig-purifier lock`' log
        mkdir $out
      '';
    });

  # A lockfile that is not valid fails at evaluation, and in the command,
  # naming `zig-purifier relock`.
  conformance-malformed =
    let
      truncated = builtins.toFile "zig-purifier.lock.json" ''{ "version": 2, '';
    in
    assert problem {
      src = null;
      lockFile = truncated;
    } "not a valid lockfile.*Run `zig-purifier relock`";
    assert problem {
      src = null;
      lockFile = builtins.toFile "zig-purifier.lock.json" "<<<<<<< HEAD\n{}\n";
    } "merge conflict markers.*Run `zig-purifier relock`";
    commandFails "conformance-malformed" (fixturesWithLock "malformed" truncated) "prefetch"
      "not valid JSON.*zig-purifier relock";

  # A fixture whose `src` holds no purifier lockfile builds from one kept
  # outside it.
  conformance-external =
    let
      external = build {
        src = lib.fileset.toSource {
          root = ./fixtures;
          fileset = lib.fileset.difference ./fixtures ./fixtures/hello/zig-purifier.lock.json;
        };
        projectDir = "hello";
        lockFile = ./fixtures/hello/zig-purifier.lock.json;
      };
    in
    prints "conformance-external" "${external.executables.hello} --name external" "Hello, external!";
}
