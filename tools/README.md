# Go tools

These are the Go ports of `scripts/gilgamesh-dns` and `installer/install.sh`.
The Bash tools remain untouched. Module: `github.com/haider-IQZ/gilgamesh/tools`;
Linux, Go 1.26, no cgo. The installer contains the real install flow; tests inject
command execution and a filesystem root, rather than extracting or copying its
implementation. No test invokes real partitioning, mounting, package installation,
network access, sudo, chroot, or reboot commands.

## Build and verify offline

From `tools/`:

```sh
make check
```

The Makefile disables module downloads and uses Go's default module cache.
The pinned dependencies must already be cached for offline builds and checks.
Both builds use `-trimpath -ldflags '-s -w'`. Outputs are
`bin/gilgamesh-dns` and `bin/gilgamesh-install`. Build both together and keep them
together for the plain-checkout fallback. That path copies the Go DNS binary into
`/usr/bin/gilgamesh-dns`. On a Gilgamesh ISO, `gilgamesh-settings` supplies that
path and the installer preserves the package's DNS helper instead.

From the checkout root, on the installation medium:

```sh
tools/bin/gilgamesh-install --source "$PWD"
# A preview changes no files, logs, keymaps, packages, mounts, or devices:
tools/bin/gilgamesh-install --source "$PWD" --dry-run
```

Real installation requires root and UEFI, as before. `--source` defaults to a
checkout beside the resolved executable or in its two parents, then falls back to
the current directory or its two parents. With no local checkout,
a real installation downloads the same GitHub main tarball as Bash into a temporary
directory; a dry run refuses to download. `--dns-binary` overrides the sibling Go
DNS binary for the fallback. `KERNEL` retains its Bash meaning (default `linux`,
plus headers) only without the ISO bootstrap repository; with it, the installer
always selects `linux-tkg` and `linux-tkg-headers`.
No unattended/force/disk-selection or fake-runner CLI escape hatch is provided.

DNS keeps the same five case-sensitive providers and no-argument status query.
On NixOS it modifies NetworkManager profiles only. On Arch/Gilgamesh it also
writes the global NetworkManager and resolved configuration; the binary implements
the existing sudo/pkexec escalation policy. Tests intercept all such calls.

## Gilgamesh packages and repository policy

Preflight checks for `/opt/gilgamesh/repo/gilgamesh.db` in the live system. When
present, pacstrap receives `-C` pointing to a private temporary copy of the live
pacman configuration, with multilib enabled and exactly one `[gilgamesh]` section
before official repositories:

```ini
[gilgamesh]
SigLevel = Never
Server = file:///opt/gilgamesh/repo
```

The unsigned policy is confined to that repository. Official signature settings
are preserved. The installer selects `linux-tkg`, `linux-tkg-headers`,
`gilgamesh-settings` and `gilgamesh-shell`; the existing NVIDIA heuristic substitutes
`nvidia-open-tkg` for `nvidia-open-dkms` while keeping the remaining NVIDIA userspace
packages. Older/mixed NVIDIA systems keep the nouveau path. The temporary config
is removed on success, failure or cancellation. Without the database, installation
keeps the existing stock-linux/custom-`KERNEL`, DKMS and raw-checkout setup. Both
paths are identified in the install log and dry-run output. The local repository
only supplies the bootstrap packages; this does not make the full installation
offline (official packages and the existing connectivity/keyring preparation are
still needed).

Initramfs generation uses `mkinitcpio -p <selected-kernel>`. Before installing GRUB,
the installer requires `/boot/vmlinuz-<selected-kernel>` and
`/boot/initramfs-<selected-kernel>.img` in the target. `grub-mkconfig` discovers these
images, including `vmlinuz-linux-tkg` and `initramfs-linux-tkg.img`; no stock-linux
boot entry is hard-coded.

The target pacman config always loses the bootstrap `[gilgamesh]` section and any
active `SigLevel` directive disabling verification. Only when the source checkout
contains `keys/gilgamesh.asc` does the installer stage that public certificate in
the target, inspect its primary fingerprints using GPG, then run target
`pacman-key --add` and `pacman-key --lsign-key`. After successful trust setup it
inserts this section before official repositories:

```ini
[gilgamesh]
SigLevel = Required DatabaseRequired
Server = https://github.com/haider-IQZ/gilgamesh/releases/download/repo
```

