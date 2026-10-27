#!/usr/bin/env python3
"""Repoint a caller workflow at the Bioconductor reusable BiocCheck workflow.

Usage: update_ci_reference.py FILE NEW_USES

Replaces any `uses: waldronlab/.github/.github/workflows/*.yml@ref` line with
NEW_USES and drops `with:` inputs the new workflow does not accept (cran,
enable_docker, dockerfile_path). An emptied `with:` block is removed.
Exits 0 and prints "changed" or "unchanged".
"""
import re
import sys

OLD_USES = re.compile(r"^(\s*)uses:\s*waldronlab/\.github/\.github/workflows/\S+\s*$")
UNSUPPORTED = {"cran", "enable_docker", "dockerfile_path"}


def indent_of(line):
    return len(line) - len(line.lstrip(" "))


def transform(lines, new_uses):
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = OLD_USES.match(line.rstrip("\n"))
        if not m:
            out.append(line)
            i += 1
            continue
        base = len(m.group(1))
        out.append(f"{m.group(1)}uses: {new_uses}\n")
        i += 1
        # Copy sibling keys, filtering the with: block.
        while i < len(lines):
            cur = lines[i]
            if cur.strip() == "":
                break
            if indent_of(cur) < base:
                break
            if indent_of(cur) == base and cur.strip().startswith("with:"):
                block = [cur]
                i += 1
                body = []
                while i < len(lines) and (
                    lines[i].strip() == "" or indent_of(lines[i]) > base
                ):
                    if lines[i].strip() == "":
                        break
                    body.append(lines[i])
                    i += 1
                kept = []
                skipping = False
                key_indent = indent_of(body[0]) if body else 0
                for b in body:
                    if indent_of(b) == key_indent:
                        key = b.strip().split(":", 1)[0]
                        skipping = key in UNSUPPORTED
                    if not skipping:
                        kept.append(b)
                if kept:
                    out.extend(block + kept)
                continue
            out.append(cur)
            i += 1
    return out


def main():
    path, new_uses = sys.argv[1], sys.argv[2]
    with open(path) as fh:
        original = fh.readlines()
    updated = transform(original, new_uses)
    if updated == original:
        print("unchanged")
        return
    with open(path, "w") as fh:
        fh.writelines(updated)
    print("changed")


if __name__ == "__main__":
    main()
