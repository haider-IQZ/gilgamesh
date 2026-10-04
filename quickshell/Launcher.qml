pragma ComponentBehavior: Bound
// Gilgamesh launcher + menu (replaces rofi/fuzzel), like Omarchy's menu. Super+D, or
// `qs ipc call launcher toggle`.
//   Nothing typed: the menu (Apps, Theme, Wallpaper picker, Power, Toggles, Settings window).
//   Typing: searches apps, themes and actions at once ("reb" finds Reboot, "nord" the theme).
//   Enter opens a submenu or runs the row; Backspace on an empty search or Esc goes back.
// Apps are ranked like Omarchy's search, plus the ones you open often first (counted in
// $XDG_STATE_HOME/gilgamesh/launcher.json).
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import "Paths.js" as Paths

Scope {
    id: launcher
    required property var shell
    property bool open: false
    function toggle() { open = !open }
    function close() { open = false }

    // ---------- launch counts ----------
    FileView {
        path: launcher.shell.stateDir + "/launcher.json"
        printErrors: false
        onAdapterUpdated: writeAdapter()
        onLoadFailed: writeAdapter()
        JsonAdapter {
            id: usage
            property var counts: ({})   // desktop id -> times launched
        }
    }

    // ---------- apps ----------
    readonly property var apps: {
        const seen = {}
        return DesktopEntries.applications.values.filter(e => {
            if (!e || e.noDisplay || !e.name || seen[e.id]) return false
            seen[e.id] = true
            return true
        })
    }
    function launchApp(e) {
        const counts = Object.assign({}, usage.counts || {})
        counts[e.id] = (counts[e.id] || 0) + 1
        usage.counts = counts
        if (e.runInTerminal)
            Quickshell.execDetached([Quickshell.env("TERMINAL") || "foot", "-e"].concat(e.command))
        else
            e.execute()
        close()
    }
    function appRow(e) {
        return { label: e.name, image: Quickshell.iconPath(e.icon, true), glyph: 0xF08C6,
                 keys: [e.genericName, e.comment, (e.keywords || []).join(" "), e.id].join(" "),
                 used: (usage.counts || {})[e.id] || 0, run: () => launchApp(e) }
    }

    // ---------- search ----------
    function words(v) {
        return String(v || "").replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/[._:/\\-]+/g, " ")
            .toLowerCase().split(/[^a-z0-9]+/).filter(w => w)
    }
    // each word you type must match somewhere; a word that starts a word of the label counts
    // most ("fi ro" -> File Roller), then inside the label, other keywords, acronym
    function score(row, q) {
        const name = row.label.toLowerCase(), nameWords = words(row.label)
        const hay = (row.label + " " + (row.keys || "")).toLowerCase()
        const acr = words(row.label + " " + (row.keys || "")).map(w => w[0]).join("")
        let total = 0
        for (const t of q.split(/\s+/).filter(t => t)) {
            if (nameWords.some(w => w.startsWith(t))) total += 300
            else if (name.includes(t)) total += 200
            else if (hay.includes(t)) total += 100
            else if (t.length <= 5 && acr.includes(t)) total += 80
            else return -1
        }
        if (name.startsWith(q)) total += 1000          // the whole thing starts the label
        else if (name.includes(q)) total += 400
        return total * 10 - name.length + Math.min(row.used || 0, 50) * 20
    }
    function ranked(rows, q) {
        if (!q) return rows
        return rows.map(r => ({ r: r, s: score(r, q) })).filter(x => x.s >= 0)
            .sort((a, b) => b.s - a.s || a.r.label.localeCompare(b.r.label)).map(x => x.r)
    }

    // ---------- the menu ----------
    function titled(name) { return name.split("-").map(w => w[0].toUpperCase() + w.slice(1)).join(" ") }
    function confirmRows(what, glyph, action) {
        return [ { label: "Yes, " + what.toLowerCase(), glyph: glyph, danger: true, run: action },
                 { label: "Cancel", glyph: 0xF0156, run: () => back() } ]
    }
    // Keep the session alive while an app is still open, including a save dialog.
    property bool loggingOut: false
    property double logoutDeadline: 0
    property int logoutRevision: 0
    property string logoutMessage: ""
    function logout() {
        if (loggingOut) return
        close()
        logoutMessage = ""
        loggingOut = true
        logoutRevision++
        logoutDeadline = Date.now() + 15000
        for (const t of Hyprland.toplevels.values) {
            const addr = String(t.address).replace(/^0x/, "")
            if (/^[0-9a-fA-F]+$/.test(addr) && addr !== "0")
                Hyprland.dispatch('hl.dsp.window.close({ window = "address:0x' + addr + '" })')
        }
        logoutPoll.start()
        logoutTimeout.start()
    }
    function cancelLogout(message) {
        loggingOut = false
        logoutPoll.stop()
        logoutTimeout.stop()
        logoutMessage = message
        open = true
    }
    Timer {
        id: logoutTimeout
        interval: 15000
        onTriggered: launcher.cancelLogout("Logout cancelled: windows are still open or could not be checked. Save your work and try again.")
    }
    Timer {
        id: logoutPoll
        interval: 250
        repeat: true
        onTriggered: if (!logoutProbe.running) {
            logoutProbe.revision = launcher.logoutRevision
            logoutProbe.pending = true
            logoutProbe.running = true
        }
    }
    Process {
        id: logoutProbe
        property int revision: 0
        property bool pending: false
        command: ["hyprctl", "clients", "-j"]
        stdout: StdioCollector { id: logoutClients }
        onExited: (code, status) => {
            pending = false
            if (!launcher.loggingOut || revision !== launcher.logoutRevision) return
            let clients = null
            try { clients = JSON.parse(logoutClients.text) } catch (e) {}
            if (code !== 0 || status !== 0 || !Array.isArray(clients)) {
                launcher.cancelLogout("Logout cancelled: could not check open windows.")
            } else if (Date.now() >= launcher.logoutDeadline) {
                launcher.cancelLogout("Logout cancelled: windows are still open. Save your work and try again.")
            } else if (clients.length === 0) {
                launcher.loggingOut = false
                logoutPoll.stop()
                logoutTimeout.stop()
                Hyprland.dispatch("hl.dsp.exit()")
            }
        }
        onRunningChanged: if (!running && pending) {
            pending = false
            if (launcher.loggingOut && revision === launcher.logoutRevision)
                launcher.cancelLogout("Logout cancelled: could not check open windows.")
        }
    }

    readonly property var menu: [
        { label: "Apps", glyph: 0xF003B, children: () => apps.map(appRow)
            .sort((a, b) => b.used - a.used || a.label.localeCompare(b.label)) },
        { label: "Theme", glyph: 0xF03D8, keys: "colors style", children: () => shell.theme.names.map(n => ({
            label: titled(n), swatch: shell.theme.palettes[n] || {}, check: n === shell.theme.name, keys: "theme",
            run: () => { shell.theme.set(n); close() } })) },
        { label: "Wallpaper", glyph: 0xF02E9, keys: "background wallpapers picker",
            run: () => { close(); shell.pickWallpaper() } },
        { label: "Power", glyph: 0xF0425, keys: "system session", children: () => [
            { label: "Suspend", glyph: 0xF04B2, keys: "sleep power", run: () => { close(); Quickshell.execDetached(["systemctl", "suspend"]) } },
            { label: "Log out", glyph: 0xF0343, keys: "logout exit leave power", confirm: true,
              children: () => confirmRows("Log out", 0xF0343, () => logout()) },
            { label: "Reboot", glyph: 0xF0709, keys: "restart power", confirm: true,
              children: () => confirmRows("Reboot", 0xF0709, () => { close(); Quickshell.execDetached(["systemctl", "reboot"]) }) },
            { label: "Shut down", glyph: 0xF0425, keys: "shutdown poweroff power off", confirm: true,
              children: () => confirmRows("Shut down", 0xF0425, () => { close(); Quickshell.execDetached(["systemctl", "poweroff"]) }) } ] },
        { label: "Toggles", glyph: 0xF0521, children: () => [
            { label: "Do Not Disturb", glyph: 0xF009B, keys: "notifications dnd quiet", check: shell.dnd, stay: true,
              run: () => { shell.dnd = !shell.dnd } },
            { label: "Transparent bar", glyph: 0xF0E7B, keys: "bar transparency", check: shell.prefs.barTransparent, stay: true,
              run: () => { shell.prefs.barTransparent = !shell.prefs.barTransparent } } ] },
        { label: "Settings", glyph: 0xF0493, keys: "gilgamesh settings preferences",
            run: () => { close(); shell.openSettings("") } }
    ]

    // ---------- where we are ----------
    property var stack: []        // submenus opened, deepest last
    property string query: ""
    onQueryChanged: current = 0
    property int current: 0
    property int version: 0       // bumped to rebuild the rows after a toggle
    readonly property var rows: {
        version
        const q = query.trim().toLowerCase()
        if (stack.length > 0) return ranked(stack[stack.length - 1].children(), q)
        if (!q) return menu
        // search everything: apps, plus every menu row and what's in its submenu (not the
        // app list again)
        let all = apps.map(appRow)
        for (const m of menu) {
            if (m.label === "Apps") continue
            all.push(m)
            if (m.children)
                for (const c of m.children()) all.push(Object.assign({}, c, { parent: m.label }))
        }
        return ranked(all, q)
    }
    onRowsChanged: if (current >= rows.length) current = 0

    function activate(row) {
        if (!row) return
        if (row.children) { win.freezeCardTop(); stack = stack.concat([row]); query = ""; input.text = ""; current = 0; return }
        row.run()
        if (row.stay) version++
    }
    function back() {
        if (stack.length === 0) { close(); return }
        win.freezeCardTop()
        stack = stack.slice(0, -1); current = 0
    }
    onOpenChanged: {
        if (!open) return
        win.cardTop = -1; win.maxRowsHeight = -1
        stack = []; query = ""; current = 0
        shell.theme.refresh()
    }
    IpcHandler {
        target: "launcher"
        function toggle(): void { launcher.toggle() }
        function open(): void { launcher.open = true }
        function close(): void { launcher.open = false }
        function menu(path: string): void {   // open straight into a submenu: `menu Power`
            launcher.open = true
            for (const name of path.split("/")) {
                const r = launcher.rows.find(x => x.label.toLowerCase() === name.toLowerCase())
                if (r && r.children) launcher.activate(r)
            }
        }
    }

    // ---------- the window ----------
    PanelWindow {
        id: win
        visible: launcher.open || card.opacity > 0
        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "gilgamesh-launcher"
        WlrLayershell.keyboardFocus: launcher.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        color: "transparent"

        // Keep the original top edge and row budget through searches/submenus.
        property int cardTop: -1
        property int maxRowsHeight: -1
        function freezeCardTop() {
            if (launcher.open && cardTop < 0) {
                cardTop = card.y
                maxRowsHeight = card.rowsHeight
            }
        }

        // click outside = close; release input as soon as the fade-out starts
        MouseArea { anchors.fill: parent; enabled: launcher.open; onClicked: launcher.close() }
        mask: Region { item: launcher.open ? win.contentItem : null }

        Rectangle {
            id: card
            // Omarchy's look, scaled up to rofi size (Omarchy's raw numbers assume HiDPI scaling).
            readonly property int padding: 20
            readonly property int rowH: 52
            readonly property int visibleRows: 9
            readonly property int rowGap: 3
            readonly property int headerH: 40
            readonly property int contentGap: 6
            readonly property int edgeGap: 5
            readonly property string menuFont: "monospace"
            readonly property color selectedFill: Qt.alpha(launcher.shell.green, 0.18)
            readonly property int noticeHeight: logoutNotice.visible ? logoutNotice.implicitHeight + contentGap : 0
            readonly property int rowsHeight: {
                const available = Math.max(0, Math.min(
                    win.height - (win.cardTop >= 0 ? win.cardTop : edgeGap) - edgeGap
                        - padding * 2 - headerH - contentGap - noticeHeight,
                    Math.round(win.height * 0.7),
                    win.height))
                // same size in every view (like rofi), so the apps list isn't squeezed to the menu's height
                return Math.min(available, visibleRows * rowH + (visibleRows - 1) * rowGap)
            }
            // The existing relevance order stays intact. Nested search results get
            // the reference's hairline separator, without adding heading rows.
            function sectionBreak(index) {
                return launcher.query.trim() !== "" && launcher.stack.length === 0 && index > 0
                    && !!launcher.rows[index]?.parent
                    && launcher.rows[index].parent !== launcher.rows[index - 1].parent
            }
            width: Math.max(0, Math.min(560, win.width - edgeGap * 2))
            height: padding * 2 + headerH + contentGap + noticeHeight + rowsHeight
            anchors.horizontalCenter: parent.horizontalCenter
            y: win.cardTop >= 0 ? win.cardTop : Math.max(edgeGap, Math.round((win.height - height) / 2))
            radius: 0
            color: launcher.shell.bg
            border { color: launcher.shell.green; width: 2 }
            // Menu.qml delegates visibility to OverlayWindow (not in the supplied
            // reference). Keep our 120ms fade, without the old scale/pop effect.
            // Keeping the panel mapped until opacity reaches zero makes closing fade too.
            opacity: launcher.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
            enabled: launcher.open
            MouseArea { anchors.fill: parent }   // clicks on the card don't close it

            Item {
                id: search
                anchors { top: parent.top; left: parent.left; right: parent.right; margins: card.padding }
                height: card.headerH
                TextInput {
                    id: input
                    anchors.fill: parent
                    verticalAlignment: TextInput.AlignVCenter
                    clip: true
                    color: launcher.shell.fg
                    selectionColor: Qt.alpha(launcher.shell.green, 0.35)
                    selectedTextColor: launcher.shell.fg
                    font { family: card.menuFont; pixelSize: 20 }
                    focus: launcher.open
                    onTextChanged: {
                        if (launcher.query !== text) win.freezeCardTop()
                        launcher.query = text
                    }
                    Component.onCompleted: forceActiveFocus()
                    Connections {
                        target: launcher
                        function onOpenChanged() { if (launcher.open) { input.text = ""; input.forceActiveFocus() } }
                    }
                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        visible: input.text === ""
                        text: (launcher.stack.length > 0 ? launcher.stack[launcher.stack.length - 1].label : "Search") + "…"
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: launcher.shell.fg
                        opacity: 0.58
                        font: input.font
                        // The submenu title retains the old header's click-to-back action.
                        MouseArea {
                            anchors.fill: parent
                            enabled: launcher.stack.length > 0 && input.text === ""
                            cursorShape: Qt.PointingHandCursor
                            onClicked: launcher.back()
                        }
                    }
                    Keys.onPressed: event => {
                        const n = launcher.rows.length
                        const ctrl = event.modifiers & Qt.ControlModifier
                        if (event.key === Qt.Key_Escape) launcher.back()
                        else if (event.key === Qt.Key_Backspace && input.text === "" && launcher.stack.length > 0) launcher.back()
                        else if (event.key === Qt.Key_Left && input.text === "" && launcher.stack.length > 0) launcher.back()
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) launcher.activate(launcher.rows[launcher.current])
                        else if (event.key === Qt.Key_Right && input.text === "" && launcher.rows[launcher.current]?.children) launcher.activate(launcher.rows[launcher.current])
                        else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N)))
                            launcher.current = n ? (launcher.current + 1) % n : 0
                        else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P)))
                            launcher.current = n ? (launcher.current - 1 + n) % n : 0
                        else return
                        event.accepted = true
                    }
                }
            }

            Text {
                id: logoutNotice
                anchors { top: search.bottom; left: search.left; right: search.right; topMargin: card.contentGap }
                visible: launcher.logoutMessage !== ""
                height: visible ? implicitHeight : 0
                text: launcher.logoutMessage
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: launcher.shell.yellow
                font { family: card.menuFont; pixelSize: 14 }
            }

            Item {
                id: results
                anchors { top: search.bottom; left: search.left; right: search.right; topMargin: card.contentGap + card.noticeHeight }
                height: card.rowsHeight
                ListView {
                    id: list
                    anchors.fill: parent
                    clip: true
                    spacing: card.rowGap
                    model: launcher.rows
                    currentIndex: launcher.current
                    boundsBehavior: Flickable.StopAtBounds
                    highlightMoveDuration: 0
                    onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                    // Defer until the new model/layout settles, including when index
                    // was already zero. Keep the query/stack/open scroll reset fix.
                    function resetScroll() { Qt.callLater(() => list.positionViewAtBeginning()) }
                    Connections {
                        target: launcher
                        function onOpenChanged() { list.resetScroll() }
                        function onQueryChanged() { list.resetScroll() }
                        function onStackChanged() { list.resetScroll() }
                    }
                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === launcher.current
                        readonly property var r: modelData
                        readonly property int dividerH: card.sectionBreak(index) ? 17 : 0
                        width: list.width
                        height: card.rowH + dividerH
                        Rectangle {
                            visible: row.dividerH > 0
                            x: 4; y: 8
                            width: parent.width - 8; height: 1
                            color: Qt.alpha(launcher.shell.fg, 0.2)
                        }
                        Rectangle {
                            id: rowBody
                            y: row.dividerH
                            width: parent.width
                            height: card.rowH
                            radius: card.radius
                            color: row.selected || rowMouse.containsMouse ? card.selectedFill : "transparent"
                            Item {
                                id: iconSlot
                                x: 8
                                width: 40; height: 26
                                anchors.verticalCenter: parent.verticalCenter
                                Rectangle {
                                    visible: !!row.r.thumb
                                    anchors.fill: parent
                                    clip: true
                                    color: launcher.shell.bgAlt
                                    Image {
                                        anchors.fill: parent
                                        source: Paths.toFileUrl(row.r.thumb || "")
                                        sourceSize { width: 72; height: 36 }
                                        fillMode: Image.PreserveAspectCrop
                                        asynchronous: true
                                    }
                                }
                                Rectangle {
                                    visible: !row.r.thumb && !!row.r.swatch
                                    anchors.centerIn: parent
                                    width: 18; height: 18; radius: 9
                                    color: row.r.swatch?.background || "transparent"
                                    border { width: 4; color: row.r.swatch?.accent || row.r.swatch?.green || launcher.shell.dim }
                                }
                                Image {
                                    id: appIcon
                                    visible: !row.r.thumb && !row.r.swatch && !!row.r.image && status !== Image.Error
                                    anchors.centerIn: parent
                                    width: 26; height: 26
                                    source: row.r.image || ""
                                    sourceSize.width: width * Screen.devicePixelRatio
                                    sourceSize.height: height * Screen.devicePixelRatio
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                }
                                Text {
                                    visible: !row.r.thumb && !row.r.swatch && (!row.r.image || appIcon.status === Image.Error)
                                    anchors.centerIn: parent
                                    text: launcher.shell.icon(row.r.glyph || 0xF08C6)
                                    color: row.r.danger ? launcher.shell.red : launcher.shell.fg
                                    font { family: launcher.shell.iconFont; pixelSize: 22 }
                                }
                            }
                            Text {
                                anchors { left: iconSlot.right; leftMargin: 6; right: trail.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                text: row.r.label
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: row.r.danger ? launcher.shell.red : launcher.shell.fg
                                font { family: card.menuFont; pixelSize: 19; weight: Font.Medium }
                            }
                            Text {
                                id: trail
                                anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                width: 14
                                text: row.r.check ? "✓" : (row.r.children && !row.r.confirm ? "›" : "")
                                color: row.r.check ? launcher.shell.green : launcher.shell.fg
                                opacity: row.r.check ? 1 : 0.36
                                font { family: card.menuFont; pixelSize: 20 }
                            }
                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: { launcher.current = row.index; launcher.activate(row.r) }
                            }
                        }
                    }
                }
                // Omarchy uses a clipped row and edge fades, not a scrollbar.
                Rectangle {
                    anchors { top: parent.top; left: parent.left; right: parent.right }
                    height: Math.min(28, parent.height / 2)
                    opacity: list.contentHeight > list.height && height > 0
                        ? Math.max(0, Math.min(1, (list.contentY - list.originY) / height)) : 0
                    gradient: Gradient {
                        GradientStop { position: 0; color: card.color }
                        GradientStop { position: 1; color: Qt.alpha(card.color, 0) }
                    }
                }
                Rectangle {
                    anchors { bottom: parent.bottom; left: parent.left; right: parent.right }
                    height: Math.min(28, parent.height / 2)
                    opacity: list.contentHeight > list.height && height > 0
                        ? Math.max(0, Math.min(1, (list.originY + list.contentHeight - list.height - list.contentY) / height)) : 0
                    gradient: Gradient {
                        GradientStop { position: 0; color: Qt.alpha(card.color, 0) }
                        GradientStop { position: 1; color: card.color }
                    }
                }
                Text {
                    anchors.fill: parent
                    visible: launcher.rows.length === 0
                    text: launcher.query ? "No matches for “" + launcher.query + "”" : "Nothing here yet"
                    textFormat: Text.PlainText
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    wrapMode: Text.Wrap
                    color: launcher.shell.fg
                    opacity: 0.7
                    font { family: card.menuFont; pixelSize: 14 }
                }
            }
        }
    }
}
