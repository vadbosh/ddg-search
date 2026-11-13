# Changelog

## 0.1.3 — 2026-11-13

Fixes from `review-2026-11-13-installer.md`.

- Codex: a `[mcp_servers.ddg-search]` header with a trailing comment or inner
  spaces, and quoted keys, made the installer write a second table. Codex then
  failed with "failed to load bootstrap configuration" (A1). Such headers and
  keys are now recognised. A server written as an inline table is refused
  (exit 1, file untouched). With Python 3.11 or newer, `config.toml` is parsed
  before and after the edit, and an edit that would not parse is refused.
- Codex: variables in an inline `env = { … }` were dropped; they are now
  moved into the `env` table (A2).
- A remote entry named `ddg-search` kept its `url` and `type: http`, so the
  assistant stayed on the URL. Those keys are now dropped (A3).
- `uninstall.sh` backs up a rule edited by hand before removing it (A4).
- `--ide` and `--search-backend` without a value exit 2 with a message, not 1
  in silence (A5).
- `--dry-run` without uv shows the configuration changes and exits 0 (B1).
- `--help` of `uninstall.sh` no longer prints a line of code (B2). Both
  scripts print their header up to the first line of code.
- The docstring of `lib/wire.py` and both READMEs say that the layout of a
  file can change (B3).
- `tests/docker.sh py310`: the suite under Python 3.10, without `tomllib`.

## 0.1.2 — 2026-11-13

- README: Python 3.12, when uv has none, is downloaded by `./install.sh`
  together with the server, not on the first start in an assistant. The
  DuckDuckGo answer to `curl_cffi` is named for what it is, a bot-check page.
  The Russian version had several sentences rewritten for clarity.

## 0.1.1 — 2026-11-13

- The repository is public: https://github.com/vadbosh/ddg-search. Both
  READMEs clone from that URL.
- `.gitignore` carries the ai-gitignore managed block: AI-assistant files and
  local noise stay out of the repository.

## 0.1.0 — 2026-11-13

First release. Before it, the ddg-search MCP entry and the rule
`disable-broken-google-search.md` lived in the ai-config-source canon.

- `install.sh` registers `duckduckgo-mcp-server[browser]==0.7.0` in Claude
  Code, Codex and Opencode, and installs the rule. It downloads the server with
  `uvx` once, so the first start in an assistant is fast.
- The `[browser]` extra is always installed. Without it, DuckDuckGo blocks the
  httpx TLS fingerprint and every search returns "No results were found".
- The search backend stays `auto` by default. `--search-backend curl` is
  available, but on 2026-11-13 DuckDuckGo answered the Chrome fingerprint of
  `curl_cffi` with an HTTP 202 anomaly page from the second search on, while
  httpx got HTTP 200. The server reports that page as "No results"
  ([upstream issue #78](https://github.com/nickclyde/duckduckgo-mcp-server/issues/78)).
- Disabled servers stay disabled: an entry in `~/.claude/mcp-disabled.json` or
  `~/.codex/mcp-disabled.toml` is updated in that file, and Opencode keeps
  `"enabled": false`.
- `uninstall.sh`, `release.sh`, `tests/test_install.sh` and `tests/docker.sh`
  (bash 3.2 suite, then a real install and search on a clean Debian).
