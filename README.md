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
  `uvx`. If uv has no Python 3.12, `./install.sh` downloads it together with
  the server

Without uv, `./install.sh` stops and prints the install command for uv.

## Install

```bash
git clone https://github.com/vadbosh/ddg-search ~/src/ddg-search
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
| `--keep-codex-search` | leave the built-in web search of Codex on |

`auto` sends a search through httpx first and repeats it through `curl_cffi`
when DuckDuckGo blocks it. `curl` sends every search through `curl_cffi` at
once. On 2026-11-13, DuckDuckGo answered httpx with HTTP 200. From the second
search on, it answered the Chrome fingerprint of `curl_cffi` with HTTP 202 and
a bot-check page. The server reports such a page as "No results"
([issue #78](https://github.com/nickclyde/duckduckgo-mcp-server/issues/78)).
For this reason, `auto` is the default.

The installer is idempotent: a second run changes nothing. Before it
overwrites a file, it copies the file to `~/.local/state/ddg-search/backups/`.
It writes nothing outside `$HOME`.

## What goes where

| Assistant | Server entry | Rule |
|---|---|---|
| Claude Code | `~/.claude.json`, key `mcpServers`; also `~/.claude/mcp.json` if that file exists | `~/.claude/rules/` |
| Codex | `~/.codex/config.toml`, section `[mcp_servers.ddg-search]`, with `default_tools_approval_mode = "approve"` | `~/.codex/memories/`, and an `@` line in `~/.codex/AGENTS.md` |
| Opencode | `opencode.json`, key `mcp`, with `"codemode": false` | `~/.config/opencode/instructions/`, listed in `instructions` |

With `"codemode": false`, Opencode shows the server's tools as ordinary tools:
`ddg-search_search` and `ddg-search_fetch_content`. The rule uses these
names.

Without `default_tools_approval_mode = "approve"`, Codex asks for permission
before every search and every page fetch. All three tools of the server only
read.

Codex has its own web search tool, `web.run`, and it is on by default. With
it available, Codex searched through `web.run` and not through ddg-search,
although the rule forbids it. So the installer also sets
`web_search = "disabled"` at the top of `~/.codex/config.toml`. It saves the
value it replaced in `~/.local/state/ddg-search/codex-web-search`, and
`./uninstall.sh` puts that value back. To keep the built-in search on, run
`./install.sh --keep-codex-search`. If ddg-search is disabled in Codex, the
installer leaves the built-in search on.

The installer owns only the entry named `ddg-search`. In that entry it sets
the command, the arguments and the variable `DDG_SEARCH_BACKEND`. It keeps all
other keys of the entry, for example `startup_timeout_sec` or `DDG_REGION`. It
does not change other servers.

If the installer cannot read a configuration file, for example a broken
`opencode.json`, it does not change that file and exits with code 1. It still
installs into the other assistants.

The installer edits `config.toml` of Codex as text. It refuses, in the same
way, when `ddg-search` there is written as an inline table
(`ddg-search = { … }` under `[mcp_servers]`). Rewrite it as a
`[mcp_servers.ddg-search]` table, or remove it, and run the installer again.
With Python 3.11 or newer, the installer also parses the file. It refuses when
the file does not parse, or would not parse after the edit.

The layout of a file can change. JSON files are written back with two-space
indentation, and `config.toml` gets LF line endings.

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
If the rule was edited by hand, the script first copies it to
`~/.local/state/ddg-search/backups/`. It does not clean uv's cache. To remove the downloaded package, run
`uv cache clean duckduckgo-mcp-server`.

## Tests

```bash
bash tests/test_install.sh   # a temporary HOME; the real configuration is not touched
bash tests/docker.sh         # in Docker: the suite under bash 3.2 and Python 3.10, then a real install
```

`tests/docker.sh` has three stages:

- `unit`: runs `test_install.sh` under bash 3.2, the version macOS ships.
- `py310`: runs `test_install.sh` under Python 3.10, which has no `tomllib`.
  There the installer edits `config.toml` without a parser.
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
