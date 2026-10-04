# Keybinds

Generated from the bindings in [hypr/hyprland.lua](../hypr/hyprland.lua), including
all ten iterations of its workspace loop: **45 bindings**. `Super` is the modifier
configured as `SUPER` (usually the Windows/logo key). These are the shipped defaults;
your local configuration can change them.

| Shortcut | Action |
| --- | --- |
| `Super + Q` | Open foot terminal. |
| `Super + X` | Open Firefox. |
| `Super + E` | Open Nautilus. |
| `Super + D` | Toggle the launcher and menu. |
| `Super + W` | Open the wallpaper picker. |
| `Super + Shift + R` | Restart the bar (terminate processes named `qs` and `quickshell`, wait one second, then start `qs -d -n`). |
| `XF86AudioPlay` | Toggle play/pause for the player shown in the bar. |
| `XF86AudioPause` | Toggle play/pause for the player shown in the bar (not a pause-only action). |
| `XF86AudioNext` | Next track for the player shown in the bar. |
| `XF86AudioPrev` | Previous track for the player shown in the bar. |
| `Print` | Select a region with slurp and copy the grim screenshot to the clipboard. |
| `Shift + Print` | Copy a full-screen grim screenshot to the clipboard. |
| `Super + C` | Close the focused window. |
| `Super + F` | Toggle fullscreen. |
| `Super + S` | Toggle floating. |
| `Super + Left mouse drag` | Hold Super and drag with the left mouse button to move a window. |
| `Super + Right mouse drag` | Hold Super and drag with the right mouse button to resize a window. |
| `Super + H` | Focus the window left. |
| `Super + J` | Focus the window down. |
| `Super + K` | Focus the window up. |
| `Super + L` | Focus the window right. |
| `Super + Shift + H` | Move the focused window left. |
| `Super + Shift + J` | Move the focused window down. |
| `Super + Shift + K` | Move the focused window up. |
| `Super + Shift + L` | Move the focused window right. |
| `Super + 1` | Switch to workspace 1. |
| `Super + Shift + 1` | Move the focused window to workspace 1. |
| `Super + 2` | Switch to workspace 2. |
| `Super + Shift + 2` | Move the focused window to workspace 2. |
| `Super + 3` | Switch to workspace 3. |
| `Super + Shift + 3` | Move the focused window to workspace 3. |
| `Super + 4` | Switch to workspace 4. |
| `Super + Shift + 4` | Move the focused window to workspace 4. |
| `Super + 5` | Switch to workspace 5. |
| `Super + Shift + 5` | Move the focused window to workspace 5. |
| `Super + 6` | Switch to workspace 6. |
| `Super + Shift + 6` | Move the focused window to workspace 6. |
| `Super + 7` | Switch to workspace 7. |
| `Super + Shift + 7` | Move the focused window to workspace 7. |
| `Super + 8` | Switch to workspace 8. |
| `Super + Shift + 8` | Move the focused window to workspace 8. |
| `Super + 9` | Switch to workspace 9. |
| `Super + Shift + 9` | Move the focused window to workspace 9. |
| `Super + 0` | Switch to workspace 10. |
| `Super + Shift + 0` | Move the focused window to workspace 10. |

Both media Play and Pause keys toggle playback. All four media-key bindings set
`locked = true`; this is a binding flag, not a bundled lock screen. If no player is
shown, play/pause tries to start the local library. Screenshots go to the clipboard,
not a file. There are no default volume-up, volume-down or mute keybindings in this
file; use the [bar's audio controls](bar.md).

Put your changes in `local.lua` beside the active `hyprland.lua` (normally
`~/.config/hypr/local.lua`). The main config loads it last with `pcall(require, "local")`.
The installer writes the selected keyboard layout there too. Preserve that setting
when adding your own bindings. The [package guide](../packages/gilgamesh-shell/README.md)
covers the shared-config stub used with packaged installs.
