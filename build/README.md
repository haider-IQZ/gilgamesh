# Local builds

Use Bash, coreutils, `flock`, and Docker accessible to your normal user. Podman is
used if Docker is absent; rootless Podman support for archiso still needs a smoke
test on the intended host. These commands download Arch packages and upstream
sources when actually run. No host privilege escalation is used. Only `iso` starts
a privileged container. Package compilation uses an unprivileged builder; the
container root installs dependencies before each build, without makepkg elevation.

```sh
build/build.sh pkg gilgamesh-shell gilgamesh-settings
KERNEL_VERSION=7.2.N BUILD_JOBS=8 build/build.sh kernel-prep
KERNEL_VERSION=7.2.N BUILD_JOBS=8 build/build.sh kernel-stack
build/build.sh iso
```

Replace `7.2.N` with the reviewed, exact release from the update plan; it is an
illustrative placeholder, not a claim that a particular release exists. There is
no floating kernel default. Tkg documents `vX.Y.Z` tags in its config; the wrapper
passes exactly that tag and checks the prepared kernel's `make kernelversion`.
The pinned upstream recipe has not been fetched or exercised by the offline audit.

Commands:

| Command | Result |
|---|---|
| `pkg <dir>...` | Order the selected packages by evaluated dependencies, build, index, refresh the local database after each |
| `kernel-prep` | Retain exact NVIDIA inputs, fetch pinned tkg, resolve config, check source policy and required symbols; no kernel compilation |
| `kernel` | Prepare and build kernel + headers, then index; may omit stale NVIDIA from this intermediate bootstrap index |
| `kernel-stack` | Build kernel + headers and NVIDIA in one container, then validate their versions |
| `all` | Run `kernel-stack`, then settings → repo → shell → repo, requiring the complete set |
| `repo` | Re-index existing archives and check dependency resolution, without upgrading the container |
| `iso` | Require the complete coherent repository, resolve ISO dependencies, then stage/build the stock-linux live image |

`pkg` orders only the directories supplied. Include settings when bootstrapping
shell; otherwise its dependency must already be indexed. Build the kernel first
or use `kernel-stack` for NVIDIA. Cycles fail before compilation. Existing package
archives are never overwritten: bump the recipe's `pkgrel`, or use `PKGREL=N` for
tkg (a positive integer above its last release). The pinned recipe's default is
273; the wrapper patches its hard-coded assignment. Rebuild NVIDIA with a higher
package release whenever the kernel changes.

## Inputs and toolchain

The first invocation creates `gilgamesh-builder` from `build/Dockerfile`. Rebuild
that image explicitly after Dockerfile or makepkg configuration changes:

```sh
docker build --pull --no-cache -t gilgamesh-builder build
```

Each build run fully upgrades the disposable container once, then holds its
official sync databases fixed. Between builds only the **local** database is
refreshed. `repo` does no upgrade and does not refresh official databases. Prefer
`kernel-stack` or `all`: kernel and NVIDIA share the same installed compiler and
libraries. Separate invocations compare GCC, GCC libraries, binutils, glibc, make
and pahole against the kernel manifest, and verify the kernel package version and
archive hashes; a mismatch requires rebuilding the pair.

Before kernel preparation, `packages/nvidia-open-tkg/preflight.sh` resolves both
exact NVIDIA dependencies, installs them and retains their signed official
archives. Those inputs are copied to the local bootstrap repository so later
builds and the live system can satisfy the same runtime version despite mirror
rotation. An unavailable pin fails immediately, before kernel compilation. For a
fresh bootstrap, use the CI **update** planning mode to advance the NVIDIA recipe
to the observed official version; push/PR planning intentionally retains its pin.
Update mode does not remove the need to retain inputs before a long build.

Tkg is extracted from commit `85fc90b0bad984902e5edd63ed9c39bbaa33a806` into a fresh
`build/cache/run.*/kernel/` directory, using a bare Git cache in `build/cache/tkg.git`.
The source checkout is mounted read-only. Work, logs, final config, retained input
archives and toolchain manifests remain in `build/cache/`; outputs are in
`repo/x86_64/`. Builds sharing this checkout are serialized with `flock`.

The evaluated recipe passes the same remote-source checksum rules as
`ci/check-sources.py` before preparation. `makepkg --nobuild` resolves Kconfig;
`kernel/check-config.sh` checks the actual `.config` and `kernelconfig.new`, including
BTF, DWARF, sched_ext prerequisites, virtio, storage and live-filesystem support.
Compilation uses `--noextract`, keeping the checked preparation. A build-function
guard rejects missing executable `resolve_btfids` before headers packaging can
reach tkg's interactive error path. Builder stdin is closed, and tkg's terminal
logging wrapper is disabled. Upstream paths and behavior still need the first
real preparation run; unexpected layouts fail closed.

## Space and parallelism

`BUILD_JOBS` defaults to `nproc`, and controls makepkg, tkg, DKMS and package
compression. Set it lower to limit compilation memory. Tkg no longer forces all
threads. Space checks run after image preparation on the host workspace/output
filesystems and in the container's root filesystem, then again before kernel
compilation. Configurable free-space budgets (GiB):

| Variable | Default | Purpose |
|---|---|---|
| `BUILD_SPACE_GIB` | 48 | Sources, build tree and retained ISO work |
| `OUTPUT_SPACE_GIB` | 8 | Package/ISO output |
| `CONTAINER_SPACE_GIB` | 16 | Container storage and installed dependencies |

