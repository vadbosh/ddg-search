#!/usr/bin/env python3
"""Stand between an assistant and duckduckgo-mcp-server; send searches one at a time.

  throttle.py <server command…>

Speaks MCP over stdio on both sides and passes every message through
unchanged, with one exception: a `tools/call` of `search` waits until the
previous search has been answered and at least DDG_MIN_INTERVAL seconds
(default 2) have passed since that search was sent. Everything else —
initialize, tools/list, fetch_content, notifications, replies — goes through
at once.

Why: an assistant may send several searches in one step. The server forwards
them to DuckDuckGo together (its rate limiter allows a burst as large as the
per-minute limit), and DuckDuckGo answers a burst with its bot block: on
2026-11-14 a run that opened with six parallel searches got "No results" for
25 of its 31 searches. A rule asking the model not to do it is advice; this is
a guarantee.

Standard library only, Python 3.8 or newer. Exit status is the server's.
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time

TOOL = "search"


def interval():
    try:
        return max(0.0, float(os.environ.get("DDG_MIN_INTERVAL", "2")))
    except ValueError:
        return 2.0


class Relay:
    def __init__(self, argv):
        self.child = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
        self.out_lock = threading.Lock()     # our stdout: replies from the child
        self.in_lock = threading.Lock()      # the child's stdin: requests from the client
        self.searches = queue.Queue()
        self.answered = {}                   # request id of a queued search -> Event
        self.answered_lock = threading.Lock()
        self.min_interval = interval()

    # ------------------------------------------------------------ to the child
    def to_child(self, raw):
        with self.in_lock:
            try:
                self.child.stdin.write(raw)
                self.child.stdin.flush()
            except (BrokenPipeError, ValueError):
                pass

    def from_client(self):
        """Read requests from the assistant. Searches go to the queue."""
        stdin = sys.stdin.buffer
        for raw in iter(stdin.readline, b""):
            if self.is_search(raw):
                self.searches.put(raw)
            else:
                self.to_child(raw)
        self.searches.put(None)              # EOF: let the worker drain and stop

    def is_search(self, raw):
        try:
            msg = json.loads(raw)
        except ValueError:
            return False
        if not isinstance(msg, dict) or msg.get("method") != "tools/call" or "id" not in msg:
            return False
        params = msg.get("params") or {}
        if params.get("name") != TOOL:
            return False
        with self.answered_lock:
            self.answered[json.dumps(msg["id"])] = threading.Event()
        return True

    def search_worker(self):
        """One search in flight at a time, spaced by the minimum interval."""
        last_sent = 0.0
        while True:
            raw = self.searches.get()
            if raw is None:
                break
            wait = last_sent + self.min_interval - time.monotonic()
            if wait > 0:
                time.sleep(wait)
            key = json.dumps(json.loads(raw)["id"])
            with self.answered_lock:
                done = self.answered[key]
            last_sent = time.monotonic()
            self.to_child(raw)
            # The server answers every call; the timeout only keeps a lost
            # reply from stopping all later searches.
            done.wait(120)
            with self.answered_lock:
                self.answered.pop(key, None)
        with self.in_lock:
            try:
                self.child.stdin.close()
            except (BrokenPipeError, ValueError):
                pass

    # ------------------------------------------------------------ to the client
    def from_child(self):
        stdout = sys.stdout.buffer
        for raw in iter(self.child.stdout.readline, b""):
            with self.out_lock:
                stdout.write(raw)
                stdout.flush()
            try:
                msg = json.loads(raw)
            except ValueError:
                continue
            if isinstance(msg, dict) and "id" in msg and ("result" in msg or "error" in msg):
                with self.answered_lock:
                    done = self.answered.get(json.dumps(msg["id"]))
                if done:
                    done.set()

    def run(self):
        threading.Thread(target=self.from_client, daemon=True).start()
        worker = threading.Thread(target=self.search_worker, daemon=True)
        worker.start()
        reader = threading.Thread(target=self.from_child, daemon=True)
        reader.start()
        code = self.child.wait()
        reader.join(5)
        return code


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if argv else 2
    try:
        return Relay(argv).run()
    except FileNotFoundError as exc:
        print(f"throttle.py: cannot start {argv[0]}: {exc}", file=sys.stderr)
        return 127


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
