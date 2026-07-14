#!/usr/bin/env python3
"""Minimal ACP client for llm-jail e2e: drive one prompt over a Unix socket.

Usage: acp-client.py --sock PATH --prompt TEXT [--timeout SECS] [--trace]
Exit 0 iff the prompt completes with a stop reason.
"""

import argparse
import json
import socket
import sys
import time


def log(msg: str) -> None:
    print(f"acp-client: {msg}", file=sys.stderr, flush=True)


class AcpClient:
    def __init__(self, sock: socket.socket, trace: bool) -> None:
        self.sock = sock
        self.trace = trace
        self.buf = b""
        self.next_id = 1

    def send(self, obj: dict) -> None:
        data = json.dumps(obj).encode() + b"\n"
        if self.trace:
            log(f">> {data.decode().rstrip()}")
        self.sock.sendall(data)

    def request(self, method: str, params: dict) -> int:
        rid = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        return rid

    def respond(self, rid, result: dict) -> None:
        self.send({"jsonrpc": "2.0", "id": rid, "result": result})

    def read_message(self, deadline: float) -> dict | None:
        while b"\n" not in self.buf:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self.sock.settimeout(min(remaining, 5.0))
            try:
                chunk = self.sock.recv(65536)
            except TimeoutError:
                continue
            if not chunk:
                raise ConnectionError("socket closed by peer")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        if not line.strip():
            return self.read_message(deadline)
        if self.trace:
            log(f"<< {line.decode(errors='replace')}")
        return json.loads(line)

    def wait_for_response(self, rid: int, deadline: float) -> dict:
        """Read until the response for rid arrives; service agent requests meanwhile."""
        while True:
            msg = self.read_message(deadline)
            if msg is None:
                raise TimeoutError(f"no response to request {rid}")
            if msg.get("id") == rid and ("result" in msg or "error" in msg):
                if "error" in msg:
                    raise RuntimeError(f"agent returned error: {msg['error']}")
                return msg["result"]
            self.handle_incoming(msg)

    def handle_incoming(self, msg: dict) -> None:
        method = msg.get("method", "")
        if method == "session/request_permission" and "id" in msg:
            options = msg.get("params", {}).get("options", [])
            allow = next(
                (o for o in options if "allow" in o.get("kind", "") or "allow" in o.get("optionId", "")),
                options[0] if options else None,
            )
            if allow is None:
                raise RuntimeError(f"permission request with no options: {msg}")
            log(f"auto-approving permission via option {allow.get('optionId')}")
            self.respond(msg["id"], {"outcome": {"outcome": "selected", "optionId": allow["optionId"]}})
        elif "id" in msg and "method" in msg:
            # Unknown agent->client request (e.g. fs/*): refuse politely.
            self.send({
                "jsonrpc": "2.0", "id": msg["id"],
                "error": {"code": -32601, "message": f"client does not support {method}"},
            })
        # Notifications (session/update etc.) need no reply.


def connect_with_retry(path: str, deadline: float) -> socket.socket:
    while True:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
            return s
        except (FileNotFoundError, ConnectionRefusedError):
            s.close()
            if time.monotonic() > deadline:
                raise TimeoutError(f"could not connect to {path}")
            time.sleep(0.5)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--sock", required=True)
    ap.add_argument("--prompt", required=True)
    ap.add_argument("--timeout", type=float, default=300.0)
    ap.add_argument("--trace", action="store_true")
    args = ap.parse_args()

    deadline = time.monotonic() + args.timeout
    sock = connect_with_retry(args.sock, deadline)
    client = AcpClient(sock, args.trace)

    # The guest adapter may not have opened the virtio port yet; virtio
    # drops host->guest bytes written before the guest opens the port, so
    # retry initialize until a response arrives.
    log("initializing (with retry until guest adapter is up)")
    init_result = None
    while init_result is None:
        rid = client.request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}},
        })
        try:
            init_result = client.wait_for_response(rid, min(time.monotonic() + 10, deadline))
        except TimeoutError:
            if time.monotonic() > deadline:
                log("FATAL: initialize never answered")
                return 1
            log("initialize unanswered, retrying")
    log(f"initialized: {json.dumps(init_result)[:200]}")

    rid = client.request("session/new", {"cwd": "/workspace", "mcpServers": []})
    session = client.wait_for_response(rid, deadline)
    session_id = session["sessionId"]
    log(f"session: {session_id}")

    rid = client.request("session/prompt", {
        "sessionId": session_id,
        "prompt": [{"type": "text", "text": args.prompt}],
    })
    result = client.wait_for_response(rid, deadline)
    log(f"prompt finished: {json.dumps(result)}")
    return 0 if result.get("stopReason") else 1


if __name__ == "__main__":
    sys.exit(main())
