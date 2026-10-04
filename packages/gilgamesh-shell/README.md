# Gilgamesh packages

Build the system defaults first, index them, then build the desktop package:

```sh
build/build.sh pkg gilgamesh-settings
build/build.sh repo
build/build.sh pkg gilgamesh-shell
```

See the [build guide](../../build/README.md) and [system settings](../gilgamesh-settings/README.md).
For native Arch builds, run `makepkg -s` inside either package directory. Both
recipes read the full checkout through `${GILGAMESH_ROOT:-$startdir/../..}`; the
container exports `GILGAMESH_ROOT=/work` so temporary package copies work. A standalone
PKGBUILD or `makepkg -S` archive is insufficient. Use a fixed checkout for releases,
and bump `pkgver` for releases or `pkgrel` for packaging fixes. Local payloads have
no makepkg source checksums.

Shell assets live under `/usr/share/gilgamesh/`: `quickshell/` includes its themes,
wallpapers and `themed/` files, alongside `hypr/` and `fish/`. This preserves the
bar's relative lookup of `../fish/starship.toml`. `gilgamesh-settings` is required
because the bar's Settings panel calls `gilgamesh-dns`. Package scripts do not
write into users' home directories.

## User configuration

Create `~/.config/hypr/hyprland.lua` containing:

```lua
require("/usr/share/gilgamesh/hypr/hyprland")
```

Use `$XDG_CONFIG_HOME/hypr/` when set. Personal settings go in `local.lua` beside
the stub; the shared config loads it last. This requires a Lua-capable Hyprland.

Launch the bar with:

```sh
qs -p /usr/share/gilgamesh/quickshell -d -n
qs ipc -p /usr/share/gilgamesh/quickshell call launcher toggle
```

The packaged Hyprland config sets `QS_CONFIG_PATH=/usr/share/gilgamesh/quickshell`
so autostart, restart and IPC commands select the same configuration. Log in again
after migrating a running session.

Fish loads `/usr/share/fish/vendor_conf.d/gilgamesh.fish` for interactive shells.
It sources the shared colors, spacing and greeting (fastfetch with the Gilgamesh logo
in place of fish's welcome text, only in a freshly opened terminal), then the packaged
`starship-init.fish`, generated at build time with `starship init fish --print-full-init`. It selects
the shared Starship config only when `STARSHIP_CONFIG` is unset and neither
`~/.config/starship.toml` nor `$XDG_CONFIG_HOME/starship.toml` exists. When neither user configuration file exists, generated theme
state takes precedence over the shared fallback. Override settings in `config.fish`, or disable
the vendor snippet with an empty `~/.config/fish/conf.d/gilgamesh.fish`. The fastfetch
config is `/etc/fastfetch/config.jsonc` (in `backup=()`), its logo
`/usr/share/gilgamesh/fastfetch/logo.txt`; `~/.config/fastfetch/config.jsonc` replaces it.

When migrating, replace copied Hyprland configs with the stub and remove duplicate
fish color/prompt snippets and Starship initialization after saving personal changes.
Stop the old bar before starting the packaged one; `-n` prevents duplicates only
for the same configuration path.

## Publishing

Use a clean Arch build environment and test package installation, ownership
conflicts, upgrade behavior and a desktop session before publishing. Collect
palette license texts and wallpaper redistribution permissions; the installed
license notice does not grant those permissions.
