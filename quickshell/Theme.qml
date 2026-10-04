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
import "Paths.js" as Paths
import "Wallpaper.js" as Wallpaper

Scope {
    id: theme
    required property var shell
    readonly property string dir: Paths.fromFileUrl(Qt.resolvedUrl("themes"))
    readonly property string name: shell.prefs.theme || "jellybeans"
    readonly property string outDir: shell.stateDir + "/theme"
    // the shared prompt config: the repo's fish/starship.toml next to this folder (the bar's
    // folder is a symlink, so resolve it first), or a starship.toml next to it,
    // else ~/.config/starship.toml
    property string starshipBase: ""
    Process {
        running: true
        command: ["sh", "-c", "d=$(readlink -f \"$1\"); for f in \"$d/../fish/starship.toml\" \"$d/../starship.toml\"; do [ -f \"$f\" ] && { readlink -f \"$f\"; exit; }; done; echo \"${XDG_CONFIG_HOME:-$HOME/.config}/starship.toml\"",
                  "sh", Paths.fromFileUrl(Qt.resolvedUrl("."))]
        stdout: StdioCollector { onStreamFinished: theme.starshipBase = this.text.replace(/\n$/, "") }
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
        const out = Object.create(null)
        for (const line of text.split("\n")) {
            const m = line.match(/^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"/)
            if (!m || m[1] === "mode") continue
            if (!/^#[0-9A-Fa-f]{6}$/.test(m[2])) return null
            out[m[1]] = m[2]
        }
        return out.background && out.foreground ? out : null
    }
    FileView {
        path: theme.dir + "/" + theme.name + "/colors.toml"
        watchChanges: true
        onFileChanged: theme.refresh()
    }

    property var wallCounts: ({})
    property bool catalogReady: false
    property string error: ""
    function refresh() {
        if (!lister.running) { lister.pending = true; lister.running = true }
        counter.running = true
    }
    Process {
        id: counter
        command: ["sh", "-c", "for d in \"$1\"/*/; do n=$(find \"$d/backgrounds\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) -printf x 2>/dev/null | wc -c); base=${d%/}; printf '%s\\0%s\\0' \"${base##*/}\" \"$n\"; done", "sh", theme.dir]
        stdout: StdioCollector {
            onStreamFinished: {
                const m = Object.create(null), fields = this.text.split("\0")
                for (let i = 0; i + 1 < fields.length; i += 2)
                    if (fields[i] && Number(fields[i + 1]) > 0) m[fields[i]] = Number(fields[i + 1])
                if (JSON.stringify(m) !== JSON.stringify(theme.wallCounts)) theme.wallCounts = m
            }
        }
    }
    Component.onCompleted: refresh()
    Process {
        id: lister
        property bool pending: false
        command: ["sh", "-c", "for f in \"$1\"/*/colors.toml; do [ -f \"$f\" ] || continue; d=${f%/colors.toml}; printf '%s\\0' \"${d##*/}\"; cat \"$f\" || exit 1; printf '\\0'; done", "sh", theme.dir]
        stdout: StdioCollector { id: catalogOutput }
        onExited: (code, status) => {
            pending = false
            if (code !== 0 || status !== 0) { theme.catalogReady = false; theme.error = "Could not load themes."; return }
            const all = Object.create(null), fields = catalogOutput.text.split("\0")
            for (let i = 0; i + 1 < fields.length; i += 2) {
                const palette = theme.parse(fields[i + 1])
                if (palette) all[fields[i]] = palette
            }
            if (JSON.stringify(all) !== JSON.stringify(theme.palettes)) theme.palettes = all
            theme.catalogReady = true
            if (!theme.transaction && !theme.pendingTheme && Object.prototype.hasOwnProperty.call(all, theme.name)
                    && JSON.stringify(theme.c) !== JSON.stringify(all[theme.name]))
                theme.requestTheme(theme.name, false)
        }
        onRunningChanged: if (!running && pending) {
            pending = false
            theme.catalogReady = false
            theme.error = "Could not load themes."
        }
    }

    // One captured palette owns the writes and restart until restoration finishes.
    property var transaction: null
    property var pendingTheme: null
    property int themeRevision: 0
    property string phase: ""
    function set(newName) {
        if (!catalogReady || !Object.prototype.hasOwnProperty.call(palettes, newName)) return false
        requestTheme(newName, true)
        return true
    }
    function requestTheme(newName, liveApply) {
        pendingTheme = { name: newName, live: liveApply, revision: wallpaperRevision, id: ++themeRevision }
        Qt.callLater(startTheme)
    }
    function startTheme() {
        if (transaction || !pendingTheme || !gtk4In.loaded || !gtk3In.loaded || !starshipIn.loaded) return
        const next = pendingTheme
        pendingTheme = null
        if (!catalogReady || !Object.prototype.hasOwnProperty.call(palettes, next.name)) return
        transaction = { name: next.name, palette: Object.assign({}, palettes[next.name]),
                        live: next.live, revision: next.revision, id: next.id }
        error = ""
        phase = "writing"
        writeFiles()
    }
    function finishTheme(message) {
        if (message) { error = message; console.warn(message) }
        phase = ""
        transaction = null
        if (!pendingTheme && !message && catalogReady && Object.prototype.hasOwnProperty.call(palettes, name)
                && JSON.stringify(c) !== JSON.stringify(palettes[name])) requestTheme(name, false)
        Qt.callLater(startTheme)
        Qt.callLater(ensureWallpaper)
    }
    function applyLive() {
        phase = "live"
        live.command = ["sh", "-c", live.script, "sh", osc(), transaction.name]
        live.running = true
        pendingWalls = { name: transaction.name, folder: dir + "/" + transaction.name + "/backgrounds",
                         revision: transaction.revision, id: transaction.id, keepCurrent: false,
                         current: shell.prefs.wallpaper, remembered: rememberedWallpaper(transaction.name) }
        startWalls()
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
        const path = Paths.fromFileUrl(uri).replace(/\/+$/, "")
        if (!path) return uri === "file:///" ? "/" : ""
        if (path === shell.home) return "Home"
        return path.slice(path.lastIndexOf("/") + 1)
    }
    function locations(text) {
        const result = JSON.parse(text)
        if (result.type !== "a{sas}" || !result.data || Array.isArray(result.data)
                || typeof result.data !== "object") throw new Error("Invalid locations")
        for (const key of Object.keys(result.data)) {
            const list = result.data[key]
            // Do not close windows whose tabs cannot all be restored by this code.
            if (!Array.isArray(list) || list.length !== 1 || typeof list[0] !== "string"
                    || !folderTitle(list[0])) throw new Error("Unrecoverable location")
        }
        return result.data
    }
    function snapshot(text) {
        const parts = text.split("\0")
        if (parts.length !== 2) throw new Error("Incomplete snapshot")
        const locs = locations(parts[0]), clients = JSON.parse(parts[1])
        if (!Array.isArray(clients)) throw new Error("Invalid windows")
        const wins = clients.filter(c => isFiles(c.class))
        const uris = Object.values(locs).map(l => l[0])
        if (wins.length !== uris.length || wins.length === 0) throw new Error("Incomplete locations")
        const pair = v => Array.isArray(v) && v.length === 2 && v.every(Number.isFinite)
        const queue = []
        for (const uri of uris) {
            const title = folderTitle(uri)
            if (uris.some(u => u !== uri && folderTitle(u) === title)) throw new Error("Ambiguous titles")
            const i = wins.findIndex(w => w.title === title)
            if (i < 0) throw new Error("Missing window")
            const w = wins.splice(i, 1)[0]
            if (!w.workspace || typeof w.workspace.name !== "string" || !pair(w.at) || !pair(w.size)
                    || typeof w.floating !== "boolean" || !Number.isInteger(w.fullscreen))
                throw new Error("Invalid placement")
            queue.push({ uri: uri, w: { ws: w.workspace.name, floating: w.floating,
                        fullscreen: w.fullscreen, at: w.at, size: w.size } })
        }
        return queue
    }
    readonly property string locationCommand: "busctl --user --json=short get-property org.freedesktop.FileManager1 /org/freedesktop/FileManager1 org.freedesktop.FileManager1 OpenWindowsWithLocations"
    Process {
        id: nautilusWindows
        command: ["sh", "-c", "pgrep -x nautilus >/dev/null || pgrep -x .nautilus-wrapp >/dev/null || exit 3; "
            + "locations=$(" + theme.locationCommand + ") || exit 1; clients=$(hyprctl clients -j) || exit 1; printf '%s\\0%s' \"$locations\" \"$clients\""]
        stdout: StdioCollector { id: snapshotOutput }
        onExited: (code, status) => {
            if (code === 3 && status === 0) { theme.finishTheme(""); return }
            try {
                if (code !== 0 || status !== 0) throw new Error("Snapshot failed")
                theme.nautilusQueue = theme.snapshot(snapshotOutput.text)
            } catch (e) {
                theme.finishTheme("Theme applied; Files was left open because its locations could not be safely recovered.")
                return
            }
            theme.nautilusTiled = []
            theme.phase = "quitting"
            nautilusQuit.running = true
        }
        onRunningChanged: if (!running && theme.phase === "snapshot")
            theme.finishTheme("Theme applied; could not snapshot Files. Its windows were left open.")
    }
    Process {
        id: nautilusQuit
        command: ["sh", "-c", `
            nautilus -q || exit 1
            for i in $(seq 50); do
              pgrep -x nautilus >/dev/null || pgrep -x .nautilus-wrapp >/dev/null || exit 0
              sleep 0.1
            done
            exit 1`]
        onExited: (code, status) => {
            if (code === 0 && status === 0) { theme.knownLocations = {}; theme.openNextFolder() }
            else theme.stopRestore("Files did not exit; automatic restoration stopped.")
        }
        onRunningChanged: if (!running && theme.phase === "quitting")
            theme.stopRestore("Could not restart Files.")
    }
    property var knownLocations: ({})
    property var candidateAddresses: []
    property bool restoreBlocked: false
    function stopRestore(message) {
        openTimeout.stop()
        correlationTimer.stop()
        nautilusOpening = null
        restoreBlocked = true
        // Retain the unprocessed queue for diagnosis; never mistake a late window for the next one.
        phase = "settling"
        error = message
        settleRestore()
    }
    function settleRestore() {
        if (phase !== "settling" || nautilusOpening || correlationProbe.running || nautilusOpen.running
                || tiledFix.running || tiledProbe.running) return
        finishTheme(error)
    }
    Process {
        id: nautilusOpen
        onExited: (code, status) => {
            if (code !== 0 || status !== 0) theme.stopRestore("Could not reopen a Files window.")
            else if (theme.phase === "settling") Qt.callLater(theme.settleRestore)
        }
        onRunningChanged: if (!running) Qt.callLater(theme.settleRestore)
    }
    function openNextFolder() {
        if (nautilusQueue.length === 0) {
            nautilusOpening = null
            phase = "settling"
            settleRestore()
            return
        }
        phase = "opening"
        nautilusOpening = nautilusQueue[0]
        candidateAddresses = []
        nautilusOpen.command = ["sh", "-c", "nautilus --new-window \"$1\" >/dev/null 2>&1 &", "sh", nautilusOpening.uri]
        nautilusOpen.running = true
        openTimeout.restart()
    }
    Timer {
        id: openTimeout
        interval: 5000
        onTriggered: theme.stopRestore("A Files window could not be identified. Automatic restarts are disabled until the bar is reloaded.")
    }
    Connections {
        target: Hyprland
        enabled: theme.nautilusOpening !== null
        function onRawEvent(event) {
            if (event.name !== "openwindow" || !theme.nautilusOpening) return
            const args = event.parse(4)
            if (!theme.isFiles(args[2]) || !/^[0-9a-fA-F]+$/.test(args[0])) return
            theme.candidateAddresses = theme.candidateAddresses.concat(["0x" + args[0]])
            correlationTimer.restart()
        }
    }
    Timer {
        id: correlationTimer
        interval: 100
        onTriggered: if (theme.nautilusOpening && !correlationProbe.running) correlationProbe.running = true
    }
    Process {
        id: correlationProbe
        command: ["sh", "-c", "locations=$(" + theme.locationCommand + ") || exit 1; clients=$(hyprctl clients -j) || exit 1; printf '%s\\0%s' \"$locations\" \"$clients\""]
        stdout: StdioCollector { id: correlationOutput }
        onExited: (code, status) => {
            const opening = theme.nautilusOpening
            if (!opening) { Qt.callLater(theme.settleRestore); return }
            try {
                if (code !== 0 || status !== 0) throw new Error("Probe failed")
                const parts = correlationOutput.text.split("\0"), locs = theme.locations(parts[0])
                const added = Object.keys(locs).filter(k => !Object.prototype.hasOwnProperty.call(theme.knownLocations, k))
                const clients = JSON.parse(parts[1]).filter(c => theme.candidateAddresses.includes(c.address)
                    && theme.isFiles(c.class) && c.title === theme.folderTitle(opening.uri))
                if (added.length !== 1 || locs[added[0]][0] !== opening.uri || clients.length !== 1)
                    throw new Error("Window not uniquely identified")
                openTimeout.stop()
                correlationTimer.stop()
                theme.placeWindow(clients[0].address, opening.w)
                theme.knownLocations = locs
                theme.nautilusQueue = theme.nautilusQueue.slice(1)
                theme.nautilusOpening = null
                Qt.callLater(theme.openNextFolder)
            } catch (e) { correlationTimer.restart() }
        }
        onRunningChanged: if (!running && theme.phase === "settling") Qt.callLater(theme.settleRestore)
    }
    function luaString(value) {
        return '"' + String(value).replace(/[\\"\x00-\x1f\x7f]/g, ch => {
            if (ch === '\\') return '\\\\'
            if (ch === '"') return '\\"'
            return '\\' + String(ch.charCodeAt(0)).padStart(3, "0")
        }) + '"'
    }
    function dsp(cmd) { Hyprland.dispatch(cmd) }
    function placeWindow(addr, w) {
        const win = 'window = "address:' + addr + '"'
        dsp('hl.dsp.window.move({ ' + win + ', workspace = ' + luaString(w.ws) + ', follow = false })')
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
    Timer {
        id: tiledFix
        interval: 350
        onTriggered: {
            if (tiledProbe.running) { restart(); return }
            tiledProbe.windows = theme.nautilusTiled
            theme.nautilusTiled = []
            tiledProbe.running = true
        }
    }
    Process {
        id: tiledProbe
        property var windows: []
        onRunningChanged: if (!running && theme.phase === "settling") Qt.callLater(theme.settleRestore)
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                let clients = []
                try { clients = JSON.parse(this.text) } catch (e) { return }
                const same = (a, b) => a && b && a[0] === b[0] && a[1] === b[1]
                for (const t of tiledProbe.windows) {
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
                tiledProbe.windows = []
            }
        }
    }
    Process {
        id: live
        // foot: write the colors as escape codes into every open foot window's terminal.
        // fish: setting the universal variable makes every open shell reload its colors.
        property string script: `
            osc="$1"
            for foot in $(pgrep -x foot); do
              for child in $(pgrep -P "$foot"); do
                tty=$(readlink "/proc/$child/fd/1" 2>/dev/null)
                case "$tty" in /dev/pts/*) printf '%b' "$osc" > "$tty" ;; esac
              done
            done
            command -v fish >/dev/null && fish -c 'set -U gilgamesh_theme "$argv[1]"' -- "$2"
        `
        onExited: (code, status) => {
            if (code !== 0 || status !== 0) { theme.finishTheme("Theme files saved, but live terminal updates failed."); return }
            if (theme.restoreBlocked) { theme.finishTheme("Theme applied; Files restart remains disabled after an uncertain restore."); return }
            theme.phase = "snapshot"
            nautilusWindows.running = true
        }
        onRunningChanged: if (!running && theme.phase === "live") theme.finishTheme("Could not apply the theme live.")
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
    function terminalColors(palette = c) {
        const k = (key, fb) => palette[key] || palette[fb] || "#888888"
        return [k("background"), k("red"), k("green"), k("yellow"), k("blue"), k("magenta"), k("cyan"), k("foreground"),
                k("muted"), k("bright_red", "red"), k("bright_green", "green"), k("bright_yellow", "yellow"),
                k("bright_blue", "blue"), k("bright_magenta", "magenta"), k("bright_cyan", "cyan"), k("bright_foreground", "foreground")]
    }

    // the theme's wallpapers (themes/<name>/backgrounds): switching sets the wallpaper you last
    // picked with this theme, or its first one. (Your own folder, prefs.wallpaperFolder, stays.)
    readonly property string wallsDir: dir + "/" + name + "/backgrounds"
    property int wallpaperRevision: 0
    property var pendingWalls: null
    function rememberedWallpaper(themeName) { return (shell.prefs.themeWallpapers || {})[themeName] || "" }
    function wallpaperBusy() {
        // Startup palette writes may wait for templates; they do not choose a wallpaper.
        return (pendingTheme && (pendingTheme.live || pendingTheme.name !== name))
            || (transaction && (transaction.live || transaction.name !== name))
    }
    // Wait for preferences before selecting a first-run default. Share the theme-switch queue
    // and revisions so a late scan cannot replace a newer theme or a manual wallpaper pick.
    function ensureWallpaper() {
        if (!shell.prefsReady || wallpaperBusy() || (pendingWalls && !pendingWalls.keepCurrent)) return
        pendingWalls = { name: name, folder: wallsDir, revision: wallpaperRevision, id: themeRevision,
                         keepCurrent: true, current: shell.prefs.wallpaper, remembered: rememberedWallpaper(name) }
        startWalls()
    }
    onNameChanged: Qt.callLater(ensureWallpaper)
    function startWalls() {
        if (walls.request || !pendingWalls) return
        walls.request = pendingWalls
        pendingWalls = null
        walls.command = Wallpaper.scanCommand(dir, walls.request)
        walls.running = true
    }
    Process {
        id: walls
        property var request: null
        stdout: StdioCollector { id: wallsOutput }
        onExited: (code, status) => {
            const r = request
            if (code === 0 && status === 0 && theme.shell.prefsReady
                    && Wallpaper.isCurrent(r, theme.name, theme.wallpaperRevision, theme.themeRevision,
                        r && r.keepCurrent ? theme.wallpaperBusy() : theme.pendingTheme,
                        theme.shell.prefs.wallpaper, theme.rememberedWallpaper(theme.name))) {
                // Only paths confirmed by -f / find -type f reach prefs and the picker.
                theme.shell.prefs.wallpaper = Wallpaper.firstFile(wallsOutput.text)
            } else if (r && code === 0 && status === 0) Qt.callLater(theme.ensureWallpaper)
            request = null
            Qt.callLater(theme.startWalls)
        }
        onRunningChanged: if (!running && request) {
            request = null
            Qt.callLater(theme.startWalls)
        }
    }
    // remember the pick: any wallpaper chosen from this theme's own folder
    Connections {
        target: theme.shell.prefs
        function onWallpaperChanged() {
            theme.wallpaperRevision++
            Qt.callLater(theme.ensureWallpaper)
            const w = theme.shell.prefs.wallpaper
            // by folder name, so ~/.config/quickshell/... and the repo's own path both count
            if (!w || !w.includes("/themes/" + theme.name + "/backgrounds/")) return
            const map = Object.assign(Object.create(null), theme.shell.prefs.themeWallpapers || {})
            if (map[theme.name] === w) return
            map[theme.name] = w
            theme.shell.prefs.themeWallpapers = map
        }
        function onThemeWallpapersChanged() { Qt.callLater(theme.ensureWallpaper) }
    }

    // ---------- theme files for other programs ----------
    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || shell.home + "/.config"
    FileView {
        id: gtk4In
        path: Paths.fromFileUrl(Qt.resolvedUrl("themed/gtk-4.0.css"))
        onLoaded: Qt.callLater(theme.startTheme)
        onLoadFailed: theme.error = "Could not read the GTK template; theme selection was not changed."
    }
    FileView {
        id: gtk3In
        path: Paths.fromFileUrl(Qt.resolvedUrl("themed/gtk-3.0.css"))
        onLoaded: Qt.callLater(theme.startTheme)
        onLoadFailed: theme.error = "Could not read the GTK template; theme selection was not changed."
    }
    FileView {
        id: starshipIn
        path: theme.starshipBase
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            if (!theme.transaction && !theme.pendingTheme && theme.catalogReady) theme.requestTheme(theme.name, false)
            else Qt.callLater(theme.startTheme)
        }
        onLoadFailed: theme.error = "Could not read the prompt template; theme selection was not changed."
    }
    Process {
        id: writer
        // Each file is replaced atomically off the UI thread. A failed batch never applies live.
        property string script: `
            set -eu
            config=$1; shift
            tmp=
            trap 'if [ -n "$tmp" ]; then rm -f -- "$tmp"; fi' EXIT HUP INT TERM
            while [ "$#" -gt 0 ]; do
              path=$1; data=$2; shift 2
              dir=\${path%/*}
              mkdir -p -- "$dir"
              tmp=$(mktemp "$dir/.gilgamesh-theme.XXXXXX")
              printf '%s' "$data" > "$tmp"
              mv -f -- "$tmp" "$path"
              tmp=
            done
            line='@import url("gilgamesh.css");'
            for v in gtk-4.0 gtk-3.0; do
              path="$config/$v/gtk.css"
              [ ! -L "$path" ] || [ -e "$path" ] || rm -- "$path"
              touch -- "$path"
              grep -Fqx "$line" "$path" || printf '%s\n' "$line" >> "$path"
            done`
        onExited: (code, status) => {
            if (code !== 0 || status !== 0) { theme.finishTheme("Could not save theme files; selection was not changed."); return }
            theme.c = theme.transaction.palette
            theme.shell.prefs.theme = theme.transaction.name
            if (theme.transaction.live) theme.applyLive()
            else theme.finishTheme("")
        }
        onRunningChanged: if (!running && theme.phase === "writing")
            theme.finishTheme("Could not start the theme writer; selection was not changed.")
    }

    function writeFiles() {
        const palette = transaction.palette
        const output = ["sh", "-c", writer.script, "sh", configHome]
        const save = (path, data) => { output.push(path, data) }
        const k = (key, fb) => palette[key] || palette[fb] || "#888888"
        const x = col => col.replace("#", "")
        const t = terminalColors(palette)
        const head = "# Written by the Gilgamesh bar. Don't edit, switch themes instead.\n"

        save(outDir + "/foot.ini", head + "[colors-dark]\n"
            + "foreground=" + x(k("foreground")) + "\nbackground=" + x(k("background")) + "\n"
            + "selection-foreground=" + x(k("foreground")) + "\nselection-background=" + x(k("selection", "lighter_background")) + "\n"
            + "cursor=" + x(k("background")) + " " + x(k("bright_foreground", "foreground")) + "\n"
            + t.slice(0, 8).map((col, i) => "regular" + i + "=" + x(col)).join("\n") + "\n"
            + t.slice(8).map((col, i) => "bright" + i + "=" + x(col)).join("\n") + "\n")

        const names8 = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white"]
        save(outDir + "/alacritty.toml", head
            + "[colors.primary]\nbackground = \"" + k("background") + "\"\nforeground = \"" + k("foreground") + "\"\n\n"
            + "[colors.cursor]\ntext = \"" + k("background") + "\"\ncursor = \"" + k("bright_foreground", "foreground") + "\"\n\n"
            + "[colors.selection]\ntext = \"" + k("foreground") + "\"\nbackground = \"" + k("selection", "lighter_background") + "\"\n\n"
            + "[colors.normal]\n" + names8.map((n, i) => n + " = \"" + t[i] + "\"").join("\n") + "\n\n"
            + "[colors.bright]\n" + names8.map((n, i) => n + " = \"" + t[i + 8] + "\"").join("\n") + "\n")

        // same roles as the original jellybeans fish colors
        save(outDir + "/colors.fish", head
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

        save(outDir + "/fzf", "--color=bg:" + k("background") + ",bg+:" + k("lighter_background") + ",fg:" + k("foreground")
            + ",fg+:" + k("yellow") + ",hl:" + k("red") + ",hl+:" + k("red") + ",info:" + k("blue")
            + ",marker:" + k("green") + ",prompt:" + k("yellow") + ",spinner:" + k("magenta")
            + ",pointer:" + k("red") + ",header:" + k("cyan") + ",border:" + k("red") + "\n")

        // Nautilus / GTK: the theme's own gtk_* colors if it has them (jellybeans does),
        // otherwise from its palette, with a colored selection from its blue like the original
        const g = (key, val) => palette["gtk_" + key] || val
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
        const css = "/* Written by the Gilgamesh bar. Don't edit, switch themes instead. */\n"
        save(configHome + "/gtk-4.0/gilgamesh.css", css + gtkVars + gtk4In.text())
        save(configHome + "/gtk-3.0/gilgamesh.css", css + gtkVars + gtk3In.text())

        // starship: the normal config with its palette swapped for this theme's colors
        const base = starshipIn.text()
        const promptPalette = "[palettes.jellybeans]\n"
            + "black = \"" + k("background") + "\"\nred = \"" + k("red") + "\"\ngreen = \"" + k("green") + "\"\n"
            + "yellow = \"" + k("yellow") + "\"\nblue = \"" + k("blue") + "\"\npurple = \"" + k("magenta") + "\"\n"
            + "cyan = \"" + k("cyan") + "\"\nwhite = \"" + k("foreground") + "\"\nbright_black = \"" + k("dark_foreground") + "\"\n"
        save(outDir + "/starship.toml", /\[palettes\.jellybeans\]/.test(base)
            ? base.replace(/\[palettes\.jellybeans\][\s\S]*$/, promptPalette) : base + "\n" + promptPalette)
        writer.command = output
        writer.running = true
    }

    // `qs ipc call theme set nord`, `qs ipc call theme list`
    IpcHandler {
        target: "theme"
        function set(name: string): string { return theme.set(name) ? "ok" : theme.catalogReady ? "no valid theme called " + name : "theme catalog is not loaded" }
        function list(): string { return theme.names.join("\n") }
        function current(): string { return theme.name }
    }
}
