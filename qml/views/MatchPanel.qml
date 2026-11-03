import QtQuick
import Dogear

// Find a book online and pick which one it is: a field (filled with its
// title and author) and what Open Library (and Google Books, given a key)
// know by that name, with covers. Enter in the field searches; in the
// list, j/k move, Enter/l keep that match, / back to the field, q/Esc
// close. In a review (`queue`, from F), Esc skips to the next book, x
// marks this one as not to be matched, q stops.
Item {
    id: root

    property bool open: false
    property var book: null
    // Books still to review after this one (ids)
    property var queue: []
    readonly property bool reviewing: queue.length > 0 || reviewTotal > 0
    property int reviewTotal: 0
    property var candidates: []
    property bool busy: false
    property string error: ""
    property string request: ""

    signal toast(string message)
    signal keysBack

    function show(b) {
        book = b;
        candidates = [];
        error = "";
        // Title and the first author's surname: Open Library wants every
        // word to match, and full names often don't
        const surname = (b.authors ?? "").split(",")[0].trim().split(/\s+/).pop() ?? "";
        input.text = [b.title.replace(/[:(].*$/, "").trim(), surname].filter(Boolean).join(" ");
        open = true;
        list.currentIndex = 0;
        run();
        input.focus = false;
        keysBack();
    }

    // Go through every book not matched yet, one after another
    function review(ids) {
        if (ids.length === 0) {
            toast("Every book is matched");
            return;
        }
        reviewTotal = ids.length;
        queue = ids.slice(1);
        show(Library.books.find(b => b.id === ids[0]));
    }

    function next() {
        if (queue.length === 0) {
            stop();
            return;
        }
        const id = queue[0];
        queue = queue.slice(1);
        const b = Library.books.find(x => x.id === id);
        if (b)
            show(b);
        else
            next();
    }

    function stop() {
        open = false;
        queue = [];
        reviewTotal = 0;
        keysBack();
    }

    function run() {
        const q = input.text.trim();
        if (!q)
            return;
        busy = true;
        error = "";
        request = `${book.id}:${Date.now()}`;
        Library.findOnline(request, q);
    }

    function pick() {
        const c = candidates[list.currentIndex];
        if (!c)
            return;
        Library.applyOnline(book.id, c);
        toast(`“${book.title}” matched`);
        if (reviewing)
            next();
        else
            stop();
    }

    Connections {
        target: Library

        function onOnlineMatches(request, found, error) {
            if (request !== root.request)
                return;
            root.busy = false;
            root.error = error;
            root.candidates = found;
            list.currentIndex = 0;
        }

        function onOnlineApplied(id, ok, error) {
            if (!ok)
                root.toast(`Couldn't keep the match: ${error}`);
        }
    }

    function handleKey(e) {
        if (input.activeFocus) {
            input.forceActiveFocus();
            return true;
        }
        if (keys.handle(e))
            return true;
        const t = e.text;
        switch (t) {
        case "/":
        case "i":
            input.forceActiveFocus();
            return true;
        case "l":
            pick();
            return true;
        case "x":
            if (book) {
                Library.skipOnline(book.id);
                toast("Won't ask about it again");
                reviewing ? next() : stop();
            }
            return true;
        case "q":
            stop();
            return true;
        }
        switch (e.key) {
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Right:
            pick();
            return true;
        case Qt.Key_Escape:
            reviewing ? next() : stop();
            return true;
        }
        return true;
    }

    anchors.fill: parent
    visible: open || scrim.opacity > 0

    ListKeys {
        id: keys

        list: list
        halfPage: Math.max(1, Math.floor(list.height / 96 / 2))
    }

    Rectangle {
        id: scrim

        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.45)
        opacity: root.open ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.stop()
        }
    }

    Rectangle {
        width: Math.min(560, parent.width - 48)
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
            text: "Which book is it?"
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
            visible: root.reviewing
            text: `${root.reviewTotal - root.queue.length} of ${root.reviewTotal}`
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }

        // The book being matched
        Row {
            id: mine

            anchors.top: title.bottom
            anchors.topMargin: 14
            x: 20
            spacing: 14

            Cover {
                width: 40
                height: 60
                radius: 4
                source: root.book?.cover ?? ""
                title: ""
                authors: ""
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Label {
                    anchors.verticalCenter: undefined
                    width: 440
                    elide: Text.ElideRight
                    text: root.book?.title ?? ""
                    color: Theme.on_surface
                    font.pixelSize: 14
                }

                Label {
                    anchors.verticalCenter: undefined
                    width: 440
                    elide: Text.ElideRight
                    text: [root.book?.authors, root.book?.isbn ? `ISBN ${root.book.isbn}` : ""].filter(Boolean).join(" · ")
                    color: Theme.on_surface_variant
                    font.pixelSize: 12
                }
            }
        }

        Rectangle {
            id: field

            anchors.top: mine.bottom
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

                Keys.onPressed: event => {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        root.run();
                        input.focus = false;
                        root.keysBack();
                    } else if (event.key === Qt.Key_Escape || event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
                        input.focus = false;
                        root.keysBack();
                    } else {
                        return;
                    }
                    event.accepted = true;
                }
            }
        }

        Label {
            id: status

            anchors.top: field.bottom
            anchors.topMargin: 10
            x: 24
            anchors.verticalCenter: undefined
            text: root.busy ? "Searching Open Library…" : root.error ? root.error : root.candidates.length === 0 ? "Nothing found · / to change the search" : `${root.candidates.length} found`
            color: root.error ? Theme.error : Theme.on_surface_variant
            font.pixelSize: 12
        }

        ListView {
            id: list

            anchors.top: status.bottom
            anchors.topMargin: 10
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: hint.top
            anchors.margins: 12
            clip: true
            spacing: 2
            model: root.candidates
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: ListView.isCurrentItem && !input.activeFocus

                width: ListView.view.width
                height: 94
                radius: Theme.radius
                color: current ? Theme.secondary_container : Theme.surface_container_high

                Cover {
                    id: art

                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    width: 50
                    height: 76
                    radius: 4
                    source: row.modelData.cover ?? ""
                    title: ""
                    authors: ""
                }

                Column {
                    anchors.left: art.right
                    anchors.leftMargin: 16
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 3

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        elide: Text.ElideRight
                        text: row.modelData.title
                        color: row.current ? Theme.on_secondary_container : Theme.on_surface
                        font.pixelSize: 14
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        elide: Text.ElideRight
                        text: (row.modelData.authors ?? []).join(", ")
                        color: row.current ? Theme.on_secondary_container : Theme.on_surface_variant
                        font.pixelSize: 13
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        elide: Text.ElideRight
                        text: [row.modelData.year, row.modelData.publisher, row.modelData.source === "google" ? "Google Books" : "Open Library"].filter(Boolean).join(" · ")
                        color: row.current ? Qt.alpha(Theme.on_secondary_container, 0.8) : Theme.on_surface_variant
                        font.pixelSize: 12
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: list.currentIndex = row.index
                    onDoubleClicked: root.pick()
                }
            }
        }

        Label {
            id: hint

            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: undefined
            text: root.reviewing ? "Enter keep · / search again · Esc skip · x never match · q stop" : "Enter keep · / search again · Esc close"
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }
    }
}
