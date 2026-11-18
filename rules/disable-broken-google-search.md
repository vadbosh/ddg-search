# Web Search

**NEVER `google_search`** — always fails `403 CONSUMER_INVALID`, permanently broken here. Don't retry "to check".

**NEVER native `WebSearch` / `websearch`** — verbose overhead; ddg-search gives the same data in fewer tokens.

**NEVER Codex's built-in web search** — `web.run` with `search_query` / `open`, whether it comes as the `web_search` tool or as the app tool `codex_apps.search_service.web_run`. It is the same kind of native search. The ddg-search installer turns both off (`web_search = "disabled"` and `[apps.connector_openai_search_service] enabled = false` in `~/.codex/config.toml`); if either is offered anyway, search and fetch pages through ddg-search all the same.

**ddg-search tool names differ per IDE — use the one for yours, exactly:**

| IDE | search | fetch page |
|---|---|---|
| Claude Code | `mcp__ddg-search__search` | `mcp__ddg-search__fetch_content` |
| Opencode | `ddg-search_search` | `ddg-search_fetch_content` |
| Codex | `search` in namespace `mcp__ddg_search` | `fetch_content` in namespace `mcp__ddg_search` |

In Opencode the server runs with `codemode: false`, so these are ordinary tools on the native list. A bare `ddg-search` or `search` is not a tool there and fails with `No tool named ...`. If the native list has no `ddg-search_*` (the server is back in Code Mode), call it inside `execute`: `await tools["ddg-search"].search({query: "..."})`.

**Search tactics — DuckDuckGo matches words, it does not interpret the question:**

- 3 to 6 words, built from the specific term — the argument name, the exception name, the version — not a description of it: `aws_eks_cluster authentication_mode`, not `how to set EKS auth in terraform`.
- **No quotes, no `site:`, no pasted URL, no whole error message, never more than 7 words.** Through this server each of these comes back "No results" while the IP is not blocked. Measured 2026-11-18, with every control query in between returning results: quotes 0 of 5 (even `"asyncio" tutorial`), `site:` 0 of 7 on four official domains, 8 words or more 0 of 4, a URL 0 of 1, a 200-character question 0 of 1. `-word`, `OR`, `intitle:` and `filetype:` did work.
- For documentation, put the domain or the product in as a plain word instead of `site:`: `tomllib docs.python.org`, `aws_eks_cluster terraform registry`, `kubernetes 1.34 release notes` — each returned the official page first.
- For an error, take the exception name and two or three words of the message: `TOMLDecodeError Expected after key`, not the whole message.
- Read the titles first. If the top results are off-topic, search again with one more word from the question, staying within 7 words, before fetching anything.
- A query in Russian is answered with Russian pages; for technical material an English query usually finds the primary source.

**One search at a time, and stop when blocked:**

- Never send several ddg-search searches in parallel. DuckDuckGo blocks a burst: on 2026-11-14 a run that opened with six parallel searches got "No results" for 25 of its 31 searches.
- "No results were found … DuckDuckGo's bot detection or the query returned no matches" is the same text for a block and for a query that matches nothing, and the shapes listed above match nothing. Tell them apart with **one** check search, never more: 2 to 5 common words on the same topic, no quotes, no `site:`, no rare identifier — `windows explorer context menu registry`, not the failed query with its quotes removed.
  - The check returns results → the IP is not blocked; go on with short queries. On 2026-11-18 a session searched `"Windows.navpane" "Windows.previewpane" …`, then `add Layout context menu Windows navigation pane details pane preview pane registry` — 11 words, still too long — took the second "No results" for a block and answered from memory. The 5-word check above returned results that same minute.
  - The check also says "No results" → **blocked**. Do not search again — each retry is another request into the block. Do not wait for it to lift either: a Codex run that paused for the block spent four minutes and returned nothing. Tell the user that web search is blocked right now, then go on without it — `mcp__context7__query-docs` for library docs, what you already know marked as such, or ask the user for a URL.

**Do not open a PDF with `fetch_content`.** It returns the raw file (`%PDF-1.6 …`), not text: one PDF came back as 155 483 characters of binary — every one of them paid for, none of them readable (upstream issue #74). A URL ending in `.pdf`, or a search result marked as a PDF, is a link to give the user or a reason to look for an HTML version of the same document.

**Priority:** 1. ddg-search search 2. ddg-search fetch_content 3. `mcp__context7__query-docs` (lib docs) 4. `mcp__tavily__tavily_search` — disabled; enable via `/mcp-tools` only if ddg returns nothing 5. `WebFetch` (explicit URL only, not search).

No match, no URL → ask user for URL.
