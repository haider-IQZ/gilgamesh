# gilgamesh-bench

A local Linux A/B benchmark kit, built with Go 1.26 and its standard library.
It measures changes; it never applies tunings, requests privileges, downloads
tools, or changes the shared Go build cache. Run it as the desktop user.

```sh
cd bench
GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOWORK=off GOTELEMETRY=off go build -o gilgamesh-bench .
./gilgamesh-bench run --label baseline --suites memory,sched,messaging \
  --settle 60s --warmups 2 --repeats 5 --cooldown 10s --duration 60s
./gilgamesh-bench compare results/baseline-TIMESTAMP.json results/treatment-TIMESTAMP.json
```

Run commands from `bench/`: output is always `results/<label>-<UTC timestamp>.json`
relative to the working directory. `results/` and the executable are ignored here.
Files are created mode 0600. **Never commit results**: they contain the kernel
command line, CPU model, paths, boot IDs, command output, and other local system
state. Review and redact any data before sharing it. An existing results directory
keeps its existing permissions.

`run --help` lists all options. All six suites run by default; `io` skips unless
`--io-dir` is supplied. Missing optional tools skip with a reason. A tool that is
present but fails (including permissions or unsupported options) fails its suite;
the command output and partial samples remain in JSON, and `run` exits nonzero.
Comparisons exclude failed suites, even if some samples succeeded. Interrupts
terminate child process groups, clean scratch files, and save partial results.
Forced termination or power loss can leave scratch files under `results/` or the
chosen I/O directory; only remove a stale `.gilgamesh-bench-*` directory after
checking that no benchmark is using it.

## Measurements

| Suite | Method and endpoint | Limits |
| --- | --- | --- |
| `boot` | `systemd-analyze time`, `blame`, and `critical-chain graphical.target`; seconds per phase/unit | Read once per boot, regardless of repeats/warmups. Unit durations overlap. These are manager timings, not login/bar visible readiness. |
| `sched` | Fair-class, one-thread `cyclictest` with CPU affinity; histogram median, p99, p99.9, mean, max, overflow | Needs rt-tests with JSON/histogram support. Never requests RT priority or locked memory. Histogram overflow is recorded; an unobservable percentile fails the suite. |
| `sched` fallback | Go timer wakeup lateness on an OS thread locked to a goroutine and pinned to `--cpu` | Clearly labelled `go-timer-approximate`; includes GC, Go scheduling, and timer overhead. Uses relative sleeps, so missed periods are not counted as extra samples. Do not compare it with cyclictest. |
| `messaging` | Fixed process/socket hackbench workload; otherwise `perf bench sched messaging`; tool-reported elapsed seconds | Methods are distinct and cannot be compared to each other. Uses the process's allowed CPU set. Neither tool is installed by the kit. |
| `memory` | `/proc` summed RSS for current UID and POSIX session ID, process counts, MemAvailable, swap totals; zram `mm_stat` byte counters | Shared pages are counted more than once. Idle state is the caller's responsibility. `--memory-scope uid` also includes apps outside the terminal's POSIX session, but includes other logins. The harness itself is excluded. Unreadable/vanished processes are counted. |
| `io` | fio direct 4 KiB random reads, synchronous QD1; total latency mean/p50/p99/p99.9 and IOPS | Only a newly created, fully filled and fsynced temporary file in `--io-dir`. Default 256 MiB, five-second ramp. Bypasses guest page cache, not host/device caches. No raw device operations or cache dropping. |
| `compile` | Build this exact module, including the standard library, with a new empty private GOCACHE each time; wall seconds | Uses `--module-dir` (default `.`), fixed flags, no cgo, no downloads. Records source hash and compiler version. Filesystem cache is not cold. |

`--duration` controls each sched/I/O repetition and accepts whole seconds;
`--interval` controls the timer interval and accepts whole microseconds.
`--cpu` defaults to the first allowed logical CPU and affects only `sched`.
Do not silently change the selected CPU, affinity, or topology between arms.
Warmups use the same workload and are excluded from metric samples; command logs
mark them. Cooldown applies between both warmup and measured invocations.

