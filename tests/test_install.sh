#!/usr/bin/env bash
# tests/test_install.sh — install.sh, lib/wire.py and uninstall.sh.
#
#   bash tests/test_install.sh       every case, then a summary
#   bash tests/test_install.sh -q    failures and the summary only
#
# HOME is a temporary directory for every case: nothing here touches the real
# configuration. The server itself is not downloaded (--no-server); the one
# case that needs uv's absence fakes it with PATH. tests/docker.sh runs this
# suite under bash 3.2 and then a real install end to end.

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
QUIET=0
[ "${1:-}" = "-q" ] && QUIET=1
TMP="$(mktemp -d)"
trap 'rm -r "$TMP"' EXIT
export PYTHONDONTWRITEBYTECODE=1
RULE="disable-broken-google-search.md"
SPEC="duckduckgo-mcp-server[browser]==$(sed -n 's/^VERSION = "\(.*\)"/\1/p' "$SRC/lib/wire.py")"

pass=0
fail=0
ok() { pass=$((pass + 1)); [ "$QUIET" -eq 1 ] || printf '  ok    %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL  %s — %s\n' "$1" "$2"; }
check() { # check NAME COMMAND... — ok when the command succeeds
    local name="$1"; shift
    if "$@" >"$TMP/chk" 2>&1; then ok "$name"; else no "$name" "$(head -3 "$TMP/chk")"; fi
}

H="$TMP/home"
fresh() {
    [ -d "$H" ] && rm -r "$H"
    mkdir -p "$H/.claude" "$H/.codex" "$H/.config/opencode"
    cat > "$H/.claude.json" <<'EOF'
{
  "numStartups": 7,
  "mcpServers": {
    "other": {"command": "other-server"},
    "ddg-search": {"type": "stdio", "command": "uvx", "args": ["duckduckgo-mcp-server"]}
  }
}
EOF
    cat > "$H/.codex/config.toml" <<'EOF'
model = "gpt"

[mcp_servers.ddg-search]
command = "uvx"
args = [
  "--python",
  "3.12",
  "duckduckgo-mcp-server",
]
startup_timeout_sec = 20

[mcp_servers.ddg-search.env]
DDG_REGION = "us-en"
DDG_SEARCH_BACKEND = "httpx"

[mcp_servers.context7]
url = "https://mcp.context7.com/mcp"

[features]
hooks = true
EOF
    cat > "$H/.config/opencode/opencode.json" <<'EOF'
{
  "mcp": {
    "other": {"type": "local", "command": ["other-server"]}
  },
  "instructions": ["~/.config/opencode/instructions/other.md"]
}
EOF
    printf '@/somewhere/other.md\n' > "$H/.codex/AGENTS.md"
}
inst()   { HOME="$H" XDG_STATE_HOME='' bash "$SRC/install.sh" --no-server "$@" > "$TMP/out" 2>&1; }
uninst() { HOME="$H" XDG_STATE_HOME='' bash "$SRC/uninstall.sh" > "$TMP/out" 2>&1; }
# py FILE EXPR — evaluate EXPR with d = the parsed file (JSON or TOML); exit 1 when falsy.
# EXPR is always a literal written in this file, never input from elsewhere.
py() {
    python3 - "$1" "$2" <<'PY'
import json, sys
path, expr = sys.argv[1], sys.argv[2]
raw = open(path, encoding="utf-8").read()
if path.endswith(".toml"):
    try:
        import tomllib
    except ImportError:         # Python 3.10 in tests/docker.sh py310; wire.py itself never uses tomli
        import tomli as tomllib
    d = tomllib.loads(raw)
else:
    d = json.loads(raw)
r = eval(expr)
print(repr(r))
sys.exit(0 if r else 1)
PY
}
state() { (cd "$H" && find . -type f -not -path './.local/state/*' | sort | xargs cat); }

# ---------------------------------------------------------------- first run
fresh
if inst; then ok "first run finishes"; else no "first run" "$(tail -5 "$TMP/out")"; fi
first="$(state)"
inst; inst
if [ "$first" = "$(state)" ]; then ok "three runs leave the same state"; else no "three runs" "$(diff <(echo "$first") <(state) | head)"; fi
check "second run reports nothing to do" grep -q "already current" "$TMP/out"

