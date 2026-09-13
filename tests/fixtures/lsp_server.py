#!/usr/bin/env python3
"""Small stdio LSP test server with deterministic discovery responses."""

from __future__ import annotations

import json
import sys
import time
from typing import Any


def read_exact(size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sys.stdin.buffer.read(size - len(chunks))
        if not chunk:
            raise EOFError
        chunks.extend(chunk)
    return bytes(chunks)


def read_message() -> dict[str, Any]:
    headers: dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            raise EOFError
        if line in (b"\r\n", b"\n"):
            break
        key, _, value = line.partition(b":")
        headers[key.decode("ascii").lower()] = value.decode("ascii").strip()
    body = read_exact(int(headers["content-length"]))
    return json.loads(body)


def send_message(message: dict[str, Any]) -> None:
    body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(body)
    sys.stdout.buffer.flush()


def response(message_id: int, result: Any = None, error: dict[str, Any] | None = None) -> None:
    payload: dict[str, Any] = {"jsonrpc": "2.0", "id": message_id}
    if error is not None:
        payload["error"] = error
    else:
        payload["result"] = result
    send_message(payload)


def serve() -> int:
    while True:
        try:
            message = read_message()
        except EOFError:
            return 0

        method = message.get("method")
        message_id = message.get("id")
        params = message.get("params") or {}
        if method == "textDocument/didOpen":
            uri = params.get("textDocument", {}).get("uri", "")
            if uri.endswith("/diagnostic.lua"):
                send_message({
                    "jsonrpc": "2.0",
                    "method": "textDocument/publishDiagnostics",
                    "params": {
                        "uri": uri,
                        "diagnostics": [{
                            "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
                            "severity": 2,
                            "code": "fake-detach",
                            "source": "fake-client",
                            "message": "diagnostic must disappear on detach",
                        }],
                    },
                })
            continue
        if method == "exit":
            return 0
        if message_id is None:
            continue
        if method == "initialize":
            response(
                message_id,
                {
                    "capabilities": {
                        "textDocumentSync": 1,
                        "documentSymbolProvider": True,
                        "definitionProvider": True,
                        "referencesProvider": True,
                        "workspaceSymbolProvider": True,
                    },
                    "serverInfo": {"name": "workbench-test-lsp", "version": "1"},
                },
            )
        elif method == "shutdown":
            response(message_id)
        elif method == "textDocument/documentSymbol":
            response(
                message_id,
                [
                    {
                        "name": "FakeRoot",
                        "kind": 5,
                        "detail": "fake server",
                        "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
                        "selectionRange": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
                        "children": [
                            {
                                "name": "FakeChild",
                                "kind": 12,
                                "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}},
                                "selectionRange": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 3}},
                            }
                        ],
                    }
                ],
            )
        elif method == "textDocument/definition":
            uri = params.get("textDocument", {}).get("uri", "")
            response(
                message_id,
                [
                    {
                        "targetUri": uri,
                        "targetRange": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
                        "targetSelectionRange": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
                        "originSelectionRange": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 1}},
                    }
                ],
            )
        elif method == "workspace/symbol":
            uri = params.get("uri", "")
            query = params.get("query", "")
            if query == "delay":
                time.sleep(0.15)
            if query == "error":
                response(message_id, error={"code": -32603, "message": "controlled fake failure"})
            elif query == "null":
                response(message_id)
            else:
                response(
                    message_id,
                    [
                        {
                            "name": "FakeWorkspaceSymbol",
                            "kind": 12,
                            "containerName": "FakeContainer",
                            "location": {
                                "uri": uri,
                                "range": {"start": {"line": 0, "character": 0}, "end": {"line": 0, "character": 5}},
                            },
                            "data": {"opaque": "preserve-me"},
                        }
                    ],
                )
        else:
            response(message_id, error={"code": -32601, "message": f"unsupported fake method: {method}"})


if __name__ == "__main__":
    raise SystemExit(serve())
