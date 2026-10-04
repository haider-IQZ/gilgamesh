#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
usage() { die 'usage: build/build.sh pkg <dir>... | kernel | kernel-prep | kernel-stack | all | repo | iso'; }

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
image=gilgamesh-builder

[[ $# -gt 0 ]] || usage
case $1 in
    pkg)
        [[ $# -ge 2 ]] || usage
        for dir in "${@:2}"; do
            [[ $dir =~ ^[a-zA-Z0-9][a-zA-Z0-9._+-]*$ ]] || die "invalid package directory: $dir"
            [[ -f $root/packages/$dir/PKGBUILD ]] || die "missing packages/$dir/PKGBUILD"
        done
        ;;
    kernel|kernel-prep|kernel-stack|all|repo|iso) [[ $# -eq 1 ]] || usage ;;
    *) usage ;;
esac
if [[ -v PKGREL ]]; then
    [[ $PKGREL =~ ^[1-9][0-9]*$ ]] || die 'PKGREL must be a positive integer'
fi

case $1 in
    kernel|kernel-prep|kernel-stack|all)
        [[ ${KERNEL_VERSION:-} =~ ^7\.2\.[0-9]+$ ]] || die 'set KERNEL_VERSION to the exact planned 7.2.x release'
        ;;
esac
export BUILD_JOBS=${BUILD_JOBS:-$(nproc)}
positive_integer BUILD_JOBS "$BUILD_JOBS"

[[ $(id -u) -ne 0 ]] || die 'run as a normal host user'
if command -v docker >/dev/null 2>&1; then
    engine=docker
    userns=()
elif command -v podman >/dev/null 2>&1; then
    engine=podman
    userns=(--userns=keep-id)
else
    die 'Docker or Podman is required'
fi

mkdir -p "$root/repo/x86_64" "$root/build/cache"
# Serialize builds and database updates sharing this checkout.
exec 9>"$root/build/cache/build.lock"
flock -n 9 || die 'another build or repo update is running'

if ! "$engine" image inspect "$image" >/dev/null 2>&1; then
    "$engine" build -t "$image" "$root/build"
fi

# Check after image preparation, which also consumes container storage.
if [[ $1 != repo ]]; then
    check_space "$root/build/cache" "${BUILD_SPACE_GIB:-48}"
    check_space "$root/repo/x86_64" "${OUTPUT_SPACE_GIB:-8}"
    # Same-filesystem work/output budgets must be available together.
    if [[ $(stat -c %d "$root/build/cache") == "$(stat -c %d "$root/repo/x86_64")" ]]; then
        check_space "$root/build/cache" "$(( ${BUILD_SPACE_GIB:-48} + ${OUTPUT_SPACE_GIB:-8} ))"
    fi
fi
extra=()
if [[ $1 == iso ]]; then
    mkdir -p "$root/out"
    check_space "$root/out" "${OUTPUT_SPACE_GIB:-8}"
    extra+=(--privileged --mount "type=bind,src=$root/out,dst=/work/out")
fi
[[ ! -v PKGREL ]] || extra+=(--env "PKGREL=$PKGREL")
[[ ! -v SOURCE_DATE_EPOCH ]] || extra+=(--env "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH")
for name in KERNEL_VERSION BUILD_JOBS BUILD_SPACE_GIB OUTPUT_SPACE_GIB CONTAINER_SPACE_GIB; do
    [[ ! -v $name ]] || extra+=(--env "$name=${!name}")
done

"$engine" run --rm "${userns[@]}" --user 0:0 \
    "${extra[@]}" \
    --env "BUILDER_UID=$(id -u)" --env "BUILDER_GID=$(id -g)" \
    --mount "type=bind,src=$root,dst=/work,readonly" \
    --mount "type=bind,src=$root/repo/x86_64,dst=/work/repo/x86_64" \
    --mount "type=bind,src=$root/build/cache,dst=/work/build/cache" \
    "$image" bash /work/build/container.sh "$@"
