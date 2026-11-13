# Review of the installer — a task for whoever fixes it

Date: 2026-11-13 (`date -Is` → 2026-11-13T22:32:34+00:00). Object: the
installer — `lib/wire.py` (473 lines, all configuration edits),
`install.sh` (146), `uninstall.sh` (52). Not in this pass: `release.sh`
(107) and the tests, except as the baseline.
Line numbers are as of commit `74580e8`. They will rot; anchor by name:
`rg -n "^def " lib/wire.py`.

Written by the same session that wrote the code, on the user's request. A
cold pass from another assistant would see what this one cannot.

Baseline, run before anything was touched:

    bash tests/test_install.sh -q    # 58 passed, 0 failed — exit 0
    shellcheck install.sh uninstall.sh release.sh tests/*.sh   # exit 0
    uvx 0.12.5, Python 3.14.4, GNU bash 5.3.9, codex-cli 0.167.1

## How to work through this file

1. Read `README.md` and the docstring of `lib/wire.py` first: they state what
   the installer promises.
2. Every item below has a reproduction. Reproduce on the broken input BEFORE
   fixing, then write the test, then fix.
3. Order: A by importance, then B. C is empty. D only after the person agrees.
4. After each item: `bash tests/test_install.sh -q` → 0 failed, and
   `bash tests/docker.sh unit` (bash 3.2) before the release.
5. Do not edit `rules/disable-broken-google-search.md` in this work: it is the
   rule, not the installer.

**Invariants — a fix may not break these**, from the project's own text:

- python3 3.8 or newer is enough (`install.sh`, README "Requirements") —
  `tomllib` exists only from 3.11, so a fix cannot simply require it.
- bash 3.2 runs `install.sh` (`tests/docker.sh unit`, README "Tests").
- A file the installer cannot read is left untouched, exit 1, other assistants
  still installed (README "What goes where").
- A disabled server stays disabled (README "Disabled servers").
- A second run changes nothing (README "Install").
- Nothing outside `$HOME` is written (`install.sh` header).

**Fix order**, because these items touch the same code:

1. A1 and A2 together — both live in `section_range` / `codex_section`, the
   Codex TOML editing. After them, re-run the reproductions of A1 and A2 and
   the Codex cases of `tests/test_install.sh` (multi-line `args`, env
   sub-table, parked file).
2. A3 — `claude_entry` and `opencode_entry`; independent of 1.
3. A4, A5 — `uninstall.sh` and the argument loop of both scripts; independent
   of everything else.
4. B1–B3 — text, after the code they describe has settled.

**Exposure while this lands:** until A1 is fixed, any user whose Codex
`config.toml` holds a `ddg-search` entry in one of the four shapes in A1 gets a
Codex that does not start after `./install.sh`. No interim measure in code is
cheaper than the fix itself; the hour-long measure is a README line telling
Codex users to check `codex mcp list` after installing.

Reproductions were run with `HOME` pointed at a fresh `mktemp -d` per case
(script: `/tmp/ddg-audit-probe.sh`), never against the real configuration.
Verdicts were taken from `tomllib` parsing the written file and from exit
statuses, not from the installer's own messages. Do the same.

---

## A. Defects (each reproduced)

### A1. Four ordinary TOML shapes make the installer write an invalid `config.toml`, and Codex stops starting

**Class:** damage — Codex refuses to load its configuration, while the
installer reports success (`server added`, exit 0).

**Where:** `section_range` (line 290), `KEY_RE` (309) and `codex_section`
(315) in `lib/wire.py`. `section_range` finds the table only when a line equals
`[mcp_servers.ddg-search]` or `[mcp_servers."ddg-search"]` exactly after
`strip()`. A header with a trailing comment or inner spaces is not found, and
neither is a server written as an inline table under `[mcp_servers]`. The
code then appends a second `[mcp_servers.ddg-search]` table. `KEY_RE` matches
bare keys only, so in a found section a quoted `"command" =` is kept as an
"extra" line beside the new `command =`. `--remove` misses the same shapes and
leaves the server in place, silently.

**Reproduction:**

    # one fresh HOME per shape; config.toml written, then
    HOME="$h" python3 lib/wire.py codex --no-rule; tomllib on the result
    T1-header-comment   [mcp_servers.ddg-search] # search
        after (rc 0): PARSE FAIL Cannot declare ('mcp_servers', 'ddg-search') twice (at line 5, column 24)
    T2-quoted-keys      "command" = "uvx"
        after (rc 0): PARSE FAIL Cannot overwrite a value (at line 4, column 18)
    T4-dotted-table     [mcp_servers]
                        ddg-search = { command = "uvx", args = [...] }
        after (rc 0): PARSE FAIL Cannot declare ('mcp_servers', 'ddg-search') twice (at line 4, column 24)
    T6-header-spaces    [ mcp_servers.ddg-search ]
        after (rc 0): PARSE FAIL Cannot declare ('mcp_servers', 'ddg-search') twice (at line 5, column 24)

    # Codex on the T1 result:
    HOME="$h" codex mcp list
    Error: failed to load bootstrap configuration
    codex rc=1

    # --remove on T1 and T4: the server stays
    remove → PARSE ok  {"command": "uvx"}
    remove → PARSE ok  {"command": "uvx"}

**Fix:** match the header with a pattern that allows inner spaces, quotes and
a trailing comment, and keys with or without quotes. When `tomllib` is
available (3.11+), parse the file before editing: if it lists
`mcp_servers.ddg-search` but `section_range` did not find a table header,
the server is written inline — refuse with exit 1 and a message, file
untouched. Parse the new text before writing and refuse in the same way if it
does not parse — the same fail-closed rule as for a broken `opencode.json`. On
3.8–3.10 there is no parser: the stricter header and key patterns are the only
protection, so say that in the message.

**Touches:** `lib/wire.py` only; `tests/test_install.sh`. Nothing else holds a
copy of the Codex logic.

**Test:** in `tests/test_install.sh`, a group "codex shapes": T1, T2, T6 must
end in a valid file with one `ddg-search` table; T4 must exit non-zero with
the file byte-identical; `--remove` on T1 must remove the table.

### A2. An inline `env = { … }` in the Codex entry is dropped, with the user's variables in it

**Class:** damage — the user's server settings (`DDG_REGION` here) are gone
after an install that reports `server updated`, exit 0.

**Where:** `codex_section`, the main-table branch: `env` is in the set of
dropped keys, so `env = { DDG_REGION = "us-en" }` is removed. Only the
variables of an `[mcp_servers.ddg-search.env]` sub-table are carried over.

**Reproduction:**

    T3-inline-env  before: {"command": "uvx", "args": [...], "env": {"DDG_REGION": "us-en"}}
                   after (rc 0): {"command": "uvx", "args": ["--python", "3.12", "duckduckgo-mcp-server[browser]==0.7.0"]}

**Fix:** read the inline table's pairs (with `tomllib` where available, else a
pattern for flat `KEY = "value"` pairs) and carry every variable except
`DDG_SEARCH_BACKEND` into the `[mcp_servers.ddg-search.env]` sub-table the
code already writes. If the inline table cannot be read, refuse as in A1.

**Touches:** `lib/wire.py`; `tests/test_install.sh`.

**Test:** "codex shapes": T3 ends with `env == {"DDG_REGION": "us-en"}`, and
with `DDG_SEARCH_BACKEND` added under `--search-backend curl`.

### A3. An existing remote entry named `ddg-search` becomes a mixed entry that does not run the server

**Class:** silent wrong result — the installer reports `server updated`; the
assistant keeps talking to the remote URL, or gets an entry with keys of both
kinds.

**Where:** `claude_entry` and `opencode_entry`. Both start from a copy of the
old entry and set only `command`/`args` (Claude) or `type`/`command`
(Opencode). `type: "http"`, `url` and `headers` survive.

**Reproduction:**

    # .claude.json: {"ddg-search": {"type": "http", "url": "https://example.invalid/mcp"}}
    claude   {'type': 'http', 'url': 'https://example.invalid/mcp', 'command': 'uvx', 'args': [...]}
    # opencode.json: {"ddg-search": {"type": "remote", "url": "https://example.invalid/mcp"}}
    opencode {'type': 'local', 'url': 'https://example.invalid/mcp', 'command': [...], 'codemode': False}

How Claude Code and Opencode treat these mixed entries was not run. The
Claude entry still says `type: http`, so the server is reached by URL, not
started. To settle: install over such an entry, then `claude mcp list`.

**Fix:** drop `url` and `headers`, and drop `type` unless it is `stdio`
(Claude) — the entry is ours by name, and a remote ddg-search is not what this
installer installs. Keep every other key, as now.

**Touches:** `lib/wire.py`; `tests/test_install.sh`.

**Test:** remote entries in both files end as a plain local/stdio entry
without `url`.

### A4. `uninstall.sh` deletes a locally edited rule without a backup

**Class:** damage — local edits to the rule are lost with no copy, while the
installer itself backs up every file it overwrites.

**Where:** `uninstall.sh`, the loop over assistants: `rm -f "$rules/$RULE"`.

**Reproduction:**

    # install, append "# my note" to ~/.claude/rules/disable-broken-google-search.md, uninstall
    rule exists after uninstall: no; backups holding the edit: 0

**Fix:** when the file differs from `rules/$RULE` of the checkout, copy it to
`~/.local/state/ddg-search/backups/` before removing it, as `install_file`
does.

**Touches:** `uninstall.sh`; `tests/test_install.sh`.

**Test:** "uninstall": an edited rule leaves one backup containing the edit.

### A5. `--ide` or `--search-backend` without a value exits 1 with no message

**Class:** visible failure — the run stops, but says nothing about why.

**Where:** the argument loops of `install.sh` and `uninstall.sh`:
`ONLY_IDE="${2:-}"; shift` followed by the loop's own `shift`. With no value
left, the second `shift` fails, and `set -e` ends the script silently.

**Reproduction:**

    HOME="$h" bash install.sh --no-server --ide
    --ide (no value): exit 1 out=[]
    HOME="$h" bash install.sh --no-server --search-backend
    --search-backend (no value): exit 1 out=[]

**Fix:** check `[ $# -ge 2 ]` before taking the value; otherwise print
`--ide needs a value: claude, codex or opencode` and exit 2, the code the
scripts already use for a bad option.

**Touches:** `install.sh`, `uninstall.sh` (`--ide`).

**Test:** "flags": both forms exit 2 with the message.

---

## B. Documentation disagrees with the code

### B1. `--dry-run` cannot run without uv

README: "`--dry-run` | print the changes, write nothing". Without uv on `PATH`,
the run stops at the uv check, before any configuration is compared:

    HOME="$h" PATH=/usr/bin:/bin bash install.sh --dry-run
    exit 1, first line: server: duckduckgo-mcp-server[browser]==0.7.0, "would" lines: 0

**Fix:** either let `--dry-run` report the missing uv as a note and go on to
the configuration (code), or say in both READMEs that `--dry-run` needs uv
unless `--no-server` is given. `README.md` and `README.RU.md` together.

### B2. `uninstall.sh --help` prints a line of code

`sed -n '2,12p'` takes line 12, which is `set -euo pipefail`:

    bash uninstall.sh --help | tail -1
    set -euo pipefail

**Fix:** `sed -n '2,11p'` in `uninstall.sh`. `install.sh --help` was checked:
its range ends on a comment line.

### B3. The `lib/wire.py` docstring says every other line is left as it was

Docstring: "Any other key in it, and every other server, key and line, is left
as it was." Keys and servers are; lines are not. JSON files are rewritten
whole with `indent=2`, and `config.toml` loses CRLF line endings:

    opencode.json written on one line → after install: lines before 1, after 20
    T5-crlf: parses and is updated, but every line of the file now ends in LF

**Fix:** state it in the docstring — "JSON files are rewritten with two-space
indentation; config.toml line endings become LF". Keeping the formatting
would need a JSON editor that preserves layout: not worth it (D).

---

## C. Efficiency

Measurement on this machine, everything already current:
`/usr/bin/time ./install.sh` → `install.sh wall 2.37s`, most of it the `uvx …
--help` check of the server. No cost here that hurts; no item.

---

## D. Judgement on the design (change only after the person agrees)

What is right and must stay:

- **`auto` as the default search backend.** Measured 2026-11-13: httpx got
  HTTP 200 while the Chrome fingerprint of curl_cffi got HTTP 202 and a
  bot-check page from the second request on (upstream issue #78).
- **The pinned `==0.7.0` and `[browser]`.** The extra is the reason search
  worked again in August; the pin makes an upstream change arrive with a
  release.
- **Updating a disabled server in place, never enabling it.** Matches how
  mcp-tools disables servers; covered by tests.
- **Backups outside every directory an assistant reads.**

What is arguable:

- **The command is a bare `uvx`.** It depends on the assistant's `PATH`. A CLI
  started from a shell finds `~/.local/bin`; an assistant started from a macOS
  GUI may not. Not reproduced here (no macOS). Writing the absolute path of
  `uvx` would fix that, and would break when uv moves. Recommendation: not
  now; a README line for macOS users is enough until someone hits it.
- **`~/.claude.json` is created when missing.** The file then holds only
  `mcpServers`. Whether Claude Code's first start accepts that and adds its
  own keys was not checked. To settle: `HOME=$(mktemp -d)` with an empty
  `.claude/`, install, then start `claude` once.
- **JSON files are re-serialised whole** (B3). A layout-preserving editor is
  more code than the problem is worth. Recommendation: not now; document it.

---

## What is NOT a defect (checked, so nobody spends the time again)

- **CRLF `config.toml`** (T5): found, updated, valid TOML afterwards; only the
  line endings change (B3).
- **Writing `~/.claude.json` while Claude Code runs.** Installed at ~21:42
  while two sessions were running. At 22:33 Claude Code had rewritten the file
  since, and the pinned `ddg-search` entry was still in it (`rg -A6
  '"ddg-search": \{' ~/.claude.json`). One observation, not a proof.
- **`install.sh --help`** prints its 25-line header and nothing else.
- **Idempotence, disabled servers, `--dry-run` with uv, `--no-rule`, a missing
  assistant, a broken `opencode.json`, uninstall** — all covered by
  `tests/test_install.sh` and passing in the baseline (58/58).
- **A valid entry works in all three assistants.** `tests/docker.sh e2e`
  (2026-11-13) started the server from each assistant's entry on a clean
  Debian and got 3 search results through MCP in each.
- **Multi-line `args = [ … ]`** in a Codex entry is replaced cleanly (covered
  by the test fixture).

## Done when

Commands to paste, each with the status it should exit with:

    bash tests/test_install.sh -q        # more than 58 passed (new groups: codex shapes, flags, uninstall edit), 0 failed — exit 0
    bash tests/docker.sh unit            # same counts under bash 3.2 — exit 0
    shellcheck install.sh uninstall.sh release.sh tests/*.sh   # exit 0
    bash /tmp/ddg-audit-probe.sh         # every "after" line: PARSE ok, or the T4 refusal with the file unchanged;
                                         # T3 keeps DDG_REGION; remote entries have no url;
                                         # "--ide (no value): exit 2" with a message; backups holding the edit: 1
    bash uninstall.sh --help | tail -1   # a comment line, not "set -euo pipefail" — exit 0

- every A item has a test that failed before the fix and passes after
- B1 resolved in both `README.md` and `README.RU.md`, or in the code
- the CHANGELOG `## Unreleased` section names A1–A5
