#!/usr/bin/env python3
"""What PyPI has for duckduckgo-mcp-server, against the version lib/wire.py pins.

  upstream.py                 one line for release.sh check
  upstream.py --latest        print the newest version on PyPI
  upstream.py --browser V     exit 0 when version V still declares the [browser] extra

Exit codes (default mode): 0 the pin is the newest, 10 a newer version
exists, 2 PyPI could not be read. DDG_PYPI_JSON names a file to read instead
of PyPI — the tests use it.
"""
import json
import os
import re
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wire import PACKAGE, VERSION  # noqa: E402

PYPI = f"https://pypi.org/pypi/{PACKAGE}/json"
PYPI_VERSION = f"https://pypi.org/pypi/{PACKAGE}/{{}}/json"


def fetch(url):
    local = os.environ.get("DDG_PYPI_JSON")
    if local:
        with open(local, encoding="utf-8") as fh:
            return json.load(fh)
    with urllib.request.urlopen(url, timeout=10) as resp:
        return json.load(resp)


def key(version):
    """Release versions compare as numbers; anything else sorts first."""
    parts = re.findall(r"\d+", version)
    final = re.fullmatch(r"\d+(\.\d+)*", version) is not None
    return (tuple(int(p) for p in parts), final)


def latest():
    data = fetch(PYPI)
    releases = [v for v, files in data.get("releases", {}).items()
                if files and not any(f.get("yanked") for f in files)]
    finals = [v for v in releases if re.fullmatch(r"\d+(\.\d+)*", v)]
    return max(finals, key=key) if finals else data["info"]["version"]


def has_browser(version):
    data = fetch(PYPI_VERSION.format(version))
    requires = data.get("info", {}).get("requires_dist") or []
    return any(re.search(r"extra\s*==\s*['\"]browser['\"]", r) for r in requires)


def main(argv):
    try:
        if argv[:1] == ["--latest"]:
            print(latest())
            return 0
        if argv[:1] == ["--browser"] and len(argv) == 2:
            return 0 if has_browser(argv[1]) else 1
        newest = latest()
    except (OSError, ValueError, KeyError) as exc:
        print(f"upstream:     not checked — PyPI unreadable ({exc})")
        return 2
    if key(newest) > key(VERSION):
        print(f"upstream:     {newest} on PyPI, pinned {VERSION} — ./update.sh")
        return 10
    print(f"upstream:     {VERSION} is the newest on PyPI")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