C="$H/.claude.json"
check "claude: pinned spec with [browser]" py "$C" "d['mcpServers']['ddg-search']['args'] == ['--python', '3.12', '$SPEC']"
check "claude: other keys of the entry kept (type)" py "$C" "d['mcpServers']['ddg-search']['type'] == 'stdio'"
check "claude: no env for the auto backend" py "$C" "'env' not in d['mcpServers']['ddg-search']"
check "claude: other server and top-level key kept" py "$C" "d['mcpServers']['other'] and d['numStartups'] == 7"
check "claude: mcp.json not created when absent" test ! -e "$H/.claude/mcp.json"

T="$H/.codex/config.toml"
check "codex: pinned spec, one-line args" py "$T" "d['mcp_servers']['ddg-search']['args'][-1] == '$SPEC'"
check "codex: extra key of the section kept" py "$T" "d['mcp_servers']['ddg-search']['startup_timeout_sec'] == 20"
check "codex: other env variable kept, ours gone (auto)" py "$T" "d['mcp_servers']['ddg-search']['env'] == {'DDG_REGION': 'us-en'}"
check "codex: other sections kept" py "$T" "d['model'] == 'gpt' and d['mcp_servers']['context7'] and d['features']['hooks']"
check "codex: AGENTS.md references the rule once" test "$(grep -c "memories/$RULE" "$H/.codex/AGENTS.md")" = 1
check "codex: AGENTS.md keeps its other line" grep -q '^@/somewhere/other.md$' "$H/.codex/AGENTS.md"

O="$H/.config/opencode/opencode.json"
check "opencode: local server, codemode off" py "$O" "d['mcp']['ddg-search'] == {'type': 'local', 'command': ['uvx', '--python', '3.12', '$SPEC'], 'codemode': False}"
check "opencode: other server kept" py "$O" "d['mcp']['other']['command'] == ['other-server']"
check "opencode: rule listed after the existing one" py "$O" "d['instructions'] == ['~/.config/opencode/instructions/other.md', '~/.config/opencode/instructions/$RULE']"

for f in .claude/rules .codex/memories .config/opencode/instructions; do
    check "rule installed: $f" cmp -s "$SRC/rules/$RULE" "$H/$f/$RULE"
done
check "backups go outside the assistants' directories" test -n "$(ls "$H/.local/state/ddg-search/backups/" 2>/dev/null)"

# ---------------------------------------------------------------- backend
inst --search-backend curl
check "curl backend: claude env" py "$C" "d['mcpServers']['ddg-search']['env'] == {'DDG_SEARCH_BACKEND': 'curl'}"
check "curl backend: codex env keeps the other variable" py "$T" "d['mcp_servers']['ddg-search']['env'] == {'DDG_REGION': 'us-en', 'DDG_SEARCH_BACKEND': 'curl'}"
check "curl backend: opencode environment" py "$O" "d['mcp']['ddg-search']['environment'] == {'DDG_SEARCH_BACKEND': 'curl'}"
inst
check "back to auto: claude env removed" py "$C" "'env' not in d['mcpServers']['ddg-search']"
check "back to auto: opencode environment removed" py "$O" "'environment' not in d['mcp']['ddg-search']"
check "back to auto: codex env back to the other variable" py "$T" "d['mcp_servers']['ddg-search']['env'] == {'DDG_REGION': 'us-en'}"

# ---------------------------------------------------------------- mcp-tools layouts
fresh
printf '{"mcpServers": {"ddg-search": {"command": "uvx", "args": ["duckduckgo-mcp-server[browser]"]}}}\n' > "$H/.claude/mcp.json"
inst
check "mcp.json present: entry updated there" py "$H/.claude/mcp.json" "d['mcpServers']['ddg-search']['args'][-1] == '$SPEC'"

fresh
printf '{"mcpServers": {"x": {"command": "x"}}}\n' > "$H/.claude/mcp.json"
printf '{"mcpServers": {"ddg-search": {"command": "uvx", "args": ["old"]}}}\n' > "$H/.claude/mcp-disabled.json"
before="$(cat "$C")"
inst
check "claude parked: updated in mcp-disabled.json" py "$H/.claude/mcp-disabled.json" "d['mcpServers']['ddg-search']['args'][-1] == '$SPEC'"
check "claude parked: not added to mcp.json" py "$H/.claude/mcp.json" "'ddg-search' not in d['mcpServers']"
check "claude parked: ~/.claude.json untouched" test "$before" = "$(cat "$C")"
check "claude parked: said so" grep -q "parked in" "$TMP/out"

