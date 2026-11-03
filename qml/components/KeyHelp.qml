import QtQuick
import Dogear

// Copied from margin (bc9f600), itself from Seedling.
// Every key, as Seedling's ? shows them. `bindings` is a list of
// [keys, what they do]; any key closes it.
Item {
    id: root

    property bool open: false
    property var bindings: []
    // The height it needs
    readonly property real wanted: open ? content.implicitHeight + 48 + 48 : 0

    function handleKey(event) {
        open = false;
        return true;
    }

    anchors.fill: parent
    visible: open || scrim.opacity > 0

    Rectangle {
        id: scrim

        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.5)
        opacity: root.open ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.open = false
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 520)
        height: Math.min(parent.height - 48, content.implicitHeight + 48)
        radius: Theme.cardRadius
        // Opaque, unlike the theme's see-through colours: the window's
        // content is behind it, not the blurred wallpaper
        color: Qt.alpha(Theme.surface_container_high, 1)
        opacity: scrim.opacity
        clip: true

        Column {
            id: content

            x: 24
            y: 24
            width: parent.width - 48
            spacing: 6

            Label {
                anchors.verticalCenter: undefined
                bottomPadding: 10
                text: "Keys"
                color: Theme.on_surface
                font.pixelSize: 24
                font.weight: Font.Normal
                roundness: Theme.titleRoundness
            }

            Repeater {
                model: root.bindings

                Row {
                    required property var modelData

                    spacing: 16

                    Label {
                        anchors.verticalCenter: undefined
                        width: 150
                        text: modelData[0]
                        color: Theme.primary
                        font.family: Theme.monoFamily
                        font.pixelSize: 13
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        text: modelData[1]
                        color: Theme.on_surface_variant
                        font.weight: Font.Normal
                    }
                }
            }
        }
    }
}
