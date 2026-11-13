# Web Search

**NEVER `google_search`** — always fails `403 CONSUMER_INVALID`, permanently broken here. Don't retry "to check".

**NEVER native `WebSearch` / `websearch`** — verbose overhead; ddg-search gives the same data in fewer tokens.

**ddg-search tool names differ per IDE — use the one for yours, exactly:**

| IDE | search | fetch page |
|---|---|---|
| Claude Code | `mcp__ddg-search__search` | `mcp__ddg-search__fetch_content` |
| Opencode | `ddg-search_search` | `ddg-search_fetch_content` |
| Codex | `search` in namespace `mcp__ddg_search` | `fetch_content` in namespace `mcp__ddg_search` |

In Opencode the server runs with `codemode: false`, so these are ordinary tools on the native list. A bare `ddg-search` or `search` is not a tool there and fails with `No tool named ...`. If the native list has no `ddg-search_*` (the server is back in Code Mode), call it inside `execute`: `await tools["ddg-search"].search({query: "..."})`.

**Priority:** 1. ddg-search search 2. ddg-search fetch_content 3. `mcp__context7__query-docs` (lib docs) 4. `mcp__tavily__tavily_search` — disabled; enable via `/mcp-tools` only if ddg returns nothing 5. `WebFetch` (explicit URL only, not search).

No match, no URL → ask user for URL.
