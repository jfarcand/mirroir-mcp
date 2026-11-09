#!/usr/bin/env python3
# ABOUTME: Validates mirroir-mcp's modern (2026-07-28) MCP results against the official schema.
# ABOUTME: Drives the revision's handshake over stdio and over `mirroir-mcp serve`, checking each result with jsonschema.

"""Modern-revision MCP conformance check.

The `2026-07-28` revision is stateless: there is no `initialize` handshake, and
every request carries a `_meta` envelope naming the protocol version. Results
must satisfy the published schema — notably `resultType` on every result and the
`ttlMs`/`cacheScope` cache directives on every cacheable one. A client that
validates against the schema discards a whole result when a required field is
missing, which surfaces as "connected, but no tools".

The schema lives alongside this script (`mcp-schema-2026-07-28.json`), copied
verbatim from the modelcontextprotocol specification repository, so the check
neither hits the network nor restates the contract in hand-written assertions.

The same cases then run over HTTP against `mirroir-mcp serve`, along with the
refusals the transport must make before a request reaches the server: no token,
a browser Origin, a method other than POST, and MCP headers that disagree with
the body. None of it needs a phone.

Usage: mcp-modern-conformance.py <path-to-mirroir-mcp-binary>
"""

import json
import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    from jsonschema import Draft202012Validator
except ImportError:
    sys.exit(
        "jsonschema is required for MCP conformance validation.\n"
        "Install it with: pip3 install jsonschema"
    )

SCHEMA_PATH = Path(__file__).with_name("mcp-schema-2026-07-28.json")
PROTOCOL_VERSION = "2026-07-28"

# Each modern request paired with the schema definition its result must satisfy.
# The last case omits the optional `clientInfo`: the revision requires only
# `protocolVersion` and `clientCapabilities`, so a server that demands more
# rejects conformant clients.
CASES = [
    ("server/discover", {}, "DiscoverResult", True),
    ("tools/list", {}, "ListToolsResult", True),
    ("tools/call", {"name": "list_skills", "arguments": {}}, "CallToolResult", True),
    ("ping", {}, "EmptyResult", True),
    ("tools/list", {}, "ListToolsResult", False),
]


def envelope(with_client_info):
    """The `_meta` every modern request carries."""
    meta = {
        "io.modelcontextprotocol/protocolVersion": PROTOCOL_VERSION,
        "io.modelcontextprotocol/clientCapabilities": {},
    }
    if with_client_info:
        meta["io.modelcontextprotocol/clientInfo"] = {
            "name": "mirroir-conformance", "version": "1.0"
        }
    return meta


def run_requests(binary):
    """Send every case to the server over stdio and return results keyed by id."""
    lines = []
    for index, (method, params, _, with_client_info) in enumerate(CASES):
        payload = dict(params)
        payload["_meta"] = envelope(with_client_info)
        lines.append(json.dumps(
            {"jsonrpc": "2.0", "id": index, "method": method, "params": payload}
        ))

    completed = subprocess.run(
        [binary],
        input="\n".join(lines) + "\n",
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )

    responses = {}
    for line in completed.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "id" in message:
            responses[message["id"]] = message
    return responses


def free_port():
    """A loopback port nothing is listening on."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_listener(port, process, seconds=30):
    """Block until the server accepts connections; False if it exits or never does."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return True
        except OSError:
            time.sleep(0.2)
    return False


def http_post(url, body, headers):
    """POST `body` and return (status, parsed JSON body or None)."""
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    try:
        return status, json.loads(raw)
    except json.JSONDecodeError:
        return status, None


def http_status(url, method, headers):
    """The status of a bodiless request."""
    request = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def modern_headers(token, method, params):
    """The headers a 2026-07-28 request repeats its routing facts in."""
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "MCP-Protocol-Version": PROTOCOL_VERSION,
        "Mcp-Method": method,
    }
    if method == "tools/call":
        headers["Mcp-Name"] = params["name"]
    return headers


