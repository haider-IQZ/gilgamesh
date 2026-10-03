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
import QtQuick.Layouts

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
    // log out gently: close every window (apps can save), then quit Hyprland
    function logout() {
        close()
        for (const t of Hyprland.toplevels.values)
            if (t.address && t.address !== "0") Hyprland.dispatch('hl.dsp.window.close({ window = "address:0x' + t.address + '" })')
        exitTimer.start()
    }
    Timer { id: exitTimer; interval: 2000; onTriggered: Hyprland.dispatch("hl.dsp.exit()") }

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
        if (row.children) { stack = stack.concat([row]); query = ""; input.text = ""; current = 0; return }
        row.run()
        if (row.stay) version++
    }
    function back() {
        if (stack.length === 0) { close(); return }
        stack = stack.slice(0, -1); current = 0
    }
    onOpenChanged: {
        if (!open) return
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
        visible: launcher.open
        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "gilgamesh-launcher"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        color: "transparent"

        // click outside = close
        MouseArea { anchors.fill: parent; onClicked: launcher.close() }

        // same size as the old rofi: 500x550, centered, name-only rows with 28px icons
        Rectangle {
            id: card
            readonly property int rowH: 44
            width: 500
            height: 550
            anchors.centerIn: parent
            radius: 12
            color: launcher.shell.bg
            border { color: launcher.shell.bgAlt; width: 1 }
            opacity: launcher.open ? 1 : 0
            scale: launcher.open ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 120 } }
            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
            MouseArea { anchors.fill: parent }   // clicks on the card don't close it

            // search, with where you are ("Power ›") in front
            RowLayout {
                id: search
                anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 26; leftMargin: 32; rightMargin: 32 }
                height: 40
                spacing: 10
                Text {
                    text: launcher.shell.icon(launcher.stack.length > 0 ? 0xF004D : 0xF0349)   // back arrow / magnify
                    color: backMouse.containsMouse ? launcher.shell.yellow : launcher.shell.dim
                    font { family: launcher.shell.iconFont; pixelSize: 20 }
                    MouseArea { id: backMouse; anchors.fill: parent; anchors.margins: -6; hoverEnabled: true
                        enabled: launcher.stack.length > 0; cursorShape: Qt.PointingHandCursor; onClicked: launcher.back() }
                }
                Text {
                    visible: launcher.stack.length > 0
                    text: launcher.stack.map(s => s.label).join(" › ") + " ›"
                    color: launcher.shell.yellow
                    font { family: launcher.shell.font; pixelSize: 17; bold: true }
                }
                TextInput {
                    id: input
                    Layout.fillWidth: true
                    verticalAlignment: TextInput.AlignVCenter
                    color: launcher.shell.fg
                    selectionColor: launcher.shell.blue
                    font { family: launcher.shell.font; pixelSize: 17 }
                    focus: launcher.open
                    onTextChanged: launcher.query = text
                    Component.onCompleted: forceActiveFocus()
                    Connections {
                        target: launcher
                        function onOpenChanged() { if (launcher.open) { input.text = ""; input.forceActiveFocus() } }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: input.text === ""
                        text: launcher.stack.length > 0 ? "Search" : "Search apps, themes, power…"
                        color: launcher.shell.faint
                        font: input.font
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

            // rows
            ListView {
                id: list
                anchors { top: search.bottom; bottom: parent.bottom; left: parent.left; right: parent.right
                          topMargin: 14; bottomMargin: 15; leftMargin: 15; rightMargin: 15 }
                clip: true
                spacing: 4
                model: launcher.rows
                currentIndex: launcher.current
                boundsBehavior: Flickable.StopAtBounds
                highlightMoveDuration: 0
                onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)
                // back to the top when it opens, on every new search and in every submenu
                Connections {
                    target: launcher
                    function onOpenChanged() { list.positionViewAtBeginning() }
                    function onQueryChanged() { list.positionViewAtBeginning() }
                    function onStackChanged() { list.positionViewAtBeginning() }
                }
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property bool selected: index === launcher.current
                    readonly property var r: modelData
                    width: ListView.view.width
                    height: card.rowH
                    radius: 8
                    color: selected ? launcher.shell.bgAlt : (rowMouse.containsMouse ? launcher.shell.hover : "transparent")
                    RowLayout {
                        anchors { fill: parent; leftMargin: 10; rightMargin: 12 }
                        spacing: 12
                        // what's in front: wallpaper thumbnail, theme colors, app icon or a glyph
                        Item {
                            implicitWidth: row.r.thumb ? 48 : 28
                            implicitHeight: 28
                            Rectangle {
                                visible: !!row.r.thumb
                                anchors.fill: parent
                                radius: 4
                                clip: true
                                color: launcher.shell.bgAlt
                                Image {
                                    anchors.fill: parent
                                    source: row.r.thumb ? "file://" + row.r.thumb : ""
                                    sourceSize { width: 96; height: 56 }
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                            }
                            Rectangle {   // a theme: its background ringed with its accent
                                visible: !row.r.thumb && !!row.r.swatch
                                anchors.centerIn: parent
                                width: 22; height: 22; radius: 11
                                color: row.r.swatch?.background || "transparent"
                                border { width: 5; color: row.r.swatch?.accent || row.r.swatch?.green || launcher.shell.dim }
                            }
                            Image {
                                visible: !row.r.thumb && !row.r.swatch && !!row.r.image
                                anchors.fill: parent
                                source: row.r.image || ""
                                sourceSize { width: 56; height: 56 }
                                asynchronous: true
                            }
                            Text {
                                visible: !row.r.thumb && !row.r.swatch && !row.r.image
                                anchors.centerIn: parent
                                text: launcher.shell.icon(row.r.glyph || 0xF08C6)
                                color: row.r.danger ? launcher.shell.red : (row.selected ? launcher.shell.yellow : launcher.shell.dim)
                                font { family: launcher.shell.iconFont; pixelSize: 20 }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: row.r.label
                            elide: Text.ElideRight
                            color: row.r.danger ? launcher.shell.red : (row.selected ? launcher.shell.yellow : launcher.shell.fg)
                            font { family: launcher.shell.font; pixelSize: 15; bold: row.selected }
                        }
                        Text {   // where a search result lives ("Power")
                            visible: !!row.r.parent
                            text: row.r.parent || ""
                            color: launcher.shell.faint
                            font { family: launcher.shell.font; pixelSize: 12 }
                        }
                        Text {
                            visible: !!row.r.check
                            text: launcher.shell.icon(0xF012C)
                            color: launcher.shell.green
                            font { family: launcher.shell.iconFont; pixelSize: 16 }
                        }
                        Text {
                            visible: !!row.r.children && !row.r.confirm
                            text: "›"
                            color: launcher.shell.dim
                            font { family: launcher.shell.font; pixelSize: 18 }
                        }
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { launcher.current = row.index; launcher.activate(row.r) }
                    }
                }
                Text {
                    anchors.centerIn: parent
                    visible: launcher.rows.length === 0
                    text: launcher.query ? "Nothing matches “" + launcher.query + "”" : "Nothing here"
                    color: launcher.shell.dim
                    font { family: launcher.shell.font; pixelSize: 14 }
                }
            }
        }
    }
}
