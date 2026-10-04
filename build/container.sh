#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source /work/build/lib.sh
export GILGAMESH_ROOT=/work PKGDEST=/work/repo/x86_64 PKGEXT=.pkg.tar.zst
export _EXT_CONFIG_PATH=/work/kernel/customization.cfg
# Keep this pin visible to CI's configuration validator; worker.sh uses the same pin.
commit=85fc90b0bad984902e5edd63ed9c39bbaa33a806
export TKG_COMMIT=$commit
[[ $(id -u) == 0 ]] || die 'container.sh must start as container root'
command=${1:?}
shift
export BUILD_JOBS=${BUILD_JOBS:-$(nproc)}
positive_integer BUILD_JOBS "$BUILD_JOBS"

# Called only by build.sh inside the disposable container.
groupmod -o -g "$BUILDER_GID" builder
usermod -o -u "$BUILDER_UID" -g "$BUILDER_GID" builder
chown -R "$BUILDER_UID:$BUILDER_GID" /home/builder
stage=$(mktemp -d /work/build/cache/run.XXXXXX)
cleanup() {
    local status=$?
    chown -R "$BUILDER_UID:$BUILDER_GID" "$PKGDEST"
    # /work/out is only mounted writable for iso; otherwise it sits on the read-only checkout
    if [[ $command == iso && -d /work/out ]]; then chown -R "$BUILDER_UID:$BUILDER_GID" /work/out; fi
    if [[ $command == iso && $status == 0 ]]; then
        # archiso leaves root-owned files that the host user cannot remove.
        rm -rf -- "$stage"
    else
        chown -R "$BUILDER_UID:$BUILDER_GID" "$stage"
    fi
    return "$status"
}
trap cleanup EXIT
chown "$BUILDER_UID:$BUILDER_GID" "$stage"

