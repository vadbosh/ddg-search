#!/usr/bin/env python3
"""Register the ddg-search MCP server with one assistant, or take it away.

  wire.py <claude|codex|opencode> [--search-backend B] [--no-rule]
                                  [--remove] [--dry-run] [--check]
  wire.py spec                    print the server command, one word per line

What each assistant gets. Files (the rule) are copied by install.sh; this
script writes only the configuration:

  claude    ~/.claude.json            mcpServers.ddg-search — the user scope
                                      Claude Code reads by default
            ~/.claude/mcp.json        the same entry, only where this file
                                      exists (a setup launched with
                                      --mcp-config ~/.claude/mcp.json)
            ~/.claude/mcp-disabled.json
                                      updated instead of mcp.json when the
                                      server is parked there (mcp-tools)
  codex     ~/.codex/config.toml      [mcp_servers.ddg-search], and the
                                      top-level web_search = "disabled" and
                                      [apps.connector_openai_search_service]
                                      enabled = false: Codex's own search
                                      (web.run, as a tool and as an app) off,
                                      the values replaced kept in
                                      ~/.local/state/ddg-search/codex-web-search
                                      for --remove; --keep-codex-search leaves
                                      it on, and so does a parked server
            ~/.codex/mcp-disabled.toml
                                      updated instead when parked there
            ~/.codex/AGENTS.md        an @-line naming the rule file
  opencode  ~/.config/opencode/opencode.json
                                      mcp.ddg-search with codemode: false,
                                      and the rule file in "instructions";
                                      an "enabled": false set by hand or by
                                      mcp-tools is kept

The entry named ddg-search is ours: its command, arguments and our one
environment variable are rewritten to the pinned form below, and the keys of a
remote server (url, headers, a type other than stdio) are dropped. Any other
key in it, and every other server and key, keeps its value. The layout does
not always survive: a JSON file is rewritten whole with two-space indentation,
and config.toml comes back with LF line endings.

config.toml is edited as text, because Python before 3.11 has no TOML parser.
Where tomllib exists, the file is parsed first and the result before it is
written: a file that does not parse, a ddg-search written as an inline table,
or an edit that would not parse are refused (exit 1, file untouched). A
configuration file is backed up before it is written, outside every directory
an assistant reads (~/.local/state/ddg-search/backups/).

Exit codes: 0 done or already current, 3 the assistant is not set up (not an
error), 4 --check found something to change, 1 a file could not be read or
written.
"""
import argparse
import json
import os
import re
import shutil
import sys
import time

NAME = "ddg-search"
PACKAGE = "duckduckgo-mcp-server"
# The [browser] extra installs curl_cffi. Without it DuckDuckGo answers the
# plain httpx client with an empty HTTP 202 page and every search comes back
# "No results were found"; with it the server retries such a search with a
# Chrome TLS fingerprint. Pinned: a new upstream version arrives with a release
# of this repository, not on whatever day uvx resolves it.
VERSION = "0.7.0"
PYTHON = "3.12"
SERVER = f"{PACKAGE}[browser]=={VERSION}"
# --fetch-backend auto: fetch_content retries through curl_cffi (Chrome TLS) when a
# site answers httpx with 403 or a Cloudflare challenge. The server default is
# httpx alone; measured 2026-11-13, extension.umn.edu gave httpx a 403 and auto
# the page (2381 characters).
# --ref-url-threshold 0: full URLs in search results. The server default (120)
# replaces a longer URL with a ref:// token, and the model then needs an extra
# expand_link call to see where a result points: 2 of 30 results on 2026-11-13.
COMMAND = ["uvx", "--python", PYTHON, SERVER, "--fetch-backend", "auto", "--ref-url-threshold", "0"]
BACKEND_ENV = "DDG_SEARCH_BACKEND"
BACKENDS = ("auto", "httpx", "curl")

HOME = os.path.expanduser("~")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), "ddg-search")
BACKUPS = os.path.join(STATE, "backups")

