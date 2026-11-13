# Changelog

## 0.1.0 — 2026-11-13

First release. Before it, the ddg-search MCP entry and the rule
`disable-broken-google-search.md` lived in the ai-config-source canon.

- `install.sh` registers `duckduckgo-mcp-server[browser]==0.7.0` in Claude
  Code, Codex and Opencode, and installs the rule. It downloads the server with
  `uvx` once, so the first start in an assistant is fast.
- The `[browser]` extra is always installed. Without it, DuckDuckGo blocks the
  httpx TLS fingerprint and every search returns "No results were found".
- The search backend stays `auto` by default. `--search-backend curl` is
  available, but on 2026-11-13 the first `curl` search from a new process
  returned no results in 3 of 3 runs.
- Disabled servers stay disabled: an entry in `~/.claude/mcp-disabled.json` or
  `~/.codex/mcp-disabled.toml` is updated in that file, and Opencode keeps
  `"enabled": false`.
- `uninstall.sh`, `release.sh`, `tests/test_install.sh` and `tests/docker.sh`
  (bash 3.2 suite, then a real install and search on a clean Debian).
