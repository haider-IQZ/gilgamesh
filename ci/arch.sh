#!/usr/bin/env bash
# One derived image per job, shared with build/build.sh.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ ${1:-} == image ]]; then
    docker build --pull -t gilgamesh-base build
    exec docker build -t gilgamesh-builder - < ci/Dockerfile
fi
extra=()
case ${1:-} in
    checksums)
        [[ $2 =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]
        extra+=(--mount "type=bind,src=$PWD/packages/$2,dst=/work/packages/$2") ;;
    nvcheck)
        mkdir -p ci/artifacts
        extra+=(--env GH_TOKEN --mount "type=bind,src=$PWD/ci/artifacts,dst=/work/ci/artifacts") ;;
    kernel-check)
        [[ ${KERNEL_VERSION:-} =~ ^7\.2\.[0-9]+$ ]] || { echo 'Exact planned KERNEL_VERSION required' >&2; exit 1; }
        mkdir -p build/cache/linux-tkg
        extra+=(--env KERNEL_VERSION --mount "type=bind,src=$PWD/build/cache/linux-tkg,dst=/work/build/cache/linux-tkg") ;;
esac
exec docker run --rm -i --user 0:0 "${extra[@]}" \
    --env "CI_UID=$(id -u)" --env "CI_GID=$(id -g)" \
    --mount "type=bind,src=$PWD,dst=/work,readonly" \
    gilgamesh-builder bash /work/ci/arch-container.sh "$@"
