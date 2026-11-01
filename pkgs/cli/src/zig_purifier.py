# SPDX-License-Identifier: MIT
"""zig-purifier: Nix as the dependency backend of Zig packages.

Commands for people:

  zig-purifier lock      lock the package in the current directory, when
                         its build.zig.zon files changed since the last lock
  zig-purifier relock    lock it again regardless
  zig-purifier update [NAME...]
                         fetch the named dependencies of build.zig.zon, or
                         all of them, again with `zig fetch --save`, a git
                         dependency at the newest commit of its ref, and
                         lock the result
  zig-purifier prefetch  realize the locked packages and the toolchain, and
                         link the packages where zig and ZLS look for them,
                         so builds and the editor work offline
  zig-purifier zig ...   run zig; `zig build` prefetches first
  zig-purifier publish TAG [--repo OWNER/REPO] [--dry-run]
                         upload the release archive Nix builds to a GitHub
                         release, and print its URL and hash

Commands the Nix library runs as builders:

  zig-purifier materialize ZIG SOURCE HASH
  zig-purifier link-farm
  zig-purifier release ZIG SOURCE
  zig-purifier outputs ZIG FARM SOURCE PROJECT_DIR FLAGS
"""

import base64
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

import zon

LOCK_FILE = "zig-purifier.lock.json"
# A lockfile kept outside the project, from `--lockfile PATH`, or for the
# zig wrapper, whose arguments are zig's, from ZIG_PURIFIER_LOCKFILE.
LOCK_OVERRIDE = os.environ.get("ZIG_PURIFIER_LOCKFILE") or None


def lock_path(project_dir):
    """The lockfile of a project: the one `--lockfile` names, or the one
    beside its build.zig.zon."""
    if LOCK_OVERRIDE:
        return os.path.abspath(LOCK_OVERRIDE)
    return os.path.join(project_dir, LOCK_FILE)


def state_dir(project_dir):
    """`.zig-purifier` beside the lockfile, which holds the GC roots of
    prefetch and the release that publish uploads."""
    return os.path.join(os.path.dirname(lock_path(project_dir)), ".zig-purifier")


LOCK_VERSION = 2
# The Nix library of this command, set by the package that installs it.
NIX_LIB = os.environ.get("ZIG_PURIFIER_NIX_LIB", "")


class Failure(Exception):
    pass


def warn(message):
    print(f"zig-purifier: {message}", file=sys.stderr)


def zig_command():
    return os.environ.get("ZIG_PURIFIER_ZIG") or "zig"


def run(args, **kwargs):
    try:
        return subprocess.run(
            args, check=True, text=True, capture_output=True, **kwargs
        )
    except FileNotFoundError:
        raise Failure(f"{args[0]} is not on the PATH") from None
    except subprocess.CalledProcessError as e:
        raise Failure(f"{' '.join(args)} failed:\n{e.stderr.strip()}") from None


def zig_version(zig):
    return run([zig, "version"]).stdout.strip()


def sri_sha256(data_or_digest):
    return "sha256-" + base64.b64encode(data_or_digest).decode()


# ---------------------------------------------------------------------------
# The definition of a package: its build.zig.zon files.


def manifest_path(package_dir):
    return os.path.join(package_dir, "build.zig.zon")


def read_manifest(package_dir):
    path = manifest_path(package_dir)
    if not os.path.exists(path):
        return None
    manifest = zon.load(path)
    if not isinstance(manifest, dict):
        raise Failure(f"{path} is not a struct literal")
    return manifest


def dependencies(manifest):
    deps = manifest.get("dependencies") or {}
    if not isinstance(deps, dict):
        raise Failure("the dependencies of a build.zig.zon must be a struct literal")
    return deps


def definition_hash(project_dir, files):
    """The hash of the build.zig.zon files the lock was made from.

    nix/lib/lock.nix computes the same hash: for each file, sorted by path,
    its path relative to the project, a newline, its length in bytes, a
    newline, and its contents.
    """
    h = hashlib.sha256()
    for rel in sorted(files):
        with open(os.path.normpath(os.path.join(project_dir, rel)), "rb") as f:
            content = f.read()
        h.update(rel.encode() + b"\n" + str(len(content)).encode() + b"\n" + content)
    return h.hexdigest()


def find_project(start):
    """The nearest directory at or above `start` holding a build.zig.zon."""
    d = os.path.abspath(start)
    while True:
        if os.path.exists(manifest_path(d)):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


# ---------------------------------------------------------------------------
# Downloads.

_ARCHIVE_SUFFIXES = (
    ".tar.gz",
    ".tgz",
    ".tar.xz",
    ".txz",
    ".tar.zst",
    ".tzst",
    ".tar",
    ".zip",
)


