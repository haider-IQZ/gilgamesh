# Themes

Gilgamesh ships eight dark palettes in [quickshell/themes](../quickshell/themes).
Jellybeans is the default.

| Display name | Folder / IPC name | Bundled backgrounds in this checkout |
| --- | --- | --- |
| Jellybeans | `jellybeans` | Yes |
| Catppuccin | `catppuccin` | No |
| Everforest | `everforest` | No |
| Gruvbox | `gruvbox` | Yes |
| Kanagawa | `kanagawa` | No |
| Nord | `nord` | Yes |
| Rose Pine | `rose-pine` | No |
| Tokyo Night | `tokyo-night` | No |

Choose **Settings → Theme**, **Super+D → Theme**, or run:

```sh
qs ipc call theme list
qs ipc call theme set nord
qs ipc call theme current
```

## What switches

[Theme.qml](../quickshell/Theme.qml) reads the palette, saves the chosen theme in bar
preferences and generates application colors. The bar's colors fade to the new palette.
Open foot terminals are recolored with terminal escape sequences. Fish reloads its
syntax colors through the `gilgamesh_theme` universal variable; the shipped fish
integration points Starship and fzf at generated theme files.

Generated files go in `$XDG_STATE_HOME/gilgamesh/theme/`, defaulting to
`~/.local/state/gilgamesh/theme/`: `foot.ini`, `alacritty.toml`, `colors.fish`,
`starship.toml` and `fzf`. Edit the source palette, not these generated files. The
installer configures foot's include and fish integration. Alacritty colors are generated,
but the installer does not install or configure Alacritty; an existing Alacritty setup
must import the generated TOML. The packaged shell respects user Starship config files;
see its [configuration guide](../packages/gilgamesh-shell/README.md).

GTK 3 and GTK 4 CSS is written to `$XDG_CONFIG_HOME/gtk-3.0/gilgamesh.css` and
`$XDG_CONFIG_HOME/gtk-4.0/gilgamesh.css`, with `~/.config` as the config-home default.
The theme engine adds an import to each `gtk.css`, preserving other CSS. GTK apps need
to restart to pick up these files.

**Nautilus is restarted automatically on a theme switch.** The engine records a folder
per open window, quits Nautilus, then reopens those folders. It attempts to restore
workspaces, floating position/size, fullscreen state and tiled placement. This is not
a complete tab/session restore: it takes the first reported location for each window,
and window matching or layout restoration can be imperfect. Other GTK apps are not
restarted automatically.

If a theme has backgrounds, switching restores its last selected bundled image or
uses the first sorted image. If it has none, the existing wallpaper stays. Your own
wallpaper-folder setting is preserved. The active palette file is watched for edits;
to rerun live application and wallpaper updates after editing, select the same theme
again or call `theme set` with its name.

## Add a theme

Create a directory beside the existing themes in the **active Quickshell configuration**:

```text
themes/
  my-theme/
    colors.toml
    backgrounds/       (optional)
      landscape.png
```

The installer copies the shell to `~/.config/quickshell`; a source checkout uses
`quickshell/themes/`. Package assets live under `/usr/share/gilgamesh/quickshell`.
For personal changes to the packaged shell, use a writable copy and point `qs -p`
and its IPC calls at that copy. Theme discovery only scans the active configuration's
adjacent `themes/` directory, not a separate user override directory.

Copy an existing `colors.toml`, change its values, then reopen the launcher or Settings
Theme page to refresh discovery. Select the new card or run `qs ipc call theme set my-theme`.
The directory name is the IPC name.

The parser accepts flat `key = "value"` lines. Use double-quoted `#rrggbb` colors,
one assignment per line; it is not a general TOML parser with nested tables or
single-quoted strings. This complete example uses the shipped Jellybeans palette:

```toml
mode = "dark"
accent = "#99ad6a"
selection = "#2a2a2a"
muted = "#555555"
background = "#151515"
dark_background = "#121212"
darker_background = "#101010"
lighter_background = "#2a2a2a"
foreground = "#e8e8d3"
dark_foreground = "#888888"
light_foreground = "#c7c7b5"
bright_foreground = "#ffffff"
red = "#cf6a4c"
yellow = "#fad07a"
orange = "#ffb964"
green = "#99ad6a"
cyan = "#5fb0b0"
blue = "#597bc5"
magenta = "#9b859d"
brown = "#8f5536"
bright_red = "#f04848"
bright_yellow = "#fad07a"
bright_green = "#99ad6a"
bright_cyan = "#5fb0b0"
bright_blue = "#8197bf"
bright_magenta = "#c6b6ee"
```

Background/foreground variants color surfaces and text; `muted` colors subdued text,
`selection` colors terminal selection, and normal/bright colors form the terminal
palette. `accent` appears in theme previews. `mode`, `dark_background`,
`light_foreground` and `brown` are present for palette compatibility but are not
currently used by the theme engine; `mode` does not enable a separate light-mode UI.

Optional GTK overrides are `gtk_bg`, `gtk_bg_alt`, `gtk_fg`, `gtk_fg_dim`, `gtk_sel`,
`gtk_sel_fg`, `gtk_red`, `gtk_orange` and `gtk_scroll`. Without them, GTK colors are
derived from the main palette, including a selection color mixed from blue and background.

## Wallpapers

Put JPG, JPEG, PNG or WebP files directly in your theme's `backgrounds/` directory.
Discovery is not recursive. **Super+W** browses theme backgrounds and your own folder;
**Settings → Wallpaper → Your folder → Change folder** changes that folder. It defaults
to the XDG Pictures directory. Settings also offers Random and Open folder.

The Settings grid additionally lists GIF files; the keyboard picker and automatic
theme wallpaper selection only list JPG, JPEG, PNG and WebP. Picking a background
from another theme changes only the wallpaper. An empty wallpaper path uses the
theme's plain background color.

Palette attribution and asset exceptions are in [LICENSE](../LICENSE). Wallpapers
retain their artists' terms and are not covered by MIT; obtain redistribution
permission before adding them to a distributed theme.