No key means no target `[gilgamesh]` section, with a clear log note that Gilgamesh
package updates need the public key and signed repository. Invalid certificates
or failed imports/signatures stop installation with the section still disabled.
The staged key is removed even on failure. The live repository is never copied
into the target or used as a persistent update source.

### Package ownership and user configuration

These mappings come from the install logic in
[`gilgamesh-settings/PKGBUILD`](../packages/gilgamesh-settings/PKGBUILD), its
[install scriptlet](../packages/gilgamesh-settings/gilgamesh-settings.install), and
[`gilgamesh-shell/PKGBUILD`](../packages/gilgamesh-shell/PKGBUILD). They apply when
the bootstrap package path is selected. `plan.SettingsOwns` filters overlay source
paths; it excludes relocated defaults too, since raw `/etc` copies would shadow
package updates. Paths below are relative to the checkout unless absolute.

| Source / generation | Package destination and installer behavior |
| --- | --- |
| `system/etc/mkinitcpio.conf.d/*.conf` | Settings owns `/etc/mkinitcpio.conf.d/*.conf` (the current `gilgamesh.conf` is a pacman backup file); do not overwrite. |
| `system/etc/{pipewire/pipewire.conf.d,pipewire/pipewire-pulse.conf.d,wireplumber/wireplumber.conf.d}/*.conf` | Settings relocates into `/usr/share/` with the same path after `etc/`; omit the old `/etc` overrides. |
| `system/etc/{sysctl.d,modprobe.d,modules-load.d,tmpfiles.d,NetworkManager/conf.d,systemd/journald.conf.d,systemd/system.conf.d,systemd/system/ly@.service.d}/*.conf` | Settings relocates into `/usr/lib/` with the same path after `etc/`; omit the old `/etc` overrides. |
| `system/etc/udev/rules.d/*.rules`, `system/etc/systemd/zram-generator.conf` | Settings relocates into `/usr/lib/udev/rules.d/` and `/usr/lib/systemd/zram-generator.conf`; omit the old `/etc` overrides. |
| `system/usr/share/libalpm/hooks/*.hook` | Settings owns the same `/usr/share/libalpm/hooks/` paths; skip raw copies. |
| `system/etc/systemd/user/localsearch-3.service` mask | Settings replaces the `/dev/null` mask with package source `10-gilgamesh.conf` at `/usr/lib/systemd/user/localsearch-3.service.d/10-gilgamesh.conf`; do not recreate the mask. |
| `scripts/gilgamesh-dns`, `etc/sudoers.d/gilgamesh-dns` | Settings owns `/usr/bin/gilgamesh-dns` and `/etc/sudoers.d/gilgamesh-dns` (backup file); skip Go-binary/rule installation, keep rule validation. |
| Settings checksum, license and post-install action | Package generates `/usr/share/gilgamesh/settings/mkinitcpio.sha256`, installs its license under `/usr/share/licenses/gilgamesh-settings/`, and applies Hyprland's capability via scriptlet/hook. Installer does not repeat those actions. |
| `quickshell/**` regular files | Shell owns `/usr/share/gilgamesh/quickshell/**`; do not copy a shadow tree into the user's `.config/quickshell`. |
| `fish/{colors.fish,prompt.fish,starship.toml}`, generated `starship-init.fish` | Shell owns `/usr/share/gilgamesh/fish/`; its packaged `colors.fish` preserves user Starship choices. Do not copy these into the home directory or generate `/etc/fish/conf.d/starship.fish`. |
| Package source `gilgamesh.fish` and license | Shell owns `/usr/share/fish/vendor_conf.d/gilgamesh.fish` and `/usr/share/licenses/gilgamesh-shell/`; vendor startup loads the packaged fish defaults. |
| `hypr/hyprland.lua` | Shell owns `/usr/share/gilgamesh/hypr/hyprland.lua` with `QS_CONFIG_PATH=/usr/share/gilgamesh/quickshell`. The installer writes a small user loader, setting the user Lua search path then loading this file, rather than copying its defaults. |

Unowned overlay entries are still copied. The installer still writes per-user
`hypr/local.lua` (keyboard), `foot/foot.ini` and `mpv/mpv.conf`, the Hyprland loader,
and machine/account configuration such as hostname, locale, fstab, wheel access,
GRUB options, services and NVIDIA environment values. On the fallback path the
packages are not installed, so the original overlay, Go DNS helper and user-default
copies remain necessary and are preserved.

