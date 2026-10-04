// Built-in folder picker (no zenity/portals): walk into subfolders, then "Use this folder".
// Used by Settings (wallpaper folder) and the media card (music folder).
import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import "Paths.js" as Paths

Rectangle {
    id: browser
    required property var shell          // the bar's root: colors, fonts, home
    property var nameFilters: []         // files counted in the folder you're looking at
    property string countNoun: "file"    // "image" -> "3 images here"
    signal chosen(string path)

    visible: false
    radius: 10
    color: shell.bgAlt

    property string path: ""
    function open(start) { path = start || shell.home; visible = true }
    function up() { const i = path.lastIndexOf("/"); path = i > 0 ? path.slice(0, i) : "/" }
    function pretty(p) { return p.startsWith(shell.home) ? "~" + p.slice(shell.home.length) : p }

    // Qt 6.11.2's FolderListModel parses the decoded local path as a URL again.
    // Bind after construction: its initial folder check only decodes once.
    // TODO: move this model-specific conversion to Paths.js.
    function folderUrl(p) { return Paths.toFileUrl(p).replace(/%/g, "%25") }

    Loader {
        id: dirsLoader
        active: browser.visible
        onLoaded: item.folder = Qt.binding(() => browser.folderUrl(browser.path || browser.shell.home))
        sourceComponent: Component {
            FolderListModel {
                folder: Paths.toFileUrl("/")
                showFiles: false
                showHidden: false
                showDotAndDotDot: false
                sortField: FolderListModel.Name
            }
        }
    }
    Loader {
        id: matchesLoader
        active: browser.visible
        onLoaded: item.folder = Qt.binding(() => browser.folderUrl(browser.path || browser.shell.home))
        sourceComponent: Component {
            FolderListModel {
                folder: Paths.toFileUrl("/")
                showDirs: false
                nameFilters: browser.nameFilters
            }
        }
    }

    ColumnLayout {
        anchors { fill: parent; margins: 14 }
        spacing: 10

        // path + Up + Home
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            Repeater {
                model: [ { label: "↑  Up", act: () => browser.up() },
                         { label: "Home", act: () => browser.path = browser.shell.home } ]
                Rectangle {
                    required property var modelData
                    implicitWidth: navText.implicitWidth + 24; implicitHeight: 32; radius: 7
                    color: navM.containsMouse ? browser.shell.hoverStrong : browser.shell.bg
                    Text { id: navText; anchors.centerIn: parent; text: parent.modelData.label; color: browser.shell.fg
                        font { family: browser.shell.font; pixelSize: 13 } }
                    MouseArea { id: navM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: parent.modelData.act() }
                }
            }
            Text {
                Layout.fillWidth: true
                text: browser.pretty(browser.path)
                elide: Text.ElideLeft
                color: browser.shell.blue
                font { family: browser.shell.font; pixelSize: 14; bold: true }
            }
        }

        // subfolders
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: dirsLoader.item
            spacing: 2
            boundsBehavior: Flickable.StopAtBounds
            delegate: Rectangle {
                required property string fileName
                required property string filePath
                width: ListView.view.width
                height: 34
                radius: 6
                color: rowM.containsMouse ? browser.shell.bg : "transparent"
                RowLayout {
                    anchors { fill: parent; leftMargin: 10 }
                    spacing: 10
                    Text { text: browser.shell.icon(0xF024B); color: browser.shell.yellow
                        font { family: browser.shell.iconFont; pixelSize: 15 } }
                    Text { Layout.fillWidth: true; text: parent.parent.fileName; elide: Text.ElideRight
                        color: browser.shell.fg; font { family: browser.shell.font; pixelSize: 14 } }
                }
                MouseArea { id: rowM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                    onClicked: browser.path = parent.filePath }
            }
            Text {
                anchors.centerIn: parent
                visible: (dirsLoader.item?.count ?? 0) === 0
                text: "no subfolders"
                color: browser.shell.dim
                font { family: browser.shell.font; pixelSize: 13; italic: true }
            }
        }

        // Cancel / Use this folder
        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            Text {
                Layout.fillWidth: true
                readonly property int count: matchesLoader.item?.count ?? 0
                text: count + " " + browser.countNoun + (count === 1 ? "" : "s") + " here"
                color: count > 0 ? browser.shell.green : browser.shell.dim
                font { family: browser.shell.font; pixelSize: 13 }
            }
            Repeater {
                model: [ { label: "Cancel", primary: false }, { label: "Use this folder", primary: true } ]
                Rectangle {
                    required property var modelData
                    implicitWidth: actText.implicitWidth + 28; implicitHeight: 34; radius: 8
                    color: modelData.primary ? browser.shell.yellow : (actM.containsMouse ? browser.shell.hoverStrong : browser.shell.bg)
                    Text { id: actText; anchors.centerIn: parent; text: parent.modelData.label
                        color: parent.modelData.primary ? browser.shell.bg : browser.shell.fg
                        font { family: browser.shell.font; pixelSize: 14; bold: parent.modelData.primary } }
                    MouseArea { id: actM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (parent.modelData.primary) browser.chosen(browser.path)
                            browser.visible = false
                        } }
                }
            }
        }
    }
}