fresh
mv "$T" "$H/.codex/mcp-disabled.toml"
printf 'model = "gpt"\n' > "$T"
inst
check "codex parked: updated in mcp-disabled.toml" py "$H/.codex/mcp-disabled.toml" "d['mcp_servers']['ddg-search']['args'][-1] == '$SPEC'"
check "codex parked: not added to config.toml" py "$T" "'mcp_servers' not in d"

fresh
python3 - "$O" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["mcp"]["ddg-search"] = {"type": "local", "command": ["uvx"], "enabled": False}
open(sys.argv[1], "w").write(json.dumps(d))
PY
inst
check "opencode parked: enabled false kept" py "$O" "d['mcp']['ddg-search']['enabled'] is False and d['mcp']['ddg-search']['codemode'] is False"

# ---------------------------------------------------------------- flags and edges
fresh
before="$(state)"
HOME="$H" bash "$SRC/install.sh" --no-server --dry-run > "$TMP/out" 2>&1
check "--dry-run changes nothing" test "$before" = "$(state)"
check "--dry-run says what it would do" grep -q "would" "$TMP/out"

fresh
inst --no-rule
check "--no-rule: no rule file" test ! -e "$H/.claude/rules/$RULE"
check "--no-rule: no instructions entry" py "$O" "len(d['instructions']) == 1"
check "--no-rule: server still wired" py "$C" "d['mcpServers']['ddg-search']['args'][-1] == '$SPEC'"

fresh
rm -r "$H/.codex"
inst
check "assistant missing: skipped, not created" test ! -e "$H/.codex"
check "assistant missing: reported" grep -q "codex: not installed here" "$TMP/out"

fresh
rm "$C" "$T" "$O"
inst
check "no config files yet: claude.json created" py "$C" "d['mcpServers']['ddg-search']['command'] == 'uvx'"
check "no config files yet: config.toml created" py "$T" "d['mcp_servers']['ddg-search']['command'] == 'uvx'"
check "no config files yet: opencode.json created" py "$O" "d['mcp']['ddg-search']['type'] == 'local'"

fresh
printf '{ broken' > "$O"
if inst; then no "broken opencode.json fails the run" "exit 0"; else ok "broken opencode.json fails the run"; fi
check "broken opencode.json left untouched" test "$(cat "$O")" = "{ broken"
check "others still wired despite one failure" py "$C" "d['mcpServers']['ddg-search']['args'][-1] == '$SPEC'"

# A PATH with python3 and the base tools but no uv: python3 may live in
# /usr/local/bin (python images), which /usr/bin:/bin alone would hide too.
mkdir -p "$TMP/nouv" && ln -sf "$(command -v python3)" "$TMP/nouv/python3"
NOUV="$TMP/nouv:/usr/bin:/bin"
if ! PATH="$NOUV" command -v uvx >/dev/null 2>&1; then
    fresh
    # "$BASH", not bash: the bash:3.2 image keeps it in /usr/local/bin.
    if HOME="$H" PATH="$NOUV" "$BASH" "$SRC/install.sh" > "$TMP/out" 2>&1; then
        no "no uv: install refuses" "exit 0"
    else
        ok "no uv: install refuses"
    fi
    check "no uv: says how to get it" grep -q "astral.sh/uv/install.sh" "$TMP/out"
    check "no uv: nothing written" test ! -e "$H/.claude/rules/$RULE"
    # review 2026-11-13 B1: --dry-run still shows the configuration changes
    fresh
    HOME="$H" PATH="$NOUV" "$BASH" "$SRC/install.sh" --dry-run > "$TMP/out" 2>&1
    check "no uv, --dry-run: exits 0" test $? -eq 0
    check "no uv, --dry-run: shows the configuration changes" grep -q "would: server updated" "$TMP/out"
    check "no uv, --dry-run: names the missing uv" grep -q "uv is not installed" "$TMP/out"
fi

# ---------------------------------------------------------------- codex shapes (review 2026-11-13 A1, A2)
# codex_shape NAME BODY — config.toml holds BODY, install runs.
codex_shape() { fresh; printf '%b' "$2" > "$T"; inst "${@:3}"; }
one_table="len([l for l in open('$T') if l.strip().startswith('[mcp_servers') and 'ddg-search' in l and '.env' not in l]) == 1"