def archive_suffix(url, path):
    """The file extension zig needs to unpack a local copy of the archive.

    zig picks the unpacker of a local file by its name, so the lock keeps
    the extension the URL names, or, when it names none, the one the
    content shows.
    """
    url_path = urllib.parse.urlparse(url).path.lower()
    for suffix in _ARCHIVE_SUFFIXES:
        if url_path.endswith(suffix):
            return suffix
    with open(path, "rb") as f:
        head = f.read(512)
    if head.startswith(b"\x1f\x8b"):
        return ".tar.gz"
    if head.startswith(b"\xfd7zXZ\x00"):
        return ".tar.xz"
    if head.startswith(b"\x28\xb5\x2f\xfd"):
        return ".tar.zst"
    if head.startswith(b"PK\x03\x04"):
        return ".zip"
    if head[257:262] == b"ustar":
        return ".tar"
    raise Failure(f"{url} is not an archive zig can unpack")


def download(url, directory):
    """Downloads `url` and returns the local path and its SRI sha256 hash."""
    request = urllib.request.Request(url, headers={"User-Agent": "zig-purifier"})
    digest = hashlib.sha256()
    fd, path = tempfile.mkstemp(dir=directory)
    try:
        with os.fdopen(fd, "wb") as out, urllib.request.urlopen(request) as response:
            while True:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                digest.update(chunk)
                out.write(chunk)
    except OSError as e:
        raise Failure(f"downloading {url} failed: {e}") from None
    suffix = archive_suffix(url, path)
    named = path + suffix
    os.rename(path, named)
    return named, sri_sha256(digest.digest())


def parse_git_url(url):
    """The fetchable URL and commit of a `git+https://host/repo#commit` URL."""
    rest = url[len("git+") :]
    base, _, fragment = rest.partition("#")
    parsed = urllib.parse.urlparse(base)
    if parsed.scheme == "ssh" or (parsed.scheme == "" and "@" in base):
        # The Nix sandbox has no SSH keys. The same repository over HTTPS is
        # what every purifier records; a private repository takes a
        # credentialed fetchgit in the builder.
        host_path = base.split("@", 1)[-1].replace(":", "/", 1).removeprefix("//")
        parsed = urllib.parse.urlparse("https://" + host_path)
    elif parsed.scheme not in ("http", "https"):
        raise Failure(f"{url}: zig fetches git over http and https only")
    clean = urllib.parse.urlunparse(parsed._replace(query="", fragment=""))
    if len(fragment) != 40 or any(c not in "0123456789abcdef" for c in fragment):
        raise Failure(
            f"{url} does not name a commit. Run `zig fetch --save` on it, which "
            "records the commit the reference points to."
        )
    return clean, fragment


def prefetch_git(url, rev):
    out = run(["nix-prefetch-git", "--quiet", "--url", url, "--rev", rev])
    info = json.loads(out.stdout)
    return info["path"], info["hash"]


def zig_hash(zig, work, source):
    """The package hash `zig fetch` reports for a local file or directory.

    Zig 0.16 fetches only inside a project, so the fetch runs in an empty
    project of its own, with a global cache of its own.
    """
    project = os.path.join(work, "project")
    os.makedirs(project, exist_ok=True)
    build_zig = os.path.join(project, "build.zig")
    if not os.path.exists(build_zig):
        with open(build_zig, "w") as f:
            f.write('pub fn build(_: *@import("std").Build) void {}\n')
    out = run(
        [zig, "fetch", source],
        cwd=project,
        env=dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(work, "global")),
    ).stdout.split()
    if not out:
        raise Failure(f"zig fetch printed no hash for {source}")
    return out[-1]


def extract(archive, dest):
    """Extracts a tar (plain, gzip, xz or zstd) or zip archive into `dest`."""
    import tarfile
    import zipfile

    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                path = z.extract(info, dest)
                mode = info.external_attr >> 16
                if not info.is_dir() and mode & 0o111:
                    os.chmod(path, 0o755)
    else:
        with tarfile.open(archive) as t:
            t.extractall(dest, filter="data")


def keeps(paths, rel):
    """Whether a package keeps the file at `rel`, by its manifest's `paths`."""
    if rel == "build.zig.zon" or paths is None or "" in paths:
        return True
    return any(
        rel == p.rstrip("/") or rel.startswith(p.rstrip("/") + "/") for p in paths
    )


