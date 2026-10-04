# The Gilgamesh bar

The bar is a Quickshell shell with a panel on every screen. It also draws the wallpaper,
serves notifications and provides the launcher and Settings window. Hyprland starts it
at login. The implementation is in [shell.qml](../quickshell/shell.qml).

## Modules and controls

| Module | What it does |
| --- | --- |
| Gilgamesh logo | Toggle Gilgamesh Settings. |
| Workspaces | Show normal workspaces on that monitor; click to switch. Green marks focus, red marks urgency. |
| Clock | Show 24-hour time; click for the current date and month's numbered day grid, with today highlighted. |
| Media | Show the selected player's title and artist when a player is available. Click for the media card, middle-click for play/pause, scroll down for next and up for previous. |
| System tray | Left-click to activate an app, right-click for its menu. Apps that expose only a menu open it on left-click too. |
| Notifications | Open history, toggle Do Not Disturb or clear notifications. The count is the history size. |
| RAM | Show used / total GiB, refreshed every two seconds. Used means total minus available; yellow starts at 75%, red at 90%. |
| Network | Show connected/offline status; click for connection details and DNS providers. |
| Microphone and volume | Click for input/output devices and sliders, middle-click to mute, scroll in 5% steps between 0 and 100%. |

Click empty bar space to close a dropdown. **Double-click empty bar space to toggle
transparency.** The choice is saved; text switches between the theme's light and dark
colors according to the wallpaper beneath the bar. The launcher has the same toggle.

Notifications keep up to 50 history entries and five visible popups. Do Not Disturb
suppresses new popups but still records history. Fullscreen on the focused workspace
suppresses ordinary popups; critical ones can still appear unless DND is on. Critical
popups stay until closed. History and DND are session state, not saved preferences.

The network card offers DHCP, Cloudflare, Google, OpenDNS and Custom through
[`gilgamesh-dns`](../scripts/gilgamesh-dns). Presets change wired/Wi-Fi connection
profiles and system DNS on Gilgamesh. Cloudflare and Google use **opportunistic**
DNS-over-TLS. Custom opens a terminal for server entry and authentication.

## Media and local music

The [media card](../quickshell/MediaCard.qml) has Now Playing and Library tabs. It
controls MPRIS players that report a track title, plus the built-in local music player.
Player buttons appear when more than one is available. Your selection stays until
another player starts playing; automatic switches are delayed to avoid flickering
between tracks. Media keys follow the player shown in the bar.

Now Playing shows artwork, title, artist, previous/next and play/pause. **Time and
seeking are local-music only.** Local playback also has shuffle and stop. Its volume
is mpv's own volume, separate from system volume. Other players use matching PipeWire
streams where available, with MPRIS volume as a fallback; mute needs a matching stream.

Open Library to search and play files in your Music folder, including subfolders.
Use the folder button and **Use this folder** to choose another location. Hidden
paths are excluded. Supported extensions are MP3, FLAC, Opus, Ogg/OGA, M4A, AAC, WAV,
WebM, MKA, WMA, AIFF, APE and WV. The list uses natural filename order. Selecting a
track starts a looping playlist from that track; Previous restarts the track when
more than three seconds have played, otherwise it goes to the previous track.

Paste an HTTP(S) or `www.` link into the Library search box and press Enter or click
the download button. [MusicPlayer.qml](../quickshell/MusicPlayer.qml) runs `yt-dlp`
with audio extraction, metadata and thumbnail embedding, saving into the selected
music folder. It disables playlist downloads. Progress, cancellation and the final
result appear in the card. Completed downloads join an active local playlist and
the library is rescanned. Playback needs `mpv`; downloading and artwork handling need
`yt-dlp` and `ffmpeg`. The installer includes all three.

When nothing is playing, the bar's media label is hidden. Open the card with
`qs ipc call media open` to start using the Library.

## Launcher and wallpaper picker