codex_shape T1 '[mcp_servers.ddg-search] # search\ncommand = "uvx"\nargs = ["duckduckgo-mcp-server"]\n'
check "codex: header with a comment — valid, pinned" py "$T" "d['mcp_servers']['ddg-search']['args'][-1] == '$SPEC'"
check "codex: header with a comment — one table" python3 -c "import sys; sys.exit(0 if $one_table else 1)"
codex_shape T2 '[mcp_servers.ddg-search]\n"command" = "uvx"\n"args" = ["duckduckgo-mcp-server"]\n'
check "codex: quoted keys — valid, pinned" py "$T" "d['mcp_servers']['ddg-search']['args'][-1] == '$SPEC'"
codex_shape T6 '[ mcp_servers . "ddg-search" ]\ncommand = "uvx"\nargs = ["duckduckgo-mcp-server"]\n'
check "codex: spaces and quotes in the header — valid, pinned" py "$T" "d['mcp_servers']['ddg-search']['args'][-1] == '$SPEC'"
codex_shape T3 '[mcp_servers.ddg-search]\ncommand = "uvx"\nargs = ["duckduckgo-mcp-server"]\nenv = { DDG_REGION = "us-en" }\n'
check "codex: inline env kept" py "$T" "d['mcp_servers']['ddg-search']['env'] == {'DDG_REGION': 'us-en'}"
codex_shape T3c '[mcp_servers.ddg-search]\ncommand = "uvx"\nargs = ["duckduckgo-mcp-server"]\nenv = { DDG_REGION = "us-en", DDG_SEARCH_BACKEND = "httpx" }\n' --search-backend curl
check "codex: inline env kept, ours replaced" py "$T" "d['mcp_servers']['ddg-search']['env'] == {'DDG_REGION': 'us-en', 'DDG_SEARCH_BACKEND': 'curl'}"
before="$(cat "$T")"; inst --search-backend curl
check "codex: inline env, second run changes nothing" test "$before" = "$(cat "$T")"
T4='[mcp_servers]\nddg-search = { command = "uvx", args = ["duckduckgo-mcp-server"] }\n'
codex_shape T4 "$T4"; rc=$?
check "codex: inline table — refused" test "$rc" -ne 0
check "codex: inline table — file unchanged" test "$(cat "$T")" = "$(printf '%b' "$T4")"
check "codex: inline table — says why" grep -q "inline" "$TMP/out"
check "codex: inline table — other assistants still wired" py "$C" "d['mcpServers']['ddg-search']['args'][-1] == '$SPEC'"
fresh
printf '[mcp_servers.ddg-search] # search\ncommand = "uvx"\n\n[features]\nhooks = true\n' > "$T"
uninst
check "codex: --remove finds a header with a comment" py "$T" "'mcp_servers' not in d and d['features']['hooks']"
T4b='model = "m"\nmcp_servers.ddg-search.command = "uvx"\n'
codex_shape T4b "$T4b"; rc=$?
check "codex: top-level dotted key — refused" test "$rc" -ne 0
check "codex: top-level dotted key — file unchanged" test "$(cat "$T")" = "$(printf '%b' "$T4b")"
fresh
printf '[features]\nddg-search = true\n' > "$T"
inst
check "codex: ddg-search as a key of another table is not the server" py "$T" "d['features']['ddg-search'] is True and d['mcp_servers']['ddg-search']['command'] == 'uvx'"
# Without tomllib (Python 3.8–3.10) there is no parser to say a file is broken.
if python3 -c 'import tomllib' 2>/dev/null; then
    fresh
    printf 'model = "m"\n[broken\n' > "$T"
    inst; rc=$?
    check "codex: unparsable config.toml — refused" test "$rc" -ne 0
    check "codex: unparsable config.toml — unchanged" test "$(cat "$T")" = "$(printf 'model = "m"\n[broken\n')"
fi

# ---------------------------------------------------------------- remote entries (review 2026-11-13 A3)
fresh
printf '{"mcpServers":{"ddg-search":{"type":"http","url":"https://example.invalid/mcp","headers":{"a":"b"}}}}\n' > "$C"
python3 - "$O" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["mcp"]["ddg-search"] = {"type": "remote", "url": "https://example.invalid/mcp"}
open(sys.argv[1], "w").write(json.dumps(d))
PY
inst
check "claude: a remote entry becomes a local one" py "$C" "d['mcpServers']['ddg-search'] == {'command': 'uvx', 'args': ['--python', '3.12', '$SPEC']}"
check "opencode: a remote entry becomes a local one" py "$O" "'url' not in d['mcp']['ddg-search'] and d['mcp']['ddg-search']['type'] == 'local'"

