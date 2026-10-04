#!/usr/bin/env python3
"""Validate evaluated .SRCINFO on stdin; never source PKGBUILDs on the host."""
import re
import sys
from collections import defaultdict


def check(text):
    values = defaultdict(list)
    for line in text.splitlines():
        key, sep, value = line.strip().partition(" = ")
        if sep:
            values[key].append(value)
    for key, sources in values.items():
        if key != "source" and not key.startswith("source_"):
            continue
        suffix = key[len("source"):]
        sums = [v for k, v in values.items()
                if re.fullmatch(r"(?:md5|sha1|sha224|sha256|sha384|sha512|b2)sums" + re.escape(suffix), k)]
        for hashes in sums:
            if len(hashes) != len(sources):
                raise ValueError(f"{key}: source/checksum counts differ")
        for i, source in enumerate(sources):
            url = source.split("::", 1)[-1]
            vcs = re.match(r"(?:git|svn|hg|bzr|fossil)(?:\+[^:]+)?://", url)
            remote = re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*://", url)
            if remote and not vcs:
                if not sums or any(h[i] == "SKIP" for h in sums):
                    raise ValueError(f"{key}: remote source lacks checksum or uses SKIP: {source}")
                if not any(re.fullmatch(r"[0-9a-fA-F]{64,128}", h[i]) for h in sums):
                    raise ValueError(f"{key}: remote source requires SHA-256 or stronger: {source}")


if __name__ == "__main__":
    check(sys.stdin.read())