as_builder() { (cd "$1"; shift; runuser -u builder -- bash /work/build/worker.sh "$@" </dev/null); }
resolve_packages() {
    local config=$1 database
    shift
    # Resolve against an empty installed DB, not the builder's transient DKMS setup.
    database=$(mktemp -d "$stage/resolve.XXXXXX")
    mkdir "$database/local"
    cp -a /var/lib/pacman/sync "$database/"
    pacman --config "$config" --dbpath "$database" -Sp --noconfirm --print-format '%n %v' "$@"
}
refresh_repo() {
    index_repo "${1:-strict}"
    repo_config /etc/pacman.conf "$stage/pacman.conf" file:///work/repo/x86_64 Never
    cp "$stage/pacman.conf" /etc/pacman.conf
    # Refresh only our database: official DBs and installed toolchain stay fixed.
    awk '/^\[/ && $0 != "[options]" && $0 != "[gilgamesh]" {exit} {print}' /etc/pacman.conf > "$stage/local.conf"
    pacman --config "$stage/local.conf" -Syy --noconfirm
    if [[ ${1:-strict} != bootstrap ]]; then
        local name
        local -a targets=()
        for name in linux-tkg linux-tkg-headers nvidia-open-tkg gilgamesh-settings gilgamesh-shell; do
            [[ ! -v latest[$name] ]] || targets+=("gilgamesh/$name")
        done
        ((${#targets[@]} == 0)) || resolve_packages /etc/pacman.conf "${targets[@]}"
    fi
}

if [[ $command == repo ]]; then
    refresh_repo strict
    exit
fi

# One full upgrade per run; never upgrade between the kernel and NVIDIA steps.
# Start with official repositories so stale local NVIDIA cannot obstruct bootstrap.
awk '/^\[gilgamesh\]$/ {skip=1; next} /^\[/ {skip=0} !skip {print}' /etc/pacman.conf > "$stage/official.conf"
cp "$stage/official.conf" /etc/pacman.conf
pacman -Syu --noconfirm
check_space /work/build/cache "${BUILD_SPACE_GIB:-48}"
check_space / "${CONTAINER_SPACE_GIB:-16}"

prepare_package() {
    local name=$1
    mkdir -p "$stage/$name"
    cp -a "/work/packages/$name/." "$stage/$name/"
    chown -R "$BUILDER_UID:$BUILDER_GID" "$stage/$name"
    as_builder "$stage/$name" metadata
    awk -f /work/build/check-sources.awk "$stage/$name/.SRCINFO"
}
install_deps() {
    local -a deps=()
    mapfile -t deps < <(srcinfo_deps "$1/.SRCINFO")
    ((${#deps[@]} == 0)) || pacman -S --needed --noconfirm "${deps[@]}"
}
build_package() {
    local directory=$1
    install_deps "$directory"
    if [[ ${directory##*/} == nvidia-open-tkg ]]; then
        [[ -f /work/build/cache/kernel-toolchain ]] || die 'kernel toolchain manifest missing; run kernel-stack'
        toolchain_manifest > "$stage/nvidia-toolchain"
        [[ $(pacman -Q linux-tkg) == "linux-tkg $(cat /work/build/cache/kernel-version)" ]] || die 'kernel does not match the recorded toolchain; run kernel-stack'
        (cd "$PKGDEST"; sha256sum -c /work/build/cache/kernel-archives.sha256) || die 'kernel archives changed since the toolchain was recorded'
        cmp -s /work/build/cache/kernel-toolchain "$stage/nvidia-toolchain" || die 'kernel/NVIDIA toolchain changed; run kernel-stack'
    fi
    as_builder "$directory" build
    refresh_repo bootstrap
}

case $command in
    pkg)
        directories=()
        for name in "$@"; do prepare_package "$name"; directories+=("$stage/$name"); done
        if [[ " $* " == *' nvidia-open-tkg '* ]]; then
            bash /work/packages/nvidia-open-tkg/preflight.sh "$stage/nvidia-open-tkg/.SRCINFO" "$stage/inputs" "$PKGDEST"
        fi
        [[ ! -f $PKGDEST/gilgamesh.db ]] || refresh_repo bootstrap
        package_order "${directories[@]}" > "$stage/order"
        while read -r directory; do build_package "$directory"; done < "$stage/order"
        refresh_repo strict
        ;;
    kernel|kernel-prep|kernel-stack|all)
        [[ ${KERNEL_VERSION:-} =~ ^7\.2\.[0-9]+$ ]] || die 'set KERNEL_VERSION to the exact planned 7.2.x release'
        [[ ! -v PKGREL ]] || positive_integer PKGREL "$PKGREL"
        prepare_package nvidia-open-tkg
        bash /work/packages/nvidia-open-tkg/preflight.sh "$stage/nvidia-open-tkg/.SRCINFO" "$stage/inputs" "$PKGDEST"
        refresh_repo bootstrap
        mkdir "$stage/kernel"
        chown "$BUILDER_UID:$BUILDER_GID" "$stage/kernel"
        as_builder "$stage/kernel" kernel-source
        as_builder "$stage/kernel" metadata
        awk -f /work/build/check-sources.awk "$stage/kernel/.SRCINFO"
        install_deps "$stage/kernel"
        toolchain_manifest > "$stage/kernel-toolchain"
        if [[ $command == kernel-prep ]]; then
            as_builder "$stage/kernel" kernel-prepare
            exit 0
        fi
        check_space /work/build/cache "${BUILD_SPACE_GIB:-48}"
        check_space / "${CONTAINER_SPACE_GIB:-16}"
        # one makepkg run: the PKGBUILD wrapper checks the config after tkg's prepare
        as_builder "$stage/kernel" build
        refresh_repo bootstrap
        for name in linux-tkg linux-tkg-headers; do
            grep -Fxq "${latest[$name]}" "$stage/kernel/.outputs" || die 'new kernel outputs were superseded by existing archives'
        done
        cp "$stage/kernel-toolchain" /work/build/cache/kernel-toolchain
        printf '%s\n' "${versions[linux-tkg]}" > /work/build/cache/kernel-version
        (cd "$PKGDEST"; sha256sum "${latest[linux-tkg]##*/}" "${latest[linux-tkg-headers]##*/}") > /work/build/cache/kernel-archives.sha256
        if [[ $command == kernel-stack || $command == all ]]; then
            build_package "$stage/nvidia-open-tkg"
            refresh_repo strict
        fi
        if [[ $command == all ]]; then
            for name in gilgamesh-settings gilgamesh-shell; do
                prepare_package "$name"
                build_package "$stage/$name"
            done
            refresh_repo complete
        fi
        ;;
    iso)
        refresh_repo complete
        # mkinitcpio provides lsinitcpio, which iso-image.sh uses to check the live initramfs
        pacman -S --needed --noconfirm archiso mkinitcpio go
        cp -a /work/iso "$stage/profile"
        repo_config /work/iso/pacman.conf "$stage/profile/pacman.conf" file:///work/repo/x86_64 Never
        live=$stage/profile/airootfs
        mkdir -p "$live/opt/gilgamesh/repo"
        # Carry selected archives and the matching DB into the live system.
        cp -- "${latest[@]}" "$PKGDEST/gilgamesh.db.tar.zst" "$PKGDEST/gilgamesh.files.tar.zst" "$live/opt/gilgamesh/repo/"
        ln -s gilgamesh.db.tar.zst "$live/opt/gilgamesh/repo/gilgamesh.db"
        ln -s gilgamesh.files.tar.zst "$live/opt/gilgamesh/repo/gilgamesh.files"
        repo_config /work/iso/pacman.conf "$live/etc/pacman.conf" file:///opt/gilgamesh/repo Never
        bash /work/build/iso-payload.sh /work "$live" "$stage/tools"
        mapfile -t iso_packages < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$stage/profile/packages.x86_64")
        resolve_packages "$stage/profile/pacman.conf" "${iso_packages[@]}"
        check_space /work/out "${OUTPUT_SPACE_GIB:-8}"
        # Verify generated boot files before mksquashfs can package the live root.
        export GILGAMESH_ISO_WORK=$stage/work
        export GILGAMESH_MKSQUASHFS
        GILGAMESH_MKSQUASHFS=$(command -v mksquashfs)
        mkdir "$stage/bin"
        printf '%s\n' '#!/usr/bin/env bash' 'exec bash /work/build/iso-image.sh "$@"' > "$stage/bin/mksquashfs"
        chmod +x "$stage/bin/mksquashfs"
        export PATH="$stage/bin:$PATH"
        mkarchiso -v -w "$stage/work" -o /work/out "$stage/profile"
        ;;
    *) die 'expected pkg, kernel, kernel-prep, kernel-stack, all, repo or iso' ;;
esac
