#!/usr/bin/env bash
# Install ddg-search — Linux / macOS.
#
#   ./install.sh                       install into every assistant found
#   ./install.sh --dry-run             print what would happen, change nothing
#   ./install.sh --ide NAME            only claude, codex or opencode
#   ./install.sh --no-rule             the MCP server only, no rule file
#   ./install.sh --search-backend B    auto (default), httpx or curl
#   ./install.sh --no-server           configuration only: no uv check, no
#                                      download of the server
#   ./install.sh --keep-codex-search   leave Codex's built-in web search on
#
# What goes where:
#   the MCP server ddg-search          duckduckgo-mcp-server[browser], pinned,
#                                      run by uvx; downloaded once here so the
#                                      first start in an assistant is fast
#   ~/.claude.json  ~/.claude/mcp.json  ~/.codex/config.toml  opencode.json
#                                      the server entry, wired by lib/wire.py
#   ~/.codex/config.toml               web_search = "disabled": Codex's own
#                                      search tool off, so the model uses
#                                      ddg-search; uninstall.sh restores it
#   ~/.claude/rules/  ~/.codex/memories/  ~/.config/opencode/instructions/
#                                      disable-broken-google-search.md, the rule
#                                      that makes the model search through it
#
# Needs python3 (3.8 or newer) and uv. Idempotent: a second run changes
# nothing. A file it would overwrite with different content is backed up to
# ~/.local/state/ddg-search/backups/ first. Nothing outside $HOME is written.
set -euo pipefail

# Not ${1/#$HOME/\~}: bash 3.2, the one macOS ships, keeps the backslash.
tilde() { case "$1" in "$HOME"*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/ddg-search"
RULE="disable-broken-google-search.md"
DRY_RUN=0
WITH_RULE=1
WITH_SERVER=1
KEEP_CODEX_SEARCH=0
BACKEND="auto"
ONLY_IDE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)        DRY_RUN=1 ;;
        --no-rule)        WITH_RULE=0 ;;
        --no-server)      WITH_SERVER=0 ;;
        --keep-codex-search) KEEP_CODEX_SEARCH=1 ;;
        # A bare `shift` past the last argument would end the script silently
        # under set -e; say what is missing instead.
        --ide)            [ $# -ge 2 ] || { echo "--ide needs a value: claude, codex or opencode" >&2; exit 2; }
                          ONLY_IDE="$2"; shift ;;
        --search-backend) [ $# -ge 2 ] || { echo "--search-backend needs a value: auto, httpx or curl" >&2; exit 2; }
                          BACKEND="$2"; shift ;;
        # The header comment, however long it gets: up to the first code line.
        -h|--help)        awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)                echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
case "$ONLY_IDE" in ""|claude|codex|opencode) ;; *) echo "--ide: claude, codex or opencode" >&2; exit 2 ;; esac
case "$BACKEND" in auto|httpx|curl) ;; *) echo "--search-backend: auto, httpx or curl" >&2; exit 2 ;; esac

say() { printf '%s\n' "$*"; }
bad() { printf '%s\n' "$*" >&2; }

command -v python3 >/dev/null 2>&1 || { bad "ddg-search needs python3 (3.8 or newer)"; exit 1; }
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || { bad "ddg-search needs python 3.8 or newer"; exit 1; }

STAMP="$(date +%Y%m%d-%H%M%S)"

# install_file SRC DST — copy if missing or different; back up what it replaces.
install_file() {
    local src="$1" dst="$2"
    if [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst"; then
        say "    = $(tilde "$dst")"; return
    fi
    if [ "$DRY_RUN" -eq 1 ]; then say "    would write $(tilde "$dst")"; return; fi
    mkdir -p "$(dirname "$dst")"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        if [ -f "$dst" ] && [ ! -L "$dst" ]; then
            mkdir -p "$STATE/backups" && chmod 700 "$STATE" "$STATE/backups"
            cp -p "$dst" "$STATE/backups/$(basename "$dst").bak.$STAMP"
        fi
        rm -f "$dst"
        say "    ~ $(tilde "$dst")"
    else
        say "    + $(tilde "$dst")"
    fi
    cp "$src" "$dst"
    chmod 644 "$dst"
}

# ---------------------------------------------------------------- the server
SPEC="$(python3 "$SRC/lib/wire.py" spec | tail -1)"
if [ "$WITH_SERVER" -eq 1 ]; then
    say "server: $SPEC"
    if ! command -v uvx >/dev/null 2>&1; then
        bad "  uv is not installed — the assistants start the server with uvx."
        bad "  Install it, then run this again:"
        if [ "$(uname -s)" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
            bad "    brew install uv"
        fi
        bad "    curl -LsSf https://astral.sh/uv/install.sh | sh"
        bad "  Or ./install.sh --no-server to write the configuration only."
        # --dry-run still shows what the configuration would get.
        [ "$DRY_RUN" -eq 1 ] || exit 1
        bad "  --dry-run: going on to the configuration."
    elif [ "$DRY_RUN" -eq 1 ]; then
        say "    would download it with uvx (and Python 3.12 if uv has none)"
    else
        # Fetches the package, curl_cffi and, when missing, a uv-managed Python
        # 3.12 into uv's cache. --help starts the server's argument parser and
        # exits, so this also proves the command the assistants will run.
        # shellcheck disable=SC2046
        if out="$(uvx $(python3 "$SRC/lib/wire.py" spec | sed -n '2,$p') --help 2>&1)"; then
            say "    = ready ($(uvx --version 2>/dev/null))"
        else
            bad "    uvx could not start the server:"
            printf '%s\n' "$out" | tail -5 | sed 's/^/      /' >&2
            exit 1
        fi
    fi
fi

# ---------------------------------------------------------------- assistants
found=0
failed=0
for ide in claude codex opencode; do
    [ -n "$ONLY_IDE" ] && [ "$ide" != "$ONLY_IDE" ] && continue
    case "$ide" in
        claude)   dir="$HOME/.claude";          rules="$HOME/.claude/rules" ;;
        codex)    dir="$HOME/.codex";           rules="$HOME/.codex/memories" ;;
        opencode) dir="$HOME/.config/opencode"; rules="$HOME/.config/opencode/instructions" ;;
    esac
    if [ ! -d "$dir" ]; then
        say "$ide: not installed here ($(tilde "$dir") missing) — skipped"
        continue
    fi
    found=$((found + 1))
    say "$ide:"
    [ "$WITH_RULE" -eq 1 ] && install_file "$SRC/rules/$RULE" "$rules/$RULE"
    args=("$ide" --search-backend "$BACKEND")
    [ "$WITH_RULE" -eq 1 ] || args+=(--no-rule)
    [ "$DRY_RUN" -eq 1 ] && args+=(--dry-run)
    [ "$ide" = codex ] && [ "$KEEP_CODEX_SEARCH" -eq 1 ] && args+=(--keep-codex-search)
    rc=0
    python3 "$SRC/lib/wire.py" "${args[@]}" || rc=$?
    case "$rc" in 0|3) ;; *) failed=$((failed + 1)) ;; esac
done

if [ "$found" -eq 0 ]; then
    bad "no assistant found: none of ~/.claude, ~/.codex, ~/.config/opencode exists"
    exit 1
fi
[ "$failed" -eq 0 ] || { bad "$failed assistant(s) not wired — see above"; exit 1; }
[ "$DRY_RUN" -eq 1 ] && exit 0
say "done. Restart the assistants that are running: they read MCP servers at start."
