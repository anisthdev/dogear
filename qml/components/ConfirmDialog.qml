import QtQuick
import Dogear

// Copied from margin (bc9f600), itself from Seedling.
// A Material 3 dialog asking to confirm something, over a scrim. Keys as
// Seedling's (tremc's) prompts: y or Enter confirms; n, q or Esc cancels. While open it
// takes every key (see handleKey).
Item {
    id: root

    property bool open: false
    property string title
    property string body
    property string confirmText
    property var onConfirm: null
    // The height it needs
    readonly property real wanted: open ? content.implicitHeight + 48 + 48 : 0

    // Asks; `confirmed` runs if the answer is yes
    function ask(title, body, confirmText, confirmed) {
        root.title = title;
        root.body = body;
        root.confirmText = confirmText;
        onConfirm = confirmed;
        open = true;
    }

    function close(confirmed) {
        open = false;
        const action = onConfirm;
        onConfirm = null;
        if (confirmed && action)
            action();
    }

    function handleKey(event) {
        if (event.text === "y" || event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
            close(true);
        else if (event.text === "n" || event.text === "q" || event.key === Qt.Key_Escape)
            close(false);
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

        // Clicking outside cancels
        MouseArea {
            anchors.fill: parent
            onClicked: root.close(false)
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 400)
        height: content.implicitHeight + 48
        radius: 28
        // Opaque, unlike the theme's see-through colours: the window's
        // content is behind it, not the blurred wallpaper
        color: Qt.alpha(Theme.surface_container_high, 1)
        opacity: scrim.opacity
        scale: 0.94 + 0.06 * scrim.opacity

        // Swallow clicks on the dialog itself
        MouseArea {
            anchors.fill: parent
        }

        Column {
            id: content

            x: 24
            y: 24
            width: parent.width - 48
            spacing: 16

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                text: root.title
                color: Theme.on_surface
                font.pixelSize: 24
                font.weight: Font.Normal
                roundness: Theme.titleRoundness
                wrapMode: Text.WordWrap
            }

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                text: root.body
                color: Theme.on_surface_variant
                font.weight: Font.Normal
                wrapMode: Text.WordWrap
            }

            Row {
                anchors.right: parent.right
                spacing: 8

                TextButton {
                    text: "Cancel  n"
                    onClicked: root.close(false)
                }

                TextButton {
                    text: `${root.confirmText}  y`
                    color: Theme.error
                    onClicked: root.close(true)
                }
            }
        }
    }
}