## Architecture and safety

- `internal/disk`: strict lsblk JSON parsing, complete graph, holder/swap reads,
  pure wipe-target selection/refusals, identity capture and comparison. Only
  immediate `TYPE=part` children followed by the selected whole disk are wiped.
- `internal/live`: both archiso mounts, optical media, loop backing files,
  mapped-device ancestors, literal kernel boot parameters and retained protection.
  An unidentified medium prevents real installation (and previews on a real ISO).
- `internal/plan`: pure keyboard, account, hostname, password, package/GPU/CPU,
  partition, mkfs, mount-option, config-editing and fstab decisions.
- `internal/exec`: explicit argv, real/fake runners, a process group for every
  subprocess, signal cancellation, TERM with a ten-second grace then group KILL.
  Secret stdin is never retained by the fake or included in logs. Even unexpected
  chpasswd output is suppressed. No command is interpreted by a shell.
- `internal/install`: preflight/questions and all 14 install steps. Records mount
  intent before mounting, then the mount ID; cleanup verifies source and ID on
  every attempt, retries busy mounts four times, kills target keyring agents before
  root unmount, and never recursively unmounts. Reboot follows successful cleanup.
- `internal/fsys`: filesystem boundary for real paths or private test fixtures;
  dry writes become previews. Overlay copy preserves symlinks, root ownership of
  copied entries, and existing directory metadata.
- `internal/ui`: a port of the Omarchy ISO configurator's look (MIT, credited in
  LICENSE): the embedded logo centred in ANSI green, every question one gum-style
  widget (choose, filter, input, confirm, spin) rebuilt from the same Bubble Tea
  components gum uses, with gum's default styles and Omarchy's `GUM_CONFIRM_*`
  colours (palette indexes, so the console and emulators match). The review is a
  rounded `gum table`; validation notices are a one-second pulse spinner; the
  install view is the dashboard's centred logo, percentage and status line; the
  end is "Installed Gilgamesh in ..." with a Reboot Now button. `TERM=linux`
  explicitly uses ANSI-16 in both the output writer and Bubble Tea, even without
  terminfo. `NO_COLOR` remains an explicit opt-out. Esc in a prompt unwinds to the
  keyboard screen (gum exit 1); Ctrl+C aborts (exit 130). A progress-output
  failure cancels and joins the worker before cleanup. Terminal input is flushed
  before target-username correction and the reboot question.

Keyboard layouts come from the live system's `/usr/share/X11/xkb/rules/base.lst`
(every layout, plus the variants systemd's `kbd-model-map` pairs with a console
keymap), English (US) and (UK) first, then alphabetically; the built-in 16-entry
list is only the fallback without X keyboard rules. Each entry carries the console
keymap `loadkeys`/`vconsole.conf` use and the XKB layout/variant/options written to
Hyprland's `local.lua`; layouts systemd knows no keymap for keep the `us` console map.

After the live internet check, timezone detection tries `https://ipapi.co/timezone`
then `http://ip-api.com/line?fields=timezone`, with a 1.5-second deadline per service.
Only a valid installed TZif file under `/usr/share/zoneinfo` is accepted. The result
preselects the filterable timezone question; edits preserve the user's choice.
Failures silently retain the existing default. Dry runs skip geo-IP requests.
The HTTP client is injectable; tests use synthetic responses without network access.

SIGINT/TERM/HUP/QUIT cancellation is consumed throughout worker shutdown; further signals
are ignored during mount cleanup. Step and main panics become errors so cleanup runs.
Results distinguish untouched/live-prepared/
possibly-partial/installed states. Cancelling the reboot question preserves the
installed state. The log is `/tmp/gilgamesh-install.log`, created only after questions;
command output and each step are logged, with a 25-line tail on failure.

### Disk identity and the conflicting Bash documentation

The executable Bash implementation and its 18-case harness are the parity authority,
not the outdated claim in `installer/README.md` that serial and diskseq are mandatory.
Identity is **major:minor + byte size + diskseq (when available) + optional serial +
optional WWN**. No serial/WWN is required, including on virtio. A missing diskseq
is recorded as `unavailable`, matching the harness's successful `no-diskseq` case;
unreadable or malformed existing diskseq is refused. Appearance, disappearance,
or change of any identity component aborts before wiping. Without diskseq and
serial/WWN, an identical-size replacement reusing major:minor cannot be distinguished;
this is an inherited limitation, not an assertion that those disks have a unique
hardware identity. Identity is checked for confirmation and immediately before the
first wipe. There is still an unavoidable kernel/device race after any userspace
identity check; this port does not claim an atomic device lock.

