import QtQuick
import Dogear

// A Material 3 dialog asking for a line of text, over a scrim, as
// Seedling's (whose path completion this leaves out): Enter answers, Esc
// cancels. The field holds QML focus while open; `closed` says to give
// the keys back.
Item {
    id: root

    property bool open: false
    property string title
    property string body
    property string confirmText: "Save"
    property var onAnswer: null

    signal closed

    function ask(title, body, text, confirmText, answered) {
        root.title = title;
        root.body = body;
        root.confirmText = confirmText;
        onAnswer = answered;
        field.text = text;
        field.selectAll();
        open = true;
        field.forceActiveFocus();
    }

    function close() {
        open = false;
        onAnswer = null;
        closed();
    }

    function submit() {
        const action = onAnswer;
        const text = field.text;
        close();
        action?.(text);
    }

    // Keys reaching the window while open (from the page): swallowed
    function handleKey(event) {
        field.forceActiveFocus();
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
            onClicked: root.close()
        }
    }

    Rectangle {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 440)
        height: content.implicitHeight + 48
        radius: 28
        color: Qt.alpha(Theme.surface_container_high, 1)
        opacity: scrim.opacity
        scale: 0.94 + 0.06 * scrim.opacity

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
                visible: root.body !== ""
                text: root.body
                color: Theme.on_surface_variant
                font.weight: Font.Normal
                wrapMode: Text.WordWrap
            }

            Rectangle {
                width: parent.width
                height: 48
                radius: Theme.radius
                color: Theme.surface_container_highest

                TextInput {
                    id: field

                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    verticalAlignment: TextInput.AlignVCenter
                    color: Theme.on_surface
                    selectionColor: Theme.primary_container
                    selectedTextColor: Theme.on_primary_container
                    font.family: Theme.fontFamily
                    font.pixelSize: 15
                    clip: true

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                            root.submit();
                            event.accepted = true;
                        } else if (event.key === Qt.Key_Escape) {
                            root.close();
                            event.accepted = true;
                        }
                    }
                }
            }

            Row {
                anchors.right: parent.right
                spacing: 8

                TextButton {
                    text: "Cancel  Esc"
                    onClicked: root.close()
                }

                TextButton {
                    text: `${root.confirmText}  ↵`
                    onClicked: root.submit()
                }
            }
        }
    }
}
