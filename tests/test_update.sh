#!/usr/bin/env bash
# tests/test_update.sh — lib/upstream.py and update.sh.
#
#   bash tests/test_update.sh       every case, then a summary
#   bash tests/test_update.sh -q    failures and the summary only
#
# PyPI is replaced by a JSON file (DDG_PYPI_JSON). update.sh runs on a copy of
# this checkout in a temporary git repository, never on the checkout itself.
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

PINNED="$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$SRC/lib/wire.py")"
NEXT="99.0.0"
pypi() { # pypi FILE NEWEST BROWSER(yes|no)
    local extra='"curl-cffi>=0.7.0; extra == '"'"'browser'"'"'"'
    [ "$3" = yes ] || extra='"httpx>=0.28"'
    printf '{"info": {"version": "%s", "requires_dist": [%s]},
 "releases": {"%s": [{"yanked": false}], "%s": [{"yanked": false}], "100.0.0rc1": [{"yanked": false}]}}\n' \
        "$2" "$extra" "$PINNED" "$2" > "$1"
}

# ---------------------------------------------------------------- upstream.py
pypi "$TMP/newer.json" "$NEXT" yes
DDG_PYPI_JSON="$TMP/newer.json" python3 "$SRC/lib/upstream.py" > "$TMP/out"; rc=$?
check "upstream: a newer version exits 10" test "$rc" -eq 10
check "upstream: names it and the next step" grep -q "$NEXT on PyPI, pinned $PINNED — ./update.sh" "$TMP/out"
check "upstream: a release candidate is not taken as newest" test "$(DDG_PYPI_JSON="$TMP/newer.json" python3 "$SRC/lib/upstream.py" --latest)" = "$NEXT"

pypi "$TMP/same.json" "$PINNED" yes
DDG_PYPI_JSON="$TMP/same.json" python3 "$SRC/lib/upstream.py" > "$TMP/out"; rc=$?
check "upstream: pinned is newest — exit 0" test "$rc" -eq 0

DDG_PYPI_JSON="$TMP/missing.json" python3 "$SRC/lib/upstream.py" > "$TMP/out"; rc=$?
check "upstream: unreadable PyPI — exit 2" test "$rc" -eq 2
check "upstream: says it was not checked" grep -q "not checked" "$TMP/out"

# ---------------------------------------------------------------- update.sh on a copy
copy() {
    R="$TMP/repo-$1"
    mkdir -p "$R" && (cd "$SRC" && tar cf - --exclude=.git .) | (cd "$R" && tar xf -)
    (cd "$R" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init)
}
pinned_in() { sed -n 's/^VERSION = "\(.*\)"$/\1/p' "$1/lib/wire.py"; }

copy ok
DDG_PYPI_JSON="$TMP/newer.json" bash "$R/update.sh" --no-docker > "$TMP/out" 2>&1; rc=$?
check "update: newer version — exit 0" test "$rc" -eq 0
check "update: pin moved" test "$(pinned_in "$R")" = "$NEXT"
check "update: CHANGELOG gets the change under Unreleased" python3 -c "
import sys; t = open('$R/CHANGELOG.md').read()
u = t.index('## Unreleased'); n = t.index('\n## ', u + 1)
sys.exit(0 if 'duckduckgo-mcp-server $PINNED → $NEXT' in t[u:n] else 1)"
check "update: says what to do next" grep -q "next: review git diff" "$TMP/out"

copy same
DDG_PYPI_JSON="$TMP/same.json" bash "$R/update.sh" --no-docker > "$TMP/out" 2>&1; rc=$?
check "update: already newest — nothing to do, exit 0" test "$rc" -eq 0 -a "$(pinned_in "$R")" = "$PINNED"

copy nobrowser
pypi "$TMP/nobrowser.json" "$NEXT" no
DDG_PYPI_JSON="$TMP/nobrowser.json" bash "$R/update.sh" --no-docker > "$TMP/out" 2>&1; rc=$?
check "update: no [browser] extra — refused" test "$rc" -ne 0 -a "$(pinned_in "$R")" = "$PINNED"
check "update: says why" grep -q "browser" "$TMP/out"

copy dirty
echo "x" >> "$R/README.md"
DDG_PYPI_JSON="$TMP/newer.json" bash "$R/update.sh" --no-docker > "$TMP/out" 2>&1; rc=$?
check "update: dirty working tree — refused, pin kept" test "$rc" -ne 0 -a "$(pinned_in "$R")" = "$PINNED"

copy failing
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/tests/test_install.sh"
(cd "$R" && git -c user.email=t@t -c user.name=t commit -qam broken)
DDG_PYPI_JSON="$TMP/newer.json" bash "$R/update.sh" --no-docker > "$TMP/out" 2>&1; rc=$?
check "update: failing tests — exit non-zero" test "$rc" -ne 0
check "update: failing tests — pin restored" test "$(pinned_in "$R")" = "$PINNED"
check "update: failing tests — CHANGELOG untouched" test -z "$(cd "$R" && git status --porcelain)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
