// Wallpaper picker in the middle of the screen, like Omarchy's: the chosen wallpaper as a big
// card, its neighbors as slanted slices around it.
//   ← → choose · ↑ ↓ another theme's wallpapers (or your folder) · Enter set · Esc close
// Opens from the launcher's Wallpaper row, Super+W, or `qs ipc call wallpaper pick`.
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import QtQuick.Shapes
import QtQuick.Effects

Scope {
    id: picker
    required property var shell
    property bool open: false

    // same sizes as Omarchy's picker
    readonly property int expandedWidth: 768
    readonly property int expandedHeight: 475
    readonly property int sliceWidth: 108
    readonly property int sliceHeight: 432
    readonly property int sliceSpacing: -30
    readonly property int skew: 28
    readonly property int radius: 8          // slices drawn on each side

    // where the pictures come from: every theme that has wallpapers, then your folder
    property var sources: []                 // [{ label, folder }]
    property int sourceIndex: 0
    property var files: []
    property int selected: 0
    readonly property var source: sources[sourceIndex] ?? null

    function titled(n) { return n.split("-").map(w => w[0].toUpperCase() + w.slice(1)).join(" ") }
    function show() {
        const th = shell.theme
        const list = th.names.filter(n => (th.wallCounts[n] || 0) > 0)
            .map(n => ({ label: titled(n), folder: th.dir + "/" + n + "/backgrounds" }))
        list.push({ label: "Your folder", folder: shell.wallpaperFolder })
        sources = list
        // start where the current wallpaper comes from, else the current theme, else your folder
        const cur = shell.prefs.wallpaper || ""
        const m = cur.match(/\/themes\/([^/]+)\/backgrounds\//)
        let i = m ? list.findIndex(s => s.label === titled(m[1])) : -1
        if (i < 0) i = cur.startsWith(shell.wallpaperFolder + "/") ? list.length - 1 : list.findIndex(s => s.label === titled(th.name))
        sourceIndex = i < 0 ? list.length - 1 : i
        open = true
        listFiles()
    }
    function listFiles() {
        if (!source) return
        lister.forFolder = source.folder
        lister.command = ["sh", "-c", "find \"$1\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \\) 2>/dev/null | sort", "sh", source.folder]
        lister.running = false
        lister.running = true
    }
    Process {
        id: lister
        property string forFolder: ""
        stdout: StdioCollector {
            onStreamFinished: {
                if (!picker.source || lister.forFolder !== picker.source.folder) return   // a late answer
                picker.files = this.text.trim().split("\n").filter(f => f !== "")
                const at = picker.files.indexOf(picker.shell.prefs.wallpaper)
                picker.selected = at >= 0 ? at : 0
            }
        }
    }
    function move(d) { if (files.length) selected = (selected + d + files.length) % files.length }
    function cycleSource(d) {
        if (sources.length < 2) return
        sourceIndex = (sourceIndex + d + sources.length) % sources.length
        files = []
        listFiles()
    }
    function apply() {
        if (files.length) shell.prefs.wallpaper = files[selected]
        open = false
    }
    function niceName(f) { return f.slice(f.lastIndexOf("/") + 1).replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ") }

    // the slices to draw: the chosen one and `radius` on each side
    readonly property var visibleItems: {
        const out = []
        for (let rel = -radius; rel <= radius; rel++) {
            const idx = selected + rel
            if (idx >= 0 && idx < files.length) out.push({ idx: idx, rel: rel })
        }
        return out
    }

    PanelWindow {
        id: win
        visible: picker.open
        screen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? Quickshell.screens[0]
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "gilgamesh-wallpaper-picker"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        color: Qt.rgba(picker.shell.bg.r, picker.shell.bg.g, picker.shell.bg.b, 0.6)   // dim the desktop

        MouseArea { anchors.fill: parent; onClicked: picker.open = false }

        Item {
            id: carousel
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -30
            width: picker.expandedWidth + 2 * picker.radius * (picker.sliceWidth + picker.sliceSpacing)
            height: picker.expandedHeight
            focus: picker.open
            readonly property real step: picker.sliceWidth + picker.sliceSpacing
            readonly property real previewX: (width - picker.expandedWidth) / 2
            Component.onCompleted: forceActiveFocus()
            Connections { target: picker; function onOpenChanged() { if (picker.open) carousel.forceActiveFocus() } }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) picker.open = false
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) picker.apply()
                else if (event.key === Qt.Key_Left || event.key === Qt.Key_H || event.key === Qt.Key_Backtab) picker.move(-1)
                else if (event.key === Qt.Key_Right || event.key === Qt.Key_L || event.key === Qt.Key_Tab) picker.move(1)
                else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) picker.cycleSource(-1)
                else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) picker.cycleSource(1)
                else return
                event.accepted = true
            }

            Repeater {
                model: picker.visibleItems
                delegate: Item {
                    id: item
                    required property var modelData
                    readonly property int idx: modelData.idx
                    readonly property int rel: modelData.rel
                    readonly property bool chosen: rel === 0
                    readonly property string file: picker.files[idx] ?? ""

                    x: chosen ? carousel.previewX
                        : (rel < 0 ? carousel.previewX + rel * carousel.step
                                   : carousel.previewX + picker.expandedWidth + picker.sliceSpacing + (rel - 1) * carousel.step)
                    y: chosen ? 0 : (picker.expandedHeight - picker.sliceHeight) / 2
                    width: chosen ? picker.expandedWidth : picker.sliceWidth
                    height: chosen ? picker.expandedHeight : picker.sliceHeight
                    z: chosen ? 100 : 50 - Math.abs(rel)
                    Behavior on x { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                    Behavior on y { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                    Behavior on width { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                    Behavior on height { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }

                    // a parallelogram: top edge shifted right by `skew`
                    Item {
                        id: mask
                        anchors.fill: parent
                        visible: false
                        layer.enabled: true
                        Shape {
                            anchors.fill: parent
                            antialiasing: true
                            preferredRendererType: Shape.CurveRenderer
                            ShapePath {
                                fillColor: "white"
                                strokeColor: "transparent"
                                startX: picker.skew; startY: 0
                                PathLine { x: item.width; y: 0 }
                                PathLine { x: item.width - picker.skew; y: item.height }
                                PathLine { x: 0; y: item.height }
                                PathLine { x: picker.skew; y: 0 }
                            }
                        }
                    }
                    Item {
                        anchors.fill: parent
                        layer.enabled: true
                        layer.smooth: true
                        layer.effect: MultiEffect {
                            maskEnabled: true
                            maskSource: mask
                            maskThresholdMin: 0.3
                            maskSpreadAtMin: 0.3
                        }
                        Rectangle { anchors.fill: parent; color: picker.shell.bg }
                        Image {
                            anchors.fill: parent
                            source: item.file ? "file://" + item.file : ""
                            // decoded at the big card's size, so moving around never reloads it
                            sourceSize { width: picker.expandedWidth; height: picker.expandedHeight }
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            opacity: status === Image.Ready ? 1 : 0
                            Behavior on opacity { NumberAnimation { duration: 90 } }
                        }
                        Rectangle {   // the slices are dimmed
                            anchors.fill: parent
                            color: picker.shell.bg
                            opacity: item.chosen ? 0 : 0.42
                        }
                    }
                    Shape {   // the outline
                        anchors.fill: parent
                        antialiasing: true
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            fillColor: "transparent"
                            strokeColor: item.chosen ? picker.shell.yellow : picker.shell.bgAlt
                            strokeWidth: item.chosen ? 3 : 1
                            startX: picker.skew; startY: 0
                            PathLine { x: item.width; y: 0 }
                            PathLine { x: item.width - picker.skew; y: item.height }
                            PathLine { x: 0; y: item.height }
                            PathLine { x: picker.skew; y: 0 }
                        }
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: item.chosen ? picker.apply() : (picker.selected = item.idx)
                    }
                }
            }
        }

        // name, where it's from, and the keys
        Column {
            anchors { top: carousel.bottom; topMargin: 22; horizontalCenter: parent.horizontalCenter }
            spacing: 8
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: picker.files.length ? picker.niceName(picker.files[picker.selected] ?? "") : "No wallpapers here"
                color: picker.shell.fg
                style: Text.Outline
                styleColor: Qt.rgba(0, 0, 0, 0.5)
                font { family: picker.shell.font; pixelSize: 24; weight: Font.DemiBold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: (picker.source ? picker.source.label : "") + (picker.files.length ? "  ·  " + (picker.selected + 1) + " / " + picker.files.length : "")
                color: picker.shell.yellow
                font { family: picker.shell.font; pixelSize: 15; bold: true }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "← →  choose     ↑ ↓  " + (picker.sources.length > 1 ? "other themes" : "") + "     Enter  set     Esc  close"
                color: picker.shell.dim
                font { family: picker.shell.font; pixelSize: 12 }
            }
        }
    }
}
