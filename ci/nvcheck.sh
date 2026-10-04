#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# A temporary keyfile, never an interpolated secret in TOML or an artifact.
export NVCHECKER_KEYFILE
NVCHECKER_KEYFILE=$(mktemp)
chmod 600 "$NVCHECKER_KEYFILE"
trap 'rm -f -- "$NVCHECKER_KEYFILE"' EXIT
python3 - <<'PY'
import json, os
from pathlib import Path
Path(os.environ['NVCHECKER_KEYFILE']).write_text(
    '[keys]\n"github.com" = ' + json.dumps(os.environ.get('GH_TOKEN', '')) + '\n')
PY
# Do not permit a partial check to reuse stale candidates.
scratch=$(mktemp -d)
trap 'rm -f -- "$NVCHECKER_KEYFILE"; rm -rf -- "$scratch"' EXIT
cp ci/nvchecker.toml ci/oldver.json "$scratch/"
nvchecker -c "$scratch/nvchecker.toml"
cp "$scratch/newver.json" ci/artifacts/newver.json
