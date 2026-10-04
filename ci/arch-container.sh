#!/usr/bin/env bash
set -Eeuo pipefail
cd /work
if [[ $(id -u) == 0 ]]; then
    groupmod -o -g "$CI_GID" builder
    usermod -o -u "$CI_UID" -g "$CI_GID" builder
    chown -R "$CI_UID:$CI_GID" /home/builder
    exec runuser -u builder -- bash "$0" "$@"
fi
case $1 in
    nvcheck)
        python /work/ci/check-workflows.py
        exec bash /work/ci/nvcheck.sh
        ;;
    check|checksums)
        mode=$1
        cd "packages/$2"
        makepkg --printsrcinfo | python /work/ci/check-sources.py
        if [[ $mode == checksums ]]; then
            updpkgsums
            makepkg --printsrcinfo | python /work/ci/check-sources.py
        fi
        ;;
    kernel-check)
        [[ ${KERNEL_VERSION:-} =~ ^7\.2\.[0-9]+$ ]] || { echo 'Exact planned KERNEL_VERSION required' >&2; exit 1; }
        checkout=/work/build/cache/linux-tkg
        pin=$(python -c 'import tomllib; print(tomllib.load(open("ci/nvchecker.toml", "rb"))["tkg"]["manual"])')
        git -C "$checkout" init
        git -C "$checkout" remote add origin https://github.com/Frogging-Family/linux-tkg.git
        git -C "$checkout" fetch --depth=1 https://github.com/Frogging-Family/linux-tkg.git "$pin"
        git -C "$checkout" checkout --detach FETCH_HEAD
        [[ $(git -C "$checkout" rev-parse HEAD) == "$pin" ]]
        cd "$checkout"
        export _EXT_CONFIG_PATH=/work/kernel/customization.cfg
        makepkg --printsrcinfo | python /work/ci/check-sources.py
        ;;
    metadata) bsdtar -xOf "$2" .PKGINFO ;;
    compare) vercmp "$2" "$3" ;;
    verify)
        export GNUPGHOME
        GNUPGHOME=$(mktemp -d)
        trap 'rm -rf -- "$GNUPGHOME"' EXIT
        gpg --batch --import /work/keys/gilgamesh.asc
        shift
        for file in "$@"; do gpg --batch --verify "$file.sig" "$file"; done
        ;;
    *) echo "unknown Arch operation: $1" >&2; exit 2 ;;
esac
