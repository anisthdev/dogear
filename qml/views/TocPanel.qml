import QtQuick
import Dogear

// The book's contents as a side sheet over the page. j/k and the other
// list keys move, Enter/l/Space go there, q/Esc/h/t close.
Item {
    id: root

    property bool open: false
    // [{ label, href, depth }]
    property var items: []
    // Where the reader is, to start on it
    property string currentHref: ""

    signal chosen(string href)

    function show() {
        let at = items.findIndex(i => i.href === currentHref);
        list.currentIndex = Math.max(0, at);
        list.positionViewAtIndex(list.currentIndex, ListView.Center);
        open = true;
    }

    function handleKey(event) {
        if (keys.handle(event))
            return true;
        const t = event.text;
        if (event.key === Qt.Key_Escape || t === "q" || t === "h" || t === "t" || event.key === Qt.Key_Left) {
            open = false;
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || t === "l" || t === " " || event.key === Qt.Key_Right) {
            const item = items[list.currentIndex];
            if (item) {
                open = false;
                chosen(item.href);
            }
            return true;
        }
        return true;
    }

    anchors.fill: parent
    visible: open || scrim.opacity > 0

    ListKeys {
        id: keys

        list: list
        halfPage: Math.max(1, Math.floor(list.height / 44 / 2))
    }

    Rectangle {
        id: scrim

        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.4)
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
        id: sheet

        width: Math.min(420, parent.width - 48)
        height: parent.height - 24
        y: 12
        x: root.open ? 12 : -width - 12
        radius: Theme.cardRadius
        color: Theme.surface_container

        Behavior on x {
            NumberAnimation {
                duration: Theme.animNormal
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.open ? Theme.emphasizedDecel : Theme.emphasizedAccel
            }
        }

        // Clicks on the sheet stay on it
        MouseArea {
            anchors.fill: parent
        }

        Label {
            id: title

            x: 20
            y: 26
            anchors.verticalCenter: undefined
            text: "Contents"
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        ListView {
            id: list

            anchors.top: title.bottom
            anchors.topMargin: 16
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 20
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            clip: true
            spacing: 2
            model: root.items
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: ListView.isCurrentItem
                readonly property bool reading: modelData.href === root.currentHref

                width: ListView.view.width
                height: 42
                radius: Theme.radius
                color: current ? Theme.secondary_container : "transparent"

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.animFast
                    }
                }

                Label {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 18 + row.modelData.depth * 16
                    anchors.rightMargin: 18
                    elide: Text.ElideRight
                    text: row.modelData.label || "Untitled"
                    font.pixelSize: row.modelData.depth === 0 ? 14 : 13
                    color: row.current ? Theme.on_secondary_container : row.reading ? Theme.primary : row.modelData.depth === 0 ? Theme.on_surface : Theme.on_surface_variant
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        list.currentIndex = row.index;
                        root.open = false;
                        root.chosen(row.modelData.href);
                    }
                }
            }
        }

        Label {
            anchors.centerIn: list
            visible: root.items.length === 0
            text: "This book has no contents"
            color: Theme.on_surface_variant
        }
    }
}
