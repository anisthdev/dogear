import QtQuick
import Dogear

// Filter the library by a tag: a side sheet of every tag with how many
// books have it, most used first, "All books" on top. j/k and the list
// keys move, Enter/l picks, q/Esc/h closes, / filters by name (Enter keeps
// the filter and gives the keys back, Esc clears it).
Item {
    id: root

    property bool open: false
    // The tag picked now ("" for all books)
    property string current: ""

    signal chosen(string tag)
    signal keysBack

    readonly property var choices: {
        const counts = new Map();
        for (const b of Library.books)
            for (const t of b.tags) {
                const key = t.toLowerCase();
                const c = counts.get(key) ?? {
                    tag: t,
                    count: 0
                };
                c.count++;
                counts.set(key, c);
            }
        const tags = [...counts.values()].sort((a, b) => (b.count - a.count) || a.tag.localeCompare(b.tag));
        const q = input.text.trim().toLowerCase();
        const all = [
            {
                tag: "",
                count: Library.books.length
            }
        ].concat(tags);
        return q ? all.filter(c => c.tag.toLowerCase().includes(q)) : all;
    }

    function show() {
        input.text = "";
        open = true;
        const at = choices.findIndex(c => c.tag.toLowerCase() === current.toLowerCase());
        list.currentIndex = Math.max(0, at);
        list.positionViewAtIndex(list.currentIndex, ListView.Center);
    }

    function pick() {
        const c = choices[list.currentIndex];
        open = false;
        if (c)
            chosen(c.tag);
    }

    function handleKey(event) {
        if (keys.handle(event))
            return true;
        const t = event.text;
        if (t === "/") {
            input.forceActiveFocus();
            return true;
        }
        if (event.key === Qt.Key_Escape || t === "q" || t === "h" || t === "t" || event.key === Qt.Key_Left) {
            open = false;
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || t === "l" || t === " " || event.key === Qt.Key_Right) {
            pick();
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
        width: Math.min(380, parent.width - 48)
        height: parent.height - 24
        y: 12
        x: root.open ? parent.width - width - 12 : parent.width + 12
        radius: Theme.cardRadius
        color: Theme.surface_container

        Behavior on x {
            NumberAnimation {
                duration: Theme.animNormal
                easing.type: Easing.BezierSpline
                easing.bezierCurve: root.open ? Theme.emphasizedDecel : Theme.emphasizedAccel
            }
        }

        MouseArea {
            anchors.fill: parent
        }

        Label {
            id: title

            x: 20
            y: 26
            anchors.verticalCenter: undefined
            text: "Tags"
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        Rectangle {
            id: field

            readonly property bool shown: input.activeFocus || input.text !== ""

            anchors.top: title.bottom
            anchors.topMargin: 14
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            height: shown ? 40 : 0
            visible: shown
            radius: Theme.radius
            color: Theme.surface_container_highest

            TextInput {
                id: input

                anchors.fill: parent
                anchors.leftMargin: 16
                anchors.rightMargin: 16
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.on_surface
                selectionColor: Theme.primary_container
                selectedTextColor: Theme.on_primary_container
                font.family: Theme.fontFamily
                font.pixelSize: 14
                clip: true

                onTextChanged: list.currentIndex = 0

                Keys.onPressed: event => {
                    const ctrl = event.modifiers & Qt.ControlModifier;
                    if (event.key === Qt.Key_Escape) {
                        text = "";
                        root.keysBack();
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.keysBack();
                    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) {
                        keys.move(1);
                    } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) {
                        keys.move(-1);
                    } else {
                        return;
                    }
                    event.accepted = true;
                }

                Label {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: !input.text
                    text: "Filter tags"
                    color: Theme.on_surface_variant
                }
            }
        }

        ListView {
            id: list

            anchors.top: field.bottom
            anchors.topMargin: 12
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 20
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            clip: true
            spacing: 2
            model: root.choices
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: ListView.isCurrentItem
                readonly property bool chosen: modelData.tag.toLowerCase() === root.current.toLowerCase()

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
                    anchors.right: count.left
                    anchors.leftMargin: 18
                    anchors.rightMargin: 12
                    elide: Text.ElideRight
                    text: row.modelData.tag || "All books"
                    color: row.current ? Theme.on_secondary_container : row.chosen ? Theme.primary : Theme.on_surface
                }

                Label {
                    id: count

                    anchors.right: parent.right
                    anchors.rightMargin: 18
                    text: row.modelData.count
                    color: row.current ? Theme.on_secondary_container : Theme.on_surface_variant
                    font.pixelSize: 12
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        list.currentIndex = row.index;
                        root.pick();
                    }
                }
            }
        }

        Label {
            anchors.centerIn: list
            visible: root.choices.length <= 1 && !input.text
            text: "No tags yet: T adds some"
            color: Theme.on_surface_variant
        }
    }
}
