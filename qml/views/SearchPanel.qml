import QtQuick
import Dogear

// A search as a side sheet: a field, then results under headings (a
// book's chapters, or the library's books). Typing searches (after a
// pause); Enter or Down moves to the results, where j/k and the list keys
// move, Enter/l opens, / goes back to the field, w toggles whole words
// (Alt+w in the field), q/Esc/h close. Case and accents never matter.
Item {
    id: root

    property bool open: false
    property string title: "Search"
    property string placeholder: "Search"
    // [{ header: true, label, sub, cover } | { before, match, after, sub,
    // payload }]
    property var rows: []
    property bool busy: false
    // Under the field: counts, or why there's nothing
    property string status: ""
    property bool wholeWords: false
    property int sheetWidth: 460
    readonly property string query: input.text

    // Run the search (debounced); "" clears it
    signal search(string query, bool wholeWords)
    signal chosen(var payload)
    // QML focus should go back to the window's key handler
    signal keysBack

    readonly property bool typing: input.activeFocus

    function show(text) {
        open = true;
        if (text !== undefined && text !== input.text)
            input.text = text;
        input.selectAll();
        input.forceActiveFocus();
    }

    function close() {
        open = false;
        input.focus = false;
        keysBack();
    }

    function firstHit(from, by) {
        for (let i = from; i >= 0 && i < rows.length; i += by)
            if (!rows[i].header)
                return i;
        return -1;
    }

    // Move by hits, stepping over the headings
    function moveBy(by) {
        if (rows.length === 0)
            return;
        let i = list.currentIndex + by;
        i = Math.max(0, Math.min(rows.length - 1, i));
        let hit = firstHit(i, by > 0 ? 1 : -1);
        if (hit < 0)
            hit = firstHit(i, by > 0 ? -1 : 1);
        if (hit >= 0) {
            list.currentIndex = hit;
            list.positionViewAtIndex(hit, ListView.Contain);
            if (hit > 0 && rows[hit - 1].header)
                list.positionViewAtIndex(hit - 1, ListView.Contain);
        }
    }

    function pick() {
        const r = rows[list.currentIndex];
        if (r && !r.header)
            chosen(r.payload);
    }

    function toggleWhole() {
        wholeWords = !wholeWords;
        if (input.text.trim())
            search(input.text, wholeWords);
    }

    property bool pendingG: false

    Timer {
        id: gTimer

        interval: 600
        onTriggered: root.pendingG = false
    }

    function handleKey(e) {
        if (input.activeFocus) {
            input.forceActiveFocus();
            return true;
        }
        const t = e.text;
        const ctrl = e.modifiers & Qt.ControlModifier;
        const page = Math.max(1, Math.floor(list.height / 70));
        if (t === "g" && !ctrl) {
            if (pendingG) {
                pendingG = false;
                list.currentIndex = -1;
                moveBy(1);
            } else {
                pendingG = true;
                gTimer.restart();
            }
            return true;
        }
        pendingG = false;
        if (ctrl) {
            if (e.key === Qt.Key_D || e.key === Qt.Key_F)
                moveBy(e.key === Qt.Key_D ? Math.ceil(page / 2) : page);
            else if (e.key === Qt.Key_U || e.key === Qt.Key_B)
                moveBy(e.key === Qt.Key_U ? -Math.ceil(page / 2) : -page);
            else if (e.key === Qt.Key_N || e.key === Qt.Key_J)
                moveBy(1);
            else if (e.key === Qt.Key_P || e.key === Qt.Key_K)
                moveBy(-1);
            return true;
        }
        switch (t) {
        case "j":
            moveBy(1);
            return true;
        case "k":
            moveBy(-1);
            return true;
        case "G":
            list.currentIndex = rows.length;
            moveBy(-1);
            return true;
        case "l":
            pick();
            return true;
        case "/":
        case "i":
            input.forceActiveFocus();
            return true;
        case "w":
            toggleWhole();
            return true;
        case "q":
        case "h":
            close();
            return true;
        }
        switch (e.key) {
        case Qt.Key_Down:
            moveBy(1);
            return true;
        case Qt.Key_Up:
            moveBy(-1);
            return true;
        case Qt.Key_PageDown:
            moveBy(page);
            return true;
        case Qt.Key_PageUp:
            moveBy(-page);
            return true;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Right:
            pick();
            return true;
        case Qt.Key_Escape:
        case Qt.Key_Left:
            close();
            return true;
        }
        return true;
    }

    // A new search starts on its first match; more of the same search
    // (a book's chapters stream in) keeps the cursor where it is. After the
    // list has the new rows, or it puts the cursor back on the heading.
    property bool restart: true
    onSearch: restart = true
    onRowsChanged: Qt.callLater(() => {
        if (restart || list.currentIndex < 0 || list.currentIndex >= rows.length || rows[list.currentIndex]?.header) {
            list.currentIndex = -1;
            moveBy(1);
            if (rows.length)
                restart = false;
        }
    })

    anchors.fill: parent
    visible: open || scrim.opacity > 0

    Timer {
        id: debounce

        interval: 250
        onTriggered: root.search(input.text, root.wholeWords)
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
            onClicked: root.close()
        }
    }

    Rectangle {
        width: Math.min(root.sheetWidth, parent.width - 48)
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
            text: root.title
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        // Whole words, on or off
        Rectangle {
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.verticalCenter: title.verticalCenter
            width: chip.implicitWidth + 24
            height: 30
            radius: 8
            color: root.wholeWords ? Theme.secondary_container : "transparent"
            border.width: root.wholeWords ? 0 : 1
            border.color: Theme.outline_variant

            Label {
                id: chip

                anchors.centerIn: parent
                text: root.wholeWords ? "✓ Whole words  w" : "Whole words  w"
                color: root.wholeWords ? Theme.on_secondary_container : Theme.on_surface_variant
                font.pixelSize: 12
            }

            MouseArea {
                anchors.fill: parent
                onClicked: root.toggleWhole()
            }
        }

        Rectangle {
            id: field

            anchors.top: title.bottom
            anchors.topMargin: 14
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            height: 44
            radius: Theme.radius
            color: Theme.surface_container_highest
            border.width: input.activeFocus ? 2 : 0
            border.color: Theme.primary

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
                font.pixelSize: 15
                clip: true

                onTextChanged: debounce.restart()

                Keys.onPressed: event => {
                    const ctrl = event.modifiers & Qt.ControlModifier;
                    const alt = event.modifiers & Qt.AltModifier;
                    if (event.key === Qt.Key_Escape) {
                        root.close();
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        // Run now if a search is pending, then to the results
                        if (debounce.running) {
                            debounce.stop();
                            root.search(input.text, root.wholeWords);
                        }
                        input.focus = false;
                        root.keysBack();
                    } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) {
                        input.focus = false;
                        root.keysBack();
                        root.moveBy(event.key === Qt.Key_Down || event.key === Qt.Key_Tab ? 0 : 1);
                    } else if (alt && event.key === Qt.Key_W) {
                        root.toggleWhole();
                    } else {
                        return;
                    }
                    event.accepted = true;
                }

                Label {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: !input.text
                    text: root.placeholder
                    color: Theme.on_surface_variant
                }
            }
        }

        Label {
            id: statusLabel

            anchors.top: field.bottom
            anchors.topMargin: 10
            x: 24
            anchors.verticalCenter: undefined
            text: root.busy ? (root.status ? `${root.status} · searching…` : "Searching…") : root.status
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }

        ListView {
            id: list

            anchors.top: statusLabel.bottom
            anchors.topMargin: 10
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 12
            clip: true
            spacing: 2
            model: root.rows
            currentIndex: -1
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: Item {
                id: row

                required property var modelData
                required property int index
                readonly property bool header: !!modelData.header
                readonly property bool current: ListView.isCurrentItem && !input.activeFocus

                width: ListView.view.width
                height: header ? (modelData.cover !== undefined ? 64 : 34) : hit.implicitHeight + 20

                // A heading: chapter, or book with its cover
                Row {
                    visible: row.header
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 6
                    spacing: 12

                    Cover {
                        visible: row.modelData.cover !== undefined
                        width: 28
                        height: 42
                        radius: 4
                        source: row.modelData.cover ?? ""
                        title: ""
                        authors: ""
                    }

                    Column {
                        anchors.bottom: parent.bottom
                        spacing: 1

                        Label {
                            anchors.verticalCenter: undefined
                            width: list.width - 70
                            elide: Text.ElideRight
                            text: row.modelData.label ?? ""
                            color: Theme.primary
                            font.pixelSize: 13
                            font.weight: Theme.titleWeight
                        }

                        Label {
                            anchors.verticalCenter: undefined
                            visible: !!row.modelData.sub
                            width: list.width - 70
                            elide: Text.ElideRight
                            text: row.modelData.sub ?? ""
                            color: Theme.on_surface_variant
                            font.pixelSize: 12
                        }
                    }
                }

                Rectangle {
                    visible: !row.header
                    anchors.fill: parent
                    radius: Theme.radius
                    color: row.current ? Theme.secondary_container : Theme.surface_container_high

                    Behavior on color {
                        ColorAnimation {
                            duration: Theme.animFast
                        }
                    }
                }

                Column {
                    id: hit

                    visible: !row.header
                    x: 16
                    y: 10
                    width: parent.width - 32
                    spacing: 3

                    Text {
                        width: parent.width
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        font.family: Theme.fontFamily
                        font.pixelSize: 14
                        color: row.current ? Theme.on_secondary_container : Theme.on_surface
                        // The match stands out in the theme's primary
                        text: {
                            const esc = s => (s ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
                            const m = row.modelData;
                            return `${esc(m.before)}<b><font color="${Theme.primary}">${esc(m.match)}</font></b>${esc(m.after)}`;
                        }
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        visible: !!row.modelData.sub
                        width: parent.width
                        elide: Text.ElideRight
                        text: row.modelData.sub ?? ""
                        color: row.current ? Qt.alpha(Theme.on_secondary_container, 0.8) : Theme.on_surface_variant
                        font.pixelSize: 12
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: !row.header
                    onClicked: {
                        list.currentIndex = row.index;
                        input.focus = false;
                        root.keysBack();
                        root.pick();
                    }
                }
            }
        }
    }
}
