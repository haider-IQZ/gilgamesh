# Gilgamesh Linux

A fast, gaming-focused Arch desktop. Hyprland for the windows. Our own Quickshell bar
for everything around them.

- Keyboard-driven tiling, with rules for game tearing, direct scanout and adaptive sync.
- One bar for workspaces, music, notifications, audio, network, settings and launching apps.
- Eight desktop themes, with matching terminal, shell and GTK colors and a wallpaper picker.
- XFS, compressed RAM swap and system defaults aimed at responsiveness.
- A linux-tkg BORE build and a signed pacman repository pipeline, with prebuilt NVIDIA
  module recipes for that kernel.

**In development. No Gilgamesh ISO has been published yet.** The current installer and
live profile use Arch's `linux` kernel; supported NVIDIA cards use `nvidia-open-dkms`.
Connecting installation to the signed `[gilgamesh]` repository and BORE kernel is still
release work.

## Install

The path is simple: boot an ISO in **UEFI** mode, get online, run the installer.
**It erases the entire selected disk.** There is no install-alongside mode, and the
disk must be at least 40 GB.

For the current development path, boot the official Arch Linux ISO and follow the
[installer guide](installer/README.md). If you build a Gilgamesh ISO yourself, it
bundles the installer and starts it on tty1 after network preparation. Run
`gilgamesh-install` from the live shell to retry after connecting.

Choose your keyboard layout, account, machine name, timezone and disk, review the
summary, then confirm. See [building](docs/building.md) for local ISO builds and the
remaining repository setup.

## Screenshots

Screenshots will be added after the release desktop is validated.

## Docs

- [Keybinds](docs/keybinds.md) — every default shortcut.
- [The bar](docs/bar.md) — controls, music, launcher, settings and IPC.
- [Themes](docs/themes.md) — switching, wallpapers and your own palette.
- [Performance](docs/performance.md) — what the system and kernel configs tune, and why.
- [Building](docs/building.md) — packages, ISO and repository owner setup.

MIT. See [LICENSE](LICENSE) for the full terms and third-party asset exceptions;
wallpapers are not covered by the repository's MIT license.
