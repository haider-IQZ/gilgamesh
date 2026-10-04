# nvidia-open-tkg

Prebuilt NVIDIA open modules for `linux-tkg`. Prefer one container/toolchain run:

```sh
KERNEL_VERSION=7.2.N BUILD_JOBS=8 build/build.sh kernel-stack
```

Replace `7.2.N` with the exact reviewed kernel release. `kernel-prep` checks NVIDIA
availability before kernel preparation; `kernel-stack` builds and indexes the pair.
Separate `kernel` and `pkg nvidia-open-tkg` commands check the recorded toolchain
and kernel archive identity, and fail if they differ. Native Arch builds need
matching kernel/headers plus both exact NVIDIA dependencies already installed.

`preflight.sh` resolves and retains the pinned `nvidia-utils` and `nvidia-open-dkms`
archives **before** kernel compilation. If either pin is unavailable, bootstrap
through CI's **update** mode, which advances the recipe to the observed official
version; push/PR mode retains the pin. Review that update and retain its inputs
before starting a long build. The wrapper copies signed official input archives
to the controlled local bootstrap repo so mirror rotation cannot remove them from
this run. CI must separately retain these inputs between jobs; see the build guide.

The kernel release comes from `/usr/src/linux-tkg/version`, or the module build
directory owned by `linux-tkg-headers`; it never comes from the running kernel.
The resulting package pins `linux-tkg` to the installed headers' full version,
including epoch and release. Modules go into that kernel's
`/usr/lib/modules/<release>/extramodules` directory.

Rebuild after every kernel or NVIDIA driver change. For a rebuild of the same
kernel version, use `PKGREL=N build/build.sh kernel` with a higher release number
(see the [build guide](../../build/README.md)), which automatically re-indexes the repository. Also
increase this package's `pkgrel` for the module rebuild. Keep its `pkgver` equal
to Arch's `nvidia-utils` version, and publish kernel and matching modules together.
Existing package archives are never overwritten by the build commands.

`nvidia-open-dkms=$pkgver` supplies the prepared sources and license. DKMS runs
only during the build; the shipped package contains compressed modules and their
license without a DKMS runtime dependency. `nvidia-utils=$pkgver` and `libglvnd`
remain runtime dependencies.
