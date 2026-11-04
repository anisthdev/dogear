import QtQuick
import Dogear

// One book of a catalogue, as a sheet from the side: what the catalogue
// says of it and its EPUBs. Enter downloads the chosen one, or reads the
// book once it's in the library.
Item {
    id: root

    required property var view

    property bool open: false
    property var book: null
    property int choice: 0

    readonly property var catalog: Library.catalog
    readonly property var formats: book?.formats ?? []
    readonly property var download: book ? catalog.downloads[book.id] ?? null : null
    readonly property var ours: book ? view.ours(book) : null

    function show(b) {
        book = b;
        choice = 0;
        flick.contentY = 0;
        open = true;
    }

    function act() {
        if (ours) {
            open = false;
            view.openBook(ours.path);
        } else if (!download)
            view.download(book, formats[choice]);
    }

    function handleKey(e) {
        const t = e.text;
        const ctrl = e.modifiers & Qt.ControlModifier;
        const scroll = by => {
            flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY + by));
        };
        if (e.key === Qt.Key_Escape || e.key === Qt.Key_Backspace || e.key === Qt.Key_Left || t === "q" || t === "h") {
            open = false;
        } else if (t === "j" || e.key === Qt.Key_Down) {
            scroll(48);
        } else if (t === "k" || e.key === Qt.Key_Up) {
            scroll(-48);
        } else if (ctrl && e.key === Qt.Key_D) {
            scroll(flick.height / 2);
        } else if (ctrl && e.key === Qt.Key_U) {
            scroll(-flick.height / 2);
        } else if (e.key === Qt.Key_Tab && formats.length) {
            choice = (choice + 1) % formats.length;
        } else if (e.key === Qt.Key_Backtab && formats.length) {
            choice = (choice + formats.length - 1) % formats.length;
        } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || t === "d" || t === "l") {
            act();
        } else if (t === "x" && download) {
            catalog.cancel(book.id);
        } else if (t === "o" && book?.web) {
            Qt.openUrlExternally(book.web);
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

    Rectangle {
        width: Math.min(500, parent.width - 48)
        height: parent.height - 24
        y: 12
        x: root.open ? parent.width - width - 12 : parent.width + 12
        radius: Theme.cardRadius
        color: Theme.surface_container
        clip: true

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
            anchors.bottomMargin: 52
            contentHeight: body.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true

            Behavior on contentY {
                NumberAnimation {
                    duration: Theme.animFast
                    easing.type: Easing.OutCubic
                }
            }

            Column {
                id: body

                width: flick.width
                spacing: 16

                Row {
                    width: parent.width
                    spacing: 18

                    Cover {
                        width: 120
                        height: 178
                        radius: 8
                        source: root.book?.cover ?? ""
                        title: root.book?.title ?? ""
                        authors: (root.book?.authors ?? []).join(", ")
                    }

                    Column {
                        width: parent.width - 138
                        spacing: 6

                        Label {
                            anchors.verticalCenter: undefined
                            width: parent.width
                            wrapMode: Text.WordWrap
                            maximumLineCount: 5
                            elide: Text.ElideRight
                            text: root.book?.title ?? ""
                            color: Theme.primary
                            font.pixelSize: 22
                            font.weight: Theme.titleWeight
                            roundness: Theme.titleRoundness
                        }

                        Label {
                            anchors.verticalCenter: undefined
                            width: parent.width
                            visible: text !== ""
                            wrapMode: Text.WordWrap
                            text: (root.book?.authors ?? []).join(", ")
                            color: Theme.on_surface
                        }

                        Label {
                            anchors.verticalCenter: undefined
                            width: parent.width
                            visible: text !== ""
                            wrapMode: Text.WordWrap
                            text: [root.book?.publisher, root.book?.published, root.book?.language].filter(x => !!x).join(" · ")
                            color: Theme.on_surface_variant
                            font.pixelSize: 13
                        }

                        Label {
                            anchors.verticalCenter: undefined
                            width: parent.width
                            visible: root.ours !== null || root.download !== null
                            wrapMode: Text.WordWrap
                            text: {
                                if (root.download)
                                    return `Downloading ${root.book ? root.view.bookState(root.book) : ""}`;
                                return root.ours ? "✓ In library" : "";
                            }
                            color: Theme.primary
                            font.pixelSize: 13
                        }
                    }
                }

                LinearProgress {
                    width: parent.width
                    visible: root.download !== null
                    thickness: 4
                    indeterminate: !root.download || root.download.total <= 0
                    progress: root.download && root.download.total > 0 ? root.download.received / root.download.total : 0
                }

                Column {
                    width: parent.width
                    spacing: 2
                    visible: root.formats.length > 0 && !root.ours

                    Repeater {
                        model: root.formats

                        Rectangle {
                            id: choice_

                            required property var modelData
                            required property int index
                            readonly property bool chosen: index === root.choice

                            width: parent.width
                            height: 40
                            radius: Theme.radius
                            color: chosen ? Theme.secondary_container : "transparent"

                            Label {
                                anchors.left: parent.left
                                anchors.right: size.left
                                anchors.leftMargin: 14
                                anchors.rightMargin: 12
                                elide: Text.ElideRight
                                text: choice_.modelData.title
                                color: choice_.chosen ? Theme.on_secondary_container : Theme.on_surface
                            }

                            Label {
                                id: size

                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                text: choice_.modelData.size > 0 ? root.view.format(choice_.modelData.size) : ""
                                color: choice_.chosen ? Theme.on_secondary_container : Theme.on_surface_variant
                                font.pixelSize: 12
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    root.choice = choice_.index;
                                    root.act();
                                }
                            }
                        }
                    }
                }

                Label {
                    anchors.verticalCenter: undefined
                    width: parent.width
                    visible: root.formats.length === 0
                    wrapMode: Text.WordWrap
                    text: {
                        const others = root.book?.others ?? [];
                        return others.length ? `No free EPUB here, only: ${others.join(", ")}.` : "No free EPUB here.";
                    }
                    color: Theme.on_surface_variant
                }

                Label {
                    anchors.verticalCenter: undefined
                    width: parent.width
                    visible: text !== ""
                    wrapMode: Text.WordWrap
                    textFormat: Text.PlainText
                    text: root.book?.summary ?? ""
                    color: Theme.on_surface_variant
                    font.pixelSize: 14
                    lineHeight: 1.25
                }

                Label {
                    anchors.verticalCenter: undefined
                    width: parent.width
                    visible: text !== ""
                    wrapMode: Text.WordWrap
                    text: (root.book?.tags ?? []).join(" · ")
                    color: Theme.on_surface_variant
                    font.pixelSize: 12
                }
            }
        }

        Label {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 20
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: undefined
            text: {
                if (root.download)
                    return "x cancel · j k scroll · q back";
                if (root.ours)
                    return "Enter read · j k scroll · q back";
                const more = root.formats.length > 1 ? " · Tab choose" : "";
                return `${root.formats.length ? "Enter download" : ""}${more} · o in the browser · j k scroll · q back`.replace(/^ · /, "");
            }
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }
    }
}
