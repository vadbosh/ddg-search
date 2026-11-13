#!/usr/bin/env python3
"""Start ddg-search the way an assistant would and run one real search.

  mcp_probe.py [claude|codex|opencode] [--query Q]

Reads the server command from that assistant's installed configuration (not
from this checkout), speaks MCP over stdio — initialize, tools/list, one
tools/call of `search` — and exits 0 only when the search returned at least
one URL. Standard library only; needs network access to DuckDuckGo.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading

HOME = os.path.expanduser("~")


def command_for(ide):
    if ide == "claude":
        e = json.load(open(os.path.join(HOME, ".claude.json")))["mcpServers"]["ddg-search"]
        return [e["command"]] + e.get("args", []), e.get("env", {})
    if ide == "opencode":
        e = json.load(open(os.path.join(HOME, ".config/opencode/opencode.json")))["mcp"]["ddg-search"]
        return e["command"], e.get("environment", {})
    import tomllib
    e = tomllib.load(open(os.path.join(HOME, ".codex/config.toml"), "rb"))["mcp_servers"]["ddg-search"]
    return [e["command"]] + e.get("args", []), e.get("env", {})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ide", nargs="?", default="claude", choices=("claude", "codex", "opencode"))
    ap.add_argument("--query", default="terraform aws provider")
    ap.add_argument("--timeout", type=float, default=120)
    a = ap.parse_args()

    argv, env = command_for(a.ide)
    print(f"server: {' '.join(argv)}  env: {env or '-'}")
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, env={**os.environ, **env}, text=True)
    timer = threading.Timer(a.timeout, proc.kill)
    timer.start()

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    def reply(rid):
        for line in proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") == rid:
                if "error" in msg:
                    raise SystemExit(f"error from server: {msg['error']}")
                return msg["result"]
        raise SystemExit("server exited or timed out before answering")

    try:
        send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "ddg-search-probe", "version": "1"}}})
        info = reply(1)["serverInfo"]
        print(f"initialize: {info.get('name')} {info.get('version')}")
        send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        tools = sorted(t["name"] for t in reply(2)["tools"])
        print(f"tools: {', '.join(tools)}")
        if "search" not in tools:
            raise SystemExit("no search tool")
        send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
            "name": "search", "arguments": {"query": a.query, "max_results": 3}}})
        text = "".join(c.get("text", "") for c in reply(3).get("content", []))
        urls = re.findall(r"https?://[^\s)\]]+", text)
        print(f"search {a.query!r}: {len(urls)} url(s)")
        for u in urls[:3]:
            print(f"  {u}")
        if not urls:
            print(text[:400])
            return 1
        return 0
    finally:
        timer.cancel()
        proc.kill()


if __name__ == "__main__":
    sys.exit(main())