def unpack(source, dest, work):
    """Makes the package directory zig makes from a download.

    Zig unpacks an archive, takes its single top-level directory as the
    package when all of the archive lies in one, and keeps the files under
    the `paths` of the package's build.zig.zon. Zig keeps the result under
    a different place in each version (the `p/<hash>` of the global cache
    up to 0.15, the project's `zig-pkg/<hash>` from 0.16), so the package
    is made here, the same for every version, and checked by its hash.
    """
    if os.path.isdir(source):
        root = source
    else:
        raw = os.path.join(work, "raw")
        shutil.rmtree(raw, ignore_errors=True)
        extract(source, raw)
        root = raw
        entries = os.listdir(root)
        if len(entries) == 1 and os.path.isdir(os.path.join(root, entries[0])):
            root = os.path.join(root, entries[0])
    manifest = read_manifest(root)
    paths = (
        list(manifest.get("paths"))
        if manifest and manifest.get("paths") is not None
        else None
    )
    for directory, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if not (directory == root and d == ".git")]
        for name in names:
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root)
            if not keeps(paths, rel):
                continue
            target = os.path.join(dest, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            if os.path.islink(path):
                os.symlink(os.readlink(path), target)
            else:
                shutil.copyfile(path, target)
                os.chmod(target, 0o755 if os.access(path, os.X_OK) else 0o644)
    os.makedirs(dest, exist_ok=True)


def materialize(zig, source, expected, dest, work):
    """Unpacks a download into `dest` and checks it is the package `expected`."""
    unpack(source, dest, work)
    actual = zig_hash(zig, os.path.join(work, "hash"), dest)
    if actual != expected:
        raise Failure(
            f"{source} unpacks to the zig package {actual}, but {expected} is expected"
        )


def project_packages(zig):
    """Whether the zig reads packages from the project's zig-pkg (0.16 on)."""
    parts = zig_version(zig).split(".")
    return (int(parts[0]), int(parts[1].split("-")[0])) >= (0, 16)


def use_packages(farm, project, global_cache, in_project=True, in_global=True):
    """Makes the packages of `farm` (a directory of packages by hash)
    visible to a zig build of `project` with ZIG_GLOBAL_CACHE_DIR set to
    `global_cache`.

    Zig up to 0.15 looks for a package at `p/<hash>` in the global cache,
    and zig 0.16 and later at `zig-pkg/<hash>` in the project, so each
    gets a link to each package when asked. Packages already there stay as
    they are, and zig can still add packages of its own beside the links.
    """
    directories = []
    if in_global:
        directories.append(os.path.join(global_cache, "p"))
    if in_project:
        directories.append(os.path.join(project, "zig-pkg"))
    for directory in directories:
        os.makedirs(directory, exist_ok=True)
        for package_hash in os.listdir(farm):
            link = os.path.join(directory, package_hash)
            if os.path.islink(link):
                os.remove(link)
            if not os.path.exists(link):
                # The package itself, so the link does not depend on the
                # farm staying where it is.
                os.symlink(os.path.realpath(os.path.join(farm, package_hash)), link)


# ---------------------------------------------------------------------------
# Locking.


class Locker:
    def __init__(self, project_dir, zig):
        self.project_dir = os.path.abspath(project_dir)
        self.zig = zig
        self.work = tempfile.mkdtemp(prefix="zig-purifier-")
        self.downloads = os.path.join(self.work, "downloads")
        os.makedirs(self.downloads)
        self.artifacts = {}
        # The unpacked package of each locked download, by hash.
        self.packages = {}
        self.definition_files = set()
        self.local_packages = set()

    def close(self):
        shutil.rmtree(self.work, ignore_errors=True)

    def relative(self, path):
        return os.path.relpath(path, self.project_dir)

    def walk_local(self, package_dir, manifest, seen):
        """Locks the dependencies of a package, following path dependencies."""
        key = os.path.realpath(package_dir)
        if key in seen:
            return
        seen.add(key)
        for name, dep in dependencies(manifest).items():
            if not isinstance(dep, dict):
                raise Failure(
                    f"dependency {name} of {manifest_path(package_dir)} is not a struct"
                )
            if "path" in dep:
                sub = os.path.normpath(os.path.join(package_dir, dep["path"]))
                sub_manifest = read_manifest(sub)
                if sub_manifest is None:
                    continue
                if self.is_project_file(sub):
                    self.local_packages.add(self.relative(sub))
                    self.definition_files.add(self.relative(manifest_path(sub)))
                self.walk_local(sub, sub_manifest, seen)
            elif "url" in dep:
                if "hash" not in dep:
                    raise Failure(
                        f"dependency {name} of {manifest_path(package_dir)} has no hash. "
                        "Run `zig build --fetch` once to add it, or `zig fetch --save` its URL."
                    )
                self.lock_remote(name, dep["url"], dep["hash"], seen)
            else:
                raise Failure(
                    f"dependency {name} of {manifest_path(package_dir)} has neither url nor path"
                )

    def is_project_file(self, path):
        # A path dependency inside a fetched package belongs to that package,
        # and the lock of the package covers it.
        return not os.path.realpath(path).startswith(
            os.path.realpath(self.work) + os.sep
        )

    def lock_remote(self, name, url, expected, seen):
        if expected in self.artifacts:
            return
        if url.startswith("file:"):
            raise Failure(
                f"dependency {name} is a file: URL, which names a path on one "
                "machine. Use a `.path` dependency inside the project instead."
            )
        if url.startswith("git+"):
            repo, rev = parse_git_url(url)
            source, nar_hash = prefetch_git(repo, rev)
            entry = {
                "path": f"git/{expected}",
                # Zig's git fetcher checks out no submodules and keeps no
                # .git, so neither does the entry.
                "git": {
                    "url": repo,
                    "rev": rev,
                    "submodules": False,
                    "leaveDotGit": False,
                    "commitObject": None,
                },
                "hash": nar_hash,
            }
        else:
            source, file_hash = download(url, self.downloads)
            suffix = next(s for s in _ARCHIVE_SUFFIXES if source.endswith(s))
            entry = {
                "path": f"archives/{expected}{suffix}",
                "url": url,
                "mirrors": [],
                "hash": file_hash,
            }
        package_dir = os.path.join(self.work, "packages", expected)
        try:
            materialize(
                self.zig,
                source,
                expected,
                package_dir,
                os.path.join(self.work, "materialize"),
            )
        except Failure as e:
            raise Failure(
                f"dependency {name} ({url}): {e}. The URL serves something other than "
                "the package build.zig.zon names."
            ) from None
        entry["zigHash"] = expected
        self.artifacts[expected] = entry
        self.packages[expected] = package_dir
        manifest = read_manifest(package_dir)
        if manifest is not None:
            self.walk_local(package_dir, manifest, seen)

    def source_top(self):
        """The directory holding the project and all its path dependencies."""
        dirs = [self.project_dir] + [
            os.path.normpath(os.path.join(self.project_dir, p))
            for p in self.local_packages
        ]
        return os.path.commonpath(dirs)

    def outputs_in_sandbox(self, partial_lock):
        """Builds nix/lib/outputs.nix, which runs the build in the sandbox."""
        cli = os.environ.get("ZIG_PURIFIER_CLI")
        if not cli:
            raise Failure(
                "ZIG_PURIFIER_CLI is not set; run zig-purifier as the package installs it"
            )
        partial_path = os.path.join(self.work, "partial.lock.json")
        with open(partial_path, "w") as f:
            json.dump(dict(partial_lock, contentHash=content_hash(partial_lock)), f)
        top = self.source_top()
        out = subprocess.run(
            [
                "nix-build",
                os.path.join(NIX_LIB, "outputs.nix"),
                "--argstr",
                "lockFile",
                partial_path,
                "--argstr",
                "srcPath",
                top,
                "--argstr",
                "projectDir",
                os.path.relpath(self.project_dir, top),
                "--argstr",
                "cli",
                cli,
                "--argstr",
                "zig",
                os.path.realpath(shutil.which(self.zig) or self.zig),
                "--no-out-link",
            ],
            text=True,
            stdout=subprocess.PIPE,
            check=False,
        )
        if out.returncode != 0:
            raise Failure(
                "building the package in the Nix sandbox with the locked dependencies "
                "failed; the log above says why"
            )
        with open(out.stdout.strip()) as f:
            return json.load(f)

    def outputs_here(self, partial_lock):
        """Runs the build in a copy of the tree, outside the sandbox.

        Only the unit tests use this, inside a Nix build of their own.
        """
        top = self.source_top()
        farm = os.path.join(self.work, "farm")
        os.makedirs(farm)
        for package_hash, package_dir in self.packages.items():
            os.symlink(package_dir, os.path.join(farm, package_hash))
        return build_outputs(
            self.zig,
            farm,
            top,
            os.path.relpath(self.project_dir, top),
            partial_lock["buildFlags"],
            self.work,
        )

    def lock(self, build_flags, outputs=None):
        manifest = read_manifest(self.project_dir)
        if manifest is None:
            raise Failure(f"no build.zig.zon in {self.project_dir}")
        self.definition_files.add("build.zig.zon")
        self.walk_local(self.project_dir, manifest, set())
        lock = {
            "version": LOCK_VERSION,
            "zigVersion": zig_version(self.zig),
            "name": str(manifest.get("name", "")),
            "packageVersion": str(manifest.get("version", "")),
            "buildFlags": build_flags,
            "steps": [],
            "installed": [],
            "definitionFiles": sorted(self.definition_files),
            "definitionHash": definition_hash(self.project_dir, self.definition_files),
            "localPackages": sorted(self.local_packages),
            "artifacts": [self.artifacts[k] for k in sorted(self.artifacts)],
        }
        found = (outputs or self.outputs_in_sandbox)(lock)
        lock["steps"] = found["steps"]
        lock["installed"] = found["installed"]
        return lock


def build_outputs(zig, farm, src, project_dir, build_flags, work):
    """The steps of a build, and the files its install step installs.

    Builds in a copy of `src`, with the packages of `farm` where zig looks
    for them, as the Nix build does.
    """
    tree = os.path.join(work, "tree")
    shutil.copytree(
        src,
        tree,
        symlinks=True,
        ignore=shutil.ignore_patterns(
            ".git", ".zig-cache", "zig-out", "zig-pkg", ".zig-purifier"
        ),
    )
    for directory, _dirs, _names in os.walk(tree):
        os.chmod(directory, 0o755)
    project = os.path.join(tree, project_dir)
    global_cache = os.path.join(work, "build-global")
    use_packages(farm, project, global_cache)
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=global_cache, HOME=work)
    prefix = os.path.join(work, "prefix")
    listing = run([zig, "build", "-l"] + build_flags, cwd=project, env=env)
    steps = []
    for line in listing.stdout.splitlines():
        parts = line.split(None, 1)
        if line.startswith("  ") and parts:
            steps.append(parts[0])
    run(
        [zig, "build", "install", "--prefix", prefix] + build_flags,
        cwd=project,
        env=env,
    )
    installed = []
    for root, _dirs, names in os.walk(prefix):
        installed.extend(os.path.relpath(os.path.join(root, n), prefix) for n in names)
    return {"steps": sorted(steps), "installed": sorted(installed)}