CLAUDE_JSON = os.path.join(HOME, ".claude.json")
CLAUDE_DIR = os.path.join(HOME, ".claude")
CLAUDE_MCP = os.path.join(CLAUDE_DIR, "mcp.json")
CLAUDE_PARKED = os.path.join(CLAUDE_DIR, "mcp-disabled.json")
CODEX_DIR = os.path.join(HOME, ".codex")
CODEX_CONFIG = os.path.join(CODEX_DIR, "config.toml")
CODEX_PARKED = os.path.join(CODEX_DIR, "mcp-disabled.toml")
CODEX_AGENTS = os.path.join(CODEX_DIR, "AGENTS.md")
OPENCODE_DIR = os.path.join(HOME, ".config", "opencode")
OPENCODE_CONFIG = os.path.join(OPENCODE_DIR, "opencode.json")

RULE = "disable-broken-google-search.md"
CODEX_RULE = os.path.join(CODEX_DIR, "memories", RULE)
OPENCODE_ENTRY = f"~/.config/opencode/instructions/{RULE}"


# ---------------------------------------------------------------- helpers

def backup(path):
    if not os.path.isfile(path):
        return
    os.makedirs(BACKUPS, mode=0o700, exist_ok=True)
    rel = path.replace(HOME, "").replace("\\", "/")
    tag = rel.strip("/").replace("/.", "/").lstrip(".").replace("/", "-")
    shutil.copy2(path, os.path.join(BACKUPS, f"{tag}.bak.{int(time.time())}"))


def atomic_write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.ddg-search-tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    if os.path.exists(path):
        shutil.copymode(path, tmp)
    os.replace(tmp, path)


class Unreadable(Exception):
    pass


def load_json(path):
    """dict, or None when the file is missing. Raises Unreadable otherwise."""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return None
    except ValueError as exc:
        raise Unreadable(f"{path} is not plain JSON ({exc})")
    if not isinstance(data, dict):
        raise Unreadable(f"{path} is not a JSON object")
    return data


def dump_json(data):
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


class Plan:
    """Pending writes: path -> new text, plus the lines to report."""

    def __init__(self):
        self.writes = {}
        self.lines = []

    def put(self, path, old, new, what):
        """new None deletes the file."""
        if old == new:
            return
        self.writes[path] = new
        if what:
            self.lines.append(what)

    def apply(self):
        for path, text in self.writes.items():
            backup(path)
            if text is None:
                if os.path.exists(path):
                    os.remove(path)
            else:
                atomic_write(path, text)


# ---------------------------------------------------------------- entries

def env_for(backend):
    return {} if backend == "auto" else {BACKEND_ENV: backend}


def merge_env(old_env, backend):
    env = dict(old_env or {})
    env.pop(BACKEND_ENV, None)
    env.update(env_for(backend))
    return env


# Keys of a remote server. An entry named ddg-search is ours, and this installer
# installs a local one: left in, they would keep the assistant on the URL.
REMOTE_KEYS = ("url", "headers")


def claude_entry(old, backend):
    entry = {k: v for k, v in (old or {}).items() if k not in REMOTE_KEYS}
    if entry.get("type", "stdio") != "stdio":
        entry.pop("type")
    entry["command"] = COMMAND[0]
    entry["args"] = COMMAND[1:]
    env = merge_env(entry.get("env"), backend)
    if env:
        entry["env"] = env
    else:
        entry.pop("env", None)
    return entry


def opencode_entry(old, backend):
    entry = {k: v for k, v in (old or {}).items() if k not in REMOTE_KEYS}
    entry["type"] = "local"
    entry["command"] = list(COMMAND)
    # Opencode's Code Mode hides MCP tools behind `execute`; with it off they are
    # ordinary tools named ddg-search_search / ddg-search_fetch_content, which is
    # what the rule tells the model to call.
    entry["codemode"] = False
    env = merge_env(entry.get("environment"), backend)
    if env:
        entry["environment"] = env
    else:
        entry.pop("environment", None)
    return entry


# ---------------------------------------------------------------- claude

