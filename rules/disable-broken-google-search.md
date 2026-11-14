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

- Put the specific term in the query — the argument name, the error string, the version — not a description of it: `aws_eks_cluster authentication_mode`, not `how to set EKS auth in terraform`.
- For documentation, add `site:` with the official domain: `site:registry.terraform.io`, `site:docs.aws.amazon.com`, `site:kubernetes.io`, `site:docs.python.org`.
- Read the titles first. If the top results are off-topic, or the same page in several versions, search again with the query narrowed — one more word from the question, a `site:`, or quotes around an exact phrase — before fetching anything.
- A query in Russian is answered with Russian pages; for technical material an English query usually finds the primary source.

**One search at a time, and stop when blocked:**

- Never send several ddg-search searches in parallel. DuckDuckGo blocks a burst: on 2026-11-14 a run that opened with six parallel searches got "No results" for 25 of its 31 searches.
- "No results were found … DuckDuckGo's bot detection" means **blocked**, not "nothing exists". Do not rephrase and search again at once — each retry is another request into the block. Do other work, or say that search is blocked; the block lifted within about five minutes that time. Then try one search. Still blocked → use `mcp__context7__query-docs` for library docs, or ask the user for a URL.

**Do not open a PDF with `fetch_content`.** It returns the raw file (`%PDF-1.6 …`), not text: one PDF came back as 155 483 characters of binary — every one of them paid for, none of them readable (upstream issue #74). A URL ending in `.pdf`, or a search result marked as a PDF, is a link to give the user or a reason to look for an HTML version of the same document.

**Priority:** 1. ddg-search search 2. ddg-search fetch_content 3. `mcp__context7__query-docs` (lib docs) 4. `mcp__tavily__tavily_search` — disabled; enable via `/mcp-tools` only if ddg returns nothing 5. `WebFetch` (explicit URL only, not search).

No match, no URL → ask user for URL.
