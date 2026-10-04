# Gilgamesh Linux: plan

An Arch-based distro for a virtualized desktop, with NVIDIA graphics and a Zen 3 CPU target.
Named after the king of Uruk from the Epic of Gilgamesh.

Status: **phase 1, nearly done**. Fish prompt done; Quickshell bar done, in `quickshell/`:
workspaces, clock/calendar, media + local music, tray, notifications, network/DNS, RAM, audio, launcher,
themes, wallpapers, Gilgamesh Settings.

## Decisions

### Base
- Stock Arch Linux, official repos + `multilib` (32-bit).
- Own pacman repo `[gilgamesh]` hosted on GitHub, listed **above** `core`/`extra`
  (same idea as CachyOS: a package in our repo wins, everything else falls back to Arch).
- AUR stuff I want is built once and shipped prebuilt in `[gilgamesh]`. **No AUR helper.**
- Packages keep normal names (`linux-tkg`, `hyprland-config`, ...). Only reuse an official
  package name when we *mean* to override it.

### Kernel
- **linux-tkg** (Frogging-Family), compiled in the build container, shipped as a package.
- CPU scheduler: **BORE**.
- Also build **linux-tkg-headers**. Settings in `kernel/` (customization.cfg + gilgamesh.myfrag, see kernel/README.md):
  BORE, GCC -O2, no LTO, znver3, 1000 Hz, full preemption, tickless idle.
- **No fallback kernel.** The live ISO uses the same tkg kernel.
- virtio drivers must stay enabled (don't let tkg's "strip unused modules" drop them,
  or the VM won't find its disk).

### Disk and boot
- Filesystem: **XFS** (fastest in recent Phoronix benchmarks: Linux 6.15 and 7.0;
  ext4 narrowly won 6.17). Confirm with an `fio` benchmark in the test VM.
- Bootloader: **GRUB**.
- Swap: **zram**.
- Rollback / rescue: a host-side disk snapshot or boot the Gilgamesh ISO.

### Desktop
- Login: **ly** (pick the session each login, so other WMs/DEs are possible later).
- **Hyprland**, with fresh custom configs written in this project, then packaged.
- Terminal: **foot**
- Launcher: our own in the bar (Super+D), see App launcher below
- File manager: **Nautilus**
- Bar: **Quickshell**, in `quickshell/` (themes and their wallpapers in `quickshell/themes/`)
- Wallpaper: drawn by the bar itself (no awww), picker in Gilgamesh Settings
- Notifications: the bar itself (no mako): popups, notification center, Do Not Disturb
- Themes: the bar switches the whole desktop between themes (jellybeans default, gruvbox, nord,
  catppuccin, tokyo-night, rose-pine, everforest, kanagawa; Omarchy's colors.toml format):
  bar, foot/alacritty, fish, starship, fzf, wallpaper. Each theme can ship `backgrounds/`;
  wallpapers must have a license we can redistribute (Omarchy's don't say).
- App launcher: our own, in Quickshell (replaces rofi/fuzzel), like Omarchy's.
- Media: the bar's media card. Any MPRIS player, plus a local music mode that plays a folder
  with **mpv** (over its IPC socket) and downloads from links with **yt-dlp** (needs **ffmpeg**)
- Screenshots / clipboard: **grim**, **slurp**, **wl-clipboard**
- Password prompts: **hyprpolkitagent**
- Plumbing: **PipeWire**, **NetworkManager**, **xdg-desktop-portal-hyprland**
- No lock screen (no hyprlock).

### Apps
- Firefox, Neovim, Vesktop, claude-code
- git, github-cli
- mpv, an image viewer, evince (PDF), file-roller + 7zip
- Shell: **fish** + starship. Done: `fish/starship.toml`, `fish/colors.fish`, `fish/prompt.fish`
  (jellybeans, full path, branch + green/red line changes, blank line between commands).

### Look
- Dark GTK theme, **Papirus-Dark** icons, **Bibata** cursor, JetBrains Mono / Iosevka Nerd Fonts.
- Bar / shell UI: **Inter** for text, **JetBrainsMono Nerd Font** for icons, jellybeans colors
  (true red `#f04848` only for critical notifications).

### GPU (NVIDIA)
- `nvidia-open` built against linux-tkg and shipped prebuilt in `[gilgamesh]` (no DKMS compile on updates;
  rebuilt with every kernel/driver bump), `nvidia-utils`, `lib32-nvidia-utils`, `nvidia-settings`
- `mesa`, `lib32-mesa`
- `vulkan-icd-loader`, `lib32-vulkan-icd-loader`
- `egl-wayland` (Wayland on NVIDIA), `libva-nvidia-driver` (GPU video decoding)
- No AMD GPU drivers in the current image; target systems use NVIDIA graphics.

### Network / DNS
- `scripts/gilgamesh-dns`: switch the DNS provider system-wide (DHCP, Cloudflare, Google,
  OpenDNS, Custom), based on Omarchy's omarchy-dns. Sets it on every wired/Wi-Fi NetworkManager
  connection (DNS-over-TLS for Cloudflare/Google). On Gilgamesh it also writes NM's global DNS +
  resolved.conf (root, passwordless for presets via `etc/sudoers.d/gilgamesh-dns`).
  Compatibility mode updates only connection profiles on systems with declaratively managed `/etc`;
  NetworkManager permissions are required.
- Bar: network icon + network card with the DNS provider pills.

### Security
- Firewall on.
- **No host <-> VM channels**: no qemu-guest-agent, no spice/shared clipboard in the VM definition.

### Installer
- Asks a few questions (disk, username, password, hostname), then installs automatically.

### Not included
- AUR helper, Docker, Telegram, monitoring tools, hyprlock, AMD GPU drivers, fallback kernel.

## Still to decide
- Installer details: exact questions, timezone, keyboard layout.
- Repo package signing (GPG key).
- Branding (boot menu, ISO name, wallpaper, etc.).

## Phases
1. **Desktop development:** ~~restyle fish~~ (done), build the Quickshell bar.
2. Arch build container on the host (Docker) → build linux-tkg (+ headers) and set up the
   `[gilgamesh]` repo on GitHub.
3. Write the custom Hyprland configs and package them.
4. Build the ISO + installer with `archiso`.
5. Test in a throwaway VM (incl. the `fio` XFS check), then install for real.
