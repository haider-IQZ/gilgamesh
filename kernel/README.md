# Kernel

[linux-tkg](https://github.com/Frogging-Family/linux-tkg) with the BORE scheduler, built in the
Arch build container and shipped in `[gilgamesh]` as `linux-tkg` + `linux-tkg-headers`.

- `customization.cfg`: tkg's own config file with our values (marked `gilgamesh`), everything else
  at tkg's default. Set so a build never stops at a prompt.
- `gilgamesh.myfrag`: kernel options tkg has no setting for.

## Choices

| Setting | Value | Why |
|---|---|---|
| Version | exact `KERNEL_VERSION=7.2.N` → `v7.2.N` | reviewed tag, no floating resolution |
| CPU scheduler | BORE | burst-aware EEVDF for desktop latency; nothing argues against it |
| Preemption | full | tkg always sets `CONFIG_PREEMPT` (no option); `PREEMPT_DYNAMIC` stays, so `preempt=lazy` can be tried without a rebuild |
| Timer | 1000 Hz | tkg's default for BORE |
| Ticks | tickless idle (`_tickless=2`) | full tickless only helps with `nohz_full` CPU isolation |
| Compiler | GCC, -O2, no LTO | -O3 and LTO show no desktop gain, tkg warns LTO may not boot; GCC keeps NVIDIA module builds simple |
| CPU target | `znver3` | Zen 3; test VMs need `host-passthrough` CPU or the kernel won't boot |
| MGLRU | on | better behaviour under memory pressure |
| Command line | nothing baked in | tkg's default bakes in `intel_pstate=passive` |
| Debug, ftrace, NUMA | kept | static keys cost ~nothing; sched_ext LAVD needs ftrace; NUMA off breaks CUDA/NVENC |
| Mitigations | speculative-execution mitigations on (kernel default) | a few % at most on Ryzen, and they keep VM isolation meaningful. Exception: Zenify sets split-lock mitigation off, which does nothing on Zen 3 (no split-lock detection) |
| Modules | full set | no `_kernel_on_diet` / modprobed-db, so virtio (`VIRTIO_BLK`, `VIRTIO_PCI` must resolve to `=y`) and everything else stays |
| Packages | `linux-tkg`, stripped | same name across kernel versions; DWARF stripped at packaging, BTF kept |

Fragment (`gilgamesh.myfrag`), where tkg's base config disagrees with us:

| Option | Why |
|---|---|
| THP `madvise` | `always` grows memory use for programs that never asked for huge pages |
| zswap off by default | swap is zram |
| `HALTPOLL_CPUIDLE=y` | guest idle polling; as a module it never loads |
| `XFS_FS=y` | root filesystem without an initramfs |
| `WQ_POWER_EFFICIENT_DEFAULT` off | performance over power saving |
| DWARF + BTF + `SCHED_CLASS_EXT` | sched_ext and BPF tools; pinned because `_STRIP=true` makes tkg pick "no debug info" |

## Build

Use the local wrapper; replace `7.2.N` with the exact reviewed release from the
update plan, not a literal `N`:

```sh
KERNEL_VERSION=7.2.N BUILD_JOBS=8 build/build.sh kernel-prep
KERNEL_VERSION=7.2.N BUILD_JOBS=8 build/build.sh kernel-stack
```

Preparation evaluates the pinned tkg recipe, checks remote-source policy, retains
exact NVIDIA inputs, and checks the resolved kernel version and configuration.
`check-config.sh` requires BTF/DWARF, sched_ext prerequisites, scheduler choices,
virtio, storage and live-filesystem support. Compilation preserves that prepared
tree and fails if `resolve_btfids` is missing before packaging headers. See
[build/README.md](../build/README.md) for resource guards, exact-version CI follow-up,
unsigned bootstrap policy and offline verification limits.

Inspect `build/cache/run.*/kernel/kernelconfig.new`, the source `.config`, and
preparation/build logs before shipping. The pinned upstream tree is not present
in this checkout; the first real prep run must validate its paths and behavior.
Output is `linux-tkg` plus `linux-tkg-headers` in `repo/x86_64/`.

## NVIDIA

We ship `nvidia-open` prebuilt against `linux-tkg` in `[gilgamesh]` instead of
`nvidia-open-dkms`: no module compile on the user's machine. It has to be rebuilt (with the same
GCC) on every `linux-tkg` or driver bump, and depend on the exact kernel version it was built for.

## Next: 7.3

Review a move to 7.3 separately, including an exact release tag and CI series policy.
7.3 "flattens the pick" (one EEVDF runqueue instead of a hierarchy): much better minimum FPS
with background load in the scheduler maintainer's test. Re-check BORE against plain EEVDF then.