def wire_claude(backend, remove, plan):
    if not os.path.isdir(CLAUDE_DIR) and not os.path.exists(CLAUDE_JSON):
        return 3
    parked = load_json(CLAUDE_PARKED) or {}
    is_parked = NAME in parked.get("mcpServers", {})

    # mcp.json / mcp-disabled.json: only on a machine that uses them.
    for path in (CLAUDE_MCP, CLAUDE_PARKED):
        data = load_json(path)
        if data is None:
            continue
        servers = data.get("mcpServers", {})
        if remove:
            if NAME not in servers:
                continue
            servers.pop(NAME)
            plan.put(path, None, dump_json(data), f"server removed from {tilde(path)}")
            continue
        if path == CLAUDE_MCP and is_parked:
            continue            # parked: the copy in mcp-disabled.json is the one to update
        if path == CLAUDE_PARKED and not is_parked:
            continue
        old = servers.get(NAME)
        new = claude_entry(old, backend)
        if old != new:
            data.setdefault("mcpServers", {})[NAME] = new
            plan.put(path, None, dump_json(data),
                     f"server {'updated' if old else 'added'} in {tilde(path)}")

    # ~/.claude.json: the user scope. Left alone while parked, as mcp-tools does.
    data = load_json(CLAUDE_JSON)
    servers = (data or {}).get("mcpServers", {})
    if remove:
        if NAME in servers:
            servers.pop(NAME)
            plan.put(CLAUDE_JSON, None, dump_json(data), f"server removed from {tilde(CLAUDE_JSON)}")
        return 0
    if is_parked:
        plan.lines.append(f"parked in {tilde(CLAUDE_PARKED)} — {tilde(CLAUDE_JSON)} left alone")
        return 0
    old = servers.get(NAME)
    new = claude_entry(old, backend)
    if old != new:
        data = data if data is not None else {}
        data.setdefault("mcpServers", {})[NAME] = new
        plan.put(CLAUDE_JSON, None, dump_json(data),
                 f"server {'updated' if old else 'added'} in {tilde(CLAUDE_JSON)}")
    return 0


# ---------------------------------------------------------------- opencode

def wire_opencode(backend, with_rule, remove, plan):
    if not os.path.isdir(OPENCODE_DIR):
        return 3
    if not os.path.exists(OPENCODE_CONFIG) and os.path.exists(OPENCODE_CONFIG + "c"):
        raise Unreadable(f"{OPENCODE_CONFIG}c is JSONC — add the entry by hand "
                         f"(see `wire.py opencode --dry-run` on a plain JSON copy)")
    data = load_json(OPENCODE_CONFIG)
    if data is None:
        if remove:
            return 0
        data = {"$schema": "https://opencode.ai/config.json"}
    before = dump_json(data)
    mcp = data.get("mcp", {})
    arr = data.get("instructions", [])
    if remove:
        mcp.pop(NAME, None)
        if not mcp:
            data.pop("mcp", None)
        if OPENCODE_ENTRY in arr:
            arr.remove(OPENCODE_ENTRY)
            if not arr:
                data.pop("instructions", None)
        plan.put(OPENCODE_CONFIG, before, dump_json(data), f"server and rule removed from {tilde(OPENCODE_CONFIG)}")
        return 0
    old = mcp.get(NAME)
    new = opencode_entry(old, backend)
    what = []
    if old != new:
        data.setdefault("mcp", {})[NAME] = new
        what.append(f"server {'updated' if old else 'added'}")
    if with_rule and OPENCODE_ENTRY not in arr:
        data.setdefault("instructions", []).append(OPENCODE_ENTRY)
        what.append("rule listed in instructions")
    if new.get("enabled") is False:
        plan.lines.append(f"parked (\"enabled\": false) in {tilde(OPENCODE_CONFIG)} — kept")
    plan.put(OPENCODE_CONFIG, before, dump_json(data), f"{', '.join(what)} in {tilde(OPENCODE_CONFIG)}")
    return 0


# ---------------------------------------------------------------- codex

try:
    import tomllib          # Python 3.11+. Older: the patterns below are all there is.
except ImportError:         # pragma: no cover — exercised on 3.8–3.10 only
    tomllib = None


def toml_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def toml_key(k):
    return k if re.fullmatch(r"[A-Za-z0-9_\-]+", k) else toml_str(k)


def toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return str(v)
    if isinstance(v, str):
        return toml_str(v)
    raise ValueError(f"unsupported value {v!r}")


# The server's table header in any spelling TOML allows on one line: bare or
# quoted name, spaces around the dots and brackets, a trailing comment.
_NAME = r"""(?:ddg-search|"ddg-search"|'ddg-search')"""
HEADER_RE = re.compile(r"^\s*\[\s*mcp_servers\s*\.\s*" + _NAME + r"\s*\]\s*(?:#.*)?$")
SUB_RE = re.compile(r"^\s*\[\s*mcp_servers\s*\.\s*" + _NAME + r"\s*\.\s*([^\]]+?)\s*\]\s*(?:#.*)?$")
# A key, bare or quoted.
KEY_RE = re.compile(r"""^\s*(?:"([^"]*)"|'([^']*)'|([A-Za-z0-9_\-]+))\s*=""")


