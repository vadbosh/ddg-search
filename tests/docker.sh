#!/usr/bin/env bash
# tests/docker.sh — the installer on clean machines.
#
#   bash tests/docker.sh            both stages
#   bash tests/docker.sh unit       tests/test_install.sh under bash 3.2
#   bash tests/docker.sh e2e        a real install, then a real search
#
# unit  image bash:3.2 (the bash macOS ships) plus python3: the whole
#       test_install.sh suite, so a bash 4 construct in a script fails here.
# e2e   image ghcr.io/astral-sh/uv:bookworm-slim plus Debian's python3 (3.11):
#       a fresh HOME with the three assistants' directories and nothing in
#       them, ./install.sh with the server download, a second run that must
#       change nothing, then tests/mcp_probe.py for each assistant — the
#       server started from the installed entry, one search through MCP.
#       uv has no Python 3.12 there, so the install also proves that uvx
#       fetches the interpreter the entry asks for. Needs network.
#
# The checkout is mounted read-only; nothing on the host is written.
set -euo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="${1:-all}"
command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }

unit() {
    echo "== unit: bash 3.2"
    docker run --rm -v "$SRC:/src:ro" bash:3.2 bash -c '
        set -e
        apk add --no-cache python3 >/dev/null
        echo "bash $BASH_VERSION, $(python3 --version)"
        bash /src/tests/test_install.sh -q'
}

e2e() {
    echo "== e2e: fresh Debian, real server"
    docker run --rm -v "$SRC:/src:ro" ghcr.io/astral-sh/uv:bookworm-slim bash -c '
        set -e
        apt-get update -qq >/dev/null && apt-get install -y -qq python3 ca-certificates >/dev/null
        echo "$(python3 --version), $(uv --version), python 3.12 managed by uv: $(uv python find 3.12 2>/dev/null || echo none)"
        mkdir -p ~/.claude ~/.codex ~/.config/opencode
        /src/install.sh
        echo "-- second run"
        out="$(/src/install.sh)"; echo "$out"
        if echo "$out" | grep -q "would\|added\|updated\| + \| ~ "; then echo "FAIL: second run changed something"; exit 1; fi
        for ide in claude codex opencode; do
            echo "-- probe $ide"
            python3 /src/tests/mcp_probe.py "$ide"
        done
        echo "-- uninstall"
        /src/uninstall.sh
        python3 -c "import json,os; d=json.load(open(os.path.expanduser(\"~/.claude.json\"))); assert \"ddg-search\" not in d.get(\"mcpServers\", {})"
        echo "e2e: ok"'
}

case "$STAGE" in
    unit) unit ;;
    e2e)  e2e ;;
    all)  unit; e2e ;;
    *)    sed -n '2,18p' "$0" | sed -e 's/^# //' -e 's/^#$//'; exit 2 ;;
esac
