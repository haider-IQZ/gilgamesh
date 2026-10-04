# Gilgamesh live ISO

Based on archiso's official `releng` profile. From the repository root, run:

```sh
build/build.sh iso
```

This is the only build command that runs a **privileged container**, with
`mkarchiso` as root. It installs archiso and Go in the builder environment, stages a
fresh profile under `build/cache/run.*/profile`, builds in that directory's `work/`,
and writes the ISO to `out/`. Package installation requires working Arch mirrors;
the Go build downloads pinned modules and verifies their checksums.
See the [build guide](../build/README.md) for host and container requirements.
Validate the installed archiso version and container mount support in a smoke build.

Staging copies `installer`, `system`, `quickshell`, `hypr`, `fish`, `scripts`, `etc`,
`branding` and `kernel` from the same checkout into
`airootfs/opt/gilgamesh/src/`. Both Go tools are built statically with trimmed paths,
no VCS metadata or build ID, and staged under `tools/bin/` in that checkout layout.
`/usr/local/bin/gilgamesh-install` is a symlink to the Go installer; it resolves
the executable path and finds the payload two parent directories above `bin/`.
The optional public `keys/gilgamesh.asc` is included for target repository trust.
Build from a fixed, clean checkout for release images. The original profile
remains unchanged. Each build gets a fresh work directory because mkarchiso caches
completed steps. Successful builds remove that run inside the container; failed
builds retain it for diagnostics. See the build guide for root-owned run cleanup.

Set `SOURCE_DATE_EPOCH` to a release timestamp to stabilize the ISO label and
version. Reproducing an entire image also requires identical package inputs and
tool versions; Arch mirrors change over time.

## Live environment

On tty1, releng's `.zlogin` hook displays the bundled logo, waits up to about
30 seconds for internet access, initializes the pacman keyring, then launches the
Go installer once per boot with `TERM=linux` for colours. If still offline, it
leaves a shell with connection instructions. Wired DHCP and `iwctl` for Wi-Fi
are available. After connecting,
run `gilgamesh-install` manually. Installation still needs internet for packages.
The legacy Bash installer remains at `/opt/gilgamesh/src/installer/install.sh`;
run `gilgamesh-install-bash` for that manual fallback (stock linux, without Go's
bootstrap package selection).
Cancelling or returning leaves a shell; other ttys never launch the installer.
Releng's explicit `script=` kernel option takes precedence over this autostart.

The x86_64 profile retains systemd-boot UEFI, Syslinux BIOS, accessibility entries,
networking, root autologin and rescue tools. The installer requires UEFI; BIOS
boot is available for rescue. Guest integration services are omitted. `gum`, `git`,
`curl` and `pciutils` are included alongside releng's installation tools.

The live image deliberately keeps Arch's `linux` package for broad compatibility;
all boot templates retain its kernel/initramfs names. Settings and shell are installed
from the completed local repository. A final `zz-archiso.conf` preserves live hooks
over settings' installed-system defaults, and the build checks generated initramfs
contents before filesystem packaging. Tkg, headers and prebuilt NVIDIA travel in
the staged repository for installation, not as the live kernel.

Before mkarchiso, the builder requires a coherent complete package set and resolves
the ISO list. The staged profile uses `file:///work/repo/x86_64`; inside the live
image the copied repository is at `file:///opt/gilgamesh/repo`. Only that bootstrap
repo disables signatures, and it precedes official repos. Published clients must
instead trust the reviewed key and use the signed flat Release URL documented in
[build/README.md](../build/README.md). The Go installer detects `gilgamesh.db` there
and installs tkg, matching prebuilt NVIDIA when selected, settings and shell.
The installed target drops the unsigned live repo; it enables the signed published
repo only after importing the bundled public key, if one is present.

Before releasing an image, test UEFI boot, tty1 startup, offline connection and
manual retry, cancellation, tty2 rescue, and a complete installation in a
disposable VM. Test BIOS rescue separately if distributing that boot mode.
