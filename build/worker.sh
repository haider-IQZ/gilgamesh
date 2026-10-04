#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=lib.sh
source /work/build/lib.sh
export HOME=/home/builder PKGDEST=/work/repo/x86_64 PKGEXT=.pkg.tar.zst
export GILGAMESH_ROOT=/work
umask 022

action=$1
shift
case $action in
    metadata) makepkg --printsrcinfo > .SRCINFO ;;
    build)
        archives=$(makepkg --packagelist)
        while IFS= read -r archive; do
            [[ ! -e $archive && ! -L $archive ]] || die "refusing to overwrite $archive; bump pkgrel"
        done <<< "$archives"
        makepkg --noconfirm "$@"
        printf '%s\n' "$archives" > .outputs
        ;;
    kernel-source)
        commit=${TKG_COMMIT:?}
        cache=/work/build/cache/tkg.git
        [[ -d $cache ]] || git init --bare "$cache"
        if ! git -C "$cache" cat-file -e "$commit^{commit}"; then
            git -C "$cache" fetch https://github.com/Frogging-Family/linux-tkg.git "$commit"
        fi
        git -C "$cache" archive "$commit" | tar -x
        cp /work/kernel/gilgamesh.myfrag gilgamesh.myfrag
        if [[ -v PKGREL ]]; then
            grep -Eq '^pkgrel=[0-9]+$' PKGBUILD || die 'unexpected tkg pkgrel assignment'
            sed -i "s/^pkgrel=[0-9][0-9]*$/pkgrel=$PKGREL/" PKGBUILD
        fi
        # Fail before any headers packaging can enter tkg's missing-BTF prompt.
        cat >> PKGBUILD <<'WRAPPER'

[[ $(type -t build) == function ]] || { echo 'tkg: missing build function' >&2; exit 1; }
eval "$(declare -f build | sed '1s/^build /_gilgamesh_tkg_build /')"
build() {
    _gilgamesh_tkg_build
    local -a btfids=()
    mapfile -t btfids < <(find "$srcdir" "$startdir/linux-src-git" -type f -path '*/tools/bpf/resolve_btfids/resolve_btfids' -executable 2>/dev/null)
    ((${#btfids[@]})) || { echo 'tkg: resolve_btfids missing; refusing headers packaging' >&2; return 1; }
}

# tkg's EXIT trap deletes its state, so the next makepkg recreates a fresh worktree without
# .config: prepare and build must happen in ONE makepkg run. Check the config right after
# tkg's prepare, before any compilation.
[[ $(type -t prepare) == function ]] || { echo 'tkg: missing prepare function' >&2; exit 1; }
eval "$(declare -f prepare | sed '1s/^prepare /_gilgamesh_tkg_prepare /')"
prepare() {
    _gilgamesh_tkg_prepare
    local -a configs=()
    mapfile -t configs < <(find "$_where" -type f -name .config -path '*/linux-*/.config')
    ((${#configs[@]} == 1)) || { echo 'tkg: cannot identify a unique prepared kernel .config' >&2; return 1; }
    bash /work/kernel/check-config.sh "${configs[0]}" || return 1
    local resolved
    resolved=$(make -s -C "${configs[0]%/.config}" kernelversion)
    [[ $resolved == "$KERNEL_VERSION" ]] || { echo "tkg: prepared kernel is $resolved, expected $KERNEL_VERSION" >&2; return 1; }
}
WRAPPER
        ;;
    kernel-prepare)
        makepkg --nobuild --noconfirm
        bash /work/kernel/check-config.sh kernelconfig.new
        # Validate the actual build-tree config as well as tkg's diagnostic copy.
        mapfile -t configs < <(find "$PWD" -type f -name .config -path '*/linux-*/.config')
        ((${#configs[@]} == 1)) || die 'cannot identify a unique prepared kernel .config'
        cmp -s kernelconfig.new "${configs[0]}" || die 'kernelconfig.new differs from prepared .config'
        bash /work/kernel/check-config.sh "${configs[0]}"
        resolved=$(make -s -C "$(dirname "${configs[0]}")" kernelversion)
        [[ $resolved == "$KERNEL_VERSION" ]] || die "prepared kernel is $resolved, expected $KERNEL_VERSION"
        ;;
    *) die "unknown worker action: $action" ;;
esac