The system snapshot includes kernel release, command line, observed scheduler
interfaces, allowed CPUs, governor per policy, THP, MGLRU, zswap, zram, swap,
cpuidle/clocksource, pressure counters, block schedulers, and all keys currently
shipped in `system/etc/sysctl.d/70-gilgamesh.conf`. Unreadable or absent interfaces
are explicitly marked. The CPU scheduler is reported as unknown when available
interfaces cannot identify it; a kernel name is not proof of an active scheduler.
Capture host/guest placement, software versions, firmware and workload versions
separately when relevant. A guest cannot establish the host's effective state.

For an I/O test, choose a scratch directory on the filesystem under investigation:

```sh
./gilgamesh-bench run --label io-baseline --suites io \
  --io-dir /path/to/scratch --io-size-mib 1024 \
  --duration 120s --io-ramp 15s --warmups 2 --repeats 5
```

This QD1 test covers unloaded read latency. It does not establish filesystem
allocation performance, behavior under competing writes, game loading, audio
roundtrip, input latency, or frame pacing. Use application workloads and physical
measurements for those claims. Summed session RSS alone does not prove an absence
of leaks; sample a controlled session over time as a separate experiment.

## Fair A/B procedure

1. Pick one tuning and one primary endpoint. Write down a meaningful improvement
   threshold and regression guardrails before looking at results. Keep a known
   baseline and a way to restore it. Distinguish a statistically detectable change
   from an improvement large enough to matter.
2. Keep the same benchmark executable, tools, workload, boot procedure, session
   contents, CPU placement, power/thermal settings, and storage state. Stop unrelated
   downloads, builds, indexing and scheduled maintenance through your usual manual
   workflow. Keep the desktop running in both desktop trials; run quiet trials
   separately. Check pressure/swap on both host and guest when virtualized.
3. Use a small pilot to estimate noise and choose duration/repeat counts. Fix the
   confirmation sample count in advance. Collect new confirmation data over several
   sessions. Do not stop when a favorable result first appears, and do not discard
   a slow run simply because it is slow. Retain failures and document exclusions.
4. Randomize A/B order within matched blocks. For a reboot-dependent tuning, give
   both conditions a fresh boot on every visit, the same number of boots, the same
   login steps, and the same idle settling time. Do not warm up only one arm. A boot
   suite queries the current boot; it never reboots the machine.
5. Use several repeated workloads per visit, with equal warmups and cooldowns.
   Their median is one visit's measurement. Timer events and I/O requests are not
   independent experimental trials. Multiple visits in a single boot are also not
   independent boots. Keep boot measurements in their own boot experiment.
6. For confirmation, collect at least a dozen new paired blocks across several
   sessions (more if the pilot is noisy), then compare whole blocks. Check the
   effective tuning state in the saved metadata, not just the intended config.
   Confirm promising microbenchmark changes in the affected application, check
   guardrails, then compare the accepted bundle against the original baseline.

An example condition visit, with a fresh boot performed manually beforehand:

```sh
./gilgamesh-bench run --label A --block 01 --suites sched,messaging,memory \
  --settle 60s --warmups 2 --repeats 5 --duration 60s --cooldown 10s
# On the matching treatment visit, use --label B --block 01 with identical flags.
# Repeat for blocks 02, 03, ... in the randomized order chosen beforehand.
mkdir -p results/A results/B
cp results/A-*.json results/A/
cp results/B-*.json results/B/
./gilgamesh-bench compare --paired results/A results/B
```

Keep each directory restricted to one condition and experiment. Directory inputs
collapse repeated invocations within the same boot to the median of invocation
medians. Each independent boot therefore has equal weight. Directory A/B arms
must not share a boot ID. `--paired` also requires matching nonempty block IDs and
one boot per condition per block; missing or duplicate pairs are rejected. This
conservative mode requires fresh boots even for runtime toggles.

## Reading the comparison

`compare A.json B.json` reports per-metric median, sample standard deviation,
sample count, absolute delta and percentage change. Positive means B is larger;
whether that is better depends on the metric (latency versus IOPS, for example).
A zero baseline produces `n/a` percent, never division by zero. Different methods,
units, source/compiler versions for compile, or encoded workload settings are
reported as not comparable. The kit does not decide whether two different system
snapshots differ in only the intended tuning; check the metadata yourself.

