# SPDX-License-Identifier: MIT
"""Unit tests of zig-purifier. The lock tests need `zig` on the PATH."""

import functools
import http.server
import os
import shutil
import subprocess
import tempfile
import threading
import unittest

import zig_purifier
import zon


class ZonTest(unittest.TestCase):
    def test_manifest_of_zig_0_14_and_later(self):
        text = r"""
        // A comment.
        .{
            .name = .hello,
            .version = "0.1.0",
            .fingerprint = 0x3610a686a09531ac, // Another comment.
            .dependencies = .{
                .clap = .{ .url = "https://example.com/c.tar.gz", .hash = "clap-1", .lazy = true },
                .@"with-dash" = .{ .path = "../x" },
            },
            .paths = .{ "build.zig", "src", },
        }
        """
        value = zon.loads(text)
        self.assertEqual(value["name"], "hello")
        self.assertIsInstance(value["name"], zon.EnumLiteral)
        self.assertEqual(value["fingerprint"], 0x3610A686A09531AC)
        self.assertEqual(value["dependencies"]["clap"]["lazy"], True)
        self.assertEqual(value["dependencies"]["with-dash"], {"path": "../x"})
        self.assertEqual(value["paths"], ["build.zig", "src"])

    def test_manifest_of_zig_0_13(self):
        value = zon.loads('.{ .name = "hello", .version = "0.1.0", .paths = .{""} }')
        self.assertEqual(value["name"], "hello")
        self.assertNotIsInstance(value["name"], zon.EnumLiteral)
        self.assertEqual(value["paths"], [""])

    def test_literals(self):
        self.assertEqual(zon.loads(r'"a\n\x41\u{1F600}\""'), 'a\nA\U0001f600"')
        self.assertEqual(zon.loads("'a'"), ord("a"))
        self.assertEqual(zon.loads("-1_000"), -1000)
        self.assertEqual(zon.loads("0b101"), 5)
        self.assertEqual(zon.loads("1.5e2"), 150.0)
        self.assertEqual(zon.loads(".{}"), {})
        self.assertEqual(zon.loads(".{ true, false, null }"), [True, False, None])
        self.assertEqual(zon.loads(".{ .a = .{ 1, 2 } }"), {"a": [1, 2]})

    def test_multiline_string(self):
        value = zon.loads(".{ .s =\n    \\\\first\n    \\\\second\n, }")
        self.assertEqual(value["s"], "first\nsecond")

    def test_errors(self):
        for text in (".{ .a = 1 .b = 2 }", '"open', ".{ .a = 1, .a = 2 }", "1 2"):
            with self.subTest(text=text), self.assertRaises(zon.ZonError):
                zon.loads(text)


class GitUrlTest(unittest.TestCase):
    rev = "a751349695ffda433a5c7d09a09eb49fed465fe6"

    def test_https(self):
        self.assertEqual(
            zig_purifier.parse_git_url(
                f"git+https://example.com/o/r?ref=v1#{self.rev}"
            ),
            ("https://example.com/o/r", self.rev),
        )

    def test_ssh_is_recorded_as_https(self):
        self.assertEqual(
            zig_purifier.parse_git_url(f"git+ssh://git@example.com/o/r.git#{self.rev}"),
            ("https://example.com/o/r.git", self.rev),
        )

    def test_reference_without_commit(self):
        with self.assertRaises(zig_purifier.Failure):
            zig_purifier.parse_git_url("git+https://example.com/o/r#main")


class ArchiveSuffixTest(unittest.TestCase):
    def test_suffix_from_url_and_content(self):
        with tempfile.NamedTemporaryFile() as f:
            f.write(b"\x1f\x8b\x08rest")
            f.flush()
            self.assertEqual(
                zig_purifier.archive_suffix("https://e.com/a.zip", f.name), ".zip"
            )
            self.assertEqual(
                zig_purifier.archive_suffix("https://e.com/archive/abc", f.name),
                ".tar.gz",
            )
            f.seek(0)
            f.write(b"not an archive")
            f.flush()
            with self.assertRaises(zig_purifier.Failure):
                zig_purifier.archive_suffix("https://e.com/x", f.name)


def zon_text(value, indent=""):
    """Writes a dict, list, str, bool or int as ZON."""
    if isinstance(value, dict):
        inner = indent + "    "
        fields = "".join(
            f"{inner}.{k} = {zon_text(v, inner)},\n" for k, v in value.items()
        )
        return ".{\n" + fields + indent + "}"
    if isinstance(value, list):
        return ".{ " + ", ".join(zon_text(v, indent) for v in value) + " }"
    if isinstance(value, zon.EnumLiteral):
        return "." + value
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return hex(value)
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def new_package(directory, dependencies=None, files=None):
    """Makes a package with `zig init --minimal`, which picks a valid fingerprint."""
    os.makedirs(directory)
    subprocess.run(
        ["zig", "init", "--minimal"], cwd=directory, check=True, capture_output=True
    )
    manifest = zon.load(os.path.join(directory, "build.zig.zon"))
    if dependencies:
        manifest["dependencies"] = dependencies
    with open(os.path.join(directory, "build.zig.zon"), "w") as f:
        f.write(zon_text(manifest) + "\n")
    for name, content in (files or {}).items():
        with open(os.path.join(directory, name), "w") as f:
            f.write(content)
    return directory


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format, *args):
        pass


