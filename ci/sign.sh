#!/usr/bin/env bash
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
: "${GILGAMESH_GPG_KEY:?Missing signing key}" "${GILGAMESH_GPG_PASSPHRASE:?Missing passphrase}"
: "${GILGAMESH_GPG_FINGERPRINT:?Missing pinned primary fingerprint}"
secret_dir=$(mktemp -d)
chmod 700 "$secret_dir"
trap 'rm -rf -- "$secret_dir"' EXIT
# Never enable xtrace or put key/passphrase in argv.
printf '%s' "$GILGAMESH_GPG_KEY" > "$secret_dir/key"
printf '%s' "$GILGAMESH_GPG_PASSPHRASE" > "$secret_dir/passphrase"
unset GILGAMESH_GPG_KEY GILGAMESH_GPG_PASSPHRASE
chmod 600 "$secret_dir/"*
docker run --rm --user "$(id -u):$(id -g)" \
    --env GILGAMESH_GPG_FINGERPRINT \
    --mount "type=bind,src=$PWD,dst=/work,readonly" \
    --mount "type=bind,src=$PWD/ci/artifacts/publish/repo,dst=/work/ci/artifacts/publish/repo" \
    --mount "type=bind,src=$secret_dir,dst=/secrets,readonly" \
    gilgamesh-builder bash /work/ci/sign-container.sh "$@"