def run_http(binary):
    """Serve over HTTP and return (responses keyed by id, transport failures)."""
    failures = []
    responses = {}
    with tempfile.TemporaryDirectory() as scratch:
        token = secrets.token_hex(32)
        token_file = Path(scratch) / "serve-token"
        descriptor = os.open(token_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            handle.write(token + "\n")

        port = free_port()
        url = f"http://127.0.0.1:{port}/mcp"
        process = subprocess.Popen(
            [binary, "serve", "--port", str(port), "--token-file", str(token_file)],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        )
        try:
            if not wait_for_listener(port, process):
                process.kill()
                return {}, [f"serve did not start listening: {process.stderr.read().strip()[-400:]}"]

            ping = json.dumps({
                "jsonrpc": "2.0", "id": 99, "method": "ping", "params": {"_meta": envelope(True)},
            }).encode()
            authorized = modern_headers(token, "ping", {})

            status, _ = http_post(url, ping, {k: v for k, v in authorized.items() if k != "Authorization"})
            if status != 401:
                failures.append(f"http: no token answered {status}, expected 401")
            status, _ = http_post(url, ping, dict(authorized, Authorization="Bearer " + "0" * 64))
            if status != 401:
                failures.append(f"http: a wrong token answered {status}, expected 401")
            status, _ = http_post(url, ping, dict(authorized, Origin="http://evil.example"))
            if status != 403:
                failures.append(f"http: a browser Origin answered {status}, expected 403")
            status = http_status(url, "GET", {"Authorization": f"Bearer {token}"})
            if status != 405:
                failures.append(f"http: GET answered {status}, expected 405")
            status, body = http_post(url, ping, dict(authorized, **{"Mcp-Method": "tools/list"}))
            code = (body or {}).get("error", {}).get("code")
            if status != 400 or code != -32020:
                failures.append(f"http: a mismatched Mcp-Method answered {status} code {code}, "
                                "expected 400 code -32020")

            for index, (method, params, _, with_client_info) in enumerate(CASES):
                payload = dict(params)
                payload["_meta"] = envelope(with_client_info)
                body = json.dumps(
                    {"jsonrpc": "2.0", "id": index, "method": method, "params": payload}
                ).encode()
                status, message = http_post(url, body, modern_headers(token, method, params))
                if status != 200 or message is None:
                    failures.append(f"http: {method} answered {status}, expected 200 with a JSON body")
                    continue
                responses[index] = message
        finally:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
    return responses, failures


def validate(schema, responses):
    """Check every case's result against its schema definition.

    Returns a list of human-readable failures; empty means conformant.
    """
    failures = []
    for index, (method, _, definition, with_client_info) in enumerate(CASES):
        label = method if with_client_info else f"{method} (no clientInfo)"
        message = responses.get(index)
        if message is None:
            failures.append(f"{label}: no response")
            continue
        if "error" in message and message["error"] is not None:
            failures.append(f"{label}: server returned error {message['error']}")
            continue

        subschema = {"$ref": f"#/$defs/{definition}", "$defs": schema["$defs"]}
        errors = sorted(
            Draft202012Validator(subschema).iter_errors(message["result"]),
            key=lambda e: list(e.path),
        )
        for error in errors:
            location = "/".join(str(part) for part in error.path) or "<root>"
            failures.append(f"{label} ({definition}) at {location}: {error.message}")
    return failures


def main():
    if len(sys.argv) != 2:
        sys.exit(f"usage: {Path(sys.argv[0]).name} <path-to-mirroir-mcp-binary>")

    binary = sys.argv[1]
    schema = json.loads(SCHEMA_PATH.read_text())
    failures = [f"stdio: {failure}" for failure in validate(schema, run_requests(binary))]

    http_responses, transport_failures = run_http(binary)
    failures += transport_failures
    if not transport_failures:
        failures += [f"http: {failure}" for failure in validate(schema, http_responses)]

    if failures:
        print(f"MCP {PROTOCOL_VERSION} conformance FAILED:")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print(f"OK ({len(CASES)} modern results conform to {PROTOCOL_VERSION} over stdio and over HTTP; "
          "the HTTP transport refuses a missing token, a browser Origin, GET and mismatched headers)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