Single-file intervals resample repeated workload endpoints within one invocation.
They are **exploratory repeat noise**, not independent evidence that a system
tuning works. Boot has only one sample and gets no interval. Repeating the query
of one boot does not produce more observations.

Directory intervals resample independent boot medians; with `--paired`, they
resample whole matched pairs and report the median paired difference. Paired
percent change is the median of per-block percentages, so it need not equal the
ratio of the two displayed medians. All intervals use a deterministic 20,000-draw
percentile bootstrap and 95% coverage; fewer than three units in either arm is
reported as insufficient data. Three is a computation floor, not a recommended
confirmation sample size. Standard deviation uses the sample denominator `n-1`.

“Beyond noise: yes” means the interval excludes zero. It does not account for
systematic drift, a bad experimental design, or selecting a winner among many
metrics. Choose the primary endpoint in advance or apply a multiple-comparison
correction externally. Keep only when the interval clears the predeclared
practical threshold and guardrails pass; an interval spanning gain and harm is
inconclusive. A constant or rounded measurement can yield a zero-width interval;
this does not establish zero real-world uncertainty.

## Toggling the shipped system settings

The kit does not execute the following examples. Privileged writes are for an
**already authorized administrative shell** prepared manually; no privilege
helper is part of this workflow. Read and save the current value, change one
setting, run the same user benchmark in both states, and restore the saved value.
Do not assume a distribution default is the baseline. Boot parameters or other
config files can override these settings.

Every sysctl in the shipped file can be written at runtime if the kernel exposes
it. For example, save `saved=$(sysctl -n vm.swappiness)`, apply exactly one selected
line below, and later restore it with `sysctl -w "vm.swappiness=$saved"`. Use the
corresponding key in both save and restore commands for each experiment.

```sh
sysctl -w vm.swappiness=180
sysctl -w vm.page-cluster=0
sysctl -w vm.watermark_boost_factor=0
sysctl -w vm.watermark_scale_factor=125
sysctl -w vm.vfs_cache_pressure=50
sysctl -w vm.dirty_bytes=268435456
sysctl -w vm.dirty_background_bytes=67108864
sysctl -w vm.dirty_writeback_centisecs=1500
sysctl -w kernel.nmi_watchdog=0
sysctl -w 'kernel.printk=3 3 3 3'
```

The dirty byte limits and corresponding ratio knobs are coupled. Save
`vm.dirty_ratio` and `vm.dirty_background_ratio` as well; restore whichever byte
or ratio mode was active. `nowatchdog` on the boot command line can prevent a
runtime watchdog comparison; change that through a separate controlled boot.

Additional settings with runtime interfaces:

```sh
# MGLRU working-set protection (system/etc/tmpfiles.d/gilgamesh-mglru.conf).
saved_ttl=$(cat /sys/kernel/mm/lru_gen/min_ttl_ms)
printf '%s\n' 1000 > /sys/kernel/mm/lru_gen/min_ttl_ms
# Measure, then restore:
printf '%s\n' "$saved_ttl" > /sys/kernel/mm/lru_gen/min_ttl_ms

# Virtual block device scheduler: replace DEVICE with the actual scratch disk.
cat /sys/block/DEVICE/queue/scheduler
# Save the bracketed active scheduler; only select an advertised alternative.
printf '%s\n' none > /sys/block/DEVICE/queue/scheduler
# Restore by writing the previously bracketed name to the same file.

# HDA runtime power saving (the module must expose a writable parameter).
saved_audio=$(cat /sys/module/snd_hda_intel/parameters/power_save)
printf '%s\n' 0 > /sys/module/snd_hda_intel/parameters/power_save
# Measure sound starts/roundtrip separately, then restore:
printf '%s\n' "$saved_audio" > /sys/module/snd_hda_intel/parameters/power_save

# Related kernel policy, when available: select one token, not the whole line.
cat /sys/kernel/mm/transparent_hugepage/enabled
printf '%s\n' madvise > /sys/kernel/mm/transparent_hugepage/enabled
# Restore the previously bracketed token; existing pages need not change at once.
```

