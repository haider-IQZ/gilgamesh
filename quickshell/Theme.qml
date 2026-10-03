// Gilgamesh themes. A theme is a folder in themes/: colors.toml (Omarchy's palette format)
// and optionally backgrounds/ (its wallpapers).
//
// The bar takes its colors from here, and a switch restyles the rest of the desktop too:
//   - open foot terminals: recolored in place with escape codes (like Omarchy)
//   - foot / alacritty: theme files they include (alacritty reloads it by itself)
//   - fish syntax colors: every open shell re-reads them (universal variable gilgamesh_theme)
//   - starship prompt and fzf: read their theme file every time they run
//   - wallpaper: the theme's own, if it has any
//   - Nautilus / GTK apps: haiderking1's Nautilus Jellybeans Theme in the theme's colors
//     (~/.config/gtk-{4,3}.0/gilgamesh.css). GTK reads it only when an app starts (once per
//     process, and libadwaita blocks the theme-reload route), so Nautilus gets restarted with
//     its windows reopened on the same folders.
// Everything else it writes goes to $XDG_STATE_HOME/gilgamesh/theme/.
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import QtQuick

Scope {
    id: theme
    required property var shell
    readonly property string dir: Qt.resolvedUrl("themes").toString().replace("file://", "")
    readonly property string name: shell.prefs.theme || "jellybeans"
    readonly property string outDir: shell.stateDir + "/theme"
    // the shared prompt config: the repo's fish/starship.toml next to this folder (the bar's
    // folder is a symlink, so resolve it first), or a starship.toml next to it,
    // else ~/.config/starship.toml
    property string starshipBase: ""
    Process {
        running: true
        command: ["sh", "-c", "d=$(readlink -f \"$1\"); for f in \"$d/../fish/starship.toml\" \"$d/../starship.toml\"; do [ -f \"$f\" ] && { readlink -f \"$f\"; exit; }; done; echo \"${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml\"",
                  "sh", Qt.resolvedUrl(".").toString().replace("file://", "")]
        stdout: StdioCollector { onStreamFinished: theme.starshipBase = this.text.trim() }
    }

    property var c: ({})          // current palette: key -> "#rrggbb"
    property var palettes: ({})   // every installed theme: name -> palette (for the Settings page)
    readonly property var names: Object.keys(palettes).sort((a, b) =>
        a === "jellybeans" ? -1 : b === "jellybeans" ? 1 : a.localeCompare(b))

    // ---------- the bar's colors ----------
    function pick(k, fallback) { return c[k] || fallback }
    function mix(a, b, t) {
        a = Qt.color(a); b = Qt.color(b)
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }
    readonly property color bg: pick("background", "#151515")
    readonly property color bgDark: pick("darker_background", "#101010")
    readonly property color bgAlt: pick("lighter_background", "#2a2a2a")
    readonly property color fg: pick("foreground", "#e8e8d3")
    readonly property color dim: pick("dark_foreground", "#888888")
    readonly property color faint: pick("muted", "#555555")
    readonly property color red: pick("red", "#cf6a4c")
    readonly property color critical: pick("bright_red", "#f04848")
    readonly property color green: pick("green", "#99ad6a")
    readonly property color yellow: pick("yellow", "#fad07a")
    readonly property color blue: pick("blue", "#597bc5")
    readonly property color purple: pick("magenta", "#9b859d")
    readonly property color cyan: pick("cyan", "#5fb0b0")
    readonly property color hover: mix(bg, bgAlt, 0.5)            // row hover
    readonly property color hoverStrong: mix(bgAlt, fg, 0.08)     // button hover

    // ---------- loading ----------
    function parse(text) {
        const out = {}
        for (const line of text.split("\n")) {
            const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"/)
            if (m) out[m[1]] = m[2]
        }
        return out
    }

    FileView {
        id: current
        path: theme.dir + "/" + theme.name + "/colors.toml"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            theme.c = theme.parse(text())
            theme.writeFiles()
            if (theme.switching) { theme.switching = false; theme.applyLive() }
        }
    }

    // all palettes, for the previews, and how many wallpapers each theme has
    property var wallCounts: ({})   // name -> number of backgrounds
    function refresh() { lister.running = true; counter.running = true }
    Process {
        id: counter
        command: ["sh", "-c", "for d in \"$1\"/*/; do n=$(find \"$d/backgrounds\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) 2>/dev/null | wc -l); echo \"$(basename \"$d\") $n\"; done", "sh", theme.dir]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = {}
                for (const line of this.text.trim().split("\n")) {
                    const [k, n] = line.split(" ")
                    if (k && Number(n) > 0) m[k] = Number(n)
                }
                theme.wallCounts = m
            }
        }
    }
    Component.onCompleted: refresh()
    Process {
        id: lister
        command: ["sh", "-c", "for f in \"$1\"/*/colors.toml; do echo \"@@$(basename \"$(dirname \"$f\")\")\"; cat \"$f\"; done", "sh", theme.dir]
        stdout: StdioCollector {
            onStreamFinished: {
                const all = {}
                for (const chunk of this.text.split("@@").slice(1)) {
                    const nl = chunk.indexOf("\n")
                    all[chunk.slice(0, nl).trim()] = theme.parse(chunk.slice(nl + 1))
                }
                theme.palettes = all
            }
        }
    }

    // ---------- switching ----------
    property bool switching: false
    function set(newName) {
        if (!palettes[newName] && Object.keys(palettes).length > 0) return false
        if (newName === name) { applyLive(); return true }
        switching = true
        shell.prefs.theme = newName    // -> new colors.toml loads -> writeFiles + applyLive
        return true
    }

    // what changes right away: open terminals, open shells, the wallpaper, Nautilus
    function applyLive() {
        live.running = false
        live.running = true
        walls.running = false
        walls.running = true
        nautilusWindows.running = false
        nautilusWindows.running = true
    }

    // ---------- Nautilus: restarted in the new theme, every window back where it was ----------
    // Before: the folder of each window (Nautilus's own D-Bus property, the tab that was open)
    // and its workspace / floating / position / size (Hyprland). After the restart each window
    // is caught the moment it opens and put back: same workspace (you stay where you are),
    // floating ones on the same pixel, tiled ones swapped into their old spot and split size.
    property var nautilusQueue: []     // [{ uri, w }] still to reopen, one at a time
    property var nautilusOpening: null // the one we just opened, waiting for its window
    property var nautilusTiled: []     // [{ addr, w }] waiting for Hyprland to lay them out
    function isFiles(cls) { return /nautilus/i.test(cls) }
    // the title Nautilus gives a window for a folder ("Home", "Downloads"...)
    function folderTitle(uri) {
        if (uri.startsWith("trash:")) return "Trash"
        if (uri.startsWith("recent:")) return "Recent"
        if (!uri.startsWith("file://")) return ""
        const path = decodeURIComponent(uri.slice(7)).replace(/\/+$/, "")
        if (path === shell.home) return "Home"
        return path ? path.slice(path.lastIndexOf("/") + 1) : "/"
    }

    Process {
        id: nautilusWindows
        command: ["sh", "-c", "pgrep -x nautilus >/dev/null || pgrep -x .nautilus-wrapp >/dev/null || exit 0; "
            + "busctl --user --json=short get-property org.freedesktop.FileManager1 /org/freedesktop/FileManager1 "
            + "org.freedesktop.FileManager1 OpenWindowsWithLocations 2>/dev/null || echo '{}'; echo '@@'; hyprctl clients -j"]
        stdout: StdioCollector {
            onStreamFinished: {
                const out = this.text.trim()
                if (!out) return     // not running
                const parts = out.split("@@")
                let uris = [], wins = []
                try { uris = Object.values(JSON.parse(parts[0]).data || {}).map(l => l[0]).filter(u => u) } catch (e) {}
                try {
                    wins = JSON.parse(parts[1]).filter(c => theme.isFiles(c.class)).map(c => ({
                        title: c.title, ws: c.workspace.name, floating: c.floating,
                        fullscreen: c.fullscreen || 0, at: c.at, size: c.size }))
                } catch (e) {}
                // pair each folder with its window by title now, while the titles are right
                const queue = uris.map(u => ({ uri: u, w: null }))
                for (const q of queue) {
                    const i = wins.findIndex(w => w.title === theme.folderTitle(q.uri))
                    if (i >= 0) q.w = wins.splice(i, 1)[0]
                }
                for (const q of queue) if (!q.w && wins.length > 0) q.w = wins.shift()
                theme.nautilusQueue = queue
                theme.nautilusTiled = []
                nautilusQuit.running = true
            }
        }
    }
    Process {
        id: nautilusQuit
        command: ["sh", "-c", `
            nautilus -q
            for i in $(seq 50); do
              pgrep -x nautilus >/dev/null || pgrep -x .nautilus-wrapp >/dev/null || break
              sleep 0.1
            done`]
        onExited: theme.openNextFolder()
    }
    Process { id: nautilusOpen }
    function openNextFolder() {
        if (nautilusQueue.length === 0) { nautilusOpening = null; return }
        nautilusOpening = nautilusQueue[0]
        nautilusQueue = nautilusQueue.slice(1)
        nautilusOpen.command = ["sh", "-c", "nautilus --new-window \"$1\" >/dev/null 2>&1 &", "sh", nautilusOpening.uri]
        nautilusOpen.running = true
        openTimeout.restart()
    }
    Timer { id: openTimeout; interval: 5000; onTriggered: theme.openNextFolder() }   // never showed up: go on

    // the window of the folder we just opened, the moment Hyprland maps it
    Connections {
        target: Hyprland
        enabled: theme.nautilusOpening !== null
        function onRawEvent(event) {
            if (event.name !== "openwindow") return
            const args = event.parse(4)   // address, workspace, class, title
            if (!theme.isFiles(args[2]) || !theme.nautilusOpening) return
            openTimeout.stop()
            if (theme.nautilusOpening.w) theme.placeWindow("0x" + args[0], theme.nautilusOpening.w)
            theme.openNextFolder()
        }
    }
    function dsp(cmd) { Hyprland.dispatch(cmd) }
    function placeWindow(addr, w) {
        const win = 'window = "address:' + addr + '"'
        dsp('hl.dsp.window.move({ ' + win + ', workspace = "' + String(w.ws).replace(/"/g, '\\"') + '", follow = false })')
        if (w.floating) {
            dsp('hl.dsp.window.float({ ' + win + ', action = "set" })')
            dsp('hl.dsp.window.resize({ ' + win + ', x = ' + w.size[0] + ', y = ' + w.size[1] + ' })')
            dsp('hl.dsp.window.move({ ' + win + ', x = ' + w.at[0] + ', y = ' + w.at[1] + ' })')
        } else {
            nautilusTiled = nautilusTiled.concat([{ addr: addr, w: w }])
            tiledFix.restart()
        }
        if (w.fullscreen > 0)
            dsp('hl.dsp.window.fullscreen({ ' + win + ', action = "set", mode = "' + (w.fullscreen === 1 ? "maximized" : "fullscreen") + '" })')
    }

    // tiled windows: once Hyprland has laid them out, swap each into the spot it had
    // (with whatever window sits there now) and give it its old split size back
    Timer { id: tiledFix; interval: 350; onTriggered: { tiledProbe.running = false; tiledProbe.running = true } }
    Process {
        id: tiledProbe
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let clients = []
                try { clients = JSON.parse(this.text) } catch (e) { return }
                const same = (a, b) => a && b && a[0] === b[0] && a[1] === b[1]
                for (const t of theme.nautilusTiled) {
                    const me = clients.find(c => c.address === t.addr)
                    if (!me) continue
                    const win = 'window = "address:' + t.addr + '"'
                    if (!same(me.at, t.w.at)) {
                        const there = clients.find(c => c.address !== t.addr && !c.floating
                            && c.workspace.name === t.w.ws && same(c.at, t.w.at))
                        if (there) theme.dsp('hl.dsp.window.swap({ ' + win + ', target = "address:' + there.address + '" })')
                    }
                    if (!same(me.size, t.w.size))
                        theme.dsp('hl.dsp.window.resize({ ' + win + ', x = ' + t.w.size[0] + ', y = ' + t.w.size[1] + ' })')
                }
                theme.nautilusTiled = []
            }
        }
    }
    Process {
        id: live
        // foot: write the colors as escape codes into every open foot window's terminal.
        // fish: setting the universal variable makes every open shell reload its colors.
        command: ["sh", "-c", `
            osc="$1"
            for foot in $(pgrep -x foot); do
              for child in $(pgrep -P "$foot"); do
                tty=$(readlink "/proc/$child/fd/1" 2>/dev/null)
                case "$tty" in /dev/pts/*) printf '%b' "$osc" > "$tty" ;; esac
              done
            done
            command -v fish >/dev/null && fish -c "set -U gilgamesh_theme $2"
        `, "sh", theme.osc(), theme.name]
    }
    function osc() {
        const k = (key, fb) => c[key] || c[fb] || ""
        let s = "\\033]10;" + k("foreground") + "\\007\\033]11;" + k("background") + "\\007"
            + "\\033]12;" + k("bright_foreground", "foreground") + "\\007"
            + "\\033]17;" + k("selection", "lighter_background") + "\\007"
        terminalColors().forEach((col, i) => { s += "\\033]4;" + i + ";" + col + "\\007" })
        return s
    }
    // the 16 terminal colors, like Omarchy's templates
    function terminalColors() {
        const k = (key, fb) => c[key] || c[fb] || "#888888"
        return [k("background"), k("red"), k("green"), k("yellow"), k("blue"), k("magenta"), k("cyan"), k("foreground"),
                k("muted"), k("bright_red", "red"), k("bright_green", "green"), k("bright_yellow", "yellow"),
                k("bright_blue", "blue"), k("bright_magenta", "magenta"), k("bright_cyan", "cyan"), k("bright_foreground", "foreground")]
    }

    // the theme's wallpapers (themes/<name>/backgrounds): switching sets the wallpaper you last
    // picked with this theme, or its first one. (Your own folder, prefs.wallpaperFolder, stays.)
    readonly property string wallsDir: dir + "/" + name + "/backgrounds"
    Process {
        id: walls
        command: ["sh", "-c", "find \"$1\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) 2>/dev/null | sort",
                  "sh", theme.wallsDir]
        stdout: StdioCollector {
            onStreamFinished: {
                const files = this.text.trim().split("\n").filter(f => f !== "")
                if (files.length === 0) return
                const picked = (theme.shell.prefs.themeWallpapers || {})[theme.name]
                theme.shell.prefs.wallpaper = files.includes(picked) ? picked : files[0]
            }
        }
    }
    // remember the pick: any wallpaper chosen from this theme's own folder
    Connections {
        target: theme.shell.prefs
        function onWallpaperChanged() {
            const w = theme.shell.prefs.wallpaper
            // by folder name, so ~/.config/quickshell/... and the repo's own path both count
            if (!w || !w.includes("/themes/" + theme.name + "/backgrounds/")) return
            const map = Object.assign({}, theme.shell.prefs.themeWallpapers || {})
            if (map[theme.name] === w) return
            map[theme.name] = w
            theme.shell.prefs.themeWallpapers = map
        }
    }

    // ---------- theme files for other programs ----------
    FileView { id: footOut; printErrors: false; path: theme.outDir + "/foot.ini"; blockWrites: true }
    FileView { id: alacrittyOut; printErrors: false; path: theme.outDir + "/alacritty.toml"; blockWrites: true }
    FileView { id: fishOut; printErrors: false; path: theme.outDir + "/colors.fish"; blockWrites: true }
    FileView { id: fzfOut; printErrors: false; path: theme.outDir + "/fzf"; blockWrites: true }
    FileView { id: starshipOut; printErrors: false; path: theme.outDir + "/starship.toml"; blockWrites: true }
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || shell.home + "/.config"
    FileView { id: gtk4In; path: Qt.resolvedUrl("themed/gtk-4.0.css").toString().replace("file://", ""); onLoaded: theme.writeFiles() }
    FileView { id: gtk3In; path: Qt.resolvedUrl("themed/gtk-3.0.css").toString().replace("file://", ""); onLoaded: theme.writeFiles() }
    FileView { id: gtk4Out; printErrors: false; path: theme.configHome + "/gtk-4.0/gilgamesh.css"; blockWrites: true }
    FileView { id: gtk3Out; printErrors: false; path: theme.configHome + "/gtk-3.0/gilgamesh.css"; blockWrites: true }
    // gtk.css has to import gilgamesh.css: create it, or add the line (other CSS stays), once
    Process {
        id: gtkImport
        command: ["sh", "-c", `
            line='@import url("gilgamesh.css");'
            for v in gtk-4.0 gtk-3.0; do
              d="$1/$v"; mkdir -p "$d"
              [ -L "$d/gtk.css" ] && [ ! -e "$d/gtk.css" ] && rm "$d/gtk.css"   # dead link
              touch "$d/gtk.css"
              grep -Fqx "$line" "$d/gtk.css" || printf '%s\n' "$line" >> "$d/gtk.css"
            done`, "sh", theme.configHome]
    }
    FileView { id: starshipIn; path: theme.starshipBase; watchChanges: true; onFileChanged: reload(); onLoaded: theme.writeFiles() }

    function writeFiles() {
        if (!c.background) return
        const k = (key, fb) => c[key] || c[fb] || "#888888"
        const x = col => col.replace("#", "")
        const t = terminalColors()
        const head = "# Written by the Gilgamesh bar for the theme \"" + name + "\". Don't edit, switch themes instead.\n"

        footOut.setText(head + "[colors-dark]\n"
            + "foreground=" + x(k("foreground")) + "\nbackground=" + x(k("background")) + "\n"
            + "selection-foreground=" + x(k("foreground")) + "\nselection-background=" + x(k("selection", "lighter_background")) + "\n"
            + "cursor=" + x(k("background")) + " " + x(k("bright_foreground", "foreground")) + "\n"
            + t.slice(0, 8).map((col, i) => "regular" + i + "=" + x(col)).join("\n") + "\n"
            + t.slice(8).map((col, i) => "bright" + i + "=" + x(col)).join("\n") + "\n")

        const names8 = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        alacrittyOut.setText(head
            + "[colors.primary]\nbackground = \"" + k("background") + "\"\nforeground = \"" + k("foreground") + "\"\n\n"
            + "[colors.cursor]\ntext = \"" + k("background") + "\"\ncursor = \"" + k("bright_foreground", "foreground") + "\"\n\n"
            + "[colors.selection]\ntext = \"" + k("foreground") + "\"\nbackground = \"" + k("selection", "lighter_background") + "\"\n\n"
            + "[colors.normal]\n" + names8.map((n, i) => n + " = \"" + t[i] + "\"").join("\n") + "\n\n"
            + "[colors.bright]\n" + names8.map((n, i) => n + " = \"" + t[i + 8] + "\"").join("\n") + "\n")

        // same roles as the original jellybeans fish colors
        fishOut.setText(head
            + "set -g fish_color_normal " + x(k("foreground")) + "\n"
            + "set -g fish_color_command " + x(k("green")) + "\n"
            + "set -g fish_color_keyword " + x(k("magenta")) + "\n"
            + "set -g fish_color_param " + x(k("foreground")) + "\n"
            + "set -g fish_color_quote " + x(k("yellow")) + "\n"
            + "set -g fish_color_redirection " + x(k("cyan")) + "\n"
            + "set -g fish_color_end " + x(k("cyan")) + "\n"
            + "set -g fish_color_operator " + x(k("blue")) + "\n"
            + "set -g fish_color_escape " + x(k("cyan")) + "\n"
            + "set -g fish_color_error " + x(k("red")) + "\n"
            + "set -g fish_color_comment " + x(k("dark_foreground")) + " --italics\n"
            + "set -g fish_color_valid_path --underline\n"
            + "set -g fish_color_autosuggestion " + x(k("muted")) + "\n"
            + "set -g fish_color_selection --background=" + x(k("lighter_background")) + "\n"
            + "set -g fish_color_search_match --background=" + x(k("lighter_background")) + "\n"
            + "set -g fish_pager_color_prefix " + x(k("yellow")) + " --bold\n"
            + "set -g fish_pager_color_completion " + x(k("foreground")) + "\n"
            + "set -g fish_pager_color_description " + x(k("dark_foreground")) + "\n"
            + "set -g fish_pager_color_progress " + x(k("blue")) + "\n"
            + "set -g fish_pager_color_selected_background --background=" + x(k("lighter_background")) + "\n")

        fzfOut.setText("--color=bg:" + k("background") + ",bg+:" + k("lighter_background") + ",fg:" + k("foreground")
            + ",fg+:" + k("yellow") + ",hl:" + k("red") + ",hl+:" + k("red") + ",info:" + k("blue")
            + ",marker:" + k("green") + ",prompt:" + k("yellow") + ",spinner:" + k("magenta")
            + ",pointer:" + k("red") + ",header:" + k("cyan") + ",border:" + k("red") + "\n")

        // Nautilus / GTK: the theme's own gtk_* colors if it has them (jellybeans does),
        // otherwise from its palette, with a colored selection from its blue like the original
        const g = (key, val) => c["gtk_" + key] || val
        const sel = g("sel", mix(k("blue"), k("background"), 0.45).toString())
        const gtkVars = "@define-color jb_bg " + g("bg", k("background")) + ";\n"
            + "@define-color jb_bg_alt " + g("bg_alt", k("background")) + ";\n"
            + "@define-color jb_fg " + g("fg", k("foreground")) + ";\n"
            + "@define-color jb_fg_dim " + g("fg_dim", k("dark_foreground")) + ";\n"
            + "@define-color jb_sel " + sel + ";\n"
            + "@define-color jb_sel_fg " + g("sel_fg", k("bright_foreground", "foreground")) + ";\n"
            + "@define-color jb_red " + g("red", k("red")) + ";\n"
            + "@define-color jb_orange " + g("orange", k("orange", "yellow")) + ";\n"
            + "@define-color jb_scroll " + g("scroll", k("lighter_background")) + ";\n\n"
        const css = "/* Written by the Gilgamesh bar for the theme \"" + name + "\". Don't edit, switch themes instead. */\n"
        if (gtk4In.text()) gtk4Out.setText(css + gtkVars + gtk4In.text())
        if (gtk3In.text()) gtk3Out.setText(css + gtkVars + gtk3In.text())
        gtkImport.running = true

        // starship: the normal config with its palette swapped for this theme's colors
        const base = starshipIn.text()
        if (base) {
            const palette = "[palettes.jellybeans]\n"
                + "black = \"" + k("background") + "\"\nred = \"" + k("red") + "\"\ngreen = \"" + k("green") + "\"\n"
                + "yellow = \"" + k("yellow") + "\"\nblue = \"" + k("blue") + "\"\npurple = \"" + k("magenta") + "\"\n"
                + "cyan = \"" + k("cyan") + "\"\nwhite = \"" + k("foreground") + "\"\nbright_black = \"" + k("dark_foreground") + "\"\n"
            starshipOut.setText(base.replace(/\[palettes\.jellybeans\][\s\S]*$/, palette))
        }
    }

    // `qs ipc call theme set nord`, `qs ipc call theme list`
    IpcHandler {
        target: "theme"
        function set(name: string): string { return theme.set(name) ? "ok" : "no theme called " + name }
        function list(): string { return theme.names.join("\n") }
        function current(): string { return theme.name }
    }
}
