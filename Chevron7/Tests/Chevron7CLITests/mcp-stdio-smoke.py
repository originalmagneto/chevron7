#!/usr/bin/env python3
"""Independent stdio client smoke. Never calls the app or uses real documents."""
import json
import pathlib
import select
import subprocess
import sys
import tempfile

helper = pathlib.Path(sys.argv[1]).resolve()
for args in [["version", "--json"], ["--version", "--json"]]:
    result = subprocess.run([str(helper), *args], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0 and result.stderr == "", result
    envelope = json.loads(result.stdout)
    assert envelope["apiVersion"] == 1 and envelope["result"]["apiVersion"] == 1
help_result = subprocess.run([str(helper), "--help"], capture_output=True, text=True, timeout=10)
assert help_result.returncode == 0 and "No PIN" in help_result.stdout
invalid = subprocess.run([str(helper), "sign", "/not-read.pdf", "--output", "/not-written.pdf", "--pin", "never-log-this", "--json"], capture_output=True, text=True, timeout=10)
assert invalid.returncode == 2 and json.loads(invalid.stdout)["error"]["code"] == "INVALID_ARGUMENTS"
assert "never-log-this" not in invalid.stdout + invalid.stderr
print("CLI local help/version/JSON and PIN refusal passed")

def receive(process):
    ready, _, _ = select.select([process.stdout], [], [], 10)
    assert ready, "Timed out waiting for MCP output"
    line = process.stdout.readline()
    assert line, "MCP process ended early"
    return json.loads(line)

def send(process, message):
    process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()

for protocol in ["2025-06-18", "2025-11-25"]:
    with tempfile.TemporaryDirectory(prefix="chevron7-mcp-smoke-") as root:
        process = subprocess.Popen([str(helper), "mcp", "--root", root], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        try:
            send(process, {"jsonrpc":"2.0", "id":1, "method":"initialize", "params":{"protocolVersion":protocol, "capabilities":{}, "clientInfo":{"name":"independent-smoke", "version":"1"}}})
            response = receive(process)
            assert response["id"] == 1 and response["result"]["protocolVersion"] == protocol, response
            send(process, {"jsonrpc":"2.0", "method":"notifications/initialized"})
            send(process, {"jsonrpc":"2.0", "id":2, "method":"tools/list", "params":{}})
            response = receive(process)
            tools = {tool["name"]:tool for tool in response["result"]["tools"]}
            assert len(tools) == 7 and "chevron7_sign" in tools
            assert "chevron7_register_list" not in tools
            assert tools["chevron7_sign"]["inputSchema"]["additionalProperties"] is False
            send(process, {"jsonrpc":"2.0", "id":3, "method":"tools/call", "params":{"name":"chevron7_inspect", "arguments":{"file":root+"/a.pdf", "roots":["/"]}}})
            response = receive(process)
            assert response["result"]["isError"] is True
            assert response["result"]["structuredContent"]["error"]["code"] == "INVALID_ARGUMENTS"
            process.stdin.close()
            assert process.wait(timeout=10) == 0, process.stderr.read()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
print("MCP stdio: both negotiated versions, tools/schema, scope rejection, EOF cleanup passed")
