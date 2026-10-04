#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
mkdir -p ci/artifacts
for script in ci/*.sh ci/gpg-loopback; do bash -n "$script"; done
python3 -m unittest discover -s ci/tests
bash ci/arch.sh image
bash ci/arch.sh nvcheck
cp ci/artifacts/newver.json ci/newver.json
python3 ci/pipeline.py plan --mode "$1" --force "${2:-}"
