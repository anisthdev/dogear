import QtQuick
import Dogear

// Copied from Seedling (082d977); ours now.
// Material 3 text button: a label in a pill with a state layer on hover
// and press.
Item {
    id: root

    property string text
    property color color: Theme.primary

    signal clicked

    implicitWidth: label.implicitWidth + 24
    implicitHeight: 40

    Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.color
        opacity: mouse.pressed ? 0.16 : mouse.containsMouse ? 0.08 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }
    }

    Label {
        id: label

        anchors.centerIn: parent
        text: root.text
        color: root.color
        font.weight: Font.DemiBold
    }

    MouseArea {
        id: mouse

        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
