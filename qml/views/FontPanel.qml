import QtQuick
import Dogear

// Choose the page's font: a side sheet listing the book's own fonts, the
// system's serif and sans-serif, then every installed family, each shown
// in itself. Moving previews it on the page; Enter/l keeps it, q/Esc puts
// back what was there. / filters by name (Enter keeps the filter and
// gives the keys back to the list, Esc clears it).
Item {
    id: root

    property bool open: false
    readonly property bool filtering: input.activeFocus

    // QML focus should go back to the window's key handler (the filter
    // field had it)
    signal keysBack

    property string original: ""
    property var families: []
    readonly property var choices: {
        const all = [
            {
                label: "Book's own fonts",
                family: ""
            },
            {
                label: "Serif (system default)",
                family: "serif"
            },
            {
                label: "Sans-serif (system default)",
                family: "sans-serif"
            }
        ].concat(families.map(f => ({
                    label: f,
                    family: f
                })));
        const q = input.text.trim().toLowerCase();
        return q ? all.filter(c => c.label.toLowerCase().includes(q)) : all;
    }

    function show() {
        families = ReadingTheme.readingFonts();
        original = ReadingTheme.settings.fontFamily;
        input.text = "";
        open = true;
        selectCurrent();
    }

    function selectCurrent() {
        const at = choices.findIndex(c => c.family === ReadingTheme.settings.fontFamily);
        list.currentIndex = Math.max(0, at);
        list.positionViewAtIndex(list.currentIndex, ListView.Center);
    }

    function close(keep) {
        const c = choices[list.currentIndex];
        if (keep && c)
            ReadingTheme.settings.fontFamily = c.family;
        ReadingTheme.previewFont = null;
        open = false;
    }

    function preview() {
        const c = choices[list.currentIndex];
        if (open && c)
            ReadingTheme.previewFont = c.family;
    }

    function handleKey(event) {
        if (keys.handle(event))
            return true;
        const t = event.text;
        if (t === "/") {
            input.forceActiveFocus();
            return true;
        }
        if (event.key === Qt.Key_Escape || t === "q" || t === "h" || event.key === Qt.Key_Left) {
            close(false);
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || t === "l" || t === " " || event.key === Qt.Key_Right) {
            close(true);
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
        // Lighter than the contents' scrim: the page behind is the preview
        color: Qt.rgba(0, 0, 0, 0.15)
        opacity: root.open ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.close(true)
        }
    }

    Rectangle {
        id: sheet

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
            text: "Font"
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        // The filter, hidden until / (or while it holds text)
        Rectangle {
            id: field

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

            readonly property bool shown: input.activeFocus || input.text !== ""

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

                onTextChanged: {
                    list.currentIndex = 0;
                    root.preview();
                }

                Keys.onPressed: event => {
                    const ctrl = event.modifiers & Qt.ControlModifier;
                    if (event.key === Qt.Key_Escape) {
                        text = "";
                        root.keysBack();
                        root.selectCurrent();
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
                    text: "Filter fonts"
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
            onCurrentIndexChanged: root.preview()

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: ListView.isCurrentItem
                readonly property bool chosen: modelData.family === root.original

                width: ListView.view.width
                height: 42
                radius: Theme.radius
                color: current ? Theme.secondary_container : "transparent"

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.animFast
                    }
                }

                // Each family shown in itself; the first, the book's own,
                // in the app's
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 18
                    anchors.rightMargin: 18
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: row.modelData.label
                    font.family: row.modelData.family || Theme.fontFamily
                    font.pixelSize: 15
                    color: row.current ? Theme.on_secondary_container : row.chosen ? Theme.primary : Theme.on_surface
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        list.currentIndex = row.index;
                        root.close(true);
                    }
                }
            }
        }

        Label {
            anchors.centerIn: list
            visible: root.choices.length === 0
            text: "No font matches"
            color: Theme.on_surface_variant
        }
    }
}