# ---------------------------------------------------------------- flags (review 2026-11-13 A5, B2)
for opt in --ide --search-backend; do
    HOME="$H" bash "$SRC/install.sh" --no-server "$opt" > "$TMP/out" 2>&1; rc=$?
    check "install $opt without a value: exit 2" test "$rc" -eq 2
    check "install $opt without a value: says so" grep -q "needs a value" "$TMP/out"
done
HOME="$H" bash "$SRC/uninstall.sh" --ide > "$TMP/out" 2>&1; rc=$?
check "uninstall --ide without a value: exit 2" test "$rc" -eq 2
check "uninstall --help ends on its header" test "$(bash "$SRC/uninstall.sh" --help | tail -1 | cut -c1-3)" != "set"

# ---------------------------------------------------------------- codex built-in web search
WS="$H/.local/state/ddg-search/codex-web-search"
fresh
inst
check "web search: turned off at the top level" py "$T" "d['web_search'] == 'disabled' and d['model'] == 'gpt'"
check "web search: state says it was unset" test "$(cat "$WS")" = "set previous=absent"
check "web search: written before the first table" test "$(grep -n '^web_search' "$T" | cut -d: -f1)" -lt "$(grep -n '^\[' "$T" | head -1 | cut -d: -f1)"
uninst
check "web search: uninstall removes the key it added" py "$T" "'web_search' not in d and d['model'] == 'gpt'"
check "web search: uninstall drops the state" test ! -e "$WS"

fresh
printf 'web_search = "live"\n%s' "$(cat "$T")" > "$T"
inst
check "web search: live → disabled" py "$T" "d['web_search'] == 'disabled'"
uninst
check "web search: uninstall puts live back" py "$T" "d['web_search'] == 'live'"

fresh
printf 'web_search = "disabled"\n%s' "$(cat "$T")" > "$T"
inst; uninst
check "web search: off by the user stays off after uninstall" py "$T" "d['web_search'] == 'disabled'"

fresh
printf 'web_search = "live"\n%s' "$(cat "$T")" > "$T"
inst --keep-codex-search
check "web search: --keep-codex-search leaves it on" py "$T" "d['web_search'] == 'live'"
check "web search: --keep-codex-search is recorded" test "$(cat "$WS")" = "kept"
inst
check "web search: a later plain install turns it off" py "$T" "d['web_search'] == 'disabled'"
inst --keep-codex-search
check "web search: --keep-codex-search after that restores live" py "$T" "d['web_search'] == 'live'"

fresh
printf '[features]\nhooks = true\n' > "$T"
inst
check "web search: config.toml with tables only — key at the top" py "$T" "d['web_search'] == 'disabled' and d['features']['hooks']"

fresh
mv "$T" "$H/.codex/mcp-disabled.toml"
printf 'model = "gpt"\n' > "$T"
inst
check "web search: parked ddg-search — built-in search left on" py "$T" "'web_search' not in d"

# ---------------------------------------------------------------- uninstall
fresh
inst
echo "# my note" >> "$H/.claude/rules/$RULE"
if uninst; then ok "uninstall finishes"; else no "uninstall" "$(tail -5 "$TMP/out")"; fi
check "uninstall: an edited rule is backed up first (review 2026-11-13 A4)" test "$(grep -l '# my note' "$H"/.local/state/ddg-search/backups/* 2>/dev/null | wc -l | tr -d ' ')" = 1
check "uninstall: claude entry gone, other kept" py "$C" "'ddg-search' not in d['mcpServers'] and 'other' in d['mcpServers']"
check "uninstall: codex section gone, rest kept" py "$T" "'ddg-search' not in d['mcp_servers'] and d['features']['hooks'] and 'web_search' not in d"
check "uninstall: opencode entry and rule gone" py "$O" "'ddg-search' not in d['mcp'] and len(d['instructions']) == 1"
check "uninstall: AGENTS.md line gone" test "$(cat "$H/.codex/AGENTS.md")" = "@/somewhere/other.md"
check "uninstall: rule files gone" test ! -e "$H/.claude/rules/$RULE" -a ! -e "$H/.codex/memories/$RULE"
after="$(state)"
uninst
check "second uninstall changes nothing" test "$after" = "$(state)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
