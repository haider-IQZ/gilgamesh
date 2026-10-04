#!/usr/bin/env bash
# Edit only the reviewed local PKGBUILD. No AUR recipe downloads.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
exec python3 ci/pipeline.py bump "$@"
