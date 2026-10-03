// Gilgamesh Settings: a normal app window, opened by clicking the 永 logo on the bar.
// To add a page: add an entry to `pages` and a matching item to the StackLayout below.

import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Networking
import QtQuick
import QtQuick.Layouts

FloatingWindow {
    id: win
    required property var shell     // the bar's root: colors, fonts, notifications, network
    title: "Gilgamesh Settings"      // Hyprland floats + centers this title (hyprland.lua)
    minimumSize: Qt.size(820, 540)
    implicitWidth: 960
    implicitHeight: 640
    color: shell.bg
    // closed from Hyprland (kill/close key): mark it hidden so the logo opens it again next click
    onClosed: visible = false

    property string page: "network"
    readonly property var pages: [
        { id: "network",       label: "Network",       icon: 0xF0200 },
        { id: "sound",         label: "Sound",         icon: 0xF057E },
        { id: "theme",         label: "Theme",         icon: 0xF03D8 },
        { id: "wallpaper",     label: "Wallpaper",     icon: 0xF02E9 },
        { id: "notifications", label: "Notifications", icon: 0xF009A },
        { id: "about",         label: "About",         icon: 0 }
    ]

    // ---------- shared bits ----------
    component Title: Text {
        color: win.shell.fg
        font { family: win.shell.font; pixelSize: 26; bold: true }
    }
    component Heading: Text {
        color: win.shell.dim
        font { family: win.shell.font; pixelSize: 12; bold: true; letterSpacing: 1.2 }
    }
    component Body: Text {
        color: win.shell.fg
        font { family: win.shell.font; pixelSize: 15 }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---------- sidebar ----------
        Rectangle {
            Layout.fillHeight: true
            Layout.preferredWidth: 230
            color: win.shell.bgDark

            ColumnLayout {
                anchors { fill: parent; margins: 16 }
                spacing: 4

                RowLayout {
                    Layout.bottomMargin: 20
                    spacing: 10
                    Image {
                        source: win.shell.logo
                        sourceSize { width: 34; height: 34 }
                    }
                    Text {
                        text: "Settings"
                        color: win.shell.fg
                        font { family: win.shell.font; pixelSize: 18; bold: true }
                    }
                }

                Repeater {
                    model: win.pages
                    Rectangle {
                        required property var modelData
                        readonly property bool active: win.page === modelData.id
                        Layout.fillWidth: true
                        implicitHeight: 40
                        radius: 8
                        color: active ? win.shell.bgAlt : (navMouse.containsMouse ? win.shell.hover : "transparent")

                        RowLayout {
                            anchors { fill: parent; leftMargin: 12 }
                            spacing: 12
                            Item {
                                Layout.preferredWidth: 20; Layout.preferredHeight: 20
                                Text {
                                    anchors.centerIn: parent
                                    visible: parent.parent.parent.modelData.icon !== 0
                                    text: win.shell.icon(parent.parent.parent.modelData.icon || 0x20)
                                    color: parent.parent.parent.active ? win.shell.yellow : win.shell.dim
                                    font { family: win.shell.iconFont; pixelSize: 17 }
                                }
                                Image {
                                    anchors.fill: parent
                                    visible: parent.parent.parent.modelData.icon === 0
                                    source: win.shell.logo
                                    sourceSize { width: 20; height: 20 }
                                }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: parent.parent.modelData.label
                                color: parent.parent.active ? win.shell.fg : win.shell.dim
                                font { family: win.shell.font; pixelSize: 15; bold: parent.parent.active }
                            }
                        }
                        MouseArea {
                            id: navMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: win.page = parent.modelData.id
                        }
                    }
                }

                Item { Layout.fillHeight: true }
            }
        }

        // ---------- pages ----------
        // the page area: every page fills it, only the selected one is visible
        Item {
            id: pagesStack
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 32

            // ===== Network =====
            ColumnLayout {
                anchors.fill: parent
                visible: win.page === "network"
                id: netPage
                spacing: 18
                property string dns: ""
                property string pending: ""
                property string ip: ""
                readonly property var providers: ["DHCP", "Cloudflare", "Google", "OpenDNS", "Custom"]
                function refresh() {
                    dnsRead.running = true
                    if (win.shell.netDevice) {
                        ipRead.command = ["sh", "-c", "ip -4 -o addr show dev " + win.shell.netDevice.name + " | awk '{print $4}' | head -1"]
                        ipRead.running = true
                    }
                }
                onVisibleChanged: if (visible) refresh()
                Process { id: dnsRead; command: ["gilgamesh-dns"]
                    stdout: StdioCollector { onStreamFinished: netPage.dns = this.text.trim() } }
                Process { id: ipRead
                    stdout: StdioCollector { onStreamFinished: netPage.ip = this.text.trim() } }
                Process { id: dnsSet; onExited: { netPage.pending = ""; dnsRead.running = true } }

                Title { text: "Network" }

                Heading { text: "CONNECTION" }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 70
                    radius: 10
                    color: win.shell.bgAlt
                    RowLayout {
                        anchors { fill: parent; margins: 16 }
                        spacing: 14
                        Text {
                            text: win.shell.icon(!win.shell.netDevice ? 0xF0202 : (win.shell.netDevice.type === DeviceType.Wifi ? 0xF05A9 : 0xF0200))
                            color: win.shell.netDevice ? win.shell.green : win.shell.red
                            font { family: win.shell.iconFont; pixelSize: 26 }
                        }
                        ColumnLayout {
                            spacing: 2
                            Body {
                                text: !win.shell.netDevice ? "Offline"
                                    : (win.shell.netDevice.type === DeviceType.Wifi ? "Wi-Fi" : "Wired") + "  ·  " + win.shell.netDevice.name
                                font.bold: true
                            }
                            Text {
                                visible: !!win.shell.netDevice
                                text: (netPage.ip || "no IP yet")
                                    + (win.shell.netDevice?.linkSpeed > 0 ? "  ·  " + win.shell.netDevice.linkSpeed + " Mb/s" : "")
                                color: win.shell.dim
                                font { family: win.shell.font; pixelSize: 13 }
                            }
                        }
                    }
                }

                Heading { text: "DNS PROVIDER"; Layout.topMargin: 8 }
                Text {
                    text: "Applies system-wide. Cloudflare and Google use encrypted DNS (DNS-over-TLS)."
                    color: win.shell.dim
                    font { family: win.shell.font; pixelSize: 13 }
                }
                RowLayout {
                    spacing: 10
                    Repeater {
                        model: netPage.providers
                        Rectangle {
                            required property string modelData
                            readonly property bool current: netPage.dns === modelData
                            implicitWidth: 120
                            implicitHeight: 38
                            radius: 8
                            opacity: netPage.pending === modelData ? 0.5 : 1
                            color: current ? win.shell.yellow : (pMouse.containsMouse ? win.shell.hoverStrong : win.shell.bgAlt)
                            Text {
                                anchors.centerIn: parent
                                text: parent.modelData
                                color: parent.current ? win.shell.bg : win.shell.fg
                                font { family: win.shell.font; pixelSize: 14; bold: parent.current }
                            }
                            MouseArea {
                                id: pMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (netPage.pending !== "") return
                                    netPage.pending = parent.modelData
                                    dnsSet.command = parent.modelData === "Custom"
                                        ? ["foot", "--app-id", "gilgamesh-dns", "-e", "gilgamesh-dns", "Custom"]
                                        : ["gilgamesh-dns", parent.modelData]
                                    dnsSet.running = true
                                }
                            }
                        }
                    }
                }
                Item { Layout.fillHeight: true }
            }

            // ===== Sound =====
            ColumnLayout {
                anchors.fill: parent
                visible: win.page === "sound"
                id: soundPage
                spacing: 14
                // device snapshots (live PipeWire lists can crash Quickshell mid-removal)
                property var sinks: []
                property var sources: []
                readonly property var liveNodes: Pipewire.nodes.values
                function isAudio(n) { return !!n.audio || String(n.type).indexOf("Audio") >= 0 }
                function refresh() {
                    const nodes = liveNodes.slice()
                    sinks = nodes.filter(n => n && n.isSink && !n.isStream && isAudio(n))
                    sources = nodes.filter(n => n && !n.isSink && !n.isStream && isAudio(n) && n.name !== "quickshell")
                }
                onLiveNodesChanged: if (visible) soundTimer.restart()
                onVisibleChanged: { if (visible) refresh(); else { sinks = []; sources = [] } }
                Timer { id: soundTimer; interval: 75; onTriggered: soundPage.refresh() }
                PwObjectTracker { objects: soundPage.sinks.concat(soundPage.sources) }

                Title { text: "Sound" }

                Repeater {
                    model: [
                        { title: "OUTPUT", isOutput: true,  node: Pipewire.defaultAudioSink,   devices: soundPage.sinks,   accent: win.shell.cyan },
                        { title: "INPUT",  isOutput: false, node: Pipewire.defaultAudioSource, devices: soundPage.sources, accent: win.shell.purple }
                    ]
                    ColumnLayout {
                        id: sec
                        required property var modelData
                        readonly property var audio: modelData.node?.audio ?? null
                        readonly property real level: audio?.volume ?? 0
                        readonly property bool muted: audio?.muted ?? true
                        Layout.fillWidth: true
                        Layout.topMargin: 6
                        spacing: 8

                        RowLayout {
                            Layout.fillWidth: true
                            Heading { text: sec.modelData.title; Layout.fillWidth: true }
                            Text {
                                text: sec.muted ? "muted" : Math.round(sec.level * 100) + "%"
                                color: sec.muted ? win.shell.red : win.shell.dim
                                font { family: win.shell.font; pixelSize: 13 }
                                MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor
                                    onClicked: if (sec.audio) sec.audio.muted = !sec.audio.muted }
                            }
                        }
                        // slider
                        Item {
                            Layout.fillWidth: true
                            implicitHeight: 22
                            readonly property real fill: Math.max(0, Math.min(1, sec.level))
                            Rectangle {
                                anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                                height: 6; radius: 3; color: win.shell.bgAlt
                                Rectangle { width: parent.width * parent.parent.fill; height: parent.height; radius: 3
                                    color: sec.muted ? win.shell.dim : sec.modelData.accent }
                            }
                            Rectangle {
                                x: parent.width * parent.fill - width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: 16; height: 16; radius: 8; color: win.shell.fg
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                function setFrom(x) { if (sec.audio) sec.audio.volume = Math.max(0, Math.min(1, x / width)) }
                                onPressed: m => setFrom(m.x)
                                onPositionChanged: m => { if (pressed) setFrom(m.x) }
                            }
                        }
                        // devices
                        Repeater {
                            model: sec.modelData.devices
                            Rectangle {
                                id: dev
                                required property var modelData
                                readonly property bool current: sec.modelData.node !== null && modelData.id === sec.modelData.node.id
                                Layout.fillWidth: true
                                implicitHeight: 36
                                radius: 8
                                color: current ? win.shell.bgAlt : (devMouse.containsMouse ? win.shell.hover : "transparent")
                                RowLayout {
                                    anchors { fill: parent; leftMargin: 12; rightMargin: 12 }
                                    spacing: 12
                                    Text { text: dev.current ? "●" : "○"; color: dev.current ? win.shell.yellow : win.shell.dim
                                        font { family: win.shell.iconFont; pixelSize: 13 } }
                                    Text {
                                        Layout.fillWidth: true
                                        text: dev.modelData.nickname || dev.modelData.description || dev.modelData.name
                                        elide: Text.ElideRight
                                        color: dev.current ? win.shell.fg : win.shell.dim
                                        font { family: win.shell.font; pixelSize: 14 }
                                    }
                                }
                                MouseArea {
                                    id: devMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (sec.modelData.isOutput) Pipewire.preferredDefaultAudioSink = dev.modelData
                                        else Pipewire.preferredDefaultAudioSource = dev.modelData
                                    }
                                }
                            }
                        }
                    }
                }
                Item { Layout.fillHeight: true }
            }

            // ===== Theme =====
            // Every installed theme as a card in its own colors. A click switches the whole
            // desktop (bar, terminals, shells, prompt, wallpaper), see Theme.qml.
            ColumnLayout {
                anchors.fill: parent
                visible: win.page === "theme"
                spacing: 14
                onVisibleChanged: if (visible) win.shell.theme.refresh()

                Title { text: "Theme" }
                Text {
                    text: "Changes the bar, terminals, the shell and prompt, and the wallpaper if the theme has its own."
                    color: win.shell.dim
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                    font { family: win.shell.font; pixelSize: 13 }
                }

                Flickable {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: themeGrid.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    GridLayout {
                        id: themeGrid
                        width: parent.width
                        columns: 2
                        rowSpacing: 12
                        columnSpacing: 12

                        Repeater {
                            model: win.shell.theme.names
                            Rectangle {
                                id: themeCard
                                required property string modelData
                                readonly property var p: win.shell.theme.palettes[modelData] || ({})
                                readonly property bool isCurrent: modelData === win.shell.theme.name
                                Layout.fillWidth: true
                                Layout.preferredHeight: 104
                                radius: 10
                                color: p.background || win.shell.bg
                                border {
                                    width: isCurrent ? 3 : (cardMouse.containsMouse ? 2 : 1)
                                    color: isCurrent ? win.shell.yellow : (cardMouse.containsMouse ? win.shell.dim : win.shell.bgAlt)
                                }

                                ColumnLayout {
                                    anchors { fill: parent; margins: 16 }
                                    spacing: 10
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            Layout.fillWidth: true
                                            text: themeCard.modelData.split("-").map(w => w[0].toUpperCase() + w.slice(1)).join(" ")
                                            color: themeCard.p.foreground || win.shell.fg
                                            font { family: win.shell.font; pixelSize: 16; bold: true }
                                        }
                                        Text {
                                            visible: themeCard.isCurrent
                                            text: win.shell.icon(0xF012C)   // check
                                            color: themeCard.p.green || win.shell.green
                                            font { family: win.shell.iconFont; pixelSize: 18 }
                                        }
                                    }
                                    // the palette
                                    RowLayout {
                                        spacing: 6
                                        Repeater {
                                            model: ["red", "orange", "yellow", "green", "cyan", "blue", "magenta"]
                                            Rectangle {
                                                required property string modelData
                                                implicitWidth: 22; implicitHeight: 22; radius: 11
                                                color: themeCard.p[modelData] || "transparent"
                                            }
                                        }
                                    }
                                    // a line of "text" in its colors
                                    Text {
                                        textFormat: Text.RichText
                                        text: "<span style='color:" + (themeCard.p.green || "") + "'>git</span> "
                                            + "<span style='color:" + (themeCard.p.foreground || "") + "'>commit -m</span> "
                                            + "<span style='color:" + (themeCard.p.yellow || "") + "'>\"update\"</span>"
                                            + "<span style='color:" + (themeCard.p.dark_foreground || "") + "'>  # ~/hq</span>"
                                        font { family: "JetBrainsMono Nerd Font"; pixelSize: 12 }
                                    }
                                }
                                MouseArea {
                                    id: cardMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: win.shell.theme.set(themeCard.modelData)
                                }
                            }
                        }
                    }
                }
            }

            // ===== Wallpaper =====
            // Tabs: every theme that has wallpapers (themes/<name>/backgrounds), plus your own folder.
            // A click sets the wallpaper; the bar draws it itself, so it's instant. Everything lives
            // in the bar's settings file (shell.prefs).
            ColumnLayout {
                anchors.fill: parent
                visible: win.page === "wallpaper"
                id: wallPage
                spacing: 14
                readonly property string home: win.shell.home
                readonly property string current: win.shell.prefs.wallpaper
                readonly property var themesWithWalls: win.shell.theme.names.filter(n => (win.shell.theme.wallCounts[n] || 0) > 0)
                // "yours" or a theme name
                property string source: "yours"
                readonly property bool isYours: source === "yours"
                readonly property string folder: isYours ? win.shell.wallpaperFolder : win.shell.theme.dir + "/" + source + "/backgrounds"
                property var files: []
                function pretty(path) { return path.startsWith(home) ? "~" + path.slice(home.length) : path }
                function title(name) { return name.split("-").map(w => w[0].toUpperCase() + w.slice(1)).join(" ") }
                // open on the tab the current wallpaper comes from
                function pickSource() {
                    const m = current.match(/\/themes\/([^/]+)\/backgrounds\//)
                    source = m ? m[1] : "yours"
                }
                // the command is built here, from the folder right now (a binding on it could still
                // hold the previous tab's folder when this runs), and a late answer for another
                // folder is thrown away
                function refresh() {
                    listWalls.forFolder = folder
                    listWalls.command = ["sh", "-c", "find \"$1\" -maxdepth 1 -type f \\( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' \\) | sort", "sh", folder]
                    listWalls.running = false
                    listWalls.running = true
                }
                onFolderChanged: refresh()
                function useFolder(path) { win.shell.prefs.wallpaperFolder = path }
                function setWall(path) { win.shell.prefs.wallpaper = path }
                // pick one ourselves (never the current one) so the highlight can move instantly
                function setRandom() {
                    const others = files.filter(f => f !== current)
                    if (others.length > 0) setWall(others[Math.floor(Math.random() * others.length)])
                }
                onVisibleChanged: {
                    if (visible) { win.shell.theme.refresh(); pickSource(); refresh() }
                    else browser.visible = false
                }

                Process {
                    id: listWalls
                    property string forFolder: ""
                    stdout: StdioCollector {
                        onStreamFinished: {
                            if (listWalls.forFolder !== wallPage.folder) return
                            wallPage.files = this.text.trim().split("\n").filter(l => l !== "")
                        }
                    }
                }
                Process { id: openProc }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10
                    Title { text: "Wallpaper"; Layout.fillWidth: true }
                    Repeater {
                        model: [ { label: "Random", show: true },
                                 { label: "Change folder", show: wallPage.isYours },
                                 { label: "Open folder", show: true } ].filter(b => b.show)
                        Rectangle {
                            required property var modelData
                            implicitWidth: btnText.implicitWidth + 28; implicitHeight: 34; radius: 8
                            color: btnMouse.containsMouse ? win.shell.hoverStrong : win.shell.bgAlt
                            Text { id: btnText; anchors.centerIn: parent; text: parent.modelData.label; color: win.shell.fg
                                font { family: win.shell.font; pixelSize: 14 } }
                            MouseArea { id: btnMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (parent.modelData.label === "Random") wallPage.setRandom()
                                    else if (parent.modelData.label === "Change folder") browser.open(wallPage.folder)
                                    else { openProc.command = ["xdg-open", wallPage.folder]; openProc.running = true }
                                } }
                        }
                    }
                }

                // tabs: each theme with wallpapers (a dot in its color), then your own folder
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: wallPage.themesWithWalls.concat(["yours"])
                        Rectangle {
                            id: tab
                            required property string modelData
                            readonly property bool yours: modelData === "yours"
                            readonly property bool selected: wallPage.source === modelData
                            readonly property var p: yours ? ({}) : (win.shell.theme.palettes[modelData] || {})
                            implicitWidth: tabRow.implicitWidth + 26
                            implicitHeight: 34
                            radius: 17
                            color: selected ? win.shell.yellow : (tabMouse.containsMouse ? win.shell.hover : win.shell.bgAlt)
                            RowLayout {
                                id: tabRow
                                anchors.centerIn: parent
                                spacing: 8
                                Rectangle {   // the theme's colors: its background ringed with its accent
                                    visible: !tab.yours
                                    implicitWidth: 14; implicitHeight: 14; radius: 7
                                    color: tab.p.background || "transparent"
                                    border { width: 3; color: tab.p.accent || tab.p.green || win.shell.dim }
                                }
                                Text {
                                    visible: tab.yours
                                    text: win.shell.icon(0xF024B)   // folder
                                    color: tab.selected ? win.shell.bg : win.shell.yellow
                                    font { family: win.shell.iconFont; pixelSize: 14 }
                                }
                                Text {
                                    text: tab.yours ? "Your folder" : wallPage.title(tab.modelData)
                                    color: tab.selected ? win.shell.bg : win.shell.fg
                                    font { family: win.shell.font; pixelSize: 13; bold: tab.selected }
                                }
                                Text {
                                    visible: !tab.yours
                                    text: win.shell.theme.wallCounts[tab.modelData] || 0
                                    color: tab.selected ? win.shell.bg : win.shell.dim
                                    font { family: win.shell.font; pixelSize: 12 }
                                }
                            }
                            MouseArea { id: tabMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: { browser.visible = false; wallPage.source = tab.modelData } }
                        }
                    }
                }

                Text {
                    text: wallPage.isYours
                        ? wallPage.files.length + " wallpapers in " + wallPage.pretty(wallPage.folder)
                        : wallPage.files.length + " wallpapers that come with " + wallPage.title(wallPage.source)
                    color: win.shell.dim
                    font { family: win.shell.font; pixelSize: 13 }
                }

                // nothing to show yet (e.g. a new user whose Pictures folder has no images)
                ColumnLayout {
                    visible: wallPage.files.length === 0 && !browser.visible
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 14
                    Item { Layout.fillHeight: true }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: win.shell.icon(0xF02E9)
                        color: win.shell.dim
                        font { family: win.shell.iconFont; pixelSize: 48 }
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "No wallpapers in " + wallPage.pretty(wallPage.folder)
                        color: win.shell.fg
                        font { family: win.shell.font; pixelSize: 16 }
                    }
                    Rectangle {
                        visible: wallPage.isYours
                        Layout.alignment: Qt.AlignHCenter
                        implicitWidth: chooseText.implicitWidth + 32; implicitHeight: 38; radius: 8
                        color: win.shell.yellow
                        Text { id: chooseText; anchors.centerIn: parent; text: "Choose folder"; color: win.shell.bg
                            font { family: win.shell.font; pixelSize: 14; bold: true } }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: browser.open(wallPage.folder) }
                    }
                    Item { Layout.fillHeight: true }
                }

                // ---------- built-in folder browser (FolderBrowser.qml) ----------
                FolderBrowser {
                    id: browser
                    shell: win.shell
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    nameFilters: ["*.jpg", "*.jpeg", "*.png", "*.webp", "*.gif", "*.JPG", "*.JPEG", "*.PNG", "*.WEBP"]
                    countNoun: "image"
                    onChosen: path => wallPage.useFolder(path)
                }

                Flickable {
                    visible: !browser.visible && wallPage.files.length > 0
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    contentHeight: wallGrid.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    GridLayout {
                        id: wallGrid
                        width: parent.width
                        columns: 3
                        rowSpacing: 12
                        columnSpacing: 12

                        Repeater {
                            model: wallPage.files
                            Rectangle {
                                id: thumb
                                required property string modelData
                                readonly property bool isCurrent: modelData === wallPage.current
                                Layout.fillWidth: true
                                Layout.preferredHeight: width * 9 / 16
                                radius: 8
                                color: win.shell.bgAlt
                                border { width: isCurrent ? 3 : (tMouse.containsMouse ? 2 : 0); color: isCurrent ? win.shell.yellow : win.shell.faint }

                                Image {
                                    anchors { fill: parent; margins: thumb.isCurrent ? 3 : 0 }
                                    source: "file://" + thumb.modelData
                                    sourceSize.width: 400
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                }
                                MouseArea {
                                    id: tMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: wallPage.setWall(thumb.modelData)
                                }
                            }
                        }
                    }
                }
            }

            // ===== Notifications =====
            ColumnLayout {
                anchors.fill: parent
                visible: win.page === "notifications"
                spacing: 18
                Title { text: "Notifications" }

                Heading { text: "DO NOT DISTURB" }
                RowLayout {
                    spacing: 14
                    // switch
                    Rectangle {
                        implicitWidth: 48; implicitHeight: 26; radius: 13
                        color: win.shell.dnd ? win.shell.red : win.shell.bgAlt
                        Rectangle {
                            width: 20; height: 20; radius: 10
                            anchors.verticalCenter: parent.verticalCenter
                            x: win.shell.dnd ? parent.width - width - 3 : 3
                            color: win.shell.fg
                            Behavior on x { NumberAnimation { duration: 120 } }
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                            onClicked: { win.shell.dnd = !win.shell.dnd; if (win.shell.dnd) win.shell.popups = [] } }
                    }
                    Body { text: win.shell.dnd ? "On: popups are paused, notifications still go to the list" : "Off" }
                }

                Heading { text: "HISTORY"; Layout.topMargin: 8 }
                RowLayout {
                    spacing: 14
                    Body { text: win.shell.history.length + " notification" + (win.shell.history.length === 1 ? "" : "s") }
                    Rectangle {
                        visible: win.shell.history.length > 0
                        implicitWidth: 110; implicitHeight: 34; radius: 8
                        color: clearMouse.containsMouse ? win.shell.hoverStrong : win.shell.bgAlt
                        Text { anchors.centerIn: parent; text: "Clear all"; color: win.shell.fg
                            font { family: win.shell.font; pixelSize: 14 } }
                        MouseArea { id: clearMouse; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; onClicked: win.shell.clearNotifications() }
                    }
                }
                Item { Layout.fillHeight: true }
            }

            // ===== About =====
            ColumnLayout {
                anchors.fill: parent
                visible: win.page === "about"
                id: aboutPage
                spacing: 16
                property string kernel: ""
                property string host: ""
                onVisibleChanged: if (visible) sysRead.running = true
                Process { id: sysRead; command: ["sh", "-c", "uname -r; hostname"]
                    stdout: StdioCollector { onStreamFinished: {
                        const l = this.text.trim().split("\n"); aboutPage.kernel = l[0] ?? ""; aboutPage.host = l[1] ?? "" } } }

                Item { Layout.fillHeight: true }
                Image {
                    Layout.alignment: Qt.AlignHCenter
                    source: win.shell.logo
                    sourceSize { width: 128; height: 128 }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Gilgamesh Linux"
                    color: win.shell.fg
                    font { family: win.shell.font; pixelSize: 30; bold: true }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "永  ·  eternity"
                    color: win.shell.green
                    font { family: win.shell.font; pixelSize: 16 }
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: 10
                    text: aboutPage.host + "  ·  kernel " + aboutPage.kernel
                    color: win.shell.dim
                    font { family: win.shell.font; pixelSize: 13 }
                }
                Item { Layout.fillHeight: true }
            }
        }
    }
}
