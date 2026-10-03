// The media dropdown. Two modes:
//   Now Playing: whatever is playing (any MPRIS player like Firefox/Spotify, or our local music)
//   Library:     the music folder (MusicPlayer.qml): play tracks, download from a link with
//                yt-dlp into the same folder, change the folder with the built-in browser.
import Quickshell
import Quickshell.Widgets
import Quickshell.Services.Pipewire
import QtQuick
import QtQuick.Layouts

Item {
    id: card
    required property var shell
    readonly property var music: shell.music
    readonly property var player: shell.media
    readonly property bool isLocal: player === music
    // Time and seek bar only for local music: mpv's numbers are exact. Browsers don't report them
    // reliably (Firefox sends position 0 and drops the length after every seek), so for other
    // players the card shows no time at all, same as Omarchy.
    readonly property real trackLength: isLocal ? music.length : 0
    readonly property real position: isLocal ? music.position : 0
    property string mode: "playing"   // "playing" or "library"

    width: 420
    height: col.implicitHeight + 32
    MouseArea { anchors.fill: parent } // clicks on the card don't close it

    onVisibleChanged: {
        if (visible) { music.refresh(); refreshStreams(); if (!player) mode = "library" }
        else { browser.visible = false; streamTimer.stop(); streams = [] }
    }

    function fmt(s) {
        s = Math.max(0, Math.floor(s || 0))
        const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60
        const mm = h > 0 && m < 10 ? "0" + m : "" + m
        return (h > 0 ? h + ":" : "") + mm + ":" + (sec < 10 ? "0" : "") + sec
    }
    function seek(seconds) { if (isLocal) music.seekTo(seconds) }
    // ---------- volume ----------
    // Local music: mpv's own volume. Other players: the app's own PipeWire streams (like a
    // per-app mixer), which works for every app. Firefox's MPRIS volume is only the fallback.
    // Streams are a snapshot refreshed shortly after PipeWire changes, only while open
    // (rebuilding from the live list while a stream disappears can crash Quickshell).
    property var streams: []
    readonly property var liveNodes: Pipewire.nodes.values
    function refreshStreams() {
        streams = liveNodes.slice().filter(n => n && n.isStream && n.isSink && n.audio)
    }
    onLiveNodesChanged: if (visible) streamTimer.restart()
    Timer { id: streamTimer; interval: 75; onTriggered: card.refreshStreams() }
    PwObjectTracker { objects: card.streams }

    // a stream belongs to the player if its name matches the app ("Firefox" ~ "firefox")
    function ownsStream(p, n) {
        const name = (n.name || "").toLowerCase()
        if (!name) return false
        return [p.desktopEntry, p.identity].filter(k => k).map(k => k.toLowerCase())
            .some(k => k === name || k.includes(name) || name.includes(k))
    }
    readonly property var appStreams: !player || isLocal ? [] : streams.filter(n => ownsStream(player, n))
    readonly property bool hasVolume: !!player && (isLocal || appStreams.length > 0 || player.volumeSupported)
    readonly property real volume: !player ? 0
        : isLocal ? music.volume
        : appStreams.length > 0 ? (appStreams[0].audio?.volume ?? 0)
        : player.volume
    readonly property bool volumeMuted: isLocal ? music.muted : (appStreams[0]?.audio?.muted ?? false)
    function setVolume(v) {
        v = Math.max(0, Math.min(1, v))
        if (isLocal) music.setVolume(v)
        else if (appStreams.length > 0) { for (const n of appStreams) if (n.audio) n.audio.volume = v }
        else if (player.volumeSupported) player.volume = v
    }
    function toggleMute() {
        if (isLocal) music.toggleMute()
        else { const m = !volumeMuted; for (const n of appStreams) if (n.audio) n.audio.muted = m }
    }

    function appIcon(p) {
        if (!p || p === music) return ""
        const e = DesktopEntries.byId(p.desktopEntry) ?? DesktopEntries.heuristicLookup(p.identity)
        return Quickshell.iconPath(e?.icon || p.desktopEntry, true)
    }
    function pretty(p) { return p.startsWith(shell.home) ? "~" + p.slice(shell.home.length) : p }

    // ---------- small building blocks ----------
    component IconTab: Rectangle {
        id: tab
        property int glyph
        property bool current: false
        signal clicked
        implicitWidth: 40
        implicitHeight: 32
        radius: 8
        color: current ? card.shell.yellow : (tabMouse.containsMouse ? card.shell.hover : card.shell.bgAlt)
        Text {
            anchors.centerIn: parent
            text: card.shell.icon(tab.glyph)
            color: tab.current ? card.shell.bg : card.shell.fg
            font { family: card.shell.iconFont; pixelSize: 18 }
        }
        MouseArea { id: tabMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: tab.clicked() }
    }
    component Button: Rectangle {
        id: btn
        property string label
        property bool primary: false
        signal clicked
        implicitWidth: btnText.implicitWidth + 24
        implicitHeight: 34
        radius: 8
        color: primary ? card.shell.yellow : (btnMouse.containsMouse ? card.shell.hoverStrong : card.shell.bgAlt)
        Text {
            id: btnText
            anchors.centerIn: parent
            text: btn.label
            color: btn.primary ? card.shell.bg : card.shell.fg
            font { family: card.shell.font; pixelSize: 13; bold: btn.primary }
        }
        MouseArea { id: btnMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: btn.clicked() }
    }
    component IconButton: Text {
        id: ib
        property int glyph
        property color tint: card.shell.fg
        property bool enabledState: true
        signal clicked
        text: card.shell.icon(glyph)
        color: !enabledState ? card.shell.faint : (ibMouse.containsMouse ? card.shell.yellow : tint)
        font { family: card.shell.iconFont; pixelSize: 26 }
        MouseArea {
            id: ibMouse
            anchors.fill: parent; anchors.margins: -6
            hoverEnabled: true
            cursorShape: ib.enabledState ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: if (ib.enabledState) ib.clicked()
        }
    }

    Rectangle {
        anchors.fill: parent
        color: card.shell.bg
        radius: 10
        border { color: card.shell.bgAlt; width: 1 }

        ColumnLayout {
            id: col
            anchors { left: parent.left; right: parent.right; top: parent.top; margins: 16 }
            spacing: 14

            // mode switch (left) + which player (right, only when there's more than one)
            RowLayout {
                Layout.fillWidth: true
                spacing: 6
                IconTab { glyph: 0xF075A; current: card.mode === "playing"; onClicked: card.mode = "playing" }   // now playing
                IconTab { glyph: 0xF0CB8; current: card.mode === "library"; onClicked: card.mode = "library" }   // library
                Item { Layout.fillWidth: true }
                IconTab {   // change the music folder
                    visible: card.mode === "library"
                    glyph: 0xF024B
                    current: browser.visible
                    onClicked: browser.visible ? browser.visible = false : browser.open(card.music.folder)
                }
                Repeater {
                    model: card.mode === "playing" && card.shell.mediaList.length > 1 ? card.shell.mediaList : []
                    Rectangle {
                        id: playerTab
                        required property var modelData
                        readonly property bool current: modelData === card.player
                        readonly property string iconSrc: card.appIcon(modelData)
                        implicitWidth: 36
                        implicitHeight: 32
                        radius: 8
                        color: current ? card.shell.bgAlt : (ptMouse.containsMouse ? card.shell.hover : "transparent")
                        Image {
                            anchors.centerIn: parent
                            visible: playerTab.iconSrc !== ""
                            source: playerTab.iconSrc
                            sourceSize { width: 20; height: 20 }
                            opacity: playerTab.current ? 1 : 0.45
                        }
                        Text {
                            anchors.centerIn: parent
                            visible: playerTab.iconSrc === ""
                            text: card.shell.icon(0xF075A)
                            color: card.shell.green
                            opacity: playerTab.current ? 1 : 0.45
                            font { family: card.shell.iconFont; pixelSize: 18 }
                        }
                        Rectangle {   // the one shown
                            visible: playerTab.current
                            anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 3 }
                            width: 14; height: 2; radius: 1
                            color: card.shell.yellow
                        }
                        MouseArea { id: ptMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: card.shell.mediaPick = playerTab.modelData }
                    }
                }
            }

            // ===================== Now Playing =====================
            ColumnLayout {
                visible: card.mode === "playing"
                Layout.fillWidth: true
                spacing: 14

                // nothing playing anywhere
                ColumnLayout {
                    visible: !card.player
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    Layout.bottomMargin: 10
                    spacing: 10
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: card.shell.icon(0xF075A)
                        color: card.shell.dim
                        font { family: card.shell.iconFont; pixelSize: 40 }
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Nothing playing"
                        color: card.shell.fg
                        font { family: card.shell.font; pixelSize: 15 }
                    }
                    Button {
                        Layout.alignment: Qt.AlignHCenter
                        label: "Open Library"
                        onClicked: card.mode = "library"
                    }
                }

                // cover + title
                RowLayout {
                    visible: !!card.player
                    Layout.fillWidth: true
                    spacing: 14

                    ClippingRectangle {
                        implicitWidth: 96
                        implicitHeight: 96
                        radius: 8
                        color: card.shell.bgAlt
                        Text {
                            anchors.centerIn: parent
                            visible: cover.status !== Image.Ready
                            text: card.shell.icon(0xF075A)
                            color: card.shell.dim
                            font { family: card.shell.iconFont; pixelSize: 36 }
                        }
                        Image {
                            id: cover
                            anchors.fill: parent
                            source: card.player?.trackArtUrl ?? ""
                            sourceSize { width: 192; height: 192 }
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: false
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        Text {
                            Layout.fillWidth: true
                            text: "\u200E" + (card.player?.trackTitle || "Unknown title")
                            horizontalAlignment: Text.AlignLeft
                            color: card.shell.fg
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                            font { family: card.shell.font; pixelSize: 16; bold: true }
                        }
                        Text {
                            Layout.fillWidth: true
                            visible: text !== ""
                            text: card.player?.trackArtist ?? ""
                            horizontalAlignment: Text.AlignLeft
                            color: card.shell.fg
                            elide: Text.ElideRight
                            font { family: card.shell.font; pixelSize: 14 }
                        }
                    }
                }

                // progress: click or drag to seek
                ColumnLayout {
                    visible: !!card.player && card.trackLength > 0
                    Layout.fillWidth: true
                    spacing: 4
                    Item {
                        id: progress
                        Layout.fillWidth: true
                        implicitHeight: 16
                        readonly property real len: card.trackLength
                        readonly property real pos: seekMouse.pressed ? seekMouse.preview : card.position
                        readonly property real fill: len > 0 ? Math.max(0, Math.min(1, pos / len)) : 0
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: 4; radius: 2
                            color: card.shell.bgAlt
                            Rectangle { width: parent.width * progress.fill; height: parent.height; radius: 2; color: card.shell.green }
                        }
                        Rectangle {
                            visible: seekMouse.containsMouse || seekMouse.pressed
                            x: parent.width * progress.fill - width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 12; height: 12; radius: 6
                            color: card.shell.fg
                        }
                        MouseArea {
                            id: seekMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: card.isLocal
                            cursorShape: Qt.PointingHandCursor
                            property real preview: 0
                            function at(x) { return Math.max(0, Math.min(1, x / width)) * progress.len }
                            onPressed: mouse => preview = at(mouse.x)
                            onPositionChanged: mouse => { if (pressed) preview = at(mouse.x) }
                            onReleased: mouse => card.seek(at(mouse.x))
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: card.fmt(progress.pos); color: card.shell.dim; font { family: card.shell.font; pixelSize: 12 } }
                        Item { Layout.fillWidth: true }
                        Text { text: card.fmt(progress.len); color: card.shell.dim; font { family: card.shell.font; pixelSize: 12 } }
                    }
                }

                // controls
                RowLayout {
                    visible: !!card.player
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 26
                    IconButton {
                        visible: card.isLocal
                        glyph: 0xF049D   // shuffle
                        tint: card.music.shuffle ? card.shell.green : card.shell.dim
                        font.pixelSize: 20
                        onClicked: card.music.setShuffle(!card.music.shuffle)
                    }
                    IconButton {
                        glyph: 0xF04AE   // previous
                        enabledState: card.player?.canGoPrevious ?? false
                        onClicked: card.player.previous()
                    }
                    Rectangle {
                        implicitWidth: 48; implicitHeight: 48; radius: 24
                        color: playMouse.containsMouse ? card.shell.yellow : card.shell.green
                        Text {
                            anchors.centerIn: parent
                            text: card.shell.icon(card.player?.isPlaying ? 0xF03E4 : 0xF040A)
                            color: card.shell.bg
                            font { family: card.shell.iconFont; pixelSize: 26 }
                        }
                        MouseArea { id: playMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: card.player.togglePlaying() }
                    }
                    IconButton {
                        glyph: 0xF04AD   // next
                        enabledState: card.player?.canGoNext ?? false
                        onClicked: card.player.next()
                    }
                    IconButton {
                        visible: card.isLocal
                        glyph: 0xF04DB   // stop
                        tint: card.shell.dim
                        font.pixelSize: 20
                        onClicked: card.music.stop()
                    }
                }

                // volume of this player only: click the icon = mute, drag/click/scroll the slider
                RowLayout {
                    visible: card.hasVolume
                    Layout.fillWidth: true
                    spacing: 10
                    Text {
                        text: card.shell.icon(card.volumeMuted ? 0xF075F : 0xF057E)
                        color: card.volumeMuted ? card.shell.red : card.shell.cyan
                        font { family: card.shell.iconFont; pixelSize: 18 }
                        MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor; onClicked: card.toggleMute() }
                    }
                    Item {
                        id: volSlider
                        Layout.fillWidth: true
                        implicitHeight: 20
                        readonly property real fill: Math.max(0, Math.min(1, card.volume))
                        Rectangle {
                            anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter }
                            height: 6; radius: 3
                            color: card.shell.bgAlt
                            Rectangle {
                                width: parent.width * volSlider.fill
                                height: parent.height; radius: 3
                                color: card.volumeMuted ? card.shell.dim : card.shell.cyan
                            }
                        }
                        Rectangle {
                            x: parent.width * volSlider.fill - width / 2
                            anchors.verticalCenter: parent.verticalCenter
                            width: 14; height: 14; radius: 7
                            color: card.shell.fg
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onPressed: mouse => card.setVolume(mouse.x / width)
                            onPositionChanged: mouse => { if (pressed) card.setVolume(mouse.x / width) }
                            onWheel: wheel => card.setVolume(card.volume + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))
                        }
                    }
                    Text {
                        Layout.preferredWidth: 38
                        horizontalAlignment: Text.AlignRight
                        text: Math.round(card.volume * 100) + "%"
                        color: card.shell.fg
                        font { family: card.shell.font; pixelSize: 13 }
                    }
                }
            }

            // ===================== Library =====================
            // One field: typing searches the tracks, a pasted link downloads (Enter).
            ColumnLayout {
                id: library
                visible: card.mode === "library"
                Layout.fillWidth: true
                spacing: 10

                readonly property string text: field.text.trim()
                readonly property bool isLink: /^(https?:\/\/|www\.)/i.test(text)
                readonly property var shown: {
                    const q = isLink ? "" : text.toLowerCase()
                    return q ? card.music.tracks.filter(t => card.music.label(t).toLowerCase().includes(q)) : card.music.tracks
                }
                function submit() {
                    if (!isLink || card.music.downloading) return
                    card.music.download(text)
                    field.text = ""
                }

                // search / link field
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 38
                    radius: 8
                    color: card.shell.bgAlt
                    border { width: field.activeFocus ? 1 : 0; color: card.shell.yellow }
                    RowLayout {
                        anchors { fill: parent; leftMargin: 12; rightMargin: 8 }
                        spacing: 8
                        Text {
                            text: card.shell.icon(library.isLink ? 0xF0337 : 0xF0349)   // link / magnify
                            color: library.isLink ? card.shell.yellow : card.shell.dim
                            font { family: card.shell.iconFont; pixelSize: 16 }
                        }
                        TextInput {
                            id: field
                            Layout.fillWidth: true
                            verticalAlignment: TextInput.AlignVCenter
                            clip: true
                            color: card.shell.fg
                            selectionColor: card.shell.blue
                            selectByMouse: true
                            font { family: card.shell.font; pixelSize: 14 }
                            onAccepted: library.submit()
                            Keys.onEscapePressed: text = ""
                            onTextChanged: if (text !== "" && !card.music.downloading) card.music.dlStatus = ""
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width
                                visible: field.text === ""
                                text: "Search local music, or paste a link to download a song"
                                elide: Text.ElideRight
                                color: card.shell.dim
                                font { family: card.shell.font; pixelSize: 13 }
                            }
                        }
                        // download button, only for a link
                        Rectangle {
                            visible: library.isLink
                            implicitWidth: 30; implicitHeight: 26; radius: 6
                            color: card.music.downloading ? card.shell.hoverStrong : card.shell.yellow
                            Text {
                                anchors.centerIn: parent
                                text: card.shell.icon(0xF01DA)   // download
                                color: card.music.downloading ? card.shell.dim : card.shell.bg
                                font { family: card.shell.iconFont; pixelSize: 16 }
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: library.submit() }
                        }
                        // clear the search
                        Text {
                            visible: field.text !== "" && !library.isLink
                            text: card.shell.icon(0xF0156)   // close
                            color: clearMouse.containsMouse ? card.shell.fg : card.shell.dim
                            font { family: card.shell.iconFont; pixelSize: 15 }
                            MouseArea { id: clearMouse; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; onClicked: field.text = "" }
                        }
                    }
                }

                // download progress / last result
                ColumnLayout {
                    visible: card.music.downloading || card.music.dlStatus !== ""
                    Layout.fillWidth: true
                    spacing: 5
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Text {
                            text: card.shell.icon(card.music.downloading ? 0xF01DA : (card.music.dlFailed ? 0xF0026 : 0xF012C))
                            color: card.music.downloading ? card.shell.yellow : (card.music.dlFailed ? card.shell.red : card.shell.green)
                            font { family: card.shell.iconFont; pixelSize: 14 }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: "\u200E" + (card.music.downloading ? (card.music.dlTitle || "Starting…") : card.music.dlStatus)
                            color: card.music.downloading ? card.shell.fg : (card.music.dlFailed ? card.shell.red : card.shell.green)
                            elide: Text.ElideRight
                            font { family: card.shell.font; pixelSize: 12 }
                        }
                        Text {
                            visible: card.music.downloading
                            text: Math.round(card.music.dlPercent) + "%"
                            color: card.shell.dim
                            font { family: card.shell.font; pixelSize: 12 }
                        }
                        Text {   // cancel a download, or dismiss the result
                            text: card.shell.icon(0xF0156)
                            color: dismissMouse.containsMouse ? card.shell.fg : card.shell.dim
                            font { family: card.shell.iconFont; pixelSize: 14 }
                            MouseArea { id: dismissMouse; anchors.fill: parent; anchors.margins: -4; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: card.music.downloading ? card.music.cancelDownload() : card.music.dlStatus = "" }
                        }
                    }
                    Rectangle {
                        visible: card.music.downloading
                        Layout.fillWidth: true
                        implicitHeight: 3; radius: 1.5
                        color: card.shell.bgAlt
                        Rectangle {
                            width: parent.width * Math.min(1, card.music.dlPercent / 100)
                            height: parent.height; radius: 1.5
                            color: card.shell.green
                            Behavior on width { NumberAnimation { duration: 200 } }
                        }
                    }
                }

                // choosing another folder (the folder button in the top row)
                FolderBrowser {
                    id: browser
                    shell: card.shell
                    Layout.fillWidth: true
                    Layout.preferredHeight: 340
                    nameFilters: card.music.nameFilters
                    countNoun: "track"
                    onChosen: path => card.shell.prefs.musicFolder = path
                }

                // the tracks
                ListView {
                    id: trackList
                    visible: !browser.visible
                    Layout.fillWidth: true
                    // grows with the list, scrolls after ~11 tracks
                    Layout.preferredHeight: Math.min(330, Math.max(library.shown.length === 0 ? 60 : 0, contentHeight))
                    clip: true
                    spacing: 1
                    boundsBehavior: Flickable.StopAtBounds
                    model: library.shown
                    delegate: Rectangle {
                        id: trackRow
                        required property string modelData
                        readonly property bool current: card.music.active && modelData === card.music.path
                        width: ListView.view.width
                        height: 30
                        radius: 6
                        color: current ? card.shell.bgAlt : (rowMouse.containsMouse ? card.shell.hover : "transparent")
                        RowLayout {
                            anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                            spacing: 10
                            Text {
                                Layout.preferredWidth: 14
                                text: card.shell.icon(trackRow.current ? (card.music.isPlaying ? 0xF040A : 0xF03E4) : 0xF075A)
                                color: trackRow.current ? card.shell.green : card.shell.faint
                                font { family: card.shell.iconFont; pixelSize: 13 }
                            }
                            Text {
                                Layout.fillWidth: true
                                text: "\u200E" + card.music.label(trackRow.modelData)
                                horizontalAlignment: Text.AlignLeft
                                elide: Text.ElideRight
                                color: trackRow.current ? card.shell.green : card.shell.fg
                                font { family: card.shell.font; pixelSize: 13; bold: trackRow.current }
                            }
                        }
                        MouseArea { id: rowMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: card.music.play(card.music.tracks.indexOf(trackRow.modelData)) }
                    }
                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 40
                        visible: library.shown.length === 0
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        text: card.music.tracks.length === 0
                            ? "No music here yet.\nPaste a link above, or pick another folder."
                            : "Nothing matches “" + library.text + "”"
                        color: card.shell.dim
                        font { family: card.shell.font; pixelSize: 13 }
                    }
                }

                // where the music is
                Text {
                    visible: !browser.visible
                    Layout.fillWidth: true
                    text: (library.shown.length !== card.music.tracks.length ? library.shown.length + " of " : "")
                        + card.music.tracks.length + " track" + (card.music.tracks.length === 1 ? "" : "s")
                        + "  ·  " + card.pretty(card.music.folder)
                    elide: Text.ElideMiddle
                    color: card.shell.faint
                    font { family: card.shell.font; pixelSize: 11 }
                }
            }
        }
    }
}
