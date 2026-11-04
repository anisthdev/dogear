import QtQuick
import QtQuick.Effects
import Dogear

// A book's cover with rounded corners, cropped to the space; books with
// none get a card with their title and author. With `measure`, a picture
// far smaller than the space (a catalogue's icon) sits on the card at its
// own size, as stretching it would blur it.
Item {
    id: root

    property string source
    property string title
    property string authors
    property real radius: 8
    // Tried if `source` can't be loaded
    property string fallback
    // Load the picture whole, to know its size: `tiny` needs it. Off for
    // the library's grid, whose covers load at the size they're drawn.
    property bool measure: false

    readonly property bool loaded: image.status === Image.Ready
    readonly property bool tiny: measure && loaded && image.implicitHeight < height * 0.6
    readonly property bool hasImage: loaded && !tiny

    Rectangle {
        anchors.fill: parent
        visible: !root.hasImage
        radius: root.radius
        color: Theme.surface_container_highest

        Image {
            anchors.centerIn: parent
            visible: root.tiny
            source: visible ? image.source : ""
        }

        Column {
            anchors.centerIn: parent
            visible: !root.tiny
            width: parent.width - 20
            spacing: 6

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                maximumLineCount: 4
                elide: Text.ElideRight
                text: root.title
                color: Theme.on_surface
                font.pixelSize: Math.max(11, Math.min(16, root.width / 10))
                font.weight: Theme.titleWeight
            }

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: root.authors
                color: Theme.on_surface_variant
                font.pixelSize: Math.max(10, Math.min(13, root.width / 13))
            }
        }
    }

    Image {
        id: image

        anchors.fill: parent
        source: root.source
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        smooth: true
        mipmap: true
        // With a size asked for, Qt stretches small pictures to it
        sourceSize: root.measure ? undefined : Qt.size(0, Math.ceil(root.height * 2))
        visible: false
        onStatusChanged: if (status === Image.Error && root.fallback && source != root.fallback)
            source = root.fallback
    }

    MultiEffect {
        anchors.fill: parent
        source: image
        visible: root.hasImage
        maskEnabled: true
        maskSource: mask
        maskThresholdMin: 0.5
        maskSpreadAtMin: 1
    }

    Item {
        id: mask

        anchors.fill: parent
        layer.enabled: true
        layer.smooth: true
        visible: false

        Rectangle {
            anchors.fill: parent
            radius: root.radius
        }
    }
}
