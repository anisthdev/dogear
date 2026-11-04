import QtQuick
import Dogear

// A book's details as a side sheet: cover, title, authors, series, tags,
// publishing details, description, and where each came from. Keys: f find
// it online (MatchPanel), t title, a authors, e series, T tags, p
// publisher, y published, I ISBN (each typed in, "" to go back), u forget
// the online match, Enter/o read, j/k scroll, q/Esc/h close.
Item {
    id: root

    property bool open: false
    property string bookId: ""
    readonly property var book: Library.books.find(b => b.id === bookId) ?? null

    // Set by the window
    property InputDialog dialog

    signal read(string path)
    signal findOnline(var book)
    signal editSeries(var book)
    signal editTags(var book)
    signal toast(string message)

    function show(id) {
        bookId = id;
        flick.contentY = 0;
        open = true;
    }

    function sourceName(from) {
        return {
            user: "typed in",
            book: "the book",
            online: book?.onlineKey?.startsWith("google") ? "Google Books" : "Open Library",
            file: "the file's name",
            catalog: "the catalogue"
        }[from] ?? "";
    }

    function edit(field, label) {
        const b = book;
        if (!b)
            return;
        dialog.ask(label, `For “${b.title}”. Empty goes back to what the book or the web says.`, b[field] ?? "", "Save", value => {
            Library.setField(b.id, field, value);
            toast(value.trim() ? `${label} saved` : `${label} as found`);
        });
    }

    function handleKey(e) {
        const t = e.text;
        if (!book) {
            open = false;
            return true;
        }
        switch (t) {
        case "f":
            findOnline(book);
            return true;
        case "t":
            edit("title", "Title");
            return true;
        case "a":
            edit("authors", "Authors");
            return true;
        case "p":
            edit("publisher", "Publisher");
            return true;
        case "y":
            edit("published", "Published");
            return true;
        case "I":
            edit("isbn", "ISBN");
            return true;
        case "e":
            editSeries(book);
            return true;
        case "T":
            editTags(book);
            return true;
        case "u":
            if (book.onlineKey) {
                Library.clearOnline(book.id);
                toast("Online details forgotten");
            }
            return true;
        case "o":
            open = false;
            read(book.path);
            return true;
        case "j":
            flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + 60);
            return true;
        case "k":
            flick.contentY = Math.max(0, flick.contentY - 60);
            return true;
        case "q":
        case "h":
        case "i":
            open = false;
            return true;
        }
        switch (e.key) {
        case Qt.Key_Return:
        case Qt.Key_Enter:
            open = false;
            read(book.path);
            return true;
        case Qt.Key_Down:
            flick.contentY = Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + 60);
            return true;
        case Qt.Key_Up:
            flick.contentY = Math.max(0, flick.contentY - 60);
            return true;
        case Qt.Key_Escape:
        case Qt.Key_Left:
            open = false;
            return true;
        }
        return true;
    }

    anchors.fill: parent
    visible: open || scrim.opacity > 0

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

    // One detail: a label, its value, and where it came from
    component Detail: Column {
        property string label
        property string value
        property string from
        property string key

        width: parent.width
        spacing: 2
        visible: value !== "" || key !== ""

        Row {
            spacing: 8

            Label {
                anchors.verticalCenter: undefined
                text: parent.parent.label
                color: Theme.on_surface_variant
                font.pixelSize: 12
            }

            Label {
                anchors.verticalCenter: undefined
                visible: parent.parent.key !== ""
                text: parent.parent.key
                color: Theme.primary
                font.family: Theme.monoFamily
                font.pixelSize: 11
            }

            Label {
                anchors.verticalCenter: undefined
                visible: parent.parent.from !== "" && parent.parent.value !== ""
                text: `· ${root.sourceName(parent.parent.from)}`
                color: Qt.alpha(Theme.on_surface_variant, 0.7)
                font.pixelSize: 11
            }
        }

        Label {
            anchors.verticalCenter: undefined
            width: parent.width
            text: parent.value || "—"
            wrapMode: Text.Wrap
            color: parent.value ? Theme.on_surface : Theme.on_surface_variant
        }
    }

    Rectangle {
        width: Math.min(520, parent.width - 48)
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

        Flickable {
            id: flick

            anchors.fill: parent
            anchors.margins: 24
            anchors.bottomMargin: 56
            contentHeight: body.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Behavior on contentY {
                NumberAnimation {
                    duration: Theme.animFast
                    easing.type: Easing.OutCubic
                }
            }

            Column {
                id: body

                width: flick.width
                spacing: 18

                Row {
                    width: parent.width
                    spacing: 20

                    Cover {
                        width: 120
                        height: 180
                        source: root.book?.cover ?? ""
                        title: root.book?.title ?? ""
                        authors: root.book?.authors ?? ""
                    }

                    Column {
                        width: parent.width - 140
                        spacing: 6

                        Label {
                            anchors.verticalCenter: undefined
                            width: parent.width
                            text: root.book?.title ?? ""
                            wrapMode: Text.Wrap
                            color: Theme.primary
                            font.pixelSize: 22
                            font.weight: Theme.titleWeight
                            roundness: Theme.titleRoundness
                        }

                        Label {
                            anchors.verticalCenter: undefined
                            width: parent.width
                            text: root.book?.authors ?? ""
                            wrapMode: Text.Wrap
                            color: Theme.on_surface
                            font.pixelSize: 15
                        }

                        Label {
                            anchors.verticalCenter: undefined
                            width: parent.width
                            visible: !!root.book?.series
                            text: root.book ? `${root.book.series}${root.book.seriesIndex ? " #" + root.book.seriesIndex : ""}` : ""
                            color: Theme.on_surface_variant
                        }

                        // How the online lookup went
                        Rectangle {
                            width: matchLabel.implicitWidth + 20
                            height: 26
                            radius: 13
                            color: root.book?.onlineKey ? Theme.secondary_container : Theme.surface_container_highest

                            Label {
                                id: matchLabel

                                anchors.centerIn: parent
                                font.pixelSize: 11
                                color: root.book?.onlineKey ? Theme.on_secondary_container : Theme.on_surface_variant
                                text: {
                                    const b = root.book;
                                    if (!b)
                                        return "";
                                    if (b.onlineKey)
                                        return `${b.online === "isbn" ? "Matched by ISBN" : "Matched by hand"} on ${root.sourceName("online")}`;
                                    return {
                                        pending: "Looking it up…",
                                        error: "Couldn't reach the web"
                                    }[b.online] ?? "Not matched online";
                                }
                            }
                        }
                    }
                }

                Detail {
                    label: "Title"
                    key: "t"
                    value: root.book?.title ?? ""
                    from: root.book?.titleFrom ?? ""
                }

                Detail {
                    label: "Authors"
                    key: "a"
                    value: root.book?.authors ?? ""
                    from: root.book?.authorsFrom ?? ""
                }

                Detail {
                    label: "Series"
                    key: "e"
                    value: root.book?.series ? `${root.book.series}${root.book.seriesIndex ? " #" + root.book.seriesIndex : ""}` : ""
                    from: ({
                            user: "user",
                            book: "book",
                            folder: "file"
                        })[root.book?.seriesSource ?? ""] ?? ""
                }

                Detail {
                    label: "Tags"
                    key: "T"
                    value: (root.book?.tags ?? []).join(", ")
                }

                Detail {
                    label: "Publisher"
                    key: "p"
                    value: root.book?.publisher ?? ""
                }

                Detail {
                    label: "Published"
                    key: "y"
                    value: root.book?.published ?? ""
                }

                Detail {
                    label: "ISBN"
                    key: "I"
                    value: root.book?.isbn ?? ""
                }

                Detail {
                    label: "Description"
                    value: (root.book?.description ?? "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim()
                    from: root.book?.descriptionFrom ?? ""
                }

                Detail {
                    label: "File"
                    value: (root.book?.path ?? "").replace(/^\/home\/[^/]+/, "~")
                }
            }
        }

        Label {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 20
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: undefined
            text: "Enter read · f find online · t a e T p y I edit · u forget online · j k scroll"
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }
    }
}
