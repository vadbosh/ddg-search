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
  codex     ~/.codex/config.toml      [mcp_servers.ddg-search]
            ~/.codex/mcp-disabled.toml
                                      updated instead when parked there
            ~/.codex/AGENTS.md        an @-line naming the rule file
  opencode  ~/.config/opencode/opencode.json
                                      mcp.ddg-search with codemode: false,
                                      and the rule file in "instructions";
                                      an "enabled": false set by hand or by
                                      mcp-tools is kept

The entry named ddg-search is ours: its command, arguments and our one
environment variable are rewritten to the pinned form below. Any other key in
it, and every other server, key and line, is left as it was. A configuration
file is backed up before it is written, outside every directory an assistant
reads (~/.local/state/ddg-search/backups/).

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
COMMAND = ["uvx", "--python", PYTHON, f"{PACKAGE}[browser]=={VERSION}"]
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
        if old == new:
            return
        self.writes[path] = new
        self.lines.append(what)

    def apply(self):
        for path, text in self.writes.items():
            backup(path)
            atomic_write(path, text)


# ---------------------------------------------------------------- entries

def env_for(backend):
    return {} if backend == "auto" else {BACKEND_ENV: backend}


def merge_env(old_env, backend):
    env = dict(old_env or {})
    env.pop(BACKEND_ENV, None)
    env.update(env_for(backend))
    return env


def claude_entry(old, backend):
    entry = dict(old or {})
    entry["command"] = COMMAND[0]
    entry["args"] = COMMAND[1:]
    env = merge_env(entry.get("env"), backend)
    if env:
        entry["env"] = env
    else:
        entry.pop("env", None)
    return entry


def opencode_entry(old, backend):
    entry = dict(old or {})
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

def toml_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def section_range(lines, name):
    """(start, end) of [mcp_servers.<name>] and its sub-tables, or (None, None)."""
    header = f"[mcp_servers.{name}]"
    quoted = f'[mcp_servers."{name}"]'
    prefixes = (f"[mcp_servers.{name}.", f'[mcp_servers."{name}".')
    start = next((i for i, ln in enumerate(lines) if ln.strip() in (header, quoted)), None)
    if start is None:
        return None, None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        s = lines[i].strip()
        if s.startswith("[") and not s.startswith(prefixes):
            end = i
            break
    while end > start + 1 and not lines[end - 1].strip():
        end -= 1
    return start, end


KEY_RE = re.compile(r"^\s*([A-Za-z0-9_\-]+)\s*=")


ENV_HEADERS = (f"[mcp_servers.{NAME}.env]", f'[mcp_servers."{NAME}".env]')


def codex_section(old_lines, backend):
    """Our section. Kept from the old one: every key of the main table except
    command, args and env; every variable of the env sub-table except ours;
    every other sub-table, verbatim. A multi-line array value of a dropped key
    is dropped whole."""
    extra, env_extra, subs = [], [], []
    where, skipping = "main", False
    for ln in old_lines[1:]:
        s = ln.strip()
        if skipping:
            skipping = "]" not in s
            continue
        if s.startswith("[") and not KEY_RE.match(ln):
            where = "env" if s in ENV_HEADERS else "sub"
            if where == "sub":
                subs.append(ln)
            continue
        m = KEY_RE.match(ln)
        if where == "main":
            if m and m.group(1) in ("command", "args", "env"):
                value = ln.split("=", 1)[1].strip()
                skipping = value.startswith("[") and "]" not in value
                continue
            if s:
                extra.append(ln)
        elif where == "env":
            if m and m.group(1) == BACKEND_ENV:
                continue
            if s:
                env_extra.append(ln)
        else:
            subs.append(ln)
    out = [f"[mcp_servers.{NAME}]",
           f"command = {toml_str(COMMAND[0])}",
           "args = [" + ", ".join(toml_str(a) for a in COMMAND[1:]) + "]"] + extra
    env_lines = env_extra + [f"{k} = {toml_str(v)}" for k, v in env_for(backend).items()]
    if env_lines:
        out += ["", ENV_HEADERS[0]] + env_lines
    if subs:
        out += [""] + subs
    return out


def codex_put(path, backend, remove, plan, create):
    text = read_text(path)
    if text is None and not create:
        return False
    lines = (text or "").splitlines()
    start, end = section_range(lines, NAME)
    if remove:
        if start is None:
            return False
        before, after = lines[:start], lines[end:]
        while before and not before[-1].strip():
            before.pop()
        while after and not after[0].strip():
            after.pop(0)
        body = before + ([""] if before and after else []) + after
        plan.put(path, text, "\n".join(body) + ("\n" if body else ""), f"server removed from {tilde(path)}")
        return True
    if start is None:
        if not create:
            return False
        section = codex_section([f"[mcp_servers.{NAME}]"], backend)
        body = lines + ([""] if lines and lines[-1].strip() else []) + section
        plan.put(path, text, "\n".join(body) + "\n", f"server added in {tilde(path)}")
        return True
    section = codex_section(lines[start:end], backend)
    body = lines[:start] + section + lines[end:]
    plan.put(path, text, "\n".join(body) + "\n", f"server updated in {tilde(path)}")
    return True


def wire_codex(backend, with_rule, remove, plan):
    if not os.path.isdir(CODEX_DIR):
        return 3
    if remove:
        codex_put(CODEX_CONFIG, backend, True, plan, False)
        codex_put(CODEX_PARKED, backend, True, plan, False)
    else:
        parked_text = read_text(CODEX_PARKED) or ""
        is_parked = section_range(parked_text.splitlines(), NAME)[0] is not None
        if is_parked:
            codex_put(CODEX_PARKED, backend, False, plan, False)
            plan.lines.append(f"parked in {tilde(CODEX_PARKED)} — {tilde(CODEX_CONFIG)} left alone")
        else:
            codex_put(CODEX_CONFIG, backend, False, plan, True)
    wire_codex_agents(with_rule, remove, plan)
    return 0


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
    a = ap.parse_args(argv)

    plan = Plan()
    try:
        if a.ide == "claude":
            rc = wire_claude(a.search_backend, a.remove, plan)
        elif a.ide == "opencode":
            rc = wire_opencode(a.search_backend, not a.no_rule, a.remove, plan)
        else:
            rc = wire_codex(a.search_backend, not a.no_rule, a.remove, plan)
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