def content_hash(lock):
    """The hash a lockfile records of its own content.

    It is the sha256 of the lockfile without `contentHash`, written as
    Nix's builtins.toJSON writes it: keys sorted, no spaces. nix/lib/lock.nix
    computes the same hash, so an edit to the lockfile fails in the command
    and at Nix evaluation alike.
    """
    content = {k: v for k, v in lock.items() if k != "contentHash"}
    text = json.dumps(
        content, sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )
    return hashlib.sha256(text.encode()).hexdigest()


def write_lock(project_dir, lock):
    lock = dict(lock, contentHash=content_hash(lock))
    path = lock_path(project_dir)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(lock, f, indent=2)
        f.write("\n")
    return path


def read_lock(project_dir):
    path = lock_path(project_dir)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as f:
        try:
            lock = json.load(f)
        except ValueError as e:
            raise Failure(
                f"{path} is not valid JSON ({e}). Run `zig-purifier relock` to write it again."
            ) from None
    if not isinstance(lock, dict) or not isinstance(lock.get("artifacts"), list):
        raise Failure(
            f"{path} is not a zig-purifier lockfile. Run `zig-purifier relock` to write it again."
        )
    if lock.get("version") != LOCK_VERSION:
        raise Failure(
            f"{path} has lock format version {lock.get('version')}, and this zig-purifier "
            f"reads version {LOCK_VERSION}. Run `zig-purifier relock` to write it again."
        )
    if lock.get("contentHash") != content_hash(lock):
        raise Failure(
            f"{path} was edited after `zig-purifier lock` wrote it. "
            "Run `zig-purifier relock` to write it again."
        )
    return lock