Workspace and package output budgets are added when they share a filesystem.
These are conservative starting guards, **not measured capacity guarantees**.
Measure peak disk/RAM in the first rehearsal, particularly full modules with
DWARF/BTF. Successful ISO builds remove their entire `build/cache/run.*` directory
inside the container. Failed ISO builds and other commands retain diagnostics.
After inspecting them, remove obsolete runs (including root-owned archiso files)
from the checkout root with:

```sh
docker run --rm -v "$PWD/build/cache:/c" archlinux:base-devel sh -c 'rm -rf /c/run.*'
```

The shell inside the container expands `/c/run.*` on the mounted cache.

`SOURCE_DATE_EPOCH` stabilizes ISO dates, not Arch mirror contents or bit-for-bit
reproducibility.

## Repository and ISO

The unsigned bootstrap `[gilgamesh]` section is inserted **before official repos**,
with a repository-specific `SigLevel = Never`. Official signature requirements
remain unchanged. Indexing selects newest Arch versions, requires identical
kernel/headers versions, and checks NVIDIA's exact kernel and local dependencies.
Intermediate bootstrap indexing omits stale NVIDIA; `repo` rejects it and `iso`
requires kernel, headers, NVIDIA, settings and shell. Pacman's resolver also checks
external dependencies against an empty installed database, so the builder's DKMS
build dependency cannot mask a missing runtime input. Old archives may remain, but are not all put in the DB.

`iso` stages a fresh profile under `build/cache/run.*/profile`. Its build-time
`pacman.conf` uses `file:///work/repo/x86_64`. Selected packages and their matching
database are also copied into the live filesystem at `/opt/gilgamesh/repo`; the
live `pacman.conf` uses that path, never `/work`. This is a controlled unsigned
bootstrap image, not a signed release-client configuration. The live image installs
settings and shell but keeps Arch's stock **linux** kernel for compatibility and
unchanged UEFI/BIOS/speech/PXE boot paths. The tkg/NVIDIA packages travel in its
repository for later installation, not as live kernel modules.

`zz-archiso.conf` overrides packaged installed-system mkinitcpio defaults. Before
mksquashfs runs, a wrapper requires stock kernel/initramfs filenames and inspects
the generated initramfs for all archiso runtime hooks. The archiso invocation and
wrapper interception still require validation against the installed archiso
version. Output goes to `out/`; successful ISO work is removed inside the container.

The ISO step installs Go in the container and builds both `gilgamesh-install` and
`gilgamesh-dns` from a writable copy of `tools/`. It downloads the pinned modules
with `GOFLAGS=-mod=mod`, verifies them, and rejects changes to `go.mod` or `go.sum`.
No vendor tree is required. Builds use `CGO_ENABLED=0`, `-trimpath`,
`-buildvcs=false` and `-ldflags '-s -w -buildid='`; the container's Go must satisfy
the module's Go 1.26 requirement. The offline `tools/Makefile` is not used.

The payload checkout is staged at `/opt/gilgamesh/src`, with both static binaries
under `tools/bin/`. `/usr/local/bin/gilgamesh-install` points to that installer;
its resolved executable's two parent directories locate `installer/packages`
and the adjacent payload even when launched from `/root`. Only the optional
public `keys/gilgamesh.asc` is copied from `keys/`. tty1 launches the Go installer
after the network wait and keyring initialization, with `TERM=linux` for colours.
Run `gilgamesh-install` to retry or `gilgamesh-install-bash` for the legacy
`installer/install.sh` fallback, which retains its stock-linux behavior.

The Go installer detects `/opt/gilgamesh/repo/gilgamesh.db` and uses
`file:///opt/gilgamesh/repo` for bootstrap packages: tkg, matching prebuilt NVIDIA
when selected, settings and shell. Official packages still require internet.
The target loses the unsigned live repository; the signed published repository
is enabled only if the bundled public key is present and imported successfully.

For **published clients**, install/trust the reviewed public certificate first,
then put this above official repositories (the GitHub Release layout is flat):

```ini
[gilgamesh]
SigLevel = Required DatabaseRequired
Server = https://github.com/haider-IQZ/gilgamesh/releases/download/repo
```

Never copy the unsigned bootstrap policy into a published client. The local
builder does not sign output or establish the published signing key's trust.

## Integration still required outside this task

CI currently requires the literal `_version="7.2-latest"` in `pipeline.py:config`.
It must accept an exact tag supplied by the planned kernel version, forward
`KERNEL_VERSION` through the build wrapper, and pass it to `kernel-check` too.
Use a shared kernel/NVIDIA run (or retain matching toolchain inputs across CI
containers) and carry the exact NVIDIA archives through preparation/build jobs.
CI must classify retained `nvidia-utils`/`nvidia-open-dkms` archives as build inputs,
not kernel outputs: its current new-archive discovery would otherwise reject them
as unexpected kernel outputs. For updates, bump the NVIDIA recipe before invoking
kernel preflight, rather than waiting until its later build unit. A standalone
NVIDIA CI job also needs the kernel toolchain/version/hash manifests from its build,
or must rebuild the pair in one run.
The current strict literal check will reject this exact-version configuration
until that CI change is made. CI was deliberately not edited here.

The Go installer implements bootstrap selection, package ownership handling and
optional signed target-repository setup; validate those paths in a disposable VM.
Full offline installation is not supported. PLAN.md still describes a tkg live kernel and needs
reconciliation with the stock live-kernel decision. No system/ change is needed
for initramfs precedence; the override is confined to the ISO.

Offline checks: `python3 build/test-local.py`, Bash syntax checks, and ShellCheck
if installed. Docker, Arch/pacman, upstream preparation, actual signatures, boot
modes and ISO/VM behavior require a connected build-only rehearsal. Start with
`kernel-prep` and an archiso smoke test before the expensive kernel build.
