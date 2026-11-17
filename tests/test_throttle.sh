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
export DDG_LOCK_FILE="$TMP/search.lock"      # never the real queue of this machine

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

# Two sessions at once, each with its own throttle and server, as two
# assistants would run them: the shared lock spaces all six searches. The
# searches follow initialize after 0.5 s, so that the start-up of a fake
# server does not delay when its first search is logged.
started() { requests | head -2; sleep 0.5; requests | tail -n +3; }
two_sessions() {    # <lock file for the 1st> <lock file for the 2nd>
    : > "$LOG"
    started | FAKE_LOG="$LOG" DDG_LOCK_FILE="$1" DDG_MIN_INTERVAL=0.5 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > /dev/null &
    local first=$!
    started | FAKE_LOG="$LOG" DDG_LOCK_FILE="$2" DDG_MIN_INTERVAL=0.5 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > /dev/null
    wait "$first"
    python3 - "$LOG" <<'PY'
import sys
s = sorted(float(l.split()[0]) for l in open(sys.argv[1]) if l.split()[2] == "search")
print(len(s), min(b - a for a, b in zip(s, s[1:])))
PY
}
read -r count gap < <(two_sessions "$TMP/shared.lock" "$TMP/shared.lock")
check "two sessions: six searches reached the servers" test "$count" -eq 6
check "two sessions, one lock: every gap >= 0.5 s (smallest $gap)" python3 -c "import sys; sys.exit(0 if $gap >= 0.49 else 1)"
check "the lock file holds the time of the last search" python3 -c "import sys,time; sys.exit(0 if 0 < time.time() - float(open('$TMP/shared.lock').read()) < 60 else 1)"
# The same run with a lock each: the test sees an overlap when there is one.
read -r count gap < <(two_sessions "$TMP/one.lock" "$TMP/two.lock")
check "two sessions, separate locks: searches overlap (smallest gap $gap s < 0.3)" python3 -c "import sys; sys.exit(0 if $gap < 0.3 else 1)"

: > "$TMP/notadir"
requests | FAKE_LOG="$LOG" DDG_LOCK_FILE="$TMP/notadir/search.lock" DDG_MIN_INTERVAL=0 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > "$TMP/out" 2> "$TMP/err"
check "lock file unusable: every search still answered" test "$(grep -c '"id"' "$TMP/out")" -eq 5
check "lock file unusable: one line on stderr says so" test "$(grep -c 'within this session only' "$TMP/err")" -eq 1

# Messages the relay was not written for (review-2026-11-17-throttle.md, A1-A4,
# C1). Before the fix each of these hung: `timeout` turns a hang into a failure.
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'
search() { printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"search","arguments":{"query":"q"}}}\n' "$1"; }
cancel() { printf '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":%s}}\n' "$1"; }
relay() {   # env assignments… ; requests on stdin; prints the ids answered
    : > "$LOG"
    env FAKE_LOG="$LOG" "$@" timeout 20 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > "$TMP/out" 2> "$TMP/err"
    python3 -c "import json,sys; print(' '.join(sorted(str(json.loads(l)['id']) for l in open(sys.argv[1]) if l.strip())))" "$TMP/out"
}

# The server never answers a cancelled call; the next search must not wait 120 s.
start=$(python3 -c 'import time; print(time.time())')
ids=$( { echo "$init"; search 3; sleep 0.5; cancel 3; search 4; } | relay FAKE_SILENT_IDS=3 DDG_MIN_INTERVAL=0.2)
took=$(python3 -c "import time; print(round(time.time() - $start, 1))")
check "cancelled search in flight: the next one answered in $took s, not 120" python3 -c "import sys; sys.exit(0 if '4' in '$ids'.split() and $took < 5 else 1)"

ids=$( { echo "$init"; search 2; search 3; cancel 3; } | relay FAKE_DELAY=0.3 DDG_MIN_INTERVAL=0.5)
check "cancelled search still queued: never sent to the server" test "$(grep -c ' search 3$' "$LOG")" -eq 0

ids=$( { echo "$init"; search 7; search 7; search 8; } | relay DDG_MIN_INTERVAL=0)
check "two outstanding searches with one id: later searches still answered ($ids)" test "$ids" = "1 7 7 8"
check "two outstanding searches with one id: the second gets an error" grep -q 'already queued' "$TMP/out"

ids=$( { echo '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":["x"]}'; echo "$init"; search 2; } | relay DDG_MIN_INTERVAL=0)
check "tools/call with array params: passed on, the session keeps working ($ids)" test "$ids" = "1 2 9"

ids=$( { echo "$init"; search 2; search 3; } | relay DDG_MIN_INTERVAL=inf)
check "DDG_MIN_INTERVAL=inf: searches still answered ($ids)" test "$ids" = "1 2 3"

printf '' | FAKE_LOG="$LOG" FAKE_EXIT=3 python3 "$SRC/lib/throttle.py" python3 "$SRC/tests/fake_server.py" > /dev/null
check "server exit status passed through (3)" test "$?" -eq 3
python3 "$SRC/lib/throttle.py" /nonexistent/server > /dev/null 2>"$TMP/err" </dev/null
check "missing server: exit 127 with a message" test "$?" -eq 127 -a -s "$TMP/err"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
