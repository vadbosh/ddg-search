# ddg-search

An installer for the DuckDuckGo search MCP server
([duckduckgo-mcp-server](https://github.com/nickclyde/duckduckgo-mcp-server))
in Claude Code, Codex and Opencode, on Linux and macOS. It also installs a
rule that tells the model to search through this server and not through
built-in search tools.

[Русская версия](README.RU.md)

## Why the [browser] extra

DuckDuckGo checks the TLS fingerprint of the client. The server's default HTTP
client is httpx. When DuckDuckGo blocks that fingerprint, it answers with an
empty HTTP 202 page. Every search then returns this message:

```
No results were found for your search query. This could be due to DuckDuckGo's
bot detection or the query returned no matches.
```

The `[browser]` extra installs `curl_cffi`. With it, the server repeats a
blocked search with the TLS fingerprint of Chrome. This installer always
installs the extra and pins the server version:

```
uvx --python 3.12 duckduckgo-mcp-server[browser]==0.7.0
```

The server version changes only with a release of this repository. It is
`VERSION` in `lib/wire.py`.

## Requirements

- python3, version 3.8 or newer: the installer edits the configuration with it
- [uv](https://docs.astral.sh/uv/): the assistants start the server with
  `uvx`. If uv has no Python 3.12, `uvx` downloads it on the first run

Without uv, `./install.sh` stops and prints the install command for uv.

## Install

```bash
git clone <this repository> ~/src/ddg-search
cd ~/src/ddg-search
./install.sh
```

Then restart the assistants that are running: they read the list of MCP
servers only at start.

| Option | What it does |
|---|---|
| `--dry-run` | print the changes, write nothing |
| `--ide NAME` | install into one assistant: `claude`, `codex` or `opencode` |
| `--no-rule` | install the MCP server only, without the rule |
| `--search-backend B` | `auto` (default), `httpx` or `curl` |
| `--no-server` | write the configuration only; do not check uv, do not download the server |

`auto` sends a search through httpx first and repeats it through `curl_cffi`
when DuckDuckGo blocks it. `curl` sends every search through `curl_cffi` at
once. On 2026-11-13, DuckDuckGo answered httpx with HTTP 200. It answered the
Chrome fingerprint of `curl_cffi` with HTTP 202, an anomaly page, from the
second search on. The server reports such a page as "No results"
([issue #78](https://github.com/nickclyde/duckduckgo-mcp-server/issues/78)).
For this reason, `auto` is the default.

The installer is idempotent: a second run changes nothing. Before it
overwrites a file, it copies the file to `~/.local/state/ddg-search/backups/`.
It writes nothing outside `$HOME`.

## What goes where

| Assistant | Server entry | Rule |
|---|---|---|
| Claude Code | `~/.claude.json`, key `mcpServers`; also `~/.claude/mcp.json` if that file exists | `~/.claude/rules/` |
| Codex | `~/.codex/config.toml`, section `[mcp_servers.ddg-search]` | `~/.codex/memories/`, and an `@` line in `~/.codex/AGENTS.md` |
| Opencode | `opencode.json`, key `mcp`, with `"codemode": false` | `~/.config/opencode/instructions/`, listed in `instructions` |

With `"codemode": false`, Opencode shows the server's tools as ordinary tools:
`ddg-search_search` and `ddg-search_fetch_content`. The rule uses these
names.

The installer owns only the entry named `ddg-search`. In that entry it sets
the command, the arguments and the variable `DDG_SEARCH_BACKEND`. It keeps all
other keys of the entry, for example `startup_timeout_sec` or `DDG_REGION`. It
does not change other servers.

If the installer cannot read a configuration file, for example a broken
`opencode.json`, it does not change that file and exits with code 1. It still
installs into the other assistants.

### Disabled servers

Some setups disable an MCP server by moving its entry to a second file:
`~/.claude/mcp-disabled.json` for Claude Code, `~/.codex/mcp-disabled.toml`
for Codex. If `ddg-search` is in that file, the installer updates the entry
there and does not enable the server. In Opencode it keeps
`"enabled": false`.

## Uninstall

```bash
./uninstall.sh            # or --dry-run, --ide NAME
```

The script removes the server entry, the rule and the references to the rule.
It does not clean uv's cache. To remove the downloaded package, run
`uv cache clean duckduckgo-mcp-server`.

## Tests

```bash
bash tests/test_install.sh   # a temporary HOME; the real configuration is not touched
bash tests/docker.sh         # in Docker: the suite under bash 3.2, then a real install
```

`tests/docker.sh` has two stages:

- `unit`: runs `test_install.sh` under bash 3.2, the version macOS ships.
- `e2e`: on a clean Debian, installs the server and starts it from the entry
  of each assistant. Then it runs one search through MCP and checks that the
  search returns links. This stage needs network access.

`tests/mcp_probe.py claude` runs the same search check against the
configuration on this machine.

## Release

`./release.sh check` compares the version in `CHANGELOG.md`, the git tag, the
installed copies of the rule and the server entries in the assistants. If
they differ, it exits with code 3. `./release.sh tag` creates the tag.

## License

MIT
