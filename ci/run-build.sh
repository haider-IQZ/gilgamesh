#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
group=$1
[[ $group =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]
mkdir -p "ci/artifacts/result-$group"
# Capture setup failures too; report() supplies default failures if result.json is absent.
exec > >(tee "ci/artifacts/result-$group/setup.log") 2>&1
if [[ $group == kernel ]]; then bash ci/free-space.sh; fi
bash ci/arch.sh image
python3 ci/pipeline.py build-group "$group"
python3 - "$group" <<'PY'
import json, sys
from pathlib import Path
results = json.loads(Path(f'ci/artifacts/result-{sys.argv[1]}/result.json').read_text())
if any(p['status'] != 'ok' for p in results['packages'].values()):
    raise SystemExit('One or more builds failed; successful independent results remain publishable')
PY