@unittest.skipIf(shutil.which("zig") is None, "needs zig")
class LockTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        # `zig init` and `zig build` need a writable global cache.
        os.environ["ZIG_GLOBAL_CACHE_DIR"] = os.path.join(self.dir, "zig-global")
        self.served = os.path.join(self.dir, "served")
        os.makedirs(self.served)
        handler = functools.partial(QuietHandler, directory=self.served)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        shutil.rmtree(self.dir, ignore_errors=True)

    def publish(self, directory):
        """Serves the release archive of a package; returns its URL and hash."""
        archive, zig_hash = zig_purifier.write_release(
            "zig", directory, os.path.join(self.dir, "out")
        )
        name = os.path.basename(archive)
        shutil.move(archive, os.path.join(self.served, name))
        return f"{self.base}/{name}", zig_hash

    def test_lock_follows_remote_and_path_dependencies(self):
        b_url, b_hash = self.publish(new_package(os.path.join(self.dir, "b")))
        a_url, a_hash = self.publish(
            new_package(
                os.path.join(self.dir, "a"),
                {"b": {"url": b_url, "hash": b_hash, "lazy": True}},
            )
        )
        new_package(os.path.join(self.dir, "local"))
        root = new_package(
            os.path.join(self.dir, "root"),
            {"a": {"url": a_url, "hash": a_hash}, "local": {"path": "../local"}},
        )
        locker = zig_purifier.Locker(root, "zig")
        try:
            lock = locker.lock([], outputs=locker.outputs_here)
        finally:
            locker.close()
        self.assertEqual({a["zigHash"] for a in lock["artifacts"]}, {a_hash, b_hash})
        for artifact in lock["artifacts"]:
            self.assertEqual(artifact["mirrors"], [])
            self.assertTrue(artifact["path"].startswith("archives/"))
            self.assertTrue(artifact["hash"].startswith("sha256-"))
        self.assertEqual(lock["localPackages"], ["../local"])
        self.assertEqual(
            lock["definitionFiles"], ["../local/build.zig.zon", "build.zig.zon"]
        )
        self.assertIn("install", lock["steps"])
        self.assertTrue(zig_purifier.lock_is_fresh(root, lock))
        with open(os.path.join(self.dir, "local", "build.zig.zon"), "a") as f:
            f.write("// changed\n")
        self.assertFalse(zig_purifier.lock_is_fresh(root, lock))

    def test_lock_rejects_a_changed_download(self):
        url, _ = self.publish(new_package(os.path.join(self.dir, "b")))
        _, other_hash = self.publish(new_package(os.path.join(self.dir, "c")))
        root = new_package(
            os.path.join(self.dir, "root"), {"b": {"url": url, "hash": other_hash}}
        )
        locker = zig_purifier.Locker(root, "zig")
        try:
            with self.assertRaisesRegex(zig_purifier.Failure, "something other than"):
                locker.lock([], outputs=locker.outputs_here)
        finally:
            locker.close()

    def test_release_is_reproducible(self):
        package = new_package(os.path.join(self.dir, "p"), files={"extra.txt": "x\n"})
        first, first_hash = zig_purifier.write_release(
            "zig", package, os.path.join(self.dir, "r1")
        )
        second, second_hash = zig_purifier.write_release(
            "zig", package, os.path.join(self.dir, "r2")
        )
        with open(first, "rb") as f1, open(second, "rb") as f2:
            self.assertEqual(f1.read(), f2.read())
        self.assertEqual(first_hash, second_hash)


class LockFileTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.lock = {
            "version": zig_purifier.LOCK_VERSION,
            "artifacts": [{"path": "a", "hash": "h"}],
        }

    def tearDown(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def path(self):
        return os.path.join(self.dir, zig_purifier.LOCK_FILE)

    def test_round_trip(self):
        zig_purifier.write_lock(self.dir, self.lock)
        read = zig_purifier.read_lock(self.dir)
        self.assertEqual(read["artifacts"], self.lock["artifacts"])
        self.assertEqual(read["contentHash"], zig_purifier.content_hash(self.lock))

    def test_edited_hash_names_relock(self):
        zig_purifier.write_lock(self.dir, self.lock)
        with open(self.path()) as f:
            text = f.read().replace('"hash": "h"', '"hash": "x"')
        with open(self.path(), "w") as f:
            f.write(text)
        with self.assertRaisesRegex(
            zig_purifier.Failure, "edited after .*zig-purifier relock"
        ):
            zig_purifier.read_lock(self.dir)

    def test_old_version_names_relock(self):
        zig_purifier.write_lock(self.dir, dict(self.lock, version=1))
        with self.assertRaisesRegex(
            zig_purifier.Failure, "version 1.*zig-purifier relock"
        ):
            zig_purifier.read_lock(self.dir)

    def test_invalid_json_names_relock(self):
        with open(self.path(), "w") as f:
            f.write('{ "version": 2, ')
        with self.assertRaisesRegex(
            zig_purifier.Failure, "not valid JSON.*zig-purifier relock"
        ):
            zig_purifier.read_lock(self.dir)


if __name__ == "__main__":
    unittest.main()