**Super+D** opens the [launcher](../quickshell/Launcher.qml). With an empty search,
it shows Apps, Theme, Wallpaper, Power, Toggles and Settings. Typing searches apps,
themes and actions together; app launch counts influence ranking.

Use Up/Down, Tab/Shift+Tab or Ctrl+J/K/N/P to select a row, and Enter to run it or enter
a submenu. Escape goes back, then closes at the top level. With an empty search,
Backspace or Left goes back and Right enters a submenu. Power offers suspend, logout,
reboot and shutdown; the last three ask for confirmation. Logout requests window
closure, then exits Hyprland after two seconds.

**Super+W** opens the [wallpaper picker](../quickshell/WallpaperPicker.qml). Left/Right
or H/L choose an image; Tab/Shift+Tab also work. Up/Down or K/J change the source
between theme wallpapers and your folder. Enter applies, Escape closes. Click a side
preview to select it, then the selected preview to apply it. Choosing wallpaper from
another theme does not change your color theme. See [themes](themes.md) for formats
and folder setup.

## Settings and saved state

Open Settings from the logo or launcher. Its [pages](../quickshell/Settings.qml) are:

| Page / IPC name | Controls |
| --- | --- |
| Network / `network` | Connection, IP address, link speed and DNS provider. |
| Sound / `sound` | Input/output device selection, levels and mute. |
| Theme / `theme` | Preview installed palettes and switch the desktop theme. |
| Wallpaper / `wallpaper` | Theme/folder tabs, image grid, Random, Change folder and Open folder. |
| Notifications / `notifications` | DND and clearing history. |
| About / `about` | Gilgamesh branding and local system information. |

Preferences live in `$XDG_STATE_HOME/gilgamesh/settings.json` (default:
`~/.local/state/gilgamesh/settings.json`). They include theme, transparency, wallpaper,
wallpaper folder, per-theme wallpaper choices, music folder and local music volume.
Pictures and Music default to the XDG user directories, falling back to `~/Pictures`
and `~/Music`. Launcher counts live alongside preferences in `launcher.json`.

## IPC

Run these in the session with the Gilgamesh shell running. These are all exported
handlers from [shell.qml](../quickshell/shell.qml), [Launcher.qml](../quickshell/Launcher.qml)
and [Theme.qml](../quickshell/Theme.qml). Page names are lowercase; track indexes start
at zero in the full local library.

| Command | Effect |
| --- | --- |
| `qs ipc call launcher toggle` | Toggle launcher. |
| `qs ipc call launcher open` | Open launcher. |
| `qs ipc call launcher close` | Close launcher. |
| `qs ipc call launcher menu Power` | Open a submenu; paths such as `Power/Reboot` also work. |
| `qs ipc call media playPause` | Toggle the shown player, or start local music if none is shown. |
| `qs ipc call media next` | Next track if supported. |
| `qs ipc call media previous` | Previous track if supported. |
| `qs ipc call media playTrack 0` | Play the first local-library track. |
| `qs ipc call media open` | Open the media card on the focused monitor. |
| `qs ipc call wallpaper set /path/to/image.png` | Set an image without changing the wallpaper folder. |
| `qs ipc call wallpaper get` | Print the current wallpaper path. |
| `qs ipc call wallpaper pick` | Open the picker. |
| `qs ipc call wallpaper closePicker` | Close the picker. |
| `qs ipc call settings open theme` | Open a Settings page from the table above. |
| `qs ipc call settings toggle` | Toggle Settings. |
| `qs ipc call theme set nord` | Apply a theme; returns `ok` or an unknown-theme message. |
| `qs ipc call theme list` | List discovered themes. |
| `qs ipc call theme current` | Print the current theme name. |

For the packaged shell outside its configured session, select its path explicitly:
`qs ipc -p /usr/share/gilgamesh/quickshell call launcher toggle`. See the
[package configuration guide](../packages/gilgamesh-shell/README.md).

**Super+Shift+R** restarts the bar. It terminates processes named `qs` and `quickshell`,
then starts the configured shell again.
