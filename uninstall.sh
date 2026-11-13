#!/usr/bin/env bash
# Remove ddg-search — Linux / macOS.
#
#   ./uninstall.sh              remove from every assistant
#   ./uninstall.sh --dry-run    print what would happen, change nothing
#   ./uninstall.sh --ide NAME   only claude, codex or opencode
#
# Takes out the ddg-search server entry (active or parked), the rule file and
# its references. Configuration files, and a rule edited by hand, are backed
# up first, to
# ~/.local/state/ddg-search/backups/. uv's cache is left alone: `uv cache clean
# duckduckgo-mcp-server` removes the downloaded package.
set -euo pipefail

tilde() { case "$1" in "$HOME"*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE="disable-broken-google-search.md"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ddg-search"
STAMP="$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
ONLY_IDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --ide)     [ $# -ge 2 ] || { echo "--ide needs a value: claude, codex or opencode" >&2; exit 2; }
                   ONLY_IDE="$2"; shift ;;
        # The header comment, however long it gets: up to the first code line.
        -h|--help) awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)         echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$ONLY_IDE" in ""|claude|codex|opencode) ;; *) echo "--ide: claude, codex or opencode" >&2; exit 2 ;; esac
command -v python3 >/dev/null 2>&1 || { echo "uninstall needs python3" >&2; exit 1; }

failed=0
for ide in claude codex opencode; do
    [ -n "$ONLY_IDE" ] && [ "$ide" != "$ONLY_IDE" ] && continue
    case "$ide" in
        claude)   rules="$HOME/.claude/rules" ;;
        codex)    rules="$HOME/.codex/memories" ;;
        opencode) rules="$HOME/.config/opencode/instructions" ;;
    esac
    printf '%s:\n' "$ide"
    if [ -e "$rules/$RULE" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then printf '    would remove %s\n' "$(tilde "$rules/$RULE")"
        else
            # A copy edited by hand is kept, as install.sh keeps what it overwrites.
            if [ -f "$rules/$RULE" ] && ! cmp -s "$SRC/rules/$RULE" "$rules/$RULE"; then
                mkdir -p "$STATE/backups" && chmod 700 "$STATE" "$STATE/backups"
                cp -p "$rules/$RULE" "$STATE/backups/$RULE.bak.$STAMP"
                printf '    edited copy kept in %s\n' "$(tilde "$STATE/backups/$RULE.bak.$STAMP")"
            fi
            rm -f "$rules/$RULE"; printf '    - %s\n' "$(tilde "$rules/$RULE")"
        fi
    fi
    args=("$ide" --remove)
    [ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
    rc=0
    python3 "$SRC/lib/wire.py" "${args[@]}" || rc=$?
    case "$rc" in 0|3) ;; *) failed=$((failed + 1)) ;; esac
done
[ "$failed" -eq 0 ] || { echo "$failed assistant(s) not cleaned — see above" >&2; exit 1; }