## Bash-to-Go parity map

Names are relative to `internal/` unless qualified. All 14 numbered installation
steps run through `install.Installer.Run` in the original order.

| Bash function / block | Go implementation |
| --- | --- |
| preflight, source download, CPU/GPU detection | `install.Prepare`, `plan.ReadList`, `plan.Graphics`, `plan.Microcode` |
| `die`, `cancel` | returned errors; `cmd/gilgamesh-install.mainCode` exit reporting |
| `stop_workers` | `exec.Real.Run` process-group termination/reaping |
| `cleanup_mounts` | `install.Cleanup` |
| `on_exit`, `on_signal` | `exec.WatchSignals`, `Signals.Ignore`, `install.Message`, `mainCode` |
| `read_list` | `plan.ReadList` |
| `measure`, `say`, `screen` | `ui.size`, `Message`, `screen` |
| `drain_input`, `confirm` | `ui.Drain`, `Confirm` |
| `ask_keyboard` | `install.Questions` keyboard loop, `plan.Keyboards` |
| `name_in_use`, `ask_username` | `install.LiveNameInUse`, `AskUsername`, `plan.Username` |
| `ask_password`, `ask_hostname` | `install.Questions`, `plan.Password`, `plan.Hostname` |
| `timezones`, `ask_timezone` | `install.Timezones`, `Questions`, `ui.Choose` |
| `read_inventory` | `disk.Read`, `disk.Parse` |
| `live_ancestors`, `protect_live_disks` | `live.Detector.Detect` recursive ancestry and retained set |
| `check_target_mounts` | `install.targetClear`, `disk.TargetClear` |
| `validate_disk`, `disk_identity` | `install.Validate`, `disk.Inspect`, `Select`, `ReadIdentity`, `Verify` |
| `ask_disk`, `summary`, `questions` | `install.AskDisk`, `Questions` |
| `show`, `x`, `in_target` | `exec.Show`, `install.x`, `chroot` |
| `write_file`, `append`, `set_conf` | `install.write`, `CopyOverlay`, `set`, `plan.SetConf`, `fsys.Write` |
| `enable_multilib`, `part` | `plan.Multilib`, `disk.Part` |
| `step` | `install.Run`, `ui.Step` |
| 1. `partition_disk` | `install.PartitionDisk`, `plan.Plan.PartitionArgs` |
| 2. `make_filesystems` | `install.MakeFilesystems`, `plan.Plan.Formats` |
| 3. `mount_target`, `mount_owned` | `install.MountTarget`, `MountOwned` |
| 4. `install_packages` | `install.InstallPackages`, `plan.Build` |
| 5. `base_config` | `install.BaseConfig`, `plan.FilterFstab` |
| 6. `copy_overlay` | `install.CopyOverlay`, `CopyTree` |
| 7. `system_config` | `install.SystemConfig` |
| `target_name_in_use`, `check_target_username` | `install.targetNames`, `CheckTargetUsername`, `plan.NameInUse` |
| 8. `create_user`, `set_password` | `install.CreateUser` (secret stdin to chpasswd) |
| 9. `tune_system` | `install.TuneSystem` |
| 10. `build_initramfs` | `install.BuildInitramfs` |
| 11. `install_bootloader` | `install.InstallBootloader` |
| 12. `enable_services` | `install.EnableServices` |
| 13. `hypr_local`, `user_config` | `plan.HyprLocal`, `install.UserConfig` |
| 14. `link_resolv_conf` | `install.LinkResolvConf` after the last chroot |
| `run_install`, `done_screen` | `install.Run`, `Full`, `Message` |
| DNS: `is_nixos`, `usage`, `require_root` | `dns.App.apply`, `App.Run`, `cmd/gilgamesh-dns.main` |
| DNS: `profiles`, `current`, `with_sni` | `dns.App.apply`, `Current`, `WithSNI` |
| DNS: `apply_connections`, `apply_etc` | `dns.App.apply` (same order and reload fallbacks) |

## Tests and interpretation

`go test ./...` runs table-driven disk/refusal/identity, live-ancestry, package,
fstab, account, hostname, password and DNS tests. Filesystem fixtures live under
`tools/.test-work` and are deleted after each test. The Go tests do not run the
old harness, which creates files under `installer/` and expects gum/Bash interfaces.