def key_of(line):
    m = KEY_RE.match(line)
    return next(g for g in m.groups() if g is not None) if m else None


def is_table(line):
    return line.lstrip().startswith("[") and key_of(line) is None


def section_range(lines):
    """(start, end) of [mcp_servers.ddg-search] and its sub-tables, or (None, None)."""
    start = next((i for i, ln in enumerate(lines) if HEADER_RE.match(ln)), None)
    if start is None:
        return None, None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if is_table(lines[i]) and not SUB_RE.match(lines[i]):
            end = i
            break
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    return start, end


def parse_toml(text, path):
    """The parsed file, or None where tomllib is missing. A file that does not
    parse is left alone, as a broken opencode.json is."""
    if tomllib is None:
        return None
    try:
        return tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise Unreadable(f"{path} is not valid TOML ({exc})")


def inline_env(value, path):
    """The variables of `env = { … }` as a dict."""
    value = value.strip()
    if tomllib is not None:
        try:
            env = tomllib.loads("v = " + value)["v"]
        except tomllib.TOMLDecodeError as exc:
            raise Unreadable(f"{path}: cannot read env of {NAME} ({exc})")
        if not isinstance(env, dict):
            raise Unreadable(f"{path}: env of {NAME} is not a table")
        return env
    m = re.fullmatch(r"\{(.*)\}\s*(?:#.*)?", value)
    pair = r"""\s*([A-Za-z0-9_\-]+)\s*=\s*"((?:[^"\\]|\\.)*)"\s*"""
    if not m or not re.fullmatch(f"(?:{pair},)*(?:{pair})?", m.group(1)):
        raise Unreadable(f"{path}: cannot read env of {NAME} without Python 3.11 — "
                         f"move it to an [mcp_servers.{NAME}.env] table")
    return dict(re.findall(pair, m.group(1)))


def codex_section(old_lines, backend, path):
    """Our section. Kept from the old one: every key of the main table except
    command, args and env; every variable of env — inline table or sub-table —
    except ours; every other sub-table, verbatim. A multi-line array value of a
    dropped key is dropped whole."""
    extra, env_lines, subs = [], [], []
    where, skipping = "main", False
    for ln in old_lines[1:]:
        s = ln.strip()
        if skipping:
            skipping = "]" not in s
            continue
        if is_table(ln):
            m = SUB_RE.match(ln)
            where = "env" if m and m.group(1).strip("\"'") == "env" else "sub"
            if where == "sub":
                subs.append(ln)
            continue
        key = key_of(ln)
        if where == "main":
            if key == "default_tools_approval_mode":
                continue
            if key in ("command", "args", "env"):
                value = ln.split("=", 1)[1].strip()
                if key == "env":
                    for k, v in inline_env(value, path).items():
                        if k != BACKEND_ENV:
                            env_lines.append(f"{toml_key(k)} = {toml_value(v)}")
                skipping = value.startswith("[") and "]" not in value
                continue
            if s:
                extra.append(ln)
        elif where == "env":
            if key == BACKEND_ENV:
                continue
            if s:
                env_lines.append(ln)
        else:
            subs.append(ln)
    # Without it Codex asks before every search and every page fetch. All three
    # tools of the server (search, fetch_content, expand_link) only read.
    out = [f"[mcp_servers.{NAME}]",
           f"command = {toml_str(COMMAND[0])}",
           "args = [" + ", ".join(toml_str(a) for a in COMMAND[1:]) + "]",
           'default_tools_approval_mode = "approve"'] + extra
    env_lines += [f"{k} = {toml_str(v)}" for k, v in env_for(backend).items()]
    if env_lines:
        out += ["", f"[mcp_servers.{NAME}.env]"] + env_lines
    if subs:
        out += [""] + subs
    return out


TOP_DOTTED_RE = re.compile(r"^\s*mcp_servers\s*\.\s*" + _NAME + r"\s*[.=]")
IN_TABLE_RE = re.compile(r"^\s*" + _NAME + r"\s*[.=]")


