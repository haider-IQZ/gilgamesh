#!/usr/bin/env bash
# Shared by the host wrapper, container and offline tests.

die() { echo "build: $*" >&2; exit 1; }

positive_integer() { [[ $2 =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer"; }

check_space() {
    local path=$1 gib=$2 available
    positive_integer 'space budget (GiB)' "$gib"
    available=$(df -Pk -- "$path" | awk 'END {print $4}')
    [[ $available =~ ^[0-9]+$ ]] || die "cannot measure free space: $path"
    (( available >= gib * 1024 * 1024 )) || die "$path needs at least $gib GiB free"
}

# Replace any existing section and insert before the first official repository.
repo_config() {
    local input=$1 output=$2 server=$3 signature=$4
    awk -v server="$server" -v signature="$signature" '
        /^\[gilgamesh\]$/ {skip=1; next}
        /^\[/ {skip=0}
        !skip && /^\[/ && $0 != "[options]" && !added {
            print "[gilgamesh]\nSigLevel = " signature "\nServer = " server "\n"
            added=1
        }
        !skip {print}
        END {if (!added) exit 1}
    ' "$input" > "$output"
}

# pkgbase section only: package() overrides like nvidia's depends=("linux-tkg=${_kernelpkg}")
# are evaluated by --printsrcinfo before the kernel exists and come out as "linux-tkg=".
srcinfo_deps() {
    awk '$1 == "pkgname" {exit} $1 ~ /^(make|check)?depends(_x86_64)?$/ && $2 == "=" {print $3}' "$1" | sort -u
}

# Input directories must already have evaluated .SRCINFO files.
package_order() {
    local dir other dep name progress
    local -a pending=("$@") next=()
    declare -A owner=() ordered=()
    for dir in "${pending[@]}"; do
        while read -r name; do owner[$name]=$dir; done < <(awk '$1 == "pkgname" {print $3}' "$dir/.SRCINFO")
    done
    while ((${#pending[@]})); do
        progress=0 next=()
        for dir in "${pending[@]}"; do
            [[ ! -v ordered[$dir] ]] || continue
            other=''
            while read -r dep; do
                name=${dep%%[\<\>\=]*}
                if [[ -v owner[$name] && ${owner[$name]} != "$dir" && ! -v ordered[${owner[$name]}] ]]; then
                    other=${owner[$name]}
                    break
                fi
            done < <(srcinfo_deps "$dir/.SRCINFO")
            if [[ -n $other ]]; then next+=("$dir"); else
                printf '%s\n' "$dir"
                ordered[$dir]=1 progress=1
            fi
        done
        ((progress)) || die 'cycle in selected package dependencies'
        pending=("${next[@]}")
    done
}

toolchain_manifest() {
    pacman -Q gcc gcc-libs binutils glibc make pahole
}

declare -A versions=() latest=() metadata=()

# Select archives using Arch version comparison, then check before replacing a DB.
select_packages() {
    local archive info key value name version
    versions=() latest=() metadata=()
    shopt -s nullglob
    for archive in "$PKGDEST"/*.pkg.tar.zst; do
        info=$(bsdtar -xOf "$archive" .PKGINFO) || die "cannot read $archive"
        name='' version=''
        while IFS=' ' read -r key _equals value; do
            case $key in pkgname) name=$value ;; pkgver) version=$value ;; esac
        done <<< "$info"
        [[ $name =~ ^[a-zA-Z0-9@_+.-]+$ && -n $version ]] || die "invalid package metadata: $archive"
        if [[ ! -v versions[$name] ]] || (( $(vercmp "$version" "${versions[$name]}") > 0 )); then
            versions[$name]=$version latest[$name]=$archive metadata[$name]=$info
        fi
    done
    ((${#latest[@]})) || die 'no packages in repo/x86_64'
}

check_coherence() {
    local mode=$1 dep name expected value
    if [[ -v versions[linux-tkg] || -v versions[linux-tkg-headers] ]]; then
        [[ -n ${versions[linux-tkg]:-} && ${versions[linux-tkg]:-} == "${versions[linux-tkg-headers]:-}" ]] ||
            die 'linux-tkg and linux-tkg-headers must have identical versions'
    fi
    if [[ -v versions[nvidia-open-tkg] ]]; then
        dep=$(awk '$1 == "depend" && $3 ~ /^linux-tkg=/ {print $3}' <<< "${metadata[nvidia-open-tkg]}")
        if [[ -z ${versions[linux-tkg]:-} || $dep != "linux-tkg=${versions[linux-tkg]:-}" ]]; then
            if [[ $mode == bootstrap ]]; then
                echo 'build: omitting stale NVIDIA archive until it is rebuilt' >&2
                unset 'latest[nvidia-open-tkg]' 'versions[nvidia-open-tkg]' 'metadata[nvidia-open-tkg]'
            else die 'NVIDIA must depend on the exact selected linux-tkg version'; fi
        fi
    fi
    if [[ $mode == bootstrap && -v versions[nvidia-open-tkg] ]]; then
        expected=$(awk '$1 == "depend" && $3 ~ /^nvidia-utils=/ {sub(/^nvidia-utils=/, "", $3); print $3}' <<< "${metadata[nvidia-open-tkg]}")
        value=${versions[nvidia-utils]:-}
        [[ $expected == *-* ]] || value=${value%-*}
        if [[ -n $expected && -n $value && $(vercmp "$expected" "$value") != 0 ]]; then
            echo 'build: omitting NVIDIA archive with stale userspace dependency' >&2
            unset 'latest[nvidia-open-tkg]' 'versions[nvidia-open-tkg]' 'metadata[nvidia-open-tkg]'
        fi
    fi
    for name in "${!latest[@]}"; do
        while read -r dep; do
            [[ $dep == *=* && $dep != *'>'* && $dep != *'<'* ]] || continue
            expected=${dep#*=} dep=${dep%%=*}
            if [[ -v versions[$dep] ]]; then
                # libalpm ignores pkgrel when the dependency omits it.
                value=${versions[$dep]}
                [[ $expected == *-* ]] || value=${value%-*}
                [[ $(vercmp "$expected" "$value") == 0 ]] || die "$name requires $dep=$expected, selected ${versions[$dep]}"
            fi
        done < <(awk '$1 == "depend" {print $3}' <<< "${metadata[$name]}")
    done
    if [[ $mode == complete ]]; then
        for name in linux-tkg linux-tkg-headers nvidia-open-tkg gilgamesh-settings gilgamesh-shell; do
            [[ -v latest[$name] ]] || die "incomplete repository: missing $name"
        done
    fi
}

index_repo() {
    local mode=${1:-strict} stage kind
    select_packages
    check_coherence "$mode"
    stage=$(mktemp -d "$PKGDEST/.database.XXXXXX")
    if ! repo-add "$stage/gilgamesh.db.tar.zst" "${latest[@]}"; then
        rm -rf -- "$stage"
        die 'repo-add failed; previous database retained'
    fi
    for kind in db files; do
        mv -f "$stage/gilgamesh.$kind.tar.zst" "$PKGDEST/"
        ln -sfn "gilgamesh.$kind.tar.zst" "$PKGDEST/gilgamesh.$kind"
    done
    rm -rf -- "$stage"
}
