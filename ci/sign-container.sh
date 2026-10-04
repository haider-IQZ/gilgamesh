#!/usr/bin/env bash
set -Eeuo pipefail
export GNUPGHOME
GNUPGHOME=$(mktemp -d)
trap 'gpgconf --kill gpg-agent || true; rm -rf -- "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"
gpg --batch --import /work/keys/gilgamesh.asc
gpg --batch --import /secrets/key
# shellcheck source=ci/sign-repo.sh
source /work/ci/sign-repo.sh
validate_signing_identity
sign_repository /work/ci/artifacts/publish/repo
