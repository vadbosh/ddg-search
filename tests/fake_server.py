#!/usr/bin/env python3
"""A stand-in MCP server for tests/test_throttle.sh.

Answers every request with an id after DELAY seconds, each in its own thread,
so the server itself never serialises anything. Appends one line per received
request to LOG: `<monotonic time> <method> <tool or -> <id>`. Exits with
EXIT_CODE when stdin closes.
"""
import json
import os
import sys
import threading
import time

LOG = os.environ["FAKE_LOG"]
DELAY = float(os.environ.get("FAKE_DELAY", "0.3"))
lock = threading.Lock()


def answer(msg):
    time.sleep(DELAY)
    reply = {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text": "ok"}]}}
    with lock:
        sys.stdout.write(json.dumps(reply) + "\n")
        sys.stdout.flush()


threads = []
for line in sys.stdin:
    msg = json.loads(line)
    tool = (msg.get("params") or {}).get("name", "-")
    with open(LOG, "a") as fh:
        fh.write(f"{time.monotonic():.3f} {msg.get('method')} {tool} {msg.get('id', '-')}\n")
    if "id" in msg:
        t = threading.Thread(target=answer, args=(msg,))
        t.start()
        threads.append(t)
for t in threads:
    t.join()
sys.exit(int(os.environ.get("FAKE_EXIT", "0")))
