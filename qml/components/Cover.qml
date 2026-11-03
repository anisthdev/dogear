import QtQuick
import QtQuick.Effects
import Dogear

// A book's cover with rounded corners, cropped to the space; books with
// none get a card with their title and author.
Item {
    id: root

    property string source
    property string title
    property string authors
    property real radius: 8

    readonly property bool hasImage: image.status === Image.Ready

    Rectangle {
        anchors.fill: parent
        visible: !root.hasImage
        radius: root.radius
        color: Theme.surface_container_highest

        Column {
            anchors.centerIn: parent
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
        sourceSize.height: Math.ceil(root.height * 2)
        visible: false
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