def inline_defined(lines):
    """The server written as a key rather than as its own table:
    `mcp_servers.ddg-search = {…}` at the top level, or `ddg-search = {…}` /
    `ddg-search.command = …` inside [mcp_servers]. Found without a parser, so
    it works on Python 3.8–3.10 too."""
    table = ""
    for ln in lines:
        if is_table(ln):
            table = re.sub(r"[\s\"']", "", ln.split("]")[0].lstrip(" \t["))
            continue
        if (table == "" and TOP_DOTTED_RE.match(ln)) or (table == "mcp_servers" and IN_TABLE_RE.match(ln)):
            return True
    return False


def codex_lists(path):
    """True when the file defines the server, in any form."""
    text = read_text(path)
    if text is None:
        return False
    lines = text.splitlines()
    if section_range(lines)[0] is not None or inline_defined(lines):
        return True
    data = parse_toml(text, path)
    return data is not None and NAME in data.get("mcp_servers", {})


def codex_put(path, backend, remove, plan, create):
    text = read_text(path)
    if text is None and not create:
        return False
    data = parse_toml(text or "", path)
    lines = (text or "").splitlines()
    start, end = section_range(lines)
    if start is None and (inline_defined(lines)
                          or (data is not None and NAME in data.get("mcp_servers", {}))):
        raise Unreadable(f"{path} defines {NAME} inline (`{NAME} = {{ … }}` or a dotted key); "
                         f"the installer edits only a [mcp_servers.{NAME}] table — rewrite it as "
                         f"one, or remove it, and run again")
    if remove:
        if start is None:
            return False
        before, after = lines[:start], lines[end:]
        while before and not before[-1].strip():
            before.pop()
        while after and not after[0].strip():
            after.pop(0)
        body = before + ([""] if before and after else []) + after
        new = "\n".join(body) + ("\n" if body else "")
        what = f"server removed from {tilde(path)}"
    elif start is None:
        if not create:
            return False
        section = codex_section([f"[mcp_servers.{NAME}]"], backend, path)
        body = lines + ([""] if lines and lines[-1].strip() else []) + section
        new = "\n".join(body) + "\n"
        what = f"server added in {tilde(path)}"
    else:
        section = codex_section(lines[start:end], backend, path)
        new = "\n".join(lines[:start] + section + lines[end:]) + "\n"
        what = f"server updated in {tilde(path)}"
    check_codex(new, path, remove)
    plan.put(path, text, new, what)
    return True


def check_codex(text, path, remove):
    """Refuse to write a file Codex could not load. Without tomllib there is no
    parser to ask, and the patterns above are the only protection."""
    if tomllib is None:
        return
    try:
        servers = tomllib.loads(text).get("mcp_servers", {})
    except tomllib.TOMLDecodeError as exc:
        raise Unreadable(f"{path}: the edit would leave invalid TOML ({exc}) — "
                         f"file left as it was; please report this")
    if remove == (NAME in servers) or (not remove and servers[NAME].get("args") != COMMAND[1:]):
        raise Unreadable(f"{path}: the edit did not come out as intended — file left as it was")


def wire_codex(backend, with_rule, remove, plan, keep_search=False):
    if not os.path.isdir(CODEX_DIR):
        return 3
    if remove:
        codex_put(CODEX_CONFIG, backend, True, plan, False)
        codex_put(CODEX_PARKED, backend, True, plan, False)
        codex_web_search(plan, restore=True)
    else:
        is_parked = codex_lists(CODEX_PARKED)
        if is_parked:
            codex_put(CODEX_PARKED, backend, False, plan, False)
            plan.lines.append(f"parked in {tilde(CODEX_PARKED)} — {tilde(CODEX_CONFIG)} left alone, "
                              f"built-in web search too")
        else:
            codex_put(CODEX_CONFIG, backend, False, plan, True)
            codex_web_search(plan, restore=keep_search, keep=keep_search)
    wire_codex_agents(with_rule, remove, plan)
    return 0


# Codex has a search tool of its own (web.run: search_query, open), on by
# default (web_search = "cached"). With it available the model used it instead
# of ddg-search, rule or not. The top-level key turns it off; the value it
# replaced is kept in this file so that --remove and --keep-codex-search can put
# it back. "kept" records the opt-out, so release.sh knows it is deliberate.
WEB_SEARCH_STATE = os.path.join(STATE, "codex-web-search")
WEB_SEARCH_RE = re.compile(r"""^\s*(?:web_search|"web_search"|'web_search')\s*=\s*(.*?)\s*(?:#.*)?$""")
DISABLED = '"disabled"'


