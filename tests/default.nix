# SPDX-License-Identifier: MIT
#
# The flake's checks: builds of the fixture from its lockfile, each run,
# its installed files and steps, its release archive, the unit tests of
# the zig-purifier command, and the refusals of the Nix library.
# tests/interactive.sh covers interactive mode and the lock run, which run
# Nix and need the network, so they cannot run in the sandbox.
{ pkgs, overlay }:
let
  pkgs' = pkgs.extend overlay;
  inherit (pkgs') lib runCommand buildZigProject;

  # The hello fixture: zig-clap from an archive, zig-clap from git as a lazy
  # dependency, and the greeting package as a path dependency outside its
  # directory.
  hello = buildZigProject {
    src = ./fixtures;
    projectDir = "hello";
    doCheck = true;
  };
  # A package locked with zig 0.17, which reads packages from the project's
  # zig-pkg rather than the global cache.
  readme = buildZigProject {
    src = ./fixtures;
    projectDir = "readme";
  };
  # The same package built with the lazy git dependency.
  helloGitClap = buildZigProject {
    src = ./fixtures;
    projectDir = "hello";
    buildFlags = hello.lock.buildFlags ++ [ "-Dgit-clap=true" ];
  };

  # ZLS, the Zig language server, at its 0.15.1 release: a real project with
  # four archive dependencies, one of them lazy. Its lockfile is kept here,
  # beside tests/projects/zls/pin.sh, which tests/relock.sh relocks from.
  zls = buildZigProject {
    src = pkgs'.fetchgit {
      url = "https://github.com/zigtools/zls";
      rev = "f91b2e1e305e5d5bd3725aea90f9f9bfb3dce055";
      hash = "sha256-6IkRtQkn+qUHDz00QvCV/rb2yuF6xWEXug41CD8LLw8=";
    };
    lockFile = ./projects/zls/zig-purifier.lock.json;
  };

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

  fails = expression: !(builtins.tryEval (builtins.deepSeq expression expression)).success;

  lockWithVersion =
    version:
    builtins.toFile "zig-purifier.lock.json" (
      builtins.toJSON {
        inherit version;
        zigVersion = "0.15.2";
        artifacts = [ ];
      }
    );
in
{
  cli = pkgs'.zig-purifier.cli;

  fixture-hello = prints "fixture-hello" "${hello.executables.hello} --name Nix" "Hello, Nix!";
  fixture-hello-default-name =
    prints "fixture-hello-default-name" (lib.getExe' hello.package "hello")
      "Hello, world!";
  fixture-hello-git-clap =
    prints "fixture-hello-git-clap" "${helloGitClap.executables.hello} -n git"
      "Hello, git!";

  project-zls = prints "project-zls" "${zls.executables.zls} --version" "0.15.1";

  fixture-readme = runCommand "fixture-readme" { } ''
    grep -q clap ${readme.files."share/clap-README.md"}
    touch $out
  '';

  # The installed files are known from the lockfile, without building.
  fixture-hello-files = runCommand "fixture-hello-files" { } ''
    test "${builtins.concatStringsSep " " (builtins.attrNames hello.files)}" = "bin/hello lib/libgreeting.a"
    head -c 8 ${hello.files."lib/libgreeting.a"} | grep -q '!<arch>'
    touch $out
  '';
  fixture-hello-step-test = hello.steps.test;
  fixture-hello-step-run = hello.steps.run;

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
  fixture-hello-packages = runCommand "fixture-hello-packages" { } ''
    ${lib.concatStrings (
      lib.mapAttrsToList (hash: package: ''
        test -e ${hello.cache}/${hash}/build.zig.zon
        test "$(readlink -f ${hello.cache}/${hash})" = ${package}
      '') hello.packages
    )}
    touch $out
  '';

  # A lockfile older than its build.zig.zon files, a path dependency
  # outside `src`, and an unknown lockfile version are refused.
  library-refusals =
    assert fails (
      (buildZigProject {
        src = ./fixtures;
        projectDir = "stale";
      }).package.drvPath
    );
    assert fails (buildZigProject { src = ./fixtures/hello; }).package.drvPath;
    assert fails (import ../nix/lib/lock.nix { lockFile = lockWithVersion 2; }).artifacts;
    assert !fails (import ../nix/lib/lock.nix { lockFile = lockWithVersion 1; }).artifacts;
    runCommand "library-refusals" { } "touch $out";
}
