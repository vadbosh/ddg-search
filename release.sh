#!/usr/bin/env bash
# release.sh — keep the changelog, the tag and the installed copies in agreement.
#
#   ./release.sh check     say whether they agree; exit 3 if they do not
#   ./release.sh tag       create the missing annotated tag for the current version
#
# The newest numbered heading in CHANGELOG.md (`## 0.1.0 — 2026-11-13`) is the
# version of this repository. The server version is VERSION in lib/wire.py. A
# release is: rename `## Unreleased` to the number and date, commit,
# `./release.sh tag`, push with --follow-tags, ./install.sh. `check` says which
# of those steps is missing, including the last one: an installed copy or a
# server entry that is behind is the one that runs.
set -uo pipefail

tilde() { case "$1" in "$HOME"*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SRC" || exit 2
RULE="disable-broken-google-search.md"

version() {
    sed -n 's/^## \([0-9][0-9.]*\) — .*/\1/p' CHANGELOG.md | head -1
}

installed() {
    cat <<EOF
rules/$RULE $HOME/.claude/rules/$RULE
rules/$RULE $HOME/.codex/memories/$RULE
rules/$RULE $HOME/.config/opencode/instructions/$RULE
EOF
}

check() {
    local v bad=0 n=0 stale=0 ide rc
    v="$(version)"
    if [ -z "$v" ]; then echo "  version:      none — no '## X.Y.Z — date' heading in CHANGELOG.md"; return 3; fi
    echo "  version:      $v (CHANGELOG.md), server $(python3 lib/wire.py package)"
    if git rev-parse -q --verify "refs/tags/v$v" >/dev/null; then
        echo "  git tag:      v$v exists"
        local since
        since="$(git rev-list --count "v$v..HEAD")"
        if [ "$since" -eq 0 ]; then
            echo "  unreleased:   nothing since v$v"
        else
            echo "  unreleased:   $since commit(s) since v$v"
            grep -q '^## Unreleased' CHANGELOG.md || { echo "                and no '## Unreleased' section describes them"; bad=1; }
        fi
    else
        echo "  git tag:      v$v MISSING — ./release.sh tag"; bad=1
    fi
    [ -z "$(git status --porcelain)" ] || { echo "  working tree: uncommitted changes"; bad=1; }
    while read -r src dst; do
        [ -e "$dst" ] || continue
        n=$((n + 1))
        if ! cmp -s "$src" "$dst"; then echo "  installed:    $(tilde "$dst") differs from $src — ./install.sh"; stale=1; fi
    done < <(installed)
    [ "$stale" -eq 0 ] && echo "  installed:    $n rule cop(ies), all identical to this checkout"
    # The backend and --keep-codex-search are whatever the last install chose;
    # --check compares the rest.
    for ide in claude codex opencode; do
        backend="$(installed_backend "$ide")"
        keep=()
        [ "$ide" = codex ] && [ "$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/ddg-search/codex-web-search" 2>/dev/null)" = kept ] \
            && keep=(--keep-codex-search)
        python3 lib/wire.py "$ide" --check --search-backend "$backend" ${keep[@]+"${keep[@]}"} >/dev/null 2>&1; rc=$?
        case "$rc" in
            0) echo "  server entry: $ide current" ;;
            3) ;;
            4) echo "  server entry: $ide behind this checkout — ./install.sh"; stale=1 ;;
            *) echo "  server entry: $ide unreadable — python3 lib/wire.py $ide --check"; stale=1 ;;
        esac
    done
    [ "$stale" -eq 0 ] || bad=1
    # Information only: a newer upstream is not a defect of this release, and
    # an unreachable PyPI must not fail a check made offline.
    echo "  $(python3 lib/upstream.py 2>&1 | tail -1)"
    if [ "$bad" -eq 0 ]; then echo "  everything agrees on $v"; return 0; fi
    return 3
}

# The DDG_SEARCH_BACKEND an earlier install wrote, so check does not report a
# deliberate --search-backend as drift. auto when none is set.
installed_backend() {
    local f
    case "$1" in
        claude)   f="$HOME/.claude.json" ;;
        codex)    f="$HOME/.codex/config.toml" ;;
        opencode) f="$HOME/.config/opencode/opencode.json" ;;
    esac
    [ -f "$f" ] || { echo auto; return; }
    python3 - "$f" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'"?DDG_SEARCH_BACKEND"?\s*[:=]\s*"(auto|httpx|curl)"', text)
print(m.group(1) if m else "auto")
PY
}

make_tag() {
    local v
    v="$(version)"
    [ -n "$v" ] || { echo "no version in CHANGELOG.md" >&2; return 2; }
    if git rev-parse -q --verify "refs/tags/v$v" >/dev/null; then echo "v$v already exists"; return 0; fi
    [ -z "$(git status --porcelain)" ] || { echo "commit first: the tag must point at what CHANGELOG.md describes" >&2; return 2; }
    git tag -a "v$v" -m "ddg-search $v"
    echo "created v$v at $(git rev-parse --short HEAD)"
    echo "push it with:  git push --follow-tags"
}

case "${1:-check}" in
    check) check ;;
    tag)   make_tag ;;
    *)     sed -n '2,12p' "$0" | sed -e 's/^# //' -e 's/^#$//'; exit 2 ;;
esac
