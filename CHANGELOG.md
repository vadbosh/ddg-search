# Changelog

## Unreleased

- The search queue of `lib/throttle.py` is shared by every session of the
  same user, not only within one session. Each search is sent under a lock on
  `~/.local/state/ddg-search/search.lock` (`DDG_LOCK_FILE` overrides it), and
  the file holds the time of the last search. So `DDG_MIN_INTERVAL` counts
  across sessions too. When the file cannot be opened, the queue works
  within the session only and says so once on stderr. `uninstall.sh`
  removes the file.

## 0.4.1 — 2026-11-14

- The rule: "No results" no longer means a block by itself. The server sends
  the same text for a block and for a query that matches nothing. After
  "No results" on a narrow query (quotes, `site:`), the model runs one broader
  search, and treats it as a block only if that search also returns nothing.
  On 2026-11-14 a Codex run stopped after two searches, although the IP was
  not blocked. Its second search was a quoted query with no matches. Five of
  its six topics were left unsearched.

## 0.4.0 — 2026-11-14

- The assistants start the server through `lib/throttle.py`, installed to
  `~/.local/share/ddg-search/`. It sends `search` calls to DuckDuckGo one at a
  time, at least `DDG_MIN_INTERVAL` seconds apart (default 2); everything else,
  `fetch_content` included, passes at once. A Codex run that opened with six
  parallel searches got "No results" — DuckDuckGo's bot block — for 25 of its
  31 searches. The server's own rate limiter does not prevent this: both
  strategies allow a burst as large as the per-minute limit (30).
- The rule: one search at a time; on a block, say so and go on without web
  search — do not retry and do not wait. With an earlier wording that allowed
  a pause, both Codex and Claude sat idle until their time ran out.
- New suite `tests/test_throttle.sh`, also run by the Docker `unit` and
  `py310` stages.

## 0.3.2 — 2026-11-13

- The server runs with `--ref-url-threshold 0`: search results carry full
  URLs. The default (120 characters) replaced longer ones with `ref://` tokens,
  and the model needed an extra `expand_link` call to see where a result
  pointed — 2 of 30 results on 2026-11-13.
- The rule gains search tactics: the specific term in the query, `site:` for
  documentation, a narrower second search when the top results are off-topic
  or one page in several versions.

## 0.3.1 — 2026-11-13

- The rule tells the model not to open a PDF with `fetch_content`: server
  0.7.0 returns the raw file. One PDF came back as 155 483 characters of
  `%PDF-1.6 …` in every parse mode and with every backend (upstream issue
  [#74](https://github.com/nickclyde/duckduckgo-mcp-server/issues/74)).

## 0.3.0 — 2026-11-13

- The server runs with `--fetch-backend auto`: `fetch_content` repeats a page
  request through `curl_cffi` when the site answers httpx with 403 or a
  Cloudflare challenge. The server default is httpx alone. Measured on
  2026-11-13: `extension.umn.edu` gave httpx 403 and `auto` the page. All three
  assistants get the new arguments with `./install.sh`. `lib/wire.py package`
  prints the package spec, which `install.sh` and `release.sh` now use.
- Codex: after 0.2.0 turned `web_search` off, Codex still searched through
  `codex_apps.search_service.web_run` — the same `web.run`, reaching the model
  as an app, which `web_search` does not control. The installer now also adds
  `[apps.connector_openai_search_service]` with `enabled = false`, only for
  this app. The previous value is saved with the `web_search` one, and
  `uninstall.sh` and `--keep-codex-search` put both back. A state file written
  by 0.2.0 is still read.
- The rule names `codex_apps.search_service.web_run` too.
- Following upstream: `./release.sh check` prints whether PyPI has a newer
  `duckduckgo-mcp-server` than the pin (information only; `not checked`
  offline). `./update.sh [VERSION]` moves the pin after checking that the
  version still has the `[browser]` extra, runs the tests and, unless
  `--no-docker`, a real install and search in Docker, then adds the change to
  `## Unreleased`. Any failure puts the old pin back. New suite:
  `tests/test_update.sh`.

## 0.2.1 — 2026-11-13

- Codex: the server entry gets `default_tools_approval_mode = "approve"`.
  Without it Codex asked for permission before every `search` and every
  `fetch_content`. All three tools of the server only read. A per-tool
  `approval_mode` set by hand is kept and still takes precedence.

## 0.2.0 — 2026-11-13

- Codex: the installer turns off Codex's own web search (`web.run`) with
  `web_search = "disabled"` at the top of `~/.codex/config.toml`. That tool is
  on by default (`cached`), and with it available Codex searched through
  `web.run` and not through ddg-search. The value it replaced is saved in
  `~/.local/state/ddg-search/codex-web-search`; `uninstall.sh` and
  `--keep-codex-search` put it back. A ddg-search disabled in Codex leaves the
  built-in search on.
- The rule names Codex's built-in search (`web.run`, `search_query`, `open`)
  as forbidden, next to `WebSearch`.

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