`install.TestVirtioFlowExactCommands` executes `Installer.Full` against fake commands
and fake sysfs/proc, on `/dev/vda` with no serial or WWN. Its independently specified
ordered argv contracts are `internal/install/testdata/virtio-commands.json` for the
fallback and `virtio-bootstrap-commands.json` for the ISO repository path (only the
random temporary-config filename is normalized). It also checks written files,
the fallback overlay symlink, stub resolver link, 14 log steps,
password secrecy, default-No erase prompt, and that device-writing commands only
address `/dev/vda` and its partitions. Every unexpected fake command fails.

The old 18 cases map as follows:

| Original case(s) | Go coverage |
| --- | --- |
| `virtio` | exact-command full-flow test |
| `no-diskseq` | `TestHarnessScenarios/no-diskseq`, identity unit tests |
| `double-signal` | real signals to a test installer subprocess during a real helper process tree |
| `spinner-failure` | flow exit handling and `ui.TestDisplayFailureWaitsForWorker` |
| `dry-run` | complete filesystem snapshot comparison and read-command allowlist |
| `size-swap`, `serial-swap`, `wwn-swap`, `sequence-swap` | changed identity during full flow; zero wipes permitted |
| `question-signal` | cancellation before log creation |
| `keys`, `username-keys` | real private-PTY input-flush test plus full-flow drain/correction checks |
| `retry-validation`, `retry-identity` | full-flow failed disk selection followed by successful selection |
| `glob` | exact literal `findfs LABEL=LIVE*` argv |
| `busy-retry`, `busy` | third-attempt success / four-attempt failure and recovery instruction |
| `reboot` | fake reboot refuses unless all mounts have been removed |

Additional tests cover pending-mount cancellation, replaced mount refusal, final
prompt cancellation, username race, loadkeys retry, timezone fallback, preflight
failures, downloaded-source control flow, overlay metadata, NVIDIA environment,
secret-output suppression, group creation, and TERM-to-KILL escalation. Private
PTYs test terminal flushing and ANSI-16 form rendering with the destructive default
still No. UI tests check the 80×24 summary and exact truecolor accent. Geo-IP tests
cover success, malformed/oversized responses, invalid zones, timeout, fallback,
cancellation, body cleanup and user overrides. Test helper subprocesses test process management.
These are simulated integration tests, not evidence of an actual bootable VM
installation, package availability, or correct firmware/GRUB behavior on hardware.

Repository tests cover database presence/absence crossed with no NVIDIA, supported
NVIDIA, old NVIDIA and mixed GPUs; bootstrap precedence and official signature
preservation; target unsigned-policy removal; public-key import/signing and failure
handling; temp-file cleanup; selected-kernel image checks; and bootstrap dry-run
immutability. Package ownership tests check every current `system/` entry against
the mapping, preserve package payloads, reject shadow copies and retain unowned
overlay/user configuration.

## Intentional differences and limits

- The UI reproduces gum's widgets in-process rather than spawning gum, so there is
  no external spinner subprocess or gum-specific exit 42; internal display errors
  fail after cancelling/joining the worker. The live preparation installs
  `archlinux-keyring` only, because gum is unnecessary. The questions follow
  Omarchy's order (keyboard, account, review, disk, erase confirmation) and the
  detected timezone is listed first.
- The fallback target receives the compiled Go DNS tool. Its sibling binary must
  be supplied with the installer on that path, even when the source checkout is downloaded. A shell script
  cannot carry a companion static binary via Bash's process-substitution invocation.
- The download is an explicit curl-to-archive then tar invocation instead of a shell
  pipeline. Configuration transformations and overlay copying use Go, preserving
  outcomes without spawning sed/awk/tar pipelines. On the fallback path config
  assets come from the checkout, including the Quickshell tree and wallpapers.
  The ISO bootstrap path installs package-owned defaults instead, as mapped above.
- Mount journal, UUIDs and write-phase marker are held in the Go parent, rather than
  temp files shared by Bash workers. Phase/ownership semantics survive all handled
  signals; neither implementation can clean up after SIGKILL or power loss.
- Device appearance is checked through fresh lsblk JSON parent/type records, not
  stat on two device nodes. Invalid/missing JSON safety fields, inconsistent duplicate
  nodes, dangling parents, read-only partitions, and too-small disks at revalidation
  fail closed. Live-medium identification is also required for a dry run on an ISO.
