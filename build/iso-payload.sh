#!/usr/bin/env bash
set -Eeuo pipefail

root=${1:?checkout root required}
live=${2:?live filesystem required}
work=${3:?tools build directory required}
payload=$live/opt/gilgamesh/src

mkdir -p "$work" "$payload/tools/bin"
for name in installer system quickshell hypr fish scripts etc branding kernel; do
    cp -a -- "$root/$name" "$payload/"
done
if [[ -f $root/keys/gilgamesh.asc ]]; then
    install -Dm644 "$root/keys/gilgamesh.asc" "$payload/keys/gilgamesh.asc"
fi

# Build from a writable copy, excluding local binaries, caches and test scratch.
for name in go.mod go.sum cmd internal; do
    cp -a -- "$root/tools/$name" "$work/"
done
(
    cd "$work"
    # The container may download pinned modules; do not inherit the offline Makefile.
    export GOENV=off GOTOOLCHAIN=local GOFLAGS=-mod=mod
    export CGO_ENABLED=0 GOOS=linux GOARCH=amd64
    go mod download
    go mod verify
    for name in gilgamesh-install gilgamesh-dns; do
        go build -trimpath -buildvcs=false -ldflags '-s -w -buildid=' -o "bin/$name" "./cmd/$name"
    done
)
# Refuse dependency changes or missing checksums instead of silently updating pins.
cmp -- "$root/tools/go.mod" "$work/go.mod"
cmp -- "$root/tools/go.sum" "$work/go.sum"
for name in gilgamesh-install gilgamesh-dns; do
    install -m755 "$work/bin/$name" "$payload/tools/bin/$name"
done
