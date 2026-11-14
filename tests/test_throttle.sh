#!/usr/bin/env bash
# tests/test_throttle.sh — lib/throttle.py against a fake MCP server.
#
#   bash tests/test_throttle.sh       every case, then a summary
#   bash tests/test_throttle.sh -q    failures and the summary only
#
# No network: tests/fake_server.py answers every request after 0.3 s, in
# parallel, and logs when each request reached it.
set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1
TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1

pass=0
fail=0
ok() { pass=$((pass + 1)); [ "$QUIET" -eq 1 ] || printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }
check() {
    local name="$1"; shift
    if "$@" >"$TMP/chk" 2>&1; then ok "$name"; else no "$name" "$(head -3 "$TMP/chk")"; fi
}

# Six requests written at once: initialize, three searches, one fetch_content,
# one notification (no reply expected).
requests() {
    printf '%s\n' \
      '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
      '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
      '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search","arguments":{"query":"a"}}}' \
      '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"b"}}}' \
      '{"jsonrpc":"2.0","id":"x4","method":"tools/call","params":{"name":"search","arguments":{"query":"c"}}}' \
      '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"fetch_content","arguments":{"url":"u"}}}'
}

LOG="$TMP/log"
requests | FAKE_LOG="$LOG" DDG_MIN_INTERVAL=0.5 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > "$TMP/out"
rc=$?
check "exit status 0 passed through" test "$rc" -eq 0
check "every request with an id answered" test "$(python3 -c "import json,sys; print(sorted(str(json.loads(l)['id']) for l in open('$TMP/out')))")" = "['1', '2', '3', '5', 'x4']"
check "notification forwarded" grep -q 'notifications/initialized' "$LOG"

python3 - "$LOG" > "$TMP/times" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1])]
s = [float(r[0]) for r in rows if r[2] == "search"]
f = [float(r[0]) for r in rows if r[2] == "fetch_content"]
# The gap between the 2nd and 3rd: the first one also carries the fake
# server's start-up, which shortens the first gap as the server sees it.
print(len(s), s[2] - s[1], f[0] - s[0])
PY
read -r count gap fetch_after_first < "$TMP/times"
check "three searches reached the server" test "$count" -eq 3
# One in flight at a time: the next leaves only after the 0.3 s answer, and
# never sooner than DDG_MIN_INTERVAL (0.5 s) after the previous one.
check "searches spaced by the interval (gap $gap s >= 0.5)" python3 -c "import sys; sys.exit(0 if $gap >= 0.49 else 1)"
check "fetch_content does not wait for the queue ($fetch_after_first s)" python3 -c "import sys; sys.exit(0 if $fetch_after_first < 0.3 else 1)"

: > "$LOG"
requests | FAKE_LOG="$LOG" DDG_MIN_INTERVAL=0 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > /dev/null
check "DDG_MIN_INTERVAL=0 still sends one search at a time" python3 - "$LOG" <<'PY'
import sys
s = [float(l.split()[0]) for l in open(sys.argv[1]) if l.split()[2] == "search"]
sys.exit(0 if all(b - a >= 0.28 for a, b in zip(s, s[1:])) else 1)
PY

printf '' | FAKE_LOG="$LOG" FAKE_EXIT=3 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > /dev/null
check "server exit status passed through (3)" test "$?" -eq 3
python3 "$SRC/lib/throttle.py" /nonexistent/server > /dev/null 2>"$TMP/err" </dev/null
check "missing server: exit 127 with a message" test "$?" -eq 127 -a -s "$TMP/err"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
