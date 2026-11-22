#!/usr/bin/env python3
"""Fail if anything in this repository should not be public.

Two layers, both run on every pull request and push:

1. Patterns anyone may read: absolute home and workspace paths, private
   document links, private key blocks, and bare 32-byte hex values.
2. Terms that must never appear here, stored only as SHA-256 hashes of the
   lowercased term with its length (tools/leak-hashes.json), so this file
   reveals nothing about what it guards. Every window of the right length in
   every tracked file is hashed and compared. Only terms of 12 characters or
   more are listed, so a hash cannot be reversed by brute force.

Exits 1 and names the file and line of each hit, never the matched text.

`leak-check.py --files PATH...` checks other files the same way, such as a
release binary before it is published: every run of 8 or more printable bytes
counts as a line, and the bare-hex rule is skipped, since binaries carry
public constants.
"""
import hashlib
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
HASHES = ROOT / "tools" / "leak-hashes.json"

PATTERNS = {
    "an absolute home or workspace path": re.compile(
        # A Windows path is escaped (\\) in text files and plain (\) in binaries.
        r"(/home/[a-z_][\w.-]*/|/(?:root)/|/Users/[\w.-]+/"
        r"|[A-Za-z]:(?:\\\\|\\|/)(?:Users|repos)(?:\\\\|\\|/)"
        r"|[\\/]\.cargo[\\/]registry[\\/]src[\\/])",
        re.I,
    ),
    "a private document link": re.compile(r"(notion\.so/|app\.notion\.com/)", re.I),
    "a private key": re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"),
    "a bare 32-byte hex value (a key or seed?)": re.compile(r"(?<![0-9a-fA-F])[0-9a-fA-F]{64}(?![0-9a-fA-F])"),
}

# A line that names a SHA-256 checksum may carry one: a published download's
# digest is public by design.
CHECKSUM = re.compile(r"sha-?256", re.I)


# This repository's own name is public by definition; it is taken out before
# the guarded terms are checked, so a term it happens to contain still counts
# everywhere else.
PUBLIC_NAMES = ("blackfall-labs/ndk-ci",)


def normalize(text: str) -> str:
    text = re.sub(r"\s+", " ", text.replace("\\", "/").lower())
    for name in PUBLIC_NAMES:
        text = text.replace(name, " ")
    return text


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
    ).stdout.decode()
    return [ROOT / p for p in out.split("\0") if p]


PRINTABLE = re.compile(rb"[\x20-\x7e]{8,}")


def check_lines(rel, lines, by_len, hits, binary=False):
    for n, line in enumerate(lines, 1):
        for what, rx in PATTERNS.items():
            if what.startswith("a bare") and (binary or CHECKSUM.search(line)):
                continue
            if rx.search(line):
                hits.append(f"{rel}:{n}: {what}")
        norm = normalize(line)
        for length, digests in by_len.items():
            for i in range(0, max(0, len(norm) - length + 1)):
                window = norm[i : i + length]
                if hashlib.sha256(window.encode()).hexdigest() in digests:
                    hits.append(f"{rel}:{n}: a term that must not be public")
                    break


def main() -> int:
    guarded = json.loads(HASHES.read_text())
    by_len = {}
    for entry in guarded:
        by_len.setdefault(entry["len"], set()).add(entry["sha256"])

    hits = []
    if sys.argv[1:2] == ["--files"]:
        for name in sys.argv[2:]:
            data = pathlib.Path(name).read_bytes()
            runs = [m.group().decode("ascii") for m in PRINTABLE.finditer(data)]
            check_lines(pathlib.Path(name).name, runs, by_len, hits, binary=True)
    else:
        for path in tracked_files():
            rel = path.relative_to(ROOT)
            if rel == pathlib.Path("tools/leak-hashes.json"):
                continue
            try:
                text = path.read_text(encoding="utf-8")
            except (UnicodeDecodeError, FileNotFoundError):
                continue
            check_lines(rel, text.splitlines(), by_len, hits)
    for h in sorted(set(hits)):
        print(f"::error::{h}")
    if hits:
        print(f"{len(set(hits))} thing(s) here should not be public.")
        return 1
    print("nothing here that should not be public")
    return 0


if __name__ == "__main__":
    sys.exit(main())
