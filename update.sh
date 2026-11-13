#!/usr/bin/env bash
# Move the pinned duckduckgo-mcp-server to a newer upstream version.
#
#   ./update.sh               the newest version on PyPI
#   ./update.sh 0.8.0         that version
#   ./update.sh --no-docker   skip the real install and search in Docker
#
# Steps: refuse on a dirty working tree; refuse when the version no longer
# declares the [browser] extra (without it DuckDuckGo blocks every search);
# set VERSION in lib/wire.py; run tests/test_install.sh and, unless
# --no-docker, tests/docker.sh e2e — the new server installed on a clean
# Debian and one real search through MCP per assistant; add the change to
# `## Unreleased` in CHANGELOG.md. Any failure puts the old pin back.
#
# It does not commit, tag or install: review the diff, then release (/release
# or ./release.sh), then ./install.sh on each machine.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC"
WANT=""
DOCKER=1
while [ $# -gt 0 ]; do
    case "$1" in
        --no-docker) DOCKER=0 ;;
        -h|--help)   awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        -*)          echo "unknown option: $1" >&2; exit 2 ;;
        *)           WANT="$1" ;;
    esac
    shift
done

pinned="$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' lib/wire.py)"
[ -n "$pinned" ] || { echo "no VERSION line in lib/wire.py" >&2; exit 1; }
if [ -z "$WANT" ]; then
    WANT="$(python3 lib/upstream.py --latest)" || { echo "PyPI unreadable" >&2; exit 1; }
fi
echo "pinned $pinned, target $WANT"
if [ "$WANT" = "$pinned" ]; then echo "already at $pinned — nothing to do"; exit 0; fi

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    echo "working tree has uncommitted changes — commit or stash them first" >&2; exit 1
fi
if ! python3 lib/upstream.py --browser "$WANT"; then
    echo "$WANT does not declare the [browser] extra (or PyPI has no such version) — not updating" >&2
    exit 1
fi

backup="$(mktemp)"
cp lib/wire.py "$backup"
restore() { cp "$backup" lib/wire.py; echo "pin restored to $pinned" >&2; }
sed -i.tmp "s/^VERSION = \"$pinned\"$/VERSION = \"$WANT\"/" lib/wire.py && rm -f lib/wire.py.tmp
grep -q "^VERSION = \"$WANT\"$" lib/wire.py || { restore; echo "could not set VERSION" >&2; exit 1; }
echo "pin $pinned → $WANT (lib/wire.py)"

if ! bash tests/test_install.sh -q; then restore; exit 1; fi
if [ "$DOCKER" -eq 1 ]; then
    if ! bash tests/docker.sh e2e; then restore; exit 1; fi
fi

note="- Server: duckduckgo-mcp-server $pinned → $WANT ([release notes](https://github.com/nickclyde/duckduckgo-mcp-server/releases/tag/v$WANT))."
python3 - "$note" <<'PY'
import sys
note = sys.argv[1]
text = open("CHANGELOG.md", encoding="utf-8").read()
if "\n## Unreleased\n\n" in text:
    # First item of the existing section.
    text = text.replace("\n## Unreleased\n\n", "\n## Unreleased\n\n" + note + "\n", 1)
else:
    # A new section above the newest release.
    at = text.index("\n## ")
    text = text[:at] + "\n## Unreleased\n\n" + note + "\n" + text[at:]
open("CHANGELOG.md", "w", encoding="utf-8").write(text)
PY
echo "CHANGELOG.md: $note"
echo "next: review git diff, commit, release (/release), then ./install.sh"
