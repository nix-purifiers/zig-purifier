# SPDX-License-Identifier: MIT
"""Asks ZLS for the definition of an @import, as an editor would.

Usage: python3 lsp_client.py ZLS ZIG PROJECT FILE LINE COLUMN

LINE and COLUMN count from 0. Prints the definition ZLS gives, as JSON, or
"no definition" when it gives none within two minutes. ZLS keeps its
configuration and cache in `editor-home` beside PROJECT.
"""

import json
import os
import subprocess
import sys
import time

zls, zig, project, file, line, column = sys.argv[1:]
uri = "file://" + os.path.join(project, file)
state = os.path.join(os.path.dirname(project), "editor-home")
env = dict(os.environ, XDG_CONFIG_HOME=state, XDG_CACHE_HOME=state, XDG_DATA_HOME=state)
proc = subprocess.Popen(
    [zls], stdin=subprocess.PIPE, stdout=subprocess.PIPE, cwd=project, env=env
)


def send(message):
    body = json.dumps(message).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()


def receive():
    length = 0
    while True:
        header = proc.stdout.readline().decode().strip()
        if not header:
            break
        if header.lower().startswith("content-length:"):
            length = int(header.split(":")[1])
    return json.loads(proc.stdout.read(length))


def request(id, method, params):
    send({"jsonrpc": "2.0", "id": id, "method": method, "params": params})
    while True:
        message = receive()
        if message.get("id") == id and "method" not in message:
            return message
        if message.get("method") == "workspace/configuration":
            send(
                {
                    "jsonrpc": "2.0",
                    "id": message["id"],
                    "result": [None] * len(message["params"]["items"]),
                }
            )
        elif "id" in message and "method" in message:
            send({"jsonrpc": "2.0", "id": message["id"], "result": None})


request(
    1,
    "initialize",
    {
        "processId": os.getpid(),
        "rootUri": "file://" + project,
        "capabilities": {},
        "initializationOptions": {"zig_exe_path": zig, "enable_build_on_save": False},
    },
)
send({"jsonrpc": "2.0", "method": "initialized", "params": {}})
with open(os.path.join(project, file)) as f:
    text = f.read()
send(
    {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "zig",
                "version": 1,
                "text": text,
            }
        },
    }
)
# ZLS resolves the packages of build.zig in the background, with the zig
# build runner; ask until it has.
for attempt in range(60):
    result = request(
        10 + attempt,
        "textDocument/definition",
        {
            "textDocument": {"uri": uri},
            "position": {"line": int(line), "character": int(column)},
        },
    )["result"]
    if result:
        print(json.dumps(result, indent=2))
        break
    time.sleep(2)
else:
    print("no definition")
proc.kill()
