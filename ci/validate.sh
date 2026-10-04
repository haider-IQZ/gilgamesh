#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
for script in ci/*.sh ci/gpg-loopback; do bash -n "$script"; done
python3 -m compileall -q ci
python3 ci/check-workflows.py
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck ci/*.sh ci/gpg-loopback
else
    echo 'UNAVAILABLE offline: shellcheck (bash -n still ran)' >&2
fi
if command -v actionlint >/dev/null 2>&1; then
    actionlint .github/workflows/*.yml
else
    echo 'UNAVAILABLE offline: actionlint (PyYAML and workflow policy checks still ran)' >&2
fi
python3 -m unittest discover -s ci/tests -v
