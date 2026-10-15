#!/usr/bin/env python3
"""Writes <lang>.lproj/<Table>.strings for every language in the given string catalogs.

Used by build-release.sh, which builds without Xcode and so cannot compile .xcstrings itself.
Usage: xcstrings-to-strings.py OUTPUT_DIR CATALOG.xcstrings...
"""
import json
import os
import sys


def escape(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


out = sys.argv[1]
for path in sys.argv[2:]:
    table = os.path.basename(path).removesuffix(".xcstrings")
    files = {}
    for key, entry in json.load(open(path, encoding="utf-8"))["strings"].items():
        for lang, loc in entry.get("localizations", {}).items():
            value = loc["stringUnit"]["value"]
            files.setdefault(lang, []).append(f'"{escape(key)}" = "{escape(value)}";')
    for lang, lines in files.items():
        os.makedirs(f"{out}/{lang}.lproj", exist_ok=True)
        with open(f"{out}/{lang}.lproj/{table}.strings", "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")