# The same web.run also reaches the model as an app: with [features] apps on
# (the default), Codex exposes the connector below as
# codex_apps.search_service.web_run, and web_search = "disabled" does not touch
# it. Seen 2026-11-13, after web_search had been turned off. Only this one app
# is turned off — [features] apps = false would take every other app with it.
APP_ID = "connector_openai_search_service"
_APP = f"(?:{APP_ID}|\"{APP_ID}\"|'{APP_ID}')"
APP_HEADER_RE = re.compile(r"^\s*\[\s*apps\s*\.\s*" + _APP + r"\s*\]\s*(?:#.*)?$")
ENABLED_RE = re.compile(r"""^\s*(?:enabled|"enabled"|'enabled')\s*=\s*(.*?)\s*(?:#.*)?$""")


def _web_find(lines):
    top_end = next((i for i, ln in enumerate(lines) if is_table(ln)), len(lines))
    at = next((i for i in range(top_end) if WEB_SEARCH_RE.match(lines[i])), None)
    return top_end, at, (WEB_SEARCH_RE.match(lines[at]).group(1) if at is not None else None)


def _app_find(lines):
    start = next((i for i, ln in enumerate(lines) if APP_HEADER_RE.match(ln)), None)
    if start is None:
        return None, None, None, None
    end = next((i for i in range(start + 1, len(lines)) if is_table(lines[i])), len(lines))
    at = next((i for i in range(start + 1, end) if ENABLED_RE.match(lines[i])), None)
    return start, end, at, (ENABLED_RE.match(lines[at]).group(1) if at is not None else None)


def read_search_state():
    """{"kept": True}, or {"web": prev, "app": prev} for what an install changed.
    `set previous=…` is the one-line form written by 0.2.0."""
    text = (read_text(WEB_SEARCH_STATE) or "").strip()
    if text == "kept":
        return {"kept": True}
    state = {}
    for ln in text.splitlines():
        key, _, value = ln.partition(" previous=")
        if key in ("set", "web"):
            state["web"] = value
        elif key == "app":
            state["app"] = value
    return state


def codex_web_search(plan, restore, keep=False):
    """Turn Codex's own search off in config.toml — the web_search key and the
    search_service app — or put back what an earlier run replaced."""
    original = read_text(CODEX_CONFIG)
    base = plan.writes.get(CODEX_CONFIG, original)
    if base is None:
        return
    lines = base.splitlines()
    state = read_search_state()
    done = []

    if restore:
        _, at, current = _web_find(lines)
        previous = state.get("web")
        if previous and current == DISABLED:
            if previous == "absent":
                del lines[at]
            else:
                lines[at] = f"web_search = {previous}"
            done.append("web_search " + ("removed" if previous == "absent" else f"back to {previous}"))
        start, end, at, current = _app_find(lines)
        previous = state.get("app")
        if previous and current == "false":
            if previous == "absent":
                while start > 0 and not lines[start - 1].strip():
                    start -= 1
                del lines[start:end]
            elif previous == "unset":
                del lines[at]
            else:
                lines[at] = f"enabled = {previous}"
            done.append(f"[apps.{APP_ID}] " + ("removed" if previous == "absent" else "restored"))
        if done:
            plan.put(CODEX_CONFIG, base, "\n".join(lines) + "\n",
                     f"built-in web search back on: {'; '.join(done)} in {tilde(CODEX_CONFIG)}")
        plan.put(WEB_SEARCH_STATE, read_text(WEB_SEARCH_STATE), "kept\n" if keep else None, "")
        if keep:
            plan.lines.append("built-in web search: left on (--keep-codex-search)")
        return

    new_state = {}
    top_end, at, current = _web_find(lines)
    if current != DISABLED:
        new_line = f"web_search = {DISABLED}"
        if at is not None:
            lines[at] = new_line
        else:
            # The top level ends at the first table; keys after it would belong to it.
            insert = top_end
            while insert > 0 and not lines[insert - 1].strip():
                insert -= 1
            block = [new_line]
            if insert == top_end and top_end < len(lines):
                block.append("")        # right before a table header: keep a blank line between
            lines[insert:insert] = block
        new_state["web"] = current if current is not None else "absent"
        done.append(f"web_search = \"disabled\" (was {current if current is not None else 'unset'})")
    elif "web" in state:
        new_state["web"] = state["web"]
    # Already off with no record means the user turned it off: it stays off
    # after --remove too, as they had it.

    start, end, at, current = _app_find(lines)
    if start is None:
        if lines and lines[-1].strip():
            lines.append("")
        lines += [f"[apps.{APP_ID}]", "enabled = false"]
        new_state["app"] = "absent"
        done.append(f"[apps.{APP_ID}] enabled = false")
    elif current != "false":
        if at is None:
            lines.insert(start + 1, "enabled = false")
        else:
            lines[at] = "enabled = false"
        new_state["app"] = current if current is not None else "unset"
        done.append(f"[apps.{APP_ID}] enabled = false (was {current if current is not None else 'unset'})")
    elif "app" in state:
        new_state["app"] = state["app"]

    if done:
        new = "\n".join(lines) + "\n"
        if tomllib is not None:
            try:
                parsed = tomllib.loads(new)
            except tomllib.TOMLDecodeError as exc:
                raise Unreadable(f"{CODEX_CONFIG}: turning off the built-in search would leave invalid "
                                 f"TOML ({exc}) — file left as it was")
            if parsed.get("web_search") != "disabled" or parsed.get("apps", {}).get(APP_ID, {}).get("enabled") is not False:
                raise Unreadable(f"{CODEX_CONFIG}: the built-in search did not come out off — file left as it was")
        plan.put(CODEX_CONFIG, base, new,
                 f"built-in web search off: {'; '.join(done)} in {tilde(CODEX_CONFIG)}")
    plan.put(WEB_SEARCH_STATE, read_text(WEB_SEARCH_STATE),
             "".join(f"{k} previous={v}\n" for k, v in new_state.items()) or None, "")


