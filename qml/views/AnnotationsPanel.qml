import QtQuick
import Dogear

// The book's highlights and bookmarks, in reading order, as a side sheet.
// j/k and the list keys move; Enter/l go there; n edits the note; y copies
// the text; dd deletes; Y copies them all as Markdown; q/Esc/h close.
Item {
    id: root

    property Reader reader
    property bool open: false
    readonly property var items: reader ? reader.annotations : []

    signal toast(string message)
    signal editNote(var annotation)
    signal chosen(string cfi)

    readonly property var swatches: ({
            yellow: "#f2c94c",
            green: "#6fcf97",
            blue: "#56a8f0",
            pink: "#f28cb5",
            purple: "#b18cf0"
        })

    property bool pendingD: false

    Timer {
        id: dTimer

        interval: 600
        onTriggered: root.pendingD = false
    }

    function show() {
        open = true;
        // Start on the one nearest where the reader is
        const f = reader.where?.fraction ?? 0;
        let at = items.findIndex(a => a.fraction >= f - 0.0001);
        list.currentIndex = at < 0 ? items.length - 1 : at;
        list.positionViewAtIndex(Math.max(0, list.currentIndex), ListView.Center);
    }

    // Markdown: the book, then each chapter's highlights as quotes with
    // their notes, and bookmarks as items
    function markdown() {
        const d = reader.details ?? {};
        const lines = [`# ${d.title || reader.title || "Untitled"}`];
        if (d.authors)
            lines.push("", `*${d.authors}*`);
        let chapter = null;
        for (const a of items) {
            if (a.chapter !== chapter) {
                chapter = a.chapter;
                lines.push("", `## ${chapter || "Untitled"}`);
            }
            if (a.kind === "bookmark") {
                lines.push("", `- Bookmark, ${Math.round(a.fraction * 100)}%${a.text ? `: “${a.text}…”` : ""}`);
                continue;
            }
            lines.push("", a.text.split("\n").map(l => `> ${l}`).join("\n"));
            if (a.note)
                lines.push("", a.note);
        }
        return lines.join("\n") + "\n";
    }

    function handleKey(event) {
        const t = event.text;
        if (t !== "d")
            pendingD = false;
        if (keys.handle(event))
            return true;
        const a = items[list.currentIndex];
        if (event.key === Qt.Key_Escape || t === "q" || t === "h" || t === "a" || event.key === Qt.Key_Left) {
            open = false;
            return true;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || t === "l" || event.key === Qt.Key_Right) {
            if (a) {
                open = false;
                chosen(a.cfi);
            }
            return true;
        }
        if (t === "Y") {
            if (items.length) {
                Library.copy(markdown());
                toast(`Copied ${items.length} as Markdown`);
            }
            return true;
        }
        if (!a)
            return true;
        if (t === "y") {
            Library.copy(a.text);
            toast("Copied");
        } else if (t === "n" || t === "e") {
            editNote(a);
        } else if (t === "d" || event.key === Qt.Key_Delete) {
            if (pendingD || event.key === Qt.Key_Delete) {
                pendingD = false;
                const i = list.currentIndex;
                reader.removeAnnotation(a.id);
                list.currentIndex = Math.min(i, items.length - 1);
                toast(a.kind === "bookmark" ? "Bookmark deleted" : "Highlight deleted");
            } else {
                pendingD = true;
                dTimer.restart();
            }
        }
        return true;
    }

    anchors.fill: parent
    visible: open || scrim.opacity > 0

    ListKeys {
        id: keys

        list: list
        halfPage: Math.max(1, Math.floor(list.height / 90 / 2))
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
        width: Math.min(440, parent.width - 48)
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
            text: "Annotations"
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        Label {
            anchors.right: parent.right
            anchors.rightMargin: 20
            anchors.bottom: title.bottom
            anchors.bottomMargin: 6
            anchors.verticalCenter: undefined
            text: {
                const h = root.items.filter(a => a.kind === "highlight").length;
                const b = root.items.length - h;
                return [h ? `${h} ${h === 1 ? "highlight" : "highlights"}` : "", b ? `${b} ${b === 1 ? "bookmark" : "bookmarks"}` : ""].filter(Boolean).join(" · ");
            }
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }

        ListView {
            id: list

            anchors.top: title.bottom
            anchors.topMargin: 16
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: hint.top
            anchors.margins: 12
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
                readonly property bool bookmark: modelData.kind === "bookmark"

                width: ListView.view.width
                height: body.implicitHeight + 24
                radius: Theme.radius
                color: current ? Theme.secondary_container : Theme.surface_container_high

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.animFast
                    }
                }

                // The highlight's colour (or the bookmark's ribbon)
                Rectangle {
                    x: 10
                    y: 12
                    width: 4
                    height: parent.height - 24
                    radius: 2
                    color: row.bookmark ? Theme.primary : root.swatches[row.modelData.color] ?? root.swatches.yellow
                }

                Column {
                    id: body

                    x: 26
                    y: 12
                    width: parent.width - 42
                    spacing: 4

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        text: row.bookmark ? (row.modelData.text ? `Bookmark · ${row.modelData.text}` : "Bookmark") : row.modelData.text
                        wrapMode: Text.Wrap
                        maximumLineCount: row.bookmark ? 2 : 4
                        elide: Text.ElideRight
                        color: row.current ? Theme.on_secondary_container : Theme.on_surface
                        font.pixelSize: 14
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        visible: !!row.modelData.note
                        text: row.modelData.note ?? ""
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        color: row.current ? Theme.on_secondary_container : Theme.primary
                        font.pixelSize: 13
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        elide: Text.ElideRight
                        text: [row.modelData.chapter, `${Math.round(row.modelData.fraction * 100)}%`].filter(Boolean).join(" · ")
                        color: row.current ? Qt.alpha(Theme.on_secondary_container, 0.8) : Theme.on_surface_variant
                        font.pixelSize: 12
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: list.currentIndex = row.index
                    onDoubleClicked: {
                        root.open = false;
                        root.chosen(row.modelData.cfi);
                    }
                }
            }
        }

        Label {
            anchors.centerIn: list
            visible: root.items.length === 0
            width: list.width - 40
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            text: "No highlights or bookmarks yet. Select text (or v), or press m to bookmark the page."
            color: Theme.on_surface_variant
        }

        Label {
            id: hint

            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: undefined
            text: "Enter go · n note · y copy · dd delete · Y copy all as Markdown"
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }
    }
}