def lock_is_fresh(project_dir, lock):
    try:
        return (
            lock.get("version") == LOCK_VERSION
            and definition_hash(project_dir, lock["definitionFiles"])
            == lock["definitionHash"]
        )
    except (OSError, KeyError):
        return False


# The flags of every `zig build` the lock run and the Nix build make, unless
# the lock names others: a release build for the baseline CPU, so the
# binaries run on every machine of the architecture.
DEFAULT_BUILD_FLAGS = ["--release=safe", "-Dcpu=baseline"]


def command_lock(args, force):
    """`lock [DIR] [-- FLAGS...]`: FLAGS replace the recorded build flags."""
    if "--" in args:
        split = args.index("--")
        args, flags = args[:split], args[split + 1 :]
    else:
        flags = None
    project_dir = find_project(args[0] if args else ".")
    if project_dir is None:
        raise Failure("no build.zig.zon here or in a parent directory")
    try:
        current = read_lock(project_dir)
        recorded_flags = (current or {}).get("buildFlags")
    except Failure:
        # A lockfile the command cannot use is what a relock replaces; its
        # build flags still count when it can be read at all.
        current = None
        try:
            with open(lock_path(project_dir), encoding="utf-8") as f:
                recorded_flags = json.load(f).get("buildFlags")
        except (OSError, ValueError, AttributeError):
            recorded_flags = None
    if flags is None:
        flags = recorded_flags or DEFAULT_BUILD_FLAGS
    elif current is not None and current.get("buildFlags") != flags:
        force = True
    if not force and current is not None and lock_is_fresh(project_dir, current):
        print(f"{lock_path(project_dir)} is up to date")
        return
    locker = Locker(project_dir, zig_command())
    try:
        lock = locker.lock(flags)
    finally:
        locker.close()
    path = write_lock(project_dir, lock)
    print(f"wrote {path}: {len(lock['artifacts'])} downloads")