- Passwords containing line breaks/NUL are rejected to prevent additional chpasswd
  records. The install log is mode 0600. DNS Custom intentionally retains Bash's
  permissive syntactic IP checks; NetworkManager validates actual addresses.
- Serial-less and missing-diskseq behavior matches the *executable* Bash harness,
  as explained above. CPU vendor detection and the NVIDIA ID >= `0x1e00` heuristic
  are unchanged, including the mixed-old/new fallback to nouveau.

All install steps have counterparts. UI/progress implementation, companion-binary
distribution and the explicit safety refinements above are not byte-for-byte Bash
behavior. Real disk installation and bootability still need disposable-VM validation.

## Dependencies

The installer core, DNS logic, command runner, filesystem copy and tests otherwise
use the standard library. No disk library, CLI framework, YAML parser, shell library,
or Go network client dependency was added.

| Direct module | Why it is present |
| --- | --- |
| `charm.land/bubbletea/v2` v2.0.10 | Runs the gum-style widgets; pins the Linux console colour profile. |
| `charm.land/bubbles/v2` v2.2.1 | gum's building blocks: text input, paginator, viewport, spinner, help. |
| `charm.land/lipgloss/v2` v2.0.6 | Styling, padding/centring and the review table. |
| `charm.land/huh/v2` v2.0.3 | No longer imported; still pinned in go.mod (removing it only prunes go.sum). |
| `github.com/charmbracelet/colorprofile` v0.4.3 | Existing UI dependency, now directly used for palette selection and output conversion. |
| `golang.org/x/sys` v0.48.0 | Maintained Linux terminal ioctl constants/wrappers for safe input flushing and terminal-size/detection; avoids architecture-specific handwritten ioctl code. |

The required UI libraries bring the following transitive modules; none are
independent application dependency choices. Versions are pinned in `go.mod`/`go.sum`
and must be available in the local module cache for offline builds.

| Transitive module(s) | UI dependency role |
| --- | --- |
| `github.com/charmbracelet/ultraviolet` | Terminal rendering and input decoding used by the UI stack. |
| `github.com/charmbracelet/x/ansi` | ANSI-aware rendering, wrapping and string widths. |
| `github.com/charmbracelet/x/term`, `x/termios`, `x/windows` | Terminal platform support pulled by the UI stack. |
| `github.com/charmbracelet/x/exp/ordered`, `x/exp/strings` | Collection/string helpers used by forms/components. |
| `github.com/clipperhouse/displaywidth`, `github.com/clipperhouse/uax29/v2` | Unicode display width and segmentation. |
| `github.com/mattn/go-runewidth`, `github.com/rivo/uniseg` | Unicode width/grapheme support in UI dependencies. |
| `github.com/lucasb-eyer/go-colorful` | Color conversion used by styling. |
| `github.com/catppuccin/go` | huh's bundled theme definitions (huh is pinned but unused). |
| `github.com/atotto/clipboard` | Clipboard support inherited through text-input components. |
| `github.com/dustin/go-humanize` | Formatting helpers in UI components. |
| `github.com/mitchellh/hashstructure/v2` | Dynamic form binding change detection. |
| `github.com/muesli/cancelreader` | Cancellable terminal input. |
| `github.com/xo/terminfo` | Terminal capability information. |
| `golang.org/x/sync` | Concurrency helpers used by dependencies. |

## Verification in this workspace

`CGO_ENABLED=0 go vet ./...` and `CGO_ENABLED=0 go test ./...` passed offline with
`GOPROXY=off`, `GOSUMDB=off` and `GOTOOLCHAIN=local`, using the existing module cache
and `/tmp/gilgamesh-gocache`: zero failures. Earlier build verification recorded both
binaries as ELF files without `PT_INTERP` or `PT_DYNAMIC`; no shared runtime is
required. The sizes below are from that build.

| Binary | Stripped static size |
| --- | --- |
| `bin/gilgamesh-dns` | 2,293,922 bytes (2.19 MiB) |
| `bin/gilgamesh-install` | 5,386,402 bytes (5.14 MiB) |

The original Bash harness was read but not executed, since it creates files under `installer/`. All new source, documentation, binaries and test fixtures are under `tools/` (apart from the explicitly configured Go build cache). No real installer/DNS commands, sudo or commits were executed.
