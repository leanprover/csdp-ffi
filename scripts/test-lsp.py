#!/usr/bin/env python3
"""Open the downstream CSDP probe through `lake serve` and check diagnostics."""

from __future__ import annotations

import json
import queue
import subprocess
import threading
from pathlib import Path


REPO = Path(__file__).resolve().parent.parent
CONSUMER = REPO / "tests" / "downstream"
SOURCE = CONSUMER / "DownstreamTest.lean"


def send(process: subprocess.Popen[bytes], message: dict[str, object]) -> None:
    body = json.dumps(message, separators=(",", ":")).encode()
    assert process.stdin is not None
    process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
    process.stdin.flush()


def read_messages(process: subprocess.Popen[bytes], out: queue.Queue[object]) -> None:
    assert process.stdout is not None
    try:
        while True:
            headers: dict[str, str] = {}
            while True:
                line = process.stdout.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n"):
                    break
                key, value = line.decode().split(":", 1)
                headers[key.lower()] = value.strip()
            length = int(headers["content-length"])
            out.put(json.loads(process.stdout.read(length)))
    except BaseException as error:
        out.put(error)


def main() -> None:
    process = subprocess.Popen(
        ["lake", "serve"],
        cwd=CONSUMER,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    messages: queue.Queue[object] = queue.Queue()
    threading.Thread(
        target=read_messages, args=(process, messages), daemon=True
    ).start()
    uri = SOURCE.as_uri()
    send(
        process,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "processId": None,
                "rootUri": CONSUMER.as_uri(),
                "capabilities": {},
            },
        },
    )
    while True:
        message = messages.get(timeout=30)
        if isinstance(message, BaseException):
            raise message
        if isinstance(message, dict) and message.get("id") == 1:
            break
    send(process, {"jsonrpc": "2.0", "method": "initialized", "params": {}})
    send(
        process,
        {
            "jsonrpc": "2.0",
            "method": "textDocument/didOpen",
            "params": {
                "textDocument": {
                    "uri": uri,
                    "languageId": "lean4",
                    "version": 1,
                    "text": SOURCE.read_text(),
                }
            },
        },
    )
    while True:
        message = messages.get(timeout=30)
        if isinstance(message, BaseException):
            raise message
        if not isinstance(message, dict):
            continue
        if message.get("method") != "textDocument/publishDiagnostics":
            continue
        params = message.get("params", {})
        if params.get("uri") != uri:
            continue
        errors = [
            item
            for item in params.get("diagnostics", [])
            if item.get("severity", 1) == 1
        ]
        if errors:
            raise RuntimeError(f"lake serve reported errors: {errors}")
        break
    send(process, {"jsonrpc": "2.0", "id": 2, "method": "shutdown"})
    send(process, {"jsonrpc": "2.0", "method": "exit"})
    try:
        return_code = process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        return_code = process.wait(timeout=5)
    if return_code != 0:
        assert process.stderr is not None
        raise RuntimeError(process.stderr.read().decode(errors="replace"))
    print("PASS: lake serve loaded CSDP and reported no downstream errors.")


if __name__ == "__main__":
    main()
