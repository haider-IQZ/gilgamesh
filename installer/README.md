# Gilgamesh installer

Installs Gilgamesh from the official Arch Linux ISO.

> **It erases the whole disk you pick.** There is no dual-boot or "install alongside" mode.

## Start it

1. Boot the [Arch Linux ISO](https://archlinux.org/download/) in **UEFI** mode (for a VM: OVMF firmware).
2. Get online. Wired connects by itself. For Wi-Fi: `iwctl`, then `station wlan0 connect "Network name"`.
3. Run:

   ```sh
   bash <(curl -fsSL https://raw.githubusercontent.com/haider-IQZ/gilgamesh/main/installer/install.sh)
   ```

   (Use `bash <(...)`, not `curl ... | bash`: the questions need the keyboard on stdin.)

For a no-write preview, run `installer/install.sh --dry-run` from an existing local checkout
with `gum` and `lspci` installed. It asks the questions and prints the planned commands without
preparing the live environment, applying a keymap, creating logs, downloading, or writing to
disks. The download/process-substitution invocation refuses `--dry-run`: downloading a checkout
would itself write temporary files. Disk safety checks still apply; outside the ISO, a dry run
may proceed without an identified live medium.

## What it asks

One question per screen:

- keyboard layout (console and Hyprland; a failed `loadkeys` on a real console asks again before password entry)
- username and password (the password is also used for sudo; root stays locked). Existing
  live accounts/groups and reserved package-created names are rejected. Target accounts/groups
  are checked again after packages are installed; a collision asks for another name before user creation.
- hostname (default `gilgamesh`)
- timezone (picked from a list, no location lookup)
- disk (at least 40 GB; the ISO's own USB stick isn't offered)

Then it shows a summary, and asks one last time before erasing the disk (that prompt defaults to No).

## What it does

- Partitions the disk: 1 GiB EFI partition + the rest as XFS root (mounted `noatime`).
- Installs the kernel and the packages in [`packages`](packages) with `pacstrap`, plus
  [`packages-nvidia`](packages-nvidia) for supported NVIDIA GPUs. `[multilib]` is turned on.
  CPU `vendor_id` selects `amd-ucode` for AMD or `intel-ucode` for Intel, including in VMs.
  `dosfstools` supplies the target ESP checker and repair tools. Empty or unreadable package lists abort.
- Detects NVIDIA VGA/3D devices using numeric PCI vendor/device IDs (`lspci -nn`, vendor `10de`).
  `nvidia-open` needs Turing or newer. The installer uses device ID **>= `0x1e00`** as a Turing+
  heuristic; this can be wrong for odd SKUs. If any older NVIDIA GPU is present, it shows a
  notice before disk confirmation and omits all NVIDIA packages, using the kernel's nouveau
  driver for the desktop instead. This also applies to mixed old/new NVIDIA systems.
- Records the newly created root and ESP UUIDs, drops all swap entries from `genfstab`, and
  writes fstab only if its filesystem entries are exactly those two UUIDs at `/` and `/boot/efi`.
  Unrelated live swap stays active but is never copied into the target; target swap uses zram.
- Copies [`system/`](../system) onto the new root (sysctl, zram, initramfs, audio, DNS, ...),
  plus `gilgamesh-dns` and its sudoers rule.
- Sets the timezone, locale (`en_US.UTF-8`), keyboard and hostname, creates your user (fish
  shell, in `wheel`), installs GRUB (no menu shown), and turns on NetworkManager,
  systemd-resolved, timesyncd, the firewall (ufw), weekly TRIM, rtkit and the ly login screen.
- Puts your desktop config in your home: Hyprland (your keyboard layout goes in
  `~/.config/hypr/local.lua`), the Quickshell bar, fish + starship, foot and mpv.

## Disk checks and cancellation

Before the erase confirmation and again immediately before wiping, the installer captures a
complete `lsblk` inventory (`NAME,TYPE,PKNAME,MOUNTPOINTS`) and checks sysfs holders. It refuses
mounted disks/partitions, active swap on the selected disk, and active md, dm/LVM or crypt
holders. Only `TYPE=part` entries whose immediate `PKNAME` is the selected disk are wiped,
followed by that disk itself. Empty, failed or malformed inventories abort before writing.

The physical ancestors of both `/run/archiso/bootmnt` and `/run/archiso/img_dev` are protected,
including loop backing files resolved through `losetup` or sysfs and mapped-device ancestors.
Optical ISO media are recognized too. Boot-device parameters from `/proc/cmdline` and identities
already discovered during this run retain protection for copy-to-RAM boots. A real installation
stops if the live medium cannot be identified; it never assumes there is no protected disk.

The disk's major:minor, kernel `diskseq`, and serial/WWN are recorded for confirmation and
checked again immediately before the first wipe. Any change aborts. A missing disk sequence or
both missing serial and WWN also aborts; configure a disk serial for a VM if necessary.
Anything already mounted at or beneath `/mnt` must be unmounted by you first. The installer
records its own mount sources and IDs, then unmounts only those mounts, in reverse order, on
exit. It never recursively unmounts `/mnt`, and reports unmount failures instead of ignoring them.

Every installation step is logged to `/tmp/gilgamesh-install.log` on the live system. Workers
run in separate process groups. Ctrl+C, TERM and HUP terminate and reap the active worker group,
then clean up owned mounts. A plain-text report names the interrupted step and log, and warns
when the disk may be partially installed. Step failures also show the end of the log. Fix the
cause and run it again; installation starts over and erases the selected disk again.

Cancellation reports the phase: nothing changed, live environment prepared, installation
interrupted, or installed successfully and ready to reboot. Cancelling the final reboot prompt
keeps the success message. A normal run prepares the live package manager before the questions,
so cancelling there does not undo live-environment changes.