def update_url(url):
    """The URL `zig fetch --save` resolves again for a dependency's URL.

    `zig fetch --save` records a git dependency fetched at a ref as
    `git+https://host/repo?ref=REF#COMMIT`. Fetching `git+https://host/repo#REF`
    resolves REF again; a git URL without a ref resolves the default branch.
    An archive URL is fetched as it stands, which gives a new hash when what
    the server holds there changed.
    """
    if not url.startswith("git+"):
        return url
    base = url.partition("#")[0]
    parsed = urllib.parse.urlparse(base)
    ref = urllib.parse.parse_qs(parsed.query).get("ref", [None])[0]
    base = urllib.parse.urlunparse(parsed._replace(query=""))
    return f"{base}#{ref}" if ref else base


def command_update(args):
    """`update [NAME...]`: fetches the dependencies of the package's
    build.zig.zon again, then locks. Dependencies of dependencies are pinned
    by the build.zig.zon of the package that names them, so only the
    package's own dependencies move."""
    project_dir = find_project(".")
    if project_dir is None:
        raise Failure("no build.zig.zon here or in a parent directory")
    deps = {
        name: dep["url"]
        for name, dep in dependencies(read_manifest(project_dir)).items()
        if isinstance(dep, dict) and "url" in dep
    }
    unknown = [name for name in args if name not in deps]
    if unknown:
        raise Failure(
            f"build.zig.zon has no dependency fetched from a URL named {', '.join(unknown)}"
        )
    zig = zig_command()
    for name in args or sorted(deps):
        run([zig, "fetch", f"--save={name}", update_url(deps[name])], cwd=project_dir)
        url = dependencies(read_manifest(project_dir))[name]["url"]
        print(f"{name}: {url}" if url != deps[name] else f"{name}: unchanged")
    command_lock([project_dir], force=False)


# ---------------------------------------------------------------------------
# Interactive mode.