def wire_codex_agents(with_rule, remove, plan):
    """Matched by file name: an @-line naming the rule from elsewhere counts."""
    body = read_text(CODEX_AGENTS) or ""
    lines = body.splitlines()
    ours = [ln for ln in lines if ln.startswith("@") and ln.rstrip().rsplit("/", 1)[-1] == RULE]
    if remove:
        if ours:
            keep = [ln for ln in lines if ln not in ours]
            plan.put(CODEX_AGENTS, body, "\n".join(keep) + ("\n" if keep else ""),
                     "rule reference removed from AGENTS.md")
        return
    if not with_rule or ours:
        return
    sep = "\n" if body and not body.endswith("\n") else ""
    plan.put(CODEX_AGENTS, body, body + sep + f"@{CODEX_RULE}\n", "rule referenced from AGENTS.md")


# ---------------------------------------------------------------- main

def tilde(path):
    return "~" + path[len(HOME):] if path.startswith(HOME) else path


def main(argv):
    if argv[:1] == ["package"]:
        print(SERVER)
        return 0
    if argv[:1] == ["spec"]:
        print("\n".join(COMMAND))
        return 0
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("ide", choices=("claude", "codex", "opencode"))
    ap.add_argument("--search-backend", choices=BACKENDS, default="auto")
    ap.add_argument("--no-rule", action="store_true")
    ap.add_argument("--remove", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--check", action="store_true", help="exit 4 when something would change")
    ap.add_argument("--keep-codex-search", action="store_true",
                    help="codex: leave the built-in web search on (restores it if an earlier run turned it off)")
    a = ap.parse_args(argv)

    plan = Plan()
    try:
        if a.ide == "claude":
            rc = wire_claude(a.search_backend, a.remove, plan)
        elif a.ide == "opencode":
            rc = wire_opencode(a.search_backend, not a.no_rule, a.remove, plan)
        else:
            rc = wire_codex(a.search_backend, not a.no_rule, a.remove, plan, a.keep_codex_search)
    except Unreadable as exc:
        print(f"    {exc} — left untouched", file=sys.stderr)
        return 1
    if rc == 3:
        print(f"    {a.ide} not set up here — skipped")
        return 3

    dry = a.dry_run or a.check
    if not dry:
        try:
            plan.apply()
        except OSError as exc:
            print(f"    {exc}", file=sys.stderr)
            return 1
    prefix = "    would: " if dry else "    "
    for line in plan.lines:
        print(prefix + line if not line.startswith("parked") else "    " + line)
    if not plan.writes:
        print("    = already current")
    return 4 if a.check and plan.writes else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
