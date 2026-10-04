//@ pragma IconTheme Papirus-Dark
// Gilgamesh bar, v1 (Hyprland, jellybeans palette like the fish prompt)
// Quickshell 0.3.1. Save this file and the bar reloads by itself.
//
//  永 [1][2][3]                  14:32 (click: calendar)        ▶ song  tray  bell  net  mic 80%  vol 65%

import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.SystemTray
import Quickshell.Services.Pipewire
import Quickshell.Networking
import Quickshell.Io
import Quickshell.Services.Notifications
import Quickshell.Services.Mpris
import QtQuick
import QtQuick.Layouts
import "Paths.js" as Paths

ShellRoot {
    id: root

    // colors come from the current theme (Theme.qml, themes/), and fade when it changes
    Theme { id: themeEngine; shell: root }
    readonly property var theme: themeEngine
    property color bg: themeEngine.bg
    property color bgDark: themeEngine.bgDark         // sidebars
    property color bgAlt: themeEngine.bgAlt
    property color fg: themeEngine.fg
    property color dim: themeEngine.dim
    property color faint: themeEngine.faint           // disabled text, placeholders
    property color red: themeEngine.red
    property color critical: themeEngine.critical     // only for critical notifications
    property color green: themeEngine.green
    property color yellow: themeEngine.yellow
    property color blue: themeEngine.blue
    property color purple: themeEngine.purple
    property color cyan: themeEngine.cyan
    property color hover: themeEngine.hover           // row hover
    property color hoverStrong: themeEngine.hoverStrong   // button hover
    Behavior on bg { ColorAnimation { duration: 400 } }
    Behavior on bgDark { ColorAnimation { duration: 400 } }
    Behavior on bgAlt { ColorAnimation { duration: 400 } }
    Behavior on fg { ColorAnimation { duration: 400 } }
    Behavior on dim { ColorAnimation { duration: 400 } }
    Behavior on faint { ColorAnimation { duration: 400 } }
    Behavior on red { ColorAnimation { duration: 400 } }
    Behavior on green { ColorAnimation { duration: 400 } }
    Behavior on yellow { ColorAnimation { duration: 400 } }
    Behavior on blue { ColorAnimation { duration: 400 } }
    Behavior on purple { ColorAnimation { duration: 400 } }
    Behavior on cyan { ColorAnimation { duration: 400 } }
    Behavior on hover { ColorAnimation { duration: 400 } }
    Behavior on hoverStrong { ColorAnimation { duration: 400 } }

    // the 永 logo in the theme's colors (the SVG's own green/dark swapped at load)
    property string logoSvg: ""
    FileView { path: Paths.fromFileUrl(Qt.resolvedUrl("gilgamesh-logo.svg")); onLoaded: root.logoSvg = text() }
    readonly property string logo: logoSvg
        ? "data:image/svg+xml;utf8," + encodeURIComponent(logoSvg.replace(/#99ad6a/gi, themeEngine.green.toString()).replace(/#151515/gi, themeEngine.bg.toString()))
        : Qt.resolvedUrl("gilgamesh-logo.svg")

    readonly property string font: "Inter"                        // all text
    readonly property string iconFont: "JetBrainsMono Nerd Font"  // icons
    readonly property int fontSize: 17

    // Nerd Font icons by codepoint (typing them directly risks them getting lost)
    function icon(cp) { return String.fromCodePoint(cp) }
    // an icon inside a sentence (rich text), so the words stay in Inter
    function iconHtml(cp) { return "<span style=\"font-family:'" + iconFont + "'\">" + icon(cp) + "</span>" }

    // keep the default speaker/mic objects live so volume + mute stay up to date
    PwObjectTracker { objects: [ Pipewire.defaultAudioSink, Pipewire.defaultAudioSource ] }
    readonly property var sink: Pipewire.defaultAudioSink?.audio ?? null
    readonly property var source: Pipewire.defaultAudioSource?.audio ?? null

    SystemClock { id: clock; precision: SystemClock.Minutes }

    // ---------- settings state: $XDG_STATE_HOME/gilgamesh/settings.json ----------
    readonly property string home: Quickshell.env("HOME")
    readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/gilgamesh"
    readonly property var prefs: prefsAdapter
    property bool prefsReady: false
    Process { running: true; command: ["mkdir", "-p", root.stateDir + "/theme"] }
    FileView {
        path: root.stateDir + "/settings.json"
        watchChanges: true
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()
        onLoaded: { root.prefsReady = true; Qt.callLater(themeEngine.ensureWallpaper) }
        onLoadFailed: {
            writeAdapter()   // first run: create it with the defaults below
            root.prefsReady = true
            Qt.callLater(themeEngine.ensureWallpaper)
        }
        JsonAdapter {
            id: prefsAdapter
            property string wallpaperFolder: ""   // empty = the user's Pictures folder
            property string wallpaper: ""         // empty or missing file = a theme background
            property bool barTransparent: false   // toggled by double-clicking the bar
            property string theme: ""             // empty = jellybeans
            property var themeWallpapers: ({})    // theme -> the wallpaper you last picked with it
            property string musicFolder: ""       // empty = the user's Music folder
            property real musicVolume: 1          // local music volume, 0..1, kept across restarts
        }
    }

    // the user's Pictures and Music folders, from the standard XDG user-dirs file
    property string picturesDir: home + "/Pictures"
    property string musicDir: home + "/Music"
    function userDir(contents, key) {
        const m = contents.match(new RegExp('^XDG_' + key + '_DIR="((?:\\\\[\\s\\S]|[^"\\\\])*)"[ \\t]*(?:#.*)?$', "m"))
        if (!m) return ""
        let value = m[1], result = ""
        const prefix = value.match(/^\$(?:HOME|\{HOME\})(?=\/|$)/)
        if (prefix) { result = home; value = value.slice(prefix[0].length) }
        // Decode double-quoted shell escapes, without expanding variables or commands.
        for (let i = 0; i < value.length; i++) {
            const c = value[i]
            if (c === "\\" && i + 1 < value.length) {
                const next = value[++i]
                if (next === "\n") continue
                result += '\\"$`'.includes(next) ? next : "\\" + next
            } else if (c === "$" || c === "`") return ""
            else result += c
        }
        return result.startsWith("/") ? result : ""
    }
    FileView {
        path: (Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/user-dirs.dirs"
        onLoaded: {
            root.picturesDir = root.userDir(text(), "PICTURES") || root.picturesDir
            root.musicDir = root.userDir(text(), "MUSIC") || root.musicDir
        }
    }
    readonly property string wallpaperFolder: prefs.wallpaperFolder || picturesDir
    readonly property string musicFolder: prefs.musicFolder || musicDir

    // ---------- media ----------
    // Local music (MusicPlayer.qml) plus every MPRIS player that has a track. Which one the bar
    // and the media card show is sticky, because players blink "not playing" for a moment
    // between songs and after seeks:
    //  - the one you picked in the card stays until a different player starts playing
    //  - otherwise the shown one stays while it plays, or while nothing plays
    //  - moving to another player that plays happens after 1.5s, so blinks don't flip it
    MusicPlayer { id: musicPlayer; shell: root }
    readonly property var music: musicPlayer
    property var mediaPick: null
    property var mediaShown: null
    readonly property var mediaList: (music.active ? [music] : [])
        .concat(Mpris.players.values.filter(p => p.trackTitle !== ""))
    readonly property var mediaWanted: {
        const list = mediaList, cur = mediaShown
        if (mediaPick && list.includes(mediaPick)) return mediaPick
        const curOk = !!cur && list.includes(cur)
        if (curOk && (cur.isPlaying || !list.some(p => p.isPlaying))) return cur
        return list.find(p => p.isPlaying) ?? (curOk ? cur : list[0]) ?? null
    }
    // (applied a tick later: mediaWanted reads mediaShown, setting it inside would loop)
    function showWanted() { mediaShown = mediaWanted }
    onMediaWantedChanged: {
        if (!mediaShown || !mediaList.includes(mediaShown) || mediaWanted === mediaPick) {
            mediaSwitch.stop()
            Qt.callLater(showWanted)
        } else mediaSwitch.restart()
    }
    Timer { id: mediaSwitch; interval: 1500; onTriggered: root.showWanted() }
    readonly property var media: mediaShown && mediaList.includes(mediaShown) ? mediaShown : mediaWanted
    // a different player starting to play ends your pick
    function playerStarted(p) { if (mediaPick && p !== mediaPick) mediaPick = null }
    Connections { target: root.music; function onIsPlayingChanged() { if (root.music.isPlaying) root.playerStarted(root.music) } }
    Variants {
        model: Mpris.players.values
        Connections {
            required property var modelData
            target: modelData
            function onIsPlayingChanged() { if (modelData.isPlaying) root.playerStarted(modelData) }
        }
    }

    // WCAG contrast ratio, used to pick readable text on a transparent bar
    function luminance(c) {
        const f = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }
    function contrast(a, b) {
        const x = luminance(a), y = luminance(b)
        return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
    }

    // ---------- RAM: used = total - available (what `free` and htop call used) ----------
    property real memTotal: 0     // kB
    property real memUsed: 0
    FileView {
        id: meminfo
        path: "/proc/meminfo"
        onLoaded: {
            const t = text()
            const total = /^MemTotal:\s+(\d+)/m.exec(t)
            const available = /^MemAvailable:\s+(\d+)/m.exec(t)
            root.memTotal = total ? Number(total[1]) : 0
            root.memUsed = root.memTotal - (available ? Number(available[1]) : 0)
        }
    }
    Timer { interval: 2000; running: true; repeat: true; triggeredOnStart: true; onTriggered: meminfo.reload() }

    // app launcher (Launcher.qml), Super+D; wallpaper picker (WallpaperPicker.qml), Super+W
    Launcher { id: launcher; shell: root }
    WallpaperPicker { id: wallPicker; shell: root }
    function pickWallpaper() { wallPicker.show() }

    // Gilgamesh Settings window (Settings.qml), opened from the launcher or a right click on the logo
    Settings { id: settings; shell: root; visible: false }
    function openSettings(page) { if (page) settings.page = page; settings.visible = true }
    readonly property var settingsPages: settings.pages

    // `qs ipc call media playPause|next|previous` (the media keys, see hyprland.lua)
    IpcHandler {
        target: "media"
        function playPause(): void { if (root.media) root.media.togglePlaying(); else root.music.togglePlaying() }
        function next(): void { if (root.media?.canGoNext) root.media.next() }
        function previous(): void { if (root.media?.canGoPrevious) root.media.previous() }
        function playTrack(index: int): void { root.music.play(index) }
        function open(): void { root.mediaCardRequest++ }
    }
    property int mediaCardRequest: 0   // bumped by `qs ipc call media open`

    // `qs ipc call wallpaper set <file>` (a picture from anywhere; it doesn't change the folder),
    // `qs ipc call wallpaper pick` (the picker in the middle of the screen)
    IpcHandler {
        target: "wallpaper"
        function set(path: string): void { root.prefs.wallpaper = path }
        function get(): string { return root.prefs.wallpaper }
        function pick(): void { root.pickWallpaper() }
        function closePicker(): void { wallPicker.open = false }
    }

    // `qs ipc call settings open <page>` (Super+W opens the wallpaper page)
    IpcHandler {
        target: "settings"
        function open(page: string): void { settings.page = page; settings.visible = true }
        function toggle(): void { settings.visible = !settings.visible }
    }

    // first connected wired/Wi-Fi device (null = offline)
    readonly property var netDevice: Networking.devices.values.find(d =>
        d.connected && (d.type === DeviceType.Wired || d.type === DeviceType.Wifi)) ?? null

    // Watchdog: when NetworkManager restarts (e.g. a rebuild that changes network settings),
    // Quickshell's networking module loses its devices and never gets them back; only a
    // fresh start fixes it. Every 15s compare with nmcli; if NetworkManager says we're
    // connected but the module has no device twice in a row, restart the bar.
    property int netMismatch: 0
    onNetDeviceChanged: if (netDevice) netMismatch = 0
    Process {
        id: nmCheck
        environment: ({ LC_ALL: "C" })
        command: ["nmcli", "-t", "-f", "TYPE,STATE", "device", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const nmOnline = this.text.split("\n").some(l => /^(ethernet|wifi):connected$/.test(l.trim()))
                if (nmOnline && !root.netDevice) {
                    if (++root.netMismatch >= 2) {
                        console.warn("networking module lost NetworkManager's devices, restarting the bar")
                        Quickshell.execDetached(["sh", "-c", "sleep 1; exec qs -d"])
                        Qt.quit()
                    }
                } else root.netMismatch = 0
            }
        }
    }
    Timer { interval: 15000; running: root.netDevice === null; repeat: true; onTriggered: if (!nmCheck.running) nmCheck.running = true }

    // ---------- notifications (replaces mako) ----------
    // Lists only hold plain JS copies. A live Notification object gets destroyed when the
    // app closes it, and reading a destroyed one from a model crashes Quickshell (Omarchy's
    // lesson). The live objects sit in a map, only used to invoke actions / dismiss.
    property var popups: []      // on screen now
    property var history: []     // notification center, newest first
    property var live: ({})      // id -> Notification
    onHistoryChanged: Qt.callLater(pruneLive)
    onPopupsChanged: Qt.callLater(pruneLive)
    property bool dnd: false     // Do Not Disturb: no popups, still logged
    // Fullscreen on the focused workspace: no popups either (critical ones still show).
    // Any mapped Overlay-layer surface makes Hyprland drop a fullscreen game out of
    // tearing / direct scanout, so a toast would cost latency. They still land in
    // history; toasts already up are pulled when fullscreen starts, nothing replays after.
    readonly property bool fullscreenFocused: Hyprland.focusedWorkspace?.hasFullscreen ?? false
    onFullscreenFocusedChanged: if (fullscreenFocused) popups = popups.filter(p => p.critical)

    NotificationServer {
        keepOnReload: false
        bodySupported: true
        bodyMarkupSupported: true
        actionsSupported: true
        imageSupported: true
        onNotification: n => root.addNotification(n)
    }

    function addNotification(n) {
        n.tracked = true
        const o = {
            id: n.id, appName: n.appName, summary: n.summary, body: n.body,
            icon: notificationIcon(n.image, n.appIcon),
            critical: n.urgency === NotificationUrgency.Critical,
            actions: n.actions.map(a => ({ id: a.identifier, text: a.text })),
            // milliseconds (Quickshell 0.3.1's docs say seconds, but it passes the app's ms through)
            timeout: n.expireTimeout > 0 ? n.expireTimeout : 5000,
            time: Date.now()
        }
        live[o.id] = n
        n.closed.connect(() => { delete root.live[o.id]; root.hidePopup(o.id) })
        // an app can replace its notification (same id): drop the old copy
        history = [o].concat(history.filter(h => h.id !== o.id)).slice(0, 50)
        if (!dnd && (o.critical || !fullscreenFocused))
            popups = popups.filter(p => p.id !== o.id).concat([o]).slice(-5)
    }
    function notificationIcon(image, appIcon) {
        if (image) return image
        if (!appIcon) return ""
        if (appIcon.startsWith("/") || appIcon.includes("://")) return appIcon
        return Quickshell.iconPath(appIcon, true)
    }
    function hidePopup(id) { popups = popups.filter(p => p.id !== id) }
    function pruneLive() {
        const keep = new Set(history.map(h => h.id).concat(popups.map(p => p.id)))
        for (const key of Object.keys(live)) {
            if (keep.has(Number(key))) continue
            const n = live[key]
            delete live[key]
            try { n?.expire() } catch (e) {}
        }
    }
    function dismissNotification(id) {
        try { live[id]?.dismiss() } catch (e) {}
        hidePopup(id)
        history = history.filter(h => h.id !== id)
    }
    function invokeAction(id, actionId) {
        try { live[id]?.actions.find(a => a.identifier === actionId)?.invoke() } catch (e) {}
        hidePopup(id)
    }
    function clearNotifications() {
        const old = Object.values(live)
        live = ({})
        history = []; popups = []
        for (const n of old) { try { n?.dismiss() } catch (e) {} }
    }
    function ago(t) {
        const m = Math.floor((clock.date - t) / 60000)
        return m < 1 ? "now" : m < 60 ? m + "m" : Math.floor(m / 60) + "h"
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            anchors { top: true; left: true; right: true }
            WlrLayershell.namespace: "gilgamesh-bar"
            implicitHeight: 42
            color: "transparent"

            // text color: light normally; on a transparent bar, dark if the wallpaper under it is bright
            readonly property color ink: root.prefs.barTransparent
                && root.contrast(root.bg, wallWindow.stripColor) > root.contrast(root.fg, wallWindow.stripColor)
                ? root.bg : root.fg

            // workspaces of the monitor this bar is on, normal ones only (no special/scratchpad)
            readonly property var monitor: Hyprland.monitorFor(modelData)
            readonly property var workspaces: Hyprland.workspaces.values
                .filter(w => w.id > 0 && w.monitor === monitor)
                .sort((a, b) => a.id - b.id)

            // the bar background, faded out when the bar is transparent
            Rectangle {
                anchors.fill: parent
                color: root.bg
                opacity: root.prefs.barTransparent ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }
            }

            // clicking empty bar space closes an open dropdown, double-click toggles transparency
            // (declared first = behind the buttons)
            MouseArea {
                anchors.fill: parent
                onClicked: dropdown.open = ""
                onDoubleClicked: root.prefs.barTransparent = !root.prefs.barTransparent
            }

            // ---------- left: logo + workspaces ----------
            RowLayout {
                anchors { left: parent.left; leftMargin: 8; verticalCenter: parent.verticalCenter }
                spacing: 4

                // Gilgamesh logo (永). Click = launcher (works even when Super is taken, e.g. in a VM),
                // right click = Gilgamesh Settings
                Image {
                    source: root.logo
                    sourceSize { width: 28; height: 28 }
                    Layout.preferredWidth: 28
                    Layout.preferredHeight: 28
                    Layout.rightMargin: 8

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: mouse => {
                            dropdown.open = ""
                            if (mouse.button === Qt.RightButton) settings.visible = !settings.visible
                            else launcher.toggle()
                        }
                    }
                }

                Repeater {
                    model: ScriptModel { values: bar.workspaces; comparisonMode: ObjectComparison.Identity }

                    Rectangle {
                        required property var modelData
                        readonly property bool isFocused: modelData.focused
                        readonly property bool isUrgent: modelData.urgent

                        implicitWidth: 32
                        implicitHeight: 30
                        radius: 6
                        color: isFocused ? root.green : (isUrgent ? root.red : "transparent")

                        Text {
                            anchors.centerIn: parent
                            text: modelData.name
                            color: parent.isFocused || parent.isUrgent ? root.bg : bar.ink
                            font { family: root.font; pixelSize: root.fontSize; bold: parent.isFocused }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { dropdown.open = ""; modelData.activate() }
                        }
                    }
                }

            }

            // ---------- center: clock (click = calendar) ----------
            Text {
                id: clockText
                anchors.centerIn: parent
                text: Qt.formatDateTime(clock.date, "HH:mm")
                color: calendar.visible ? root.yellow : bar.ink
                font { family: root.font; pixelSize: root.fontSize; bold: true }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -6
                    cursorShape: Qt.PointingHandCursor
                    onClicked: dropdown.toggle("calendar")
                }
            }

            // ---------- wallpaper (drawn by us, no awww/swww/hyprpaper) ----------
            // Two image layers: the new wallpaper loads into the hidden one, fades in over the
            // old one, then they swap roles. Decoded at screen size to save memory.
            PanelWindow {
                id: wallWindow
                screen: bar.screen
                anchors { top: true; bottom: true; left: true; right: true }
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Background
                WlrLayershell.namespace: "gilgamesh-wallpaper"
                color: root.bg

                readonly property string target: root.prefs.wallpaper
                property var front: imgA
                property var back: imgB
                property int revision: 0
                function loadWallpaper() {
                    fadeIn.stop()
                    revision++
                    if (!front || !back) return
                    back.opacity = 0
                    back.source = ""
                    if (!target) {
                        front.opacity = 0
                        front.source = ""
                        sampler.sample(null)
                        stripColor = root.bg
                        return
                    }
                    back.revision = revision
                    back.source = Paths.toFileUrl(target)
                }
                onTargetChanged: loadWallpaper()
                Component.onCompleted: loadWallpaper()
                function fadeReady(img) {
                    if (!target || img !== back || img.revision !== revision || img.status !== Image.Ready) return
                    fadeIn.target = img
                    fadeIn.revision = revision
                    fadeIn.restart()
                }

                NumberAnimation {
                    id: fadeIn
                    property int revision: -1
                    property: "opacity"
                    from: 0; to: 1
                    duration: 420
                    easing.type: Easing.OutCubic
                    onFinished: {
                        if (fadeIn.revision !== wallWindow.revision || fadeIn.target !== wallWindow.back || wallWindow.back.status !== Image.Ready) return
                        const old = wallWindow.front
                        wallWindow.front = fadeIn.target
                        wallWindow.back = old
                        old.opacity = 0
                        old.source = ""
                        sampler.sample(wallWindow.front)
                    }
                }

                // average color of the strip under the bar, so a transparent bar can pick
                // readable text. The wallpaper is drawn small into a Canvas the same way the
                // Image crops it, then the top rows are averaged. Never visible.
                property color stripColor: root.bg
                Canvas {
                    id: sampler
                    width: 192
                    height: Math.max(1, Math.round(width * wallWindow.height / Math.max(1, wallWindow.width)))
                    opacity: 0
                    property string url: ""
                    property real aspect: 1

                    function sample(img) {
                        if (url) unloadImage(url)
                        url = ""
                        if (!img || img.status !== Image.Ready) return
                        url = img.source.toString()
                        if (!url) return
                        aspect = img.implicitWidth / Math.max(1, img.implicitHeight)
                        const dw = Math.max(width, height * aspect), dh = dw / aspect
                        loadImage(url, Qt.size(Math.ceil(dw), Math.ceil(dh)))
                        if (isImageLoaded(url)) requestPaint()
                    }
                    onImageLoaded: requestPaint()
                    onPaint: {
                        if (!url || !isImageLoaded(url)) return
                        const ctx = getContext("2d")
                        // PreserveAspectCrop: cover the whole area, centered
                        const dw = Math.max(width, height * aspect), dh = dw / aspect
                        ctx.drawImage(url, (width - dw) / 2, (height - dh) / 2, dw, dh)
                        const rows = Math.max(1, Math.round(height * bar.height / Math.max(1, wallWindow.height)))
                        const d = ctx.getImageData(0, 0, width, rows).data
                        let r = 0, g = 0, b = 0
                        for (let i = 0; i < d.length; i += 4) { r += d[i]; g += d[i + 1]; b += d[i + 2] }
                        const n = d.length / 4 * 255
                        wallWindow.stripColor = Qt.rgba(r / n, g / n, b / n, 1)
                        unloadImage(url)
                    }
                }

                Image {
                    id: imgA
                    property int revision: -1
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    sourceSize { width: wallWindow.width; height: wallWindow.height }
                    asynchronous: true
                    opacity: 0
                    z: wallWindow.back === imgA ? 1 : 0
                    onStatusChanged: wallWindow.fadeReady(imgA)
                }
                Image {
                    id: imgB
                    property int revision: -1
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    sourceSize { width: wallWindow.width; height: wallWindow.height }
                    asynchronous: true
                    opacity: 0
                    z: wallWindow.back === imgB ? 1 : 0
                    onStatusChanged: wallWindow.fadeReady(imgB)
                }
            }

            // ---------- dropdowns (calendar, control center) ----------
            // A transparent layer window covering the screen *below* the bar, with the cards
            // drawn inside. Clicking the empty part closes it; the bar stays clickable.
            // (Same approach as Omarchy: xdg popups + Hyprland focus grabs eat clicks inside.)
            PanelWindow {
                id: dropdown
                property string open: ""   // "", "calendar", "audio", "network", "notifications", "tray" or "media"
                function toggle(name) { open = (open === name) ? "" : name }
                // cards drop under the module that opened them (centered, kept on screen)
                property real anchorX: -1
                function toggleAt(name, item) {
                    if (open !== name) anchorX = item.mapToItem(null, item.width / 2, 0).x
                    toggle(name)
                }
                function cardX(w) {
                    return anchorX < 0 ? width - w - 10 : Math.max(10, Math.min(width - w - 10, anchorX - w / 2))
                }
                Connections {
                    target: root
                    function onMediaCardRequestChanged() {
                        if (bar.screen.name === Hyprland.focusedMonitor?.name && dropdown.open !== "media") dropdown.toggleAt("media", mediaButton)
                    }
                }

                screen: bar.screen
                visible: open !== ""
                anchors { top: true; bottom: true; left: true; right: true }
                margins.top: bar.height
                exclusionMode: ExclusionMode.Ignore
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "gilgamesh-dropdown"
                // only the media card's library has text boxes (search, download link); other cards and
                // the now-playing view don't need the keyboard (with it, clicks outside didn't close the card)
                WlrLayershell.keyboardFocus: open === "media" && mediaCard.mode === "library"
                    ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
                color: "transparent"

                MouseArea { anchors.fill: parent; onClicked: dropdown.open = "" }

                Item {
                    id: calendar
                    visible: dropdown.open === "calendar"
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 6
                    width: calBox.implicitWidth
                    height: calBox.implicitHeight
                    MouseArea { anchors.fill: parent } // clicks on the card don't close it

                    // always the current month
                    readonly property int year: clock.date.getFullYear()
                    readonly property int month: clock.date.getMonth()
                    readonly property int days: new Date(year, month + 1, 0).getDate()

                    Rectangle {
                        id: calBox
                        implicitWidth: calCol.implicitWidth + 28
                        implicitHeight: calCol.implicitHeight + 28
                        color: root.bg
                        radius: 10
                        border { color: root.bgAlt; width: 1 }

                        ColumnLayout {
                            id: calCol
                            anchors.centerIn: parent
                            spacing: 10

                            // full date
                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: Qt.formatDateTime(clock.date, "dddd, d MMMM yyyy")
                                color: root.fg
                                font { family: root.font; pixelSize: root.fontSize + 1; bold: true }
                            }

                            Text {
                                Layout.alignment: Qt.AlignHCenter
                                text: Qt.formatDate(clock.date, "MMMM yyyy")
                                color: root.blue
                                font { family: root.font; pixelSize: root.fontSize; bold: true }
                            }

                            GridLayout {
                                columns: 7
                                rowSpacing: 4
                                columnSpacing: 4

                                // just this month: 1 in the top-left, 7 per row
                                Repeater {
                                    model: calendar.days
                                    Rectangle {
                                        required property int index
                                        readonly property int day: index + 1
                                        readonly property bool isToday: day === clock.date.getDate()
                                        Layout.preferredWidth: 32
                                        Layout.preferredHeight: 28
                                        radius: 6
                                        color: isToday ? root.yellow : "transparent"

                                        Text {
                                            anchors.centerIn: parent
                                            text: parent.day
                                            color: parent.isToday ? root.bg : root.fg
                                            font { family: root.font; pixelSize: root.fontSize; bold: parent.isToday }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Item {
                    id: audioPanel
                    visible: dropdown.open === "audio"
                                                            x: dropdown.cardX(width)
                                                            y: 6
                    width: 380
                    height: panelCol.implicitHeight + 32
                    MouseArea { anchors.fill: parent } // clicks on the card don't close it

                    // Device lists are snapshots, refreshed a moment after PipeWire changes and
                    // cleared while closed. Rebuilding straight from PipeWire's live list while a
                    // device is disappearing can crash Quickshell (same trick Omarchy uses).
                    property var sinks: []
                    property var sources: []
                    readonly property var liveNodes: Pipewire.nodes.values

                    function isAudio(n) { return !!n.audio || String(n.type).indexOf("Audio") >= 0 }
                    function refresh() {
                        const nodes = liveNodes.slice()
                        sinks = nodes.filter(n => n && n.isSink && !n.isStream && isAudio(n))
                        sources = nodes.filter(n => n && !n.isSink && !n.isStream && isAudio(n) && n.name !== "quickshell")
                    }
                    onLiveNodesChanged: if (visible) refreshTimer.restart()
                    onVisibleChanged: { if (visible) refresh(); else { refreshTimer.stop(); sinks = []; sources = [] } }
                    Timer { id: refreshTimer; interval: 75; onTriggered: audioPanel.refresh() }

                    PwObjectTracker { objects: audioPanel.sinks.concat(audioPanel.sources) }

                    function label(n) { return n.nickname || n.description || n.name || "Unknown" }

                    Rectangle {
                        anchors.fill: parent
                        color: root.bg
                        radius: 10
                        border { color: root.bgAlt; width: 1 }

                        ColumnLayout {
                            id: panelCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
                            spacing: 18

                            Repeater {
                                model: ScriptModel {
                                    objectProp: "isOutput"
                                    comparisonMode: ObjectComparison.Identity
                                    values: [
                                        { title: "Output", isOutput: true,  node: Pipewire.defaultAudioSink,   devices: audioPanel.sinks,
                                          accent: root.cyan,   icon: 0xF057E, mutedIcon: 0xF075F },
                                        { title: "Input",  isOutput: false, node: Pipewire.defaultAudioSource, devices: audioPanel.sources,
                                          accent: root.purple, icon: 0xF036C, mutedIcon: 0xF036D }
                                    ]
                                }

                                ColumnLayout {
                                    id: section
                                    required property var modelData
                                    readonly property var audio: modelData.node?.audio ?? null
                                    readonly property bool muted: audio?.muted ?? true
                                    readonly property real level: audio?.volume ?? 0
                                    Layout.fillWidth: true
                                    spacing: 8

                                    // header: icon (click = mute), title, percentage
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            text: root.icon(section.muted ? section.modelData.mutedIcon : section.modelData.icon)
                                            color: section.muted ? root.red : section.modelData.accent
                                            font { family: root.iconFont; pixelSize: root.fontSize + 3 }
                                            MouseArea {
                                                anchors.fill: parent; anchors.margins: -6
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: if (section.audio) section.audio.muted = !section.audio.muted
                                            }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            Layout.leftMargin: 6
                                            text: section.modelData.title
                                            color: root.fg
                                            font { family: root.font; pixelSize: root.fontSize; bold: true }
                                        }
                                        Text {
                                            text: section.muted ? "muted" : Math.round(section.level * 100) + "%"
                                            color: section.muted ? root.red : root.dim
                                            font { family: root.font; pixelSize: root.fontSize }
                                        }
                                    }

                                    // slider: click or drag to set, scroll for 5% steps
                                    Item {
                                        Layout.fillWidth: true
                                        implicitHeight: 20
                                        readonly property real fill: Math.max(0, Math.min(1, section.level))

                                        Rectangle {
                                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                                            height: 6; radius: 3
                                            color: root.bgAlt
                                            Rectangle {
                                                width: parent.width * parent.parent.fill
                                                height: parent.height; radius: 3
                                                color: section.muted ? root.dim : section.modelData.accent
                                            }
                                        }
                                        Rectangle {
                                            x: parent.width * parent.fill - width / 2
                                            anchors.verticalCenter: parent.verticalCenter
                                            width: 14; height: 14; radius: 7
                                            color: root.fg
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            function setFrom(x) { if (section.audio) section.audio.volume = Math.max(0, Math.min(1, x / width)) }
                                            onPressed: mouse => setFrom(mouse.x)
                                            onPositionChanged: mouse => { if (pressed) setFrom(mouse.x) }
                                            onWheel: wheel => {
                                                if (!section.audio) return
                                                const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                                                section.audio.volume = Math.max(0, Math.min(1, section.audio.volume + step))
                                            }
                                        }
                                    }

                                    // devices: the current one is marked, click another to switch
                                    Repeater {
                                        model: ScriptModel { values: section.modelData.devices; comparisonMode: ObjectComparison.Identity }

                                        Rectangle {
                                            id: deviceRow
                                            required property var modelData
                                            readonly property bool current: section.modelData.node !== null
                                                && modelData.id === section.modelData.node.id
                                            Layout.fillWidth: true
                                            implicitHeight: 32
                                            radius: 6
                                            color: current ? root.bgAlt : (rowMouse.containsMouse ? root.hover : "transparent")

                                            RowLayout {
                                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                                spacing: 10
                                                Text {
                                                    text: deviceRow.current ? "●" : "○"
                                                    color: deviceRow.current ? root.yellow : root.dim
                                                    font { family: root.iconFont; pixelSize: root.fontSize - 2 }
                                                }
                                                Text {
                                                    Layout.fillWidth: true
                                                    text: audioPanel.label(deviceRow.modelData)
                                                    elide: Text.ElideRight
                                                    color: deviceRow.current ? root.fg : root.dim
                                                    font { family: root.font; pixelSize: root.fontSize - 1 }
                                                }
                                            }

                                            MouseArea {
                                                id: rowMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    if (section.modelData.isOutput) Pipewire.preferredDefaultAudioSink = deviceRow.modelData
                                                    else Pipewire.preferredDefaultAudioSource = deviceRow.modelData
                                                }
                                            }
                                        }
                                    }

                                    Text {
                                        visible: section.modelData.devices.length === 0
                                        text: "no devices"
                                        color: root.dim
                                        font { family: root.font; pixelSize: root.fontSize - 1; italic: true }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------- network card: connection + DNS provider ----------
                Item {
                    id: networkCard
                    visible: dropdown.open === "network"
                                                            x: dropdown.cardX(width)
                                                            y: 6
                    width: 380
                    height: netCol.implicitHeight + 32
                    MouseArea { anchors.fill: parent } // clicks on the card don't close it

                    readonly property var providers: ["DHCP", "Cloudflare", "Google", "OpenDNS", "Custom"]
                    property string dns: ""        // what gilgamesh-dns reports
                    property string pending: ""    // being applied right now
                    property string dnsError: ""
                    property string ip: ""

                    function refresh() {
                        dnsRead.running = true
                        if (root.netDevice) { ipRead.command = ["sh", "-c", "ip -4 -o addr show dev \"$1\" | awk '{print $4}' | head -1", "sh", root.netDevice.name]; ipRead.running = true }
                    }
                    function setDns(p) {
                        if (pending !== "") return
                        dnsError = ""
                        pending = p
                        dnsSet.command = p === "Custom"
                            ? ["foot", "--app-id", "gilgamesh-dns", "-e", "gilgamesh-dns", "Custom"]
                            : ["gilgamesh-dns", p]
                        dnsSet.running = true
                    }
                    onVisibleChanged: if (visible) refresh()

                    Process { id: dnsRead; command: ["gilgamesh-dns"]
                        stdout: StdioCollector { onStreamFinished: networkCard.dns = this.text.trim() } }
                    Process { id: ipRead
                        stdout: StdioCollector { onStreamFinished: networkCard.ip = this.text.trim() } }
                    Process {
                        id: dnsSet
                        onRunningChanged: {
                            if (!running && networkCard.pending !== "") {
                                networkCard.pending = ""
                                networkCard.dnsError = "Could not start " + command[0] + ". Check that it is installed."
                            }
                        }
                        onExited: exitCode => {
                            networkCard.pending = ""
                            if (exitCode !== 0) networkCard.dnsError = "DNS change failed (exit " + exitCode + ")."
                            dnsRead.running = true
                        }
                    }

                    Rectangle {
                        anchors.fill: parent
                        color: root.bg
                        radius: 10
                        border { color: root.bgAlt; width: 1 }

                        ColumnLayout {
                            id: netCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
                            spacing: 14

                            // connection
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text {
                                    text: !root.netDevice ? root.icon(0xF0202)
                                        : (root.netDevice.type === DeviceType.Wifi ? root.icon(0xF05A9) : root.icon(0xF0200))
                                    color: root.netDevice ? root.green : root.red
                                    font { family: root.iconFont; pixelSize: root.fontSize + 6 }
                                }
                                ColumnLayout {
                                    spacing: 2
                                    Text {
                                        text: !root.netDevice ? "Offline"
                                            : (root.netDevice.type === DeviceType.Wifi ? "Wi-Fi" : "Wired") + "  ·  " + root.netDevice.name
                                        color: root.fg
                                        font { family: root.font; pixelSize: root.fontSize; bold: true }
                                    }
                                    Text {
                                        visible: !!root.netDevice
                                        text: (networkCard.ip || "no IP yet")
                                            + (root.netDevice?.linkSpeed > 0 ? "  ·  " + root.netDevice.linkSpeed + " Mb/s" : "")
                                        color: root.dim
                                        font { family: root.font; pixelSize: root.fontSize - 2 }
                                    }
                                }
                            }

                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.bgAlt }

                            Text {
                                text: "DNS PROVIDER"
                                color: root.dim
                                font { family: root.font; pixelSize: root.fontSize - 3; bold: true; letterSpacing: 1 }
                            }

                            // pills: current one yellow, the one being applied blinks dim
                            GridLayout {
                                Layout.fillWidth: true
                                columns: 3
                                rowSpacing: 8
                                columnSpacing: 8

                                Repeater {
                                    model: networkCard.providers
                                    Rectangle {
                                        id: pill
                                        required property string modelData
                                        readonly property bool current: networkCard.dns === modelData
                                        readonly property bool applying: networkCard.pending === modelData
                                        Layout.fillWidth: true
                                        implicitHeight: 32
                                        radius: 8
                                        color: current ? root.yellow : (pillMouse.containsMouse ? root.hover : root.bgAlt)
                                        opacity: applying ? 0.5 : 1

                                        Text {
                                            anchors.centerIn: parent
                                            text: pill.modelData
                                            color: pill.current ? root.bg : root.fg
                                            font { family: root.font; pixelSize: root.fontSize - 1; bold: pill.current }
                                        }
                                        MouseArea {
                                            id: pillMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: networkCard.setDns(pill.modelData)
                                        }
                                    }
                                }
                            }
                            Text {
                                visible: networkCard.dnsError !== ""
                                Layout.fillWidth: true
                                text: networkCard.dnsError
                                wrapMode: Text.Wrap
                                color: root.red
                                font { family: root.font; pixelSize: root.fontSize - 2 }
                            }
                        }
                    }
                }

                // ---------- tray menu: the app's menu, drawn by us in jellybeans ----------
                // Quickshell can only show apps' own (platform) menus in QApplication mode,
                // and they wouldn't match the bar anyway. Submenus drill down in place.
                Item {
                    id: trayMenu
                    visible: dropdown.open === "tray"
                    width: 280
                    height: menuCol.implicitHeight + 16
                    y: 6
                    // centered under the clicked icon, kept on screen
                    x: Math.max(8, Math.min(parent.width - width - 8, anchorX - width / 2))
                    MouseArea { anchors.fill: parent } // clicks on the card don't close it

                    property var item: null       // the SystemTrayItem
                    property real anchorX: 0
                    property var stack: []        // [{ title, opener }] for submenus
                    property bool settling: false // ignore clicks right after changing level
                    readonly property var opener: stack.length > 0 ? stack[stack.length - 1].opener : rootOpener

                    function openFor(it, x) {
                        reset()
                        item = it
                        anchorX = x
                        dropdown.open = "tray"
                    }
                    function reset() {
                        const old = stack; stack = []
                        for (const lvl of old) lvl.opener.destroy()
                    }
                    function settle() { settling = true; settleTimer.restart() }
                    function enter(entry) {
                        const o = openerComponent.createObject(trayMenu, { menu: entry })
                        stack = stack.concat([{ title: entry.text, opener: o }])
                        settle()
                    }
                    function back() {
                        const lvl = stack[stack.length - 1]
                        stack = stack.slice(0, -1)
                        lvl.opener.destroy()
                        settle()
                    }
                    function clean(t) { return String(t ?? "").replace(/_(?!_)/g, "").replace(/__/g, "_") } // drop "_" mnemonics
                    onVisibleChanged: if (!visible) reset()

                    QsMenuOpener { id: rootOpener; menu: trayMenu.visible ? (trayMenu.item?.menu ?? null) : null }
                    Component { id: openerComponent; QsMenuOpener {} }
                    Timer { id: settleTimer; interval: 250; onTriggered: trayMenu.settling = false }

                    Rectangle {
                        anchors.fill: parent
                        color: root.bg
                        radius: 10
                        border { color: root.bgAlt; width: 1 }

                        ColumnLayout {
                            id: menuCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 8 }
                            spacing: 2

                            // header: app name, or "‹ submenu" to go back
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: 30
                                radius: 6
                                color: trayMenu.stack.length > 0 && backMouse.containsMouse ? root.bgAlt : "transparent"
                                Text {
                                    anchors { left: parent.left; leftMargin: 8; right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                    elide: Text.ElideRight
                                    text: trayMenu.stack.length > 0
                                        ? "‹  " + trayMenu.clean(trayMenu.stack[trayMenu.stack.length - 1].title)
                                        : (trayMenu.item?.tooltipTitle || trayMenu.item?.title || trayMenu.item?.id || "")
                                    color: trayMenu.stack.length > 0 ? root.blue : root.dim
                                    font { family: root.font; pixelSize: root.fontSize - 2; bold: true }
                                }
                                MouseArea {
                                    id: backMouse
                                    anchors.fill: parent
                                    enabled: trayMenu.stack.length > 0
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: if (!trayMenu.settling) trayMenu.back()
                                }
                            }

                            Repeater {
                                model: trayMenu.opener.children

                                Item {
                                    id: entryRow
                                    required property var modelData
                                    readonly property bool sep: modelData.isSeparator
                                    readonly property bool on: modelData.enabled
                                    readonly property bool checkable: modelData.buttonType !== QsMenuButtonType.None
                                    readonly property bool checked: modelData.checkState === Qt.Checked
                                    Layout.fillWidth: true
                                    implicitHeight: sep ? 9 : 30

                                    Rectangle { // separator
                                        visible: entryRow.sep
                                        anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 6; rightMargin: 6 }
                                        height: 1
                                        color: root.bgAlt
                                    }

                                    Rectangle {
                                        visible: !entryRow.sep
                                        anchors.fill: parent
                                        radius: 6
                                        color: entryMouse.containsMouse && entryRow.on ? root.bgAlt : "transparent"

                                        RowLayout {
                                            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                                            spacing: 8

                                            // checkbox / radio state, or the entry's icon
                                            Item {
                                                Layout.preferredWidth: 16
                                                Layout.preferredHeight: 16
                                                Text {
                                                    anchors.centerIn: parent
                                                    visible: entryRow.checkable
                                                    text: entryRow.checked
                                                        ? (entryRow.modelData.buttonType === QsMenuButtonType.RadioButton ? "●" : root.icon(0xF012C))
                                                        : (entryRow.modelData.buttonType === QsMenuButtonType.RadioButton ? "○" : "")
                                                    color: root.yellow
                                                    font { family: root.iconFont; pixelSize: root.fontSize - 2 }
                                                }
                                                Image {
                                                    anchors.fill: parent
                                                    // hidden unless it actually loaded (no "missing image" squares)
                                                    visible: !entryRow.checkable && entryRow.modelData.icon !== "" && status === Image.Ready
                                                    source: entryRow.modelData.icon
                                                    sourceSize { width: 16; height: 16 }
                                                }
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: trayMenu.clean(entryRow.modelData.text)
                                                elide: Text.ElideRight
                                                color: entryRow.on ? root.fg : root.faint
                                                font { family: root.font; pixelSize: root.fontSize - 1 }
                                            }
                                            Text {
                                                visible: entryRow.modelData.hasChildren
                                                text: "›"
                                                color: root.dim
                                                font { family: root.font; pixelSize: root.fontSize + 2 }
                                            }
                                        }

                                        MouseArea {
                                            id: entryMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            enabled: entryRow.on
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (trayMenu.settling) return
                                                if (entryRow.modelData.hasChildren) trayMenu.enter(entryRow.modelData)
                                                else { entryRow.modelData.triggered(); dropdown.open = "" }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // ---------- notification center ----------
                MediaCard {
                    id: mediaCard
                    shell: root
                    visible: dropdown.open === "media"
                                                            x: dropdown.cardX(width)
                                                            y: 6
                }

                Item {
                    id: notifCenter
                    visible: dropdown.open === "notifications"
                                                            x: dropdown.cardX(width)
                                                            y: 6
                    width: 400
                    height: centerCol.implicitHeight + 32
                    MouseArea { anchors.fill: parent } // clicks on the card don't close it

                    Rectangle {
                        anchors.fill: parent
                        color: root.bg
                        radius: 10
                        border { color: root.bgAlt; width: 1 }

                        ColumnLayout {
                            id: centerCol
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
                            spacing: 12

                            // header: title, DND toggle, clear all
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10
                                Text {
                                    Layout.fillWidth: true
                                    text: "Notifications"
                                    color: root.fg
                                    font { family: root.font; pixelSize: root.fontSize; bold: true }
                                }
                                Rectangle {
                                    implicitWidth: dndText.implicitWidth + 20
                                    implicitHeight: 26
                                    radius: 6
                                    color: root.dnd ? root.red : root.bgAlt
                                    Text {
                                        id: dndText
                                        anchors.centerIn: parent
                                        textFormat: Text.RichText
                                        text: root.iconHtml(root.dnd ? 0xF009B : 0xF009A) + " Do Not Disturb"
                                        color: root.dnd ? root.bg : root.fg
                                        font { family: root.font; pixelSize: root.fontSize - 3; bold: root.dnd }
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: { root.dnd = !root.dnd; if (root.dnd) root.popups = [] }
                                    }
                                }
                                Text {
                                    visible: root.history.length > 0
                                    text: "Clear"
                                    color: root.blue
                                    font { family: root.font; pixelSize: root.fontSize - 2 }
                                    MouseArea {
                                        anchors.fill: parent; anchors.margins: -6
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.clearNotifications()
                                    }
                                }
                            }

                            Text {
                                visible: root.history.length === 0
                                Layout.alignment: Qt.AlignHCenter
                                Layout.topMargin: 8
                                Layout.bottomMargin: 8
                                text: "No notifications"
                                color: root.dim
                                font { family: root.font; pixelSize: root.fontSize - 1; italic: true }
                            }

                            // the list (scrolls when long)
                            Flickable {
                                visible: root.history.length > 0
                                Layout.fillWidth: true
                                Layout.preferredHeight: Math.min(historyCol.implicitHeight, 520)
                                contentHeight: historyCol.implicitHeight
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                ColumnLayout {
                                    id: historyCol
                                    width: parent.width
                                    spacing: 8

                                    Repeater {
                                        model: ScriptModel { values: root.history; comparisonMode: ObjectComparison.Identity }
                                        Rectangle {
                                            id: hRow
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: hBody.implicitHeight + 20
                                            radius: 8
                                            color: root.bgAlt
                                            border { color: hRow.modelData.critical ? root.critical : "transparent"; width: 1 }

                                            RowLayout {
                                                id: hBody
                                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 10 }
                                                spacing: 10

                                                Image {
                                                    Layout.preferredWidth: 32
                                                    Layout.preferredHeight: 32
                                                    Layout.alignment: Qt.AlignTop
                                                    source: hRow.modelData.icon
                                                    sourceSize { width: 32; height: 32 }
                                                    visible: status === Image.Ready
                                                }
                                                ColumnLayout {
                                                    Layout.fillWidth: true
                                                    spacing: 2
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: (hRow.modelData.appName || "notification") + "  ·  " + root.ago(hRow.modelData.time)
                                                        color: root.dim
                                                        elide: Text.ElideRight
                                                        font { family: root.font; pixelSize: root.fontSize - 4 }
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true
                                                        text: hRow.modelData.summary
                                                        color: root.fg
                                                        elide: Text.ElideRight
                                                        font { family: root.font; pixelSize: root.fontSize - 1; bold: true }
                                                    }
                                                    Text {
                                                        Layout.fillWidth: true
                                                        visible: text !== ""
                                                        text: hRow.modelData.body
                                                        textFormat: Text.StyledText
                                                        wrapMode: Text.Wrap
                                                        maximumLineCount: 3
                                                        elide: Text.ElideRight
                                                        color: root.dim
                                                        font { family: root.font; pixelSize: root.fontSize - 2 }
                                                    }
                                                }
                                                Text {
                                                    Layout.alignment: Qt.AlignTop
                                                    text: "×"
                                                    color: root.dim
                                                    font { family: root.font; pixelSize: root.fontSize + 2 }
                                                    MouseArea {
                                                        anchors.fill: parent; anchors.margins: -6
                                                        cursorShape: Qt.PointingHandCursor
                                                        onClicked: root.dismissNotification(hRow.modelData.id)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---------- notification popups ----------
            // Top-right, right under the bar (it respects the bar's reserved space).
            PanelWindow {
                id: toastWindow
                screen: bar.screen
                visible: root.popups.length > 0
                anchors { top: true; right: true }
                margins { top: 6; right: 10 }
                implicitWidth: 380
                implicitHeight: toastCol.implicitHeight
                WlrLayershell.layer: WlrLayer.Overlay
                WlrLayershell.namespace: "gilgamesh-notifications"
                color: "transparent"

                ColumnLayout {
                    id: toastCol
                    width: parent.width
                    spacing: 8

                    Repeater {
                        model: ScriptModel {
                            values: root.popups
                            comparisonMode: ObjectComparison.Identity
                        }

                        Rectangle {
                            id: toast
                            required property var modelData
                            Layout.fillWidth: true
                            implicitHeight: toastBody.implicitHeight + 24
                            radius: 10
                            color: root.bg
                            border { color: toast.modelData.critical ? root.critical : root.bgAlt; width: toast.modelData.critical ? 2 : 1 }

                            // disappears after the app's timeout; critical ones stay, hovering pauses
                            Timer {
                                interval: toast.modelData.timeout
                                running: !toast.modelData.critical && !toastMouse.containsMouse
                                onTriggered: root.hidePopup(toast.modelData.id)
                            }

                            // click = the app's default action (if any), otherwise just close the popup
                            MouseArea {
                                id: toastMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    const def = toast.modelData.actions.find(a => a.id === "default")
                                    if (def) root.invokeAction(toast.modelData.id, "default")
                                    else root.hidePopup(toast.modelData.id)
                                }
                            }

                            ColumnLayout {
                                id: toastBody
                                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 12 }
                                spacing: 8

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 12

                                    Image {
                                        Layout.preferredWidth: 40
                                        Layout.preferredHeight: 40
                                        Layout.alignment: Qt.AlignTop
                                        source: toast.modelData.icon
                                        sourceSize { width: 40; height: 40 }
                                        visible: status === Image.Ready
                                    }
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        Text {
                                            Layout.fillWidth: true
                                            text: toast.modelData.appName || "notification"
                                            color: root.dim
                                            elide: Text.ElideRight
                                            font { family: root.font; pixelSize: root.fontSize - 4 }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            text: toast.modelData.summary
                                            color: root.fg
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 2
                                            elide: Text.ElideRight
                                            font { family: root.font; pixelSize: root.fontSize - 1; bold: true }
                                        }
                                        Text {
                                            Layout.fillWidth: true
                                            visible: text !== ""
                                            text: toast.modelData.body
                                            textFormat: Text.StyledText
                                            wrapMode: Text.Wrap
                                            maximumLineCount: 4
                                            elide: Text.ElideRight
                                            color: root.dim
                                            font { family: root.font; pixelSize: root.fontSize - 2 }
                                        }
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignTop
                                        text: "×"
                                        color: root.dim
                                        font { family: root.font; pixelSize: root.fontSize + 2 }
                                        MouseArea {
                                            anchors.fill: parent; anchors.margins: -6
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.hidePopup(toast.modelData.id)
                                        }
                                    }
                                }

                                // action buttons (the "default" action is the click on the popup itself)
                                RowLayout {
                                    Layout.fillWidth: true
                                    visible: toast.modelData.actions.some(a => a.id !== "default")
                                    spacing: 8
                                    Repeater {
                                        model: toast.modelData.actions.filter(a => a.id !== "default")
                                        Rectangle {
                                            required property var modelData
                                            Layout.fillWidth: true
                                            implicitHeight: 28
                                            radius: 6
                                            color: actMouse.containsMouse ? root.hoverStrong : root.bgAlt
                                            Text {
                                                anchors.centerIn: parent
                                                text: parent.modelData.text
                                                color: root.fg
                                                font { family: root.font; pixelSize: root.fontSize - 3 }
                                            }
                                            MouseArea {
                                                id: actMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.invokeAction(toast.modelData.id, parent.modelData.id)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---------- right: tray + mic + volume ----------
            RowLayout {
                anchors { right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                spacing: 14

                // media: what's playing. click = media card, middle click = play/pause, scroll = next/previous.
                // Nothing playing: just a music note, and the card opens on the local library.
                Item {
                    id: mediaButton
                    implicitWidth: mediaRow.implicitWidth
                    implicitHeight: mediaRow.implicitHeight
                    RowLayout {
                        id: mediaRow
                        spacing: 6
                        Text {
                            text: root.icon(!root.media ? 0xF075A : root.media.isPlaying ? 0xF03E4 : 0xF040A)
                            color: root.green
                            font { family: root.iconFont; pixelSize: root.fontSize + 2 }
                        }
                        Text {
                            visible: root.media !== null
                            Layout.maximumWidth: 280
                            // \u200E (left-to-right mark): an Arabic/Hebrew title would otherwise flip the
                            // whole line right-to-left, cutting it on the wrong side
                            text: "\u200E" + (root.media?.trackTitle || "Unknown")
                                + (root.media?.trackArtist ? " — " + root.media.trackArtist : "")
                            elide: Text.ElideRight
                            color: dropdown.open === "media" ? root.yellow : bar.ink
                            font { family: root.font; pixelSize: root.fontSize }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent; anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        property real lastWheel: 0
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton) root.media?.togglePlaying()
                            else dropdown.toggleAt("media", parent)
                        }
                        onWheel: wheel => {
                            // one skip per gesture: touchpads send many small wheel events
                            const now = Date.now()
                            if (!root.media || now - lastWheel < 400) return
                            lastWheel = now
                            if (wheel.angleDelta.y < 0) { if (root.media.canGoNext) root.media.next() }
                            else if (root.media.canGoPrevious) root.media.previous()
                        }
                    }
                }

                // tray: left click = open app, right click = its menu (our own, see trayMenu)
                RowLayout {
                    spacing: 8
                    visible: SystemTray.items.values.length > 0

                    Repeater {
                        model: SystemTray.items

                        Image {
                            id: trayIcon
                            required property var modelData
                            source: modelData.icon
                            sourceSize { width: 22; height: 22 }
                            Layout.preferredWidth: 22
                            Layout.preferredHeight: 22

                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.LeftButton | Qt.RightButton
                                cursorShape: Qt.PointingHandCursor
                                onClicked: mouse => {
                                    if ((mouse.button === Qt.RightButton || trayIcon.modelData.onlyMenu) && trayIcon.modelData.hasMenu)
                                        trayMenu.openFor(trayIcon.modelData, trayIcon.mapToItem(null, trayIcon.width / 2, 0).x)
                                    else
                                        trayIcon.modelData.activate()
                                }
                            }
                        }
                    }
                }

                // notifications: bell + count, slashed bell = Do Not Disturb. click = notification center
                Text {
                    textFormat: Text.RichText
                    text: (root.dnd ? root.iconHtml(0xF009B) : root.iconHtml(0xF009A))
                        + (root.history.length > 0 ? " " + root.history.length : "")
                    color: root.dnd ? root.red : (root.history.length > 0 ? root.yellow : root.dim)
                    font { family: root.font; pixelSize: root.fontSize }

                    MouseArea {
                        anchors.fill: parent; anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: dropdown.toggleAt("notifications", parent)
                    }
                }

                // RAM: used / total in GiB, like `free -h` (yellow from 75% used, red from 90%)
                RowLayout {
                    id: ramModule
                    readonly property real frac: root.memTotal > 0 ? root.memUsed / root.memTotal : 0
                    readonly property color tint: frac >= 0.9 ? root.red : (frac >= 0.75 ? root.yellow : root.blue)
                    visible: root.memTotal > 0
                    spacing: 6
                    Text {   // a RAM stick (fa-memory); it's wider than a normal glyph, so it gets its own Text
                        text: root.icon(0xEFC5)
                        color: ramModule.tint
                        font { family: root.iconFont; pixelSize: root.fontSize }
                    }
                    Text {
                        text: (root.memUsed / 1048576).toFixed(1) + " / " + (root.memTotal / 1048576).toFixed(1) + "G"
                        color: ramModule.tint
                        font { family: root.font; pixelSize: root.fontSize }
                    }
                }

                // network: green = connected, red = offline. click = network card (DNS)
                Text {
                    readonly property bool wifi: root.netDevice?.type === DeviceType.Wifi
                    text: !root.netDevice ? root.icon(0xF0202) : (wifi ? root.icon(0xF05A9) : root.icon(0xF0200))
                    color: root.netDevice ? root.green : root.red
                    font { family: root.iconFont; pixelSize: root.fontSize + 2 }

                    MouseArea {
                        anchors.fill: parent; anchors.margins: -4
                        cursorShape: Qt.PointingHandCursor
                        onClicked: dropdown.toggleAt("network", parent)
                    }
                }

                // mic: click = control center, middle click = mute, scroll = level
                Text {
                    readonly property bool muted: root.source?.muted ?? true
                    readonly property int level: Math.round((root.source?.volume ?? 0) * 100)
                    textFormat: Text.RichText
                    text: (muted ? root.iconHtml(0xF036D) : root.iconHtml(0xF036C)) + " " + level + "%"
                    color: muted ? root.red : root.purple
                    font { family: root.font; pixelSize: root.fontSize }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton) { if (root.source) root.source.muted = !root.source.muted }
                            else dropdown.toggleAt("audio", parent)
                        }
                        onWheel: wheel => {
                            if (!root.source) return
                            const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                            root.source.volume = Math.max(0, Math.min(1, root.source.volume + step))
                        }
                    }
                }

                // volume: click = control center, middle click = mute, scroll = level
                Text {
                    readonly property bool muted: root.sink?.muted ?? true
                    readonly property int level: Math.round((root.sink?.volume ?? 0) * 100)
                    textFormat: Text.RichText
                    text: (muted ? root.iconHtml(0xF075F) : root.iconHtml(0xF057E)) + " " + level + "%"
                    color: muted ? root.red : root.cyan
                    font { family: root.font; pixelSize: root.fontSize }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                        onClicked: mouse => {
                            if (mouse.button === Qt.MiddleButton) { if (root.sink) root.sink.muted = !root.sink.muted }
                            else dropdown.toggleAt("audio", parent)
                        }
                        onWheel: wheel => {
                            if (!root.sink) return
                            const step = wheel.angleDelta.y > 0 ? 0.05 : -0.05
                            root.sink.volume = Math.max(0, Math.min(1, root.sink.volume + step))
                        }
                    }
                }
            }
        }
    }
}