def realize(project_dir, zig):
    """Builds the package cache of the lockfile; returns its path."""
    state = state_dir(project_dir)
    os.makedirs(state, exist_ok=True)
    packages = os.path.join(state, "packages")
    with open(lock_path(project_dir), "rb") as f:
        lock_hash = hashlib.sha256(f.read()).hexdigest()
    marker = os.path.join(state, "lock.sha256")
    try:
        with open(marker) as f:
            current = f.read().strip() == lock_hash and os.path.exists(packages)
    except OSError:
        current = False
    if not current:
        # The command as installed, which the package builds run as their
        # builder, so they are the derivations a sandboxed build makes.
        cli = os.environ.get("ZIG_PURIFIER_CLI")
        if not cli:
            raise Failure(
                "ZIG_PURIFIER_CLI is not set; run zig-purifier as the package installs it"
            )
        subprocess.run(
            [
                "nix-build",
                os.path.join(NIX_LIB, "realize.nix"),
                "--argstr",
                "lockFile",
                lock_path(project_dir),
                "--argstr",
                "cli",
                cli,
                "--argstr",
                "zig",
                os.path.realpath(shutil.which(zig) or zig),
                "--out-link",
                packages,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        with open(marker, "w") as f:
            f.write(lock_hash + "\n")
    return packages


def global_cache_dir(zig):
    """The global cache every zig uses by default, which `zig env` reports."""
    if os.environ.get("ZIG_GLOBAL_CACHE_DIR"):
        return os.environ["ZIG_GLOBAL_CACHE_DIR"]
    text = run([zig, "env"]).stdout
    try:
        env = json.loads(text)
    except ValueError:
        env = zon.loads(text)
    return env["global_cache_dir"]


def stale_message(project_dir):
    return (
        f"the build.zig.zon files of {project_dir} changed since {lock_path(project_dir)} was "
        "written, so the build needs downloads the lock does not hold. "
        "Run `zig-purifier lock`."
    )


def prefetch(project_dir, zig, quiet=False):
    """Realizes what working on a project needs, and links it where zig
    and ZLS look.

    It builds every locked package into the store, with a GC root at
    `.zig-purifier/packages` beside the lockfile, and the toolchain the command runs
    from (zig and the ZLS of the same version), with a GC root at
    `.zig-purifier/toolchain`. Zig up to 0.15 looks for a
    package at `p/<hash>` in its global cache, and zig 0.16 and later at
    `zig-pkg/<hash>` in the project. A package is named by the hash of its
    contents, so a link there is the package whatever else uses the cache,
    and `zig build`, `zig fetch` and ZLS find it without the network.
    """
    lock = read_lock(project_dir)
    if lock is None:
        raise Failure(
            f"no {lock_path(project_dir)} for {project_dir}. Run `zig-purifier lock`."
        )
    if not lock_is_fresh(project_dir, lock):
        raise Failure(stale_message(project_dir))
    packages = realize(project_dir, zig)
    toolchain = os.environ.get("ZIG_PURIFIER_TOOLCHAIN")
    if toolchain:
        root = os.path.join(state_dir(project_dir), "toolchain")
        run(["nix-store", "--realise", toolchain, "--add-root", root])
    if project_packages(zig):
        use_packages(packages, project_dir, None, in_project=True, in_global=False)
    else:
        use_packages(packages, project_dir, global_cache_dir(zig), in_project=False)
    if not quiet:
        print(f"prefetched {len(lock['artifacts'])} locked packages for {project_dir}")


def command_prefetch(args):
    project_dir = find_project(args[0] if args else ".")
    if project_dir is None:
        raise Failure("no build.zig.zon here or in a parent directory")
    prefetch(project_dir, zig_command())


def command_zig(args):
    """Runs zig. In a project with a lockfile, `zig build` runs with the
    locked packages, and stops when the lock is stale, because the build
    would need downloads the lock does not hold. Every other zig command,
    such as `zig fetch --save`, which adds a dependency, runs as it is."""
    zig = zig_command()
    project_dir = find_project(".")
    if (
        project_dir is not None
        and os.environ.get("ZIG_PURIFIER") != "0"
        and args[:1] == ["build"]
    ):
        lock = read_lock(project_dir)
        if lock is not None:
            if not lock_is_fresh(project_dir, lock):
                raise Failure(stale_message(project_dir))
            prefetch(project_dir, zig, quiet=True)
    os.execvp(zig, [zig] + args)


# ---------------------------------------------------------------------------
# Releases.


def package_files(project_dir, paths):
    """The files of the package: those under the `paths` of build.zig.zon."""
    files = []
    for entry in paths or [""]:
        top = os.path.normpath(os.path.join(project_dir, entry))
        if os.path.isfile(top):
            files.append(os.path.relpath(top, project_dir))
        elif os.path.isdir(top):
            for root, dirs, names in os.walk(top):
                dirs[:] = [
                    d
                    for d in dirs
                    if not (
                        root == project_dir
                        and d in (".zig-cache", "zig-out", "zig-pkg", ".zig-purifier")
                    )
                ]
                files.extend(
                    os.path.relpath(os.path.join(root, n), project_dir) for n in names
                )
    return sorted(set(files))


def write_release(zig, project_dir, out_dir):
    """Writes the release archive of a package and the hash zig gives it.

    The archive holds the files under the `paths` of build.zig.zon in one
    directory named for the package, with fixed owners, modes and times,
    so the same tree always makes the same bytes.
    """
    import gzip
    import tarfile

    manifest = read_manifest(project_dir) or {}
    name = str(manifest.get("name", "package"))
    version = str(manifest.get("version", "0.0.0"))
    top = f"{name}-{version}"
    os.makedirs(out_dir, exist_ok=True)
    archive = os.path.join(out_dir, f"{top}.tar.gz")
    with (
        open(archive, "wb") as raw,
        gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as gz,
        tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar,
    ):
        for rel in package_files(project_dir, manifest.get("paths")):
            path = os.path.join(project_dir, rel)
            info = tar.gettarinfo(path, arcname=f"{top}/{rel}")
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = 0
            if info.isfile():
                info.mode = 0o755 if os.access(path, os.X_OK) else 0o644
                with open(path, "rb") as f:
                    tar.addfile(info, f)
            else:
                tar.addfile(info)
    work = tempfile.mkdtemp(prefix="zig-purifier-")
    try:
        archive_hash = zig_hash(zig, os.path.join(work, "a"), archive)
        tree_hash = zig_hash(zig, os.path.join(work, "t"), project_dir)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    if archive_hash != tree_hash:
        raise Failure(
            f"the release archive hashes to {archive_hash}, but the package tree to {tree_hash}"
        )
    with open(os.path.join(out_dir, "zig-hash"), "w") as f:
        f.write(archive_hash + "\n")
    return archive, archive_hash


def build_release(project_dir, zig):
    """Builds the release archive with Nix; returns the archive and its hash."""
    cli = os.environ.get("ZIG_PURIFIER_CLI")
    if not cli:
        raise Failure(
            "ZIG_PURIFIER_CLI is not set; run zig-purifier as the package installs it"
        )
    out = run(
        [
            "nix-build",
            os.path.join(NIX_LIB, "release.nix"),
            "--argstr",
            "srcPath",
            project_dir,
            "--argstr",
            "cli",
            cli,
            "--argstr",
            "zig",
            os.path.realpath(shutil.which(zig) or zig),
            "--out-link",
            os.path.join(state_dir(project_dir), "release"),
        ]
    ).stdout.strip()
    archives = [n for n in os.listdir(out) if n.endswith(".tar.gz")]
    with open(os.path.join(out, "zig-hash")) as f:
        return os.path.join(out, archives[0]), f.read().strip()


def command_publish(args):
    """`publish TAG [--repo OWNER/REPO] [--dry-run]`.

    Zig has no package registry: a package is published as an archive at
    a URL, which others name in their build.zig.zon with the hash zig
    gives the archive. This uploads the release archive that Nix built to
    the GitHub release TAG, and prints the URL and the hash to use.
    """
    dry_run = "--dry-run" in args
    args = [a for a in args if a != "--dry-run"]
    repo = None
    if "--repo" in args:
        i = args.index("--repo")
        repo = args[i + 1]
        args = args[:i] + args[i + 2 :]
    if len(args) != 1:
        raise Failure("usage: zig-purifier publish TAG [--repo OWNER/REPO] [--dry-run]")
    tag = args[0]
    project_dir = find_project(".")
    if project_dir is None:
        raise Failure("no build.zig.zon here or in a parent directory")
    archive, archive_hash = build_release(project_dir, zig_command())
    if repo is None:
        repo = run(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            cwd=project_dir,
        ).stdout.strip()
    url = (
        f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(archive)}"
    )
    command = [
        "gh",
        "release",
        "create",
        tag,
        archive,
        "--repo",
        repo,
        "--title",
        tag,
        "--notes",
        f"zig fetch hash: {archive_hash}",
    ]
    if dry_run:
        print("would run: " + " ".join(command))
    else:
        run(command)
    print(f'.url = "{url}",')
    print(f'.hash = "{archive_hash}",')


def command_outputs(args):
    """The builder of nix/lib/outputs.nix: ZIG FARM SRC PROJECT_DIR FLAGS."""
    zig, farm, src, project_dir, flags = args
    work = os.path.join(os.environ.get("TMPDIR") or tempfile.mkdtemp(), "outputs")
    os.makedirs(work)
    found = build_outputs(zig, farm, src, project_dir, json.loads(flags), work)
    with open(os.environ["out"], "w") as f:
        json.dump(found, f)


def command_release(args):
    """The builder of the release archive: ZIG SOURCE, written to $out."""
    zig, source = args
    write_release(zig, source, os.environ["out"])


# ---------------------------------------------------------------------------
# Builders.


def command_materialize(args):
    """Unpacks one locked download into a zig package directory at $out."""
    zig, source, expected = args
    work = os.path.join(os.environ.get("TMPDIR") or tempfile.mkdtemp(), "materialize")
    materialize(zig, source, expected, os.environ["out"], work)


def command_link_farm(args):
    """Links each package of the manifest at $out/<hash>."""
    out = os.environ["out"]
    os.mkdir(out)
    with open(os.environ["manifestPath"]) as f:
        for line in f:
            line = line.rstrip("\n")
            if line:
                name, target = line.split("\t")
                os.symlink(target, os.path.join(out, name))


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__.strip())
        return 0
    global LOCK_OVERRIDE
    command, args = argv[0], argv[1:]
    if command != "zig" and "--lockfile" in args:
        i = args.index("--lockfile")
        if i + 1 >= len(args):
            warn("--lockfile needs a path")
            return 2
        LOCK_OVERRIDE = args[i + 1]
        args = args[:i] + args[i + 2 :]
    try:
        if command == "lock":
            command_lock(args, force=False)
        elif command == "relock":
            command_lock(args, force=True)
        elif command == "update":
            command_update(args)
        elif command == "zig":
            command_zig(args)
        elif command == "prefetch":
            command_prefetch(args)
        elif command == "publish":
            command_publish(args)
        elif command == "materialize":
            command_materialize(args)
        elif command == "link-farm":
            command_link_farm(args)
        elif command == "release":
            command_release(args)
        elif command == "outputs":
            command_outputs(args)
        else:
            warn(f"unknown command {command}; see `zig-purifier help`")
            return 2
    except Failure as e:
        warn(str(e))
        return 1
    except zon.ZonError as e:
        warn(f"cannot read {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
