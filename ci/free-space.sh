#!/usr/bin/env bash
# Hosted, disposable runner only. No host sudo; Docker already grants root access.
set -Eeuo pipefail
[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_ENVIRONMENT:-} == github-hosted ]] || {
    echo 'Disk cleanup is restricted to GitHub-hosted Actions runners' >&2; exit 1;
}
df -h . /mnt || true
# The stock runner has ~14 GB free. Remove only known preinstalled toolchains.
mounts=()
for dir in /usr/share /usr/local/lib /opt; do
    [[ ! -d $dir ]] || mounts+=(--mount "type=bind,src=$dir,dst=/host$dir")
done
docker run --rm --user 0:0 --entrypoint /bin/bash "${mounts[@]}" \
    archlinux:base-devel -c \
    'rm -rf /host/usr/share/dotnet /host/usr/share/swift /host/usr/local/lib/android /host/opt/ghc /host/opt/hostedtoolcache/CodeQL'
# No shared PR caches: tkg resets tracked files but does not clean untracked patches.
free_kb=$(df -Pk . | awk 'END {print $4}')
(( free_kb >= 32 * 1024 * 1024 )) || {
    echo 'Kernel needs at least 32 GiB free on the workspace filesystem' >&2; exit 1;
}
df -h .
