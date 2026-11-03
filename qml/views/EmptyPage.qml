import QtQuick
import Dogear

// What shows with no book open
Item {
    Column {
        anchors.centerIn: parent
        spacing: 10

        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: undefined
            text: "Dogear"
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: undefined
            text: "Press o to open a book, or drop an EPUB here"
            color: Theme.on_surface_variant
        }
    }
}
