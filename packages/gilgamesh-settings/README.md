# Gilgamesh settings

System defaults and the `gilgamesh-dns` helper. See the [packaging guide](../gilgamesh-shell/README.md)
for builds and desktop configuration.

| Source directory under `system/` | Installed directory |
| --- | --- |
| `etc/sysctl.d` | `/usr/lib/sysctl.d` |
| `etc/udev/rules.d` | `/usr/lib/udev/rules.d` |
| `etc/modprobe.d` | `/usr/lib/modprobe.d` |
| `etc/modules-load.d` | `/usr/lib/modules-load.d` |
| `etc/tmpfiles.d` | `/usr/lib/tmpfiles.d` |
| `etc/systemd/journald.conf.d` | `/usr/lib/systemd/journald.conf.d` |
| `etc/systemd/system.conf.d` | `/usr/lib/systemd/system.conf.d` |
| `etc/systemd/system/ly@.service.d` | `/usr/lib/systemd/system/ly@.service.d` |
| `etc/systemd` (`zram-generator.conf`) | `/usr/lib/systemd` |
| `etc/pipewire/pipewire.conf.d` | `/usr/share/pipewire/pipewire.conf.d` |
| `etc/pipewire/pipewire-pulse.conf.d` | `/usr/share/pipewire/pipewire-pulse.conf.d` |
| `etc/wireplumber/wireplumber.conf.d` | `/usr/share/wireplumber/wireplumber.conf.d` |
| `etc/NetworkManager/conf.d` | `/usr/lib/NetworkManager/conf.d` |
| `etc/dconf/profile` | `/usr/share/dconf/profile` |
| `etc/mkinitcpio.conf.d` | `/etc/mkinitcpio.conf.d` |
| `etc/dconf/db/local.d` | `/etc/dconf/db/local.d` |
| `etc/xdg-desktop-portal` (`*-portals.conf`) | `/etc/xdg-desktop-portal` |
| `usr/share/libalpm/hooks` | `/usr/share/libalpm/hooks` |

Regular files retain their filenames. Packaging fails on unmapped files and
unsupported file types anywhere under `system/`. The one supported symlink,
`etc/systemd/user/localsearch-3.service -> /dev/null`, is replaced by a vendor
`localsearch-3.service.d/10-gilgamesh.conf` drop-in to avoid owning localsearch's
unit file. The drop-in skips indexing unless `/etc/gilgamesh/enable-localsearch`
exists. Create that marker, or override the drop-in with an empty file of the
same name under `/etc/systemd/user/localsearch-3.service.d/`, to re-enable indexing.
Restart the service or start a new session to apply the change.

Override vendor files in the corresponding `/etc` directory, or user configuration
for PipeWire/WirePlumber. Identical filenames shadow vendor files for systemd and
NetworkManager, while audio fragments merge. Old copies in `/etc` can hide package
updates; compare and migrate them before installation. Resolve unowned-file
conflicts without a blanket pacman `--overwrite`.

Only the mkinitcpio drop-in, the sudoers rule, the dconf keyfile and the portal
configuration are installed in `/etc`; all four are in `backup=()`. The DNS helper is
mode `0755`, sudoers is `0440`, and other files are `0644`. DNS state written by the
helper belongs to the administrator. NetworkManager and systemd-resolved still need
to be enabled and the resolver symlink configured by the installer.

The desktop is dark by default: `etc/dconf/db/local.d/00-gilgamesh` sets the GNOME
interface settings (`color-scheme`, `gtk-theme`, `icon-theme`) that GTK apps read,
the `user` dconf profile adds that `local` database below each user's own, and
`etc/xdg-desktop-portal/hyprland-portals.conf` routes the settings portal to
`xdg-desktop-portal-gtk` so Firefox and libadwaita apps see the same color scheme.
No GTK `settings.ini`: `/usr/share/gtk-{3,4}.0/settings.ini` belong to the gtk3/gtk4
packages, and on Wayland GTK reads these settings from dconf anyway. The install script runs `dconf update` after installs, upgrades and removal to
compile the keyfiles into `/etc/dconf/db/local` (unowned). Users' own choices live in
their user database and win; override the system defaults with another keyfile in
`/etc/dconf/db/local.d/` and run `dconf update`.

Dependencies include the audio services, zram-generator, NetworkManager, systemd,
libcap, kmod, mkinitcpio, lz4 and dconf, plus the DNS helper's shell, utilities and sudo.
Ly and Hyprland remain optional, as do the theme packages the dconf defaults name.
`rtkit` supports audio realtime scheduling.

The install script sets Hyprland's capability when its binary exists; a libalpm
hook repeats that after Hyprland replacement. Installation prints an initramfs
reminder. Upgrades compare the old and new packaged mkinitcpio drop-in checksums
and print the reminder only when the content changes, including changes delivered
as `.pacnew`. Upgrades from packages without checksum metadata compare the installed
drop-in instead. Review the configuration and rebuild with `mkinitcpio -P` as root;
transaction scripts do not rebuild kernel images.