The remaining `system/` settings need configuration or lifecycle changes; the
table explains the A/B operation without restarting system services from the kit.
Keep backups outside the repo and restore exactly the original files afterwards.

| Shipped setting | A/B operation and endpoint |
| --- | --- |
| zram size, zstd, swap priority (`systemd/zram-generator.conf`) | Prepare two configs and reboot for each visit. Reinitializing active swap is not an idle-session toggle. Measure controlled memory pressure/application response as well as `mm_stat`; idle compressed-byte counts alone prove little. |
| `cpuidle-haltpoll` autoload | Prepare boots with/without the module entry; verify `cpuidle/current_driver`. Compare sched wakeup under identical quiet and loaded scenarios plus application tails and externally measured power. No automatic module unload. |
| `ntsync` autoload | Prepare boots with/without the module entry and use the same supported application/backend. The CPU microbenchmarks do not exercise this interface. |
| Watchdog module blacklists | Change one blacklist in the disposable boot configuration and reboot; verify actual module and watchdog state. Boot command-line watchdog policy is a separate factor. |
| HDA `enable_msi=1` | Reboot with the alternate module option; verify interrupts. Do not unload an audio driver with a live session. Physical audio/xrun testing is required. |
| PipeWire VM minimum quantum and Pulse minimum quantum | In a disposable session, disable only the relevant installed `10-gilgamesh-vm.conf` override (rename to a suffix other than `.conf`), then restart the user audio services or log out/in. The two files are separate factors. Verify negotiated quantum; measure physical roundtrip and xruns. |
| WirePlumber HDMI headroom and suspend timeout | Change one property in the installed `90-gilgamesh-alsa.conf`, restart the user audio session, verify the effective node property. Test sound starts and physical roundtrip. |
| ly `Type=simple` | Disable only the installed ly drop-in for the baseline, reboot, compare boot timings and external login-screen readiness. Reloading config after startup cannot remeasure startup. |
| Manager start/stop timeout limits | Change the relevant drop-in and use equivalent fresh boots/shutdowns. A timeout ceiling is not ordinary boot speed; test controlled timeout cases separately. |
| journald `SystemMaxUse` | Alternate the installed drop-in across boots with comparable journal occupancy. Measure storage use/behavior; this cap is not a latency measurement. |
| systemd initramfs hooks and lz4 compression | Prepare matched boot artifacts with the supported local build workflow, reboot, and compare boot phases plus external readiness. Runtime changes cannot alter an already completed boot. |
| NetworkManager resolved DNS mode | Alternate the installed DNS drop-in across boots and verify effective resolution. This offline kit does not measure DNS latency or use network probes. |
| Hyprland realtime capability hook | Inspect with `getcap /usr/bin/Hyprland`; in the test installation, use `setcap -r /usr/bin/Hyprland` for the arm without file capabilities or `setcap cap_sys_nice=ep /usr/bin/Hyprland` for the shipped arm, then start a fresh compositor. Save/restore any original capabilities, and avoid package upgrades between visits. Verify actual scheduling policy; measure application frame pacing under load separately. |

For the audio config experiments, an ordinary user can restart their own audio
services with `systemctl --user restart pipewire.service pipewire-pulse.service
wireplumber.service` after the prepared file change. This interrupts that user's
audio and is a manual experiment step, not a harness action. A user-only runtime
quantum probe such as `pw-metadata -n settings 0 clock.force-quantum 128` can help
diagnosis; restore automatic negotiation with value `0`. Forced quantum changes
a different variable from the shipped minimum/headroom settings.

Kernel scheduler, preemption and boot-parameter experiments require matched boot
artifacts or an explicitly supported kernel runtime interface. Keep the base
kernel version constant when testing schedulers; compare kernel versions as a
separate factor. Filesystem creation flags require disposable scratch filesystems
and an external workload; this kit never formats a device.

## Local verification

```sh
GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOWORK=off GOTELEMETRY=off go vet ./...
GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOWORK=off GOTELEMETRY=off go test ./...
```

Tests use synthetic fixtures for systemd output, procfs, zram, cyclictest and fio,
plus known statistical results and experimental-unit/pairing validation. Real
tool options and kernel permissions still need a run on the target installation.
