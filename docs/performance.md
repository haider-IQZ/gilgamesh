# Performance defaults

Gilgamesh's tuning aims at responsive interaction, memory pressure and game/audio
latency. This page describes the checked-in [system](../system) and [kernel](../kernel)
configuration and its intent. It makes no benchmark or FPS claims. Kernel settings
below describe the custom build recipe; inspect the built kernel configuration before
treating them as effective runtime settings.

## Memory and storage

| Configuration | Setting | Intent / tradeoff |
| --- | --- | --- |
| [zram](../system/etc/systemd/zram-generator.conf) | One zstd-compressed swap device, logical size equal to RAM, priority 100. | Use compressed memory for swap; compression costs CPU time and still consumes RAM. |
| [sysctl](../system/etc/sysctl.d/70-gilgamesh.conf) | `vm.swappiness=180`, `vm.page-cluster=0` | Favor zram over evicting file cache; skip swap readahead on random-access compressed RAM. |
| Same | `vm.watermark_boost_factor=0`, `vm.watermark_scale_factor=125` | Avoid boosted reclaim bursts and begin background reclaim earlier. |
| Same | `vm.vfs_cache_pressure=50` | Retain directory and inode caches longer. |
| Same | `vm.dirty_bytes=268435456`, `vm.dirty_background_bytes=67108864`, `vm.dirty_writeback_centisecs=1500` | Start background flushing at 64 MiB, make writers flush at 256 MiB, and wake periodic writeback every 15 seconds. These choose writeback behavior, not a durability guarantee. |
| [MGLRU](../system/etc/tmpfiles.d/gilgamesh-mglru.conf) | `min_ttl_ms=1000` | Protect the last second of the working set from eviction to reduce thrashing; under severe pressure this can favor an OOM kill over continued reclaim. |
| [I/O scheduler](../system/etc/udev/rules.d/60-gilgamesh-ioschedulers.rules) | `none` for disks matching `vd[a-z]*` | Avoid another scheduling layer for virtual disks whose host already schedules I/O. Other disk names are untouched by this rule. |

## Scheduling and kernel build

[customization.cfg](../kernel/customization.cfg) selects BORE, a 1000 Hz timer and
tickless idle. Its BORE minimum base-slice setting is 2,000,000 ns. The intent is low
interactive scheduling latency without requiring full tickless CPU isolation. The
default governor selection is `ondemand` with tkg's aggressive ondemand option; this
does not establish which governor a particular running system actually uses.

The recipe uses GCC, `-O2`, no LTO and `_processor_opt="znver3"`. That is an explicit
CPU architecture target, not a portable build for every x86_64 CPU. Change and validate
the target when building for other CPUs. Full modules are retained: both the diet
build and modprobed-db filtering are disabled. Debug facilities, ftrace and NUMA are
not broadly disabled, preserving tracing and compatibility. No custom kernel command
line is baked in.

[gilgamesh.myfrag](../kernel/gilgamesh.myfrag) requests:

- Transparent huge pages on `madvise`, so programs opt in rather than applying them everywhere.
- zswap off by default, avoiding another compression layer in front of zram.
- Built-in XFS and haltpoll support. Haltpoll is intended for KVM's dedicated-vCPU hint.
- Per-CPU workqueues rather than power-efficient workqueues, favoring cache locality.
- DWARF during the build, BTF and `SCHED_CLASS_EXT`, preserving BPF/sched_ext support
  while the packaged kernel is stripped.

The fragment records full/dynamic preemption, MGLRU, virtio block/PCI and 1000 Hz as
inherited tkg base settings. They still need checking in the generated `kernelconfig.new`;
see [kernel build checks](../kernel/README.md#build). Enabling sched_ext support does
not select a sched_ext scheduler: this recipe selects BORE.

The [module list](../system/etc/modules-load.d/gilgamesh.conf) requests `ntsync` for
Windows-style game synchronization and `cpuidle-haltpoll` for eligible KVM guests.
The kernel config's legacy `_ntsync=false` option is documented there as having no
effect on kernel 6.14 and later; it is not a switch disabling the upstream driver.

A [pacman hook](../system/usr/share/libalpm/hooks/gilgamesh-hyprland-rt.hook) reapplies
`cap_sys_nice=ep` to Hyprland after installation or replacement, allowing its realtime
scheduling request to work under CPU load.

## Audio

- [PipeWire](../system/etc/pipewire/pipewire.conf.d/10-gilgamesh-vm.conf) permits a minimum
  quantum of 32 in detected VMs. The [PulseAudio compatibility layer](../system/etc/pipewire/pipewire-pulse.conf.d/10-gilgamesh-vm.conf)
  permits `256/48000`. These lower limits allow smaller buffers; they do not force every
  client to use them or promise a measured end-to-end latency.
- [WirePlumber](../system/etc/wireplumber/wireplumber.conf.d/90-gilgamesh-alsa.conf)
  sets zero ALSA headroom and disables idle suspension for matching PCI HDMI outputs,
  avoiding extra buffering and a delayed first sound.
- [snd_hda_intel](../system/etc/modprobe.d/gilgamesh-audio.conf) uses `power_save=0`
  and `enable_msi=1`. Keeping the device awake trades power saving for prompt playback;
  MSI is intended to avoid legacy interrupt overhead.

## Boot and background work

The [initramfs config](../system/etc/mkinitcpio.conf.d/gilgamesh.conf) uses systemd
hooks and lz4 compression for fast decompression. Its hooks include microcode,
keyboard, block devices and filesystems; the fsck hook is omitted for the XFS setup.
The [ly override](../system/etc/systemd/system/ly@.service.d/10-gilgamesh.conf) uses
`Type=simple` to avoid the idle-service delay before showing login.

[Service defaults](../system/etc/systemd/system.conf.d/00-gilgamesh.conf) shorten start
timeouts to 15 seconds and stop timeouts to 10 seconds. Slow services may need their
own overrides. [Journald](../system/etc/systemd/journald.conf.d/00-gilgamesh.conf) caps
system journal use at 50M. The system overlay masks `localsearch-3.service`, disabling
background file indexing.

The sysctl file disables the NMI watchdog and lowers console log verbosity;
[modprobe rules](../system/etc/modprobe.d/gilgamesh-watchdog.conf) blacklist three
hardware watchdog drivers (`sp5100_tco`, `iTCO_wdt`, `wdat_wdt`). This reduces watchdog
activity while giving up those diagnostics. [NetworkManager](../system/etc/NetworkManager/conf.d/gilgamesh-dns.conf)
uses systemd-resolved for its resolver/cache integration.
