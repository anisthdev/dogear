import QtQuick
import Dogear

// The menu by a selection or a clicked highlight: five colours (1–5),
// highlight or underline (u), a note (n), define (d), copy (c), delete (x,
// for a highlight). Enter highlights in the colour used last; Esc or q lets go
// of the selection.
Item {
    id: root

    property Reader reader
    readonly property var selection: reader?.selection ?? null
    readonly property bool existing: !!selection?.annotation
    property bool open: false

    // The look new highlights get, remembered between books
    readonly property var colorNames: ["yellow", "green", "blue", "pink", "purple"]
    readonly property var swatches: ({
            yellow: "#f2c94c",
            green: "#6fcf97",
            blue: "#56a8f0",
            pink: "#f28cb5",
            purple: "#b18cf0"
        })
    property string lastColor: ReadingTheme.settings.highlightColor || "yellow"
    property string style: "highlight"

    signal toast(string message)
    // A note to write for this annotation
    signal editNote(var annotation)
    // Look the selection up
    signal define

    function show() {
        style = existing ? (selection.style || "highlight") : (ReadingTheme.settings.highlightStyle || "highlight");
        open = true;
    }

    function close(clear) {
        open = false;
        if (clear)
            reader.clearSelection();
    }

    function apply(color) {
        ReadingTheme.settings.highlightColor = color;
        ReadingTheme.settings.highlightStyle = style;
        const a = reader.highlight(color, style);
        open = false;
        return a;
    }

    function handleKey(e) {
        const t = e.text;
        const n = parseInt(t);
        if (n >= 1 && n <= 5) {
            apply(colorNames[n - 1]);
            return true;
        }
        switch (t) {
        case "u":
            style = style === "underline" ? "highlight" : "underline";
            if (existing)
                apply(selection.color || lastColor);
            return true;
        case "n":
            {
                // A new selection is highlighted first, so the note has
                // something to belong to
                let a;
                if (existing) {
                    a = reader.annotations.find(x => x.id === selection.annotation);
                    close(true);
                } else {
                    a = apply(lastColor);
                }
                if (a)
                    editNote(a);
                return true;
            }
        case "c":
        case "y":
            Library.copy(selection.text);
            toast("Copied");
            close(true);
            return true;
        case "d":
            open = false;
            define();
            return true;
        case "x":
            if (existing) {
                reader.removeAnnotation(selection.annotation);
                open = false;
                toast("Highlight deleted");
            }
            return true;
        case "q":
            close(true);
            return true;
        }
        switch (e.key) {
        case Qt.Key_Return:
        case Qt.Key_Enter:
            apply(existing ? (selection.color || lastColor) : lastColor);
            return true;
        case Qt.Key_Delete:
            if (existing) {
                reader.removeAnnotation(selection.annotation);
                open = false;
                toast("Highlight deleted");
            }
            return true;
        case Qt.Key_Escape:
            close(true);
            return true;
        }
        return true;
    }

    anchors.fill: parent
    visible: open || card.opacity > 0

    // A click elsewhere lets go
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.close(true)
    }

    Rectangle {
        id: card

        readonly property var r: root.selection?.rect ?? ({
                x: 0,
                y: 0,
                width: 0,
                height: 0
            })
        readonly property real pageTop: root.reader ? root.reader.pageY : 0
        readonly property real above: pageTop + r.y - height - 12
        readonly property real below: pageTop + r.y + r.height + 12

        width: row.implicitWidth + 24
        height: 56
        x: Math.max(12, Math.min(root.width - width - 12, (root.reader ? root.reader.pageX : 0) + r.x + r.width / 2 - width / 2))
        y: above >= 12 ? above : Math.min(root.height - height - 12, below)
        radius: Theme.cardRadius
        color: Qt.alpha(Theme.surface_container_high, 1)
        border.width: 1
        border.color: Theme.outline_variant
        opacity: root.open ? 1 : 0
        scale: 0.94 + 0.06 * opacity

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        MouseArea {
            anchors.fill: parent
        }

        Row {
            id: row

            anchors.centerIn: parent
            spacing: 6

            Repeater {
                model: root.colorNames

                Rectangle {
                    id: swatch

                    required property string modelData
                    required property int index
                    readonly property bool chosen: root.existing && root.selection.color === modelData

                    anchors.verticalCenter: parent.verticalCenter
                    width: 32
                    height: 32
                    radius: 16
                    color: root.swatches[modelData]
                    border.width: chosen ? 3 : 0
                    border.color: Theme.on_surface

                    // Underline mode shows as a bar under the number
                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 6
                        width: 14
                        height: 2
                        radius: 1
                        color: "#20202080"
                        visible: root.style === "underline"
                    }

                    Label {
                        anchors.centerIn: parent
                        text: swatch.index + 1
                        color: "#202020"
                        opacity: 0.7
                        font.pixelSize: 12
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.apply(swatch.modelData)
                    }
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 1
                height: 28
                color: Theme.outline_variant
            }

            Repeater {
                model: [
                    {
                        key: "u",
                        label: root.style === "underline" ? "Underline" : "Highlight"
                    },
                    {
                        key: "n",
                        label: "Note"
                    },
                    {
                        key: "d",
                        label: "Define"
                    },
                    {
                        key: "c",
                        label: "Copy"
                    }
                ].concat(root.existing ? [
                        {
                            key: "x",
                            label: "Delete"
                        }
                    ] : [])

                Rectangle {
                    id: action

                    required property var modelData

                    anchors.verticalCenter: parent.verticalCenter
                    width: actionRow.implicitWidth + 20
                    height: 36
                    radius: 18
                    color: hover.hovered ? Theme.surface_container_highest : "transparent"

                    HoverHandler {
                        id: hover
                    }

                    Row {
                        id: actionRow

                        anchors.centerIn: parent
                        spacing: 6

                        Label {
                            text: action.modelData.key
                            color: Theme.primary
                            font.family: Theme.monoFamily
                            font.pixelSize: 12
                        }

                        Label {
                            text: action.modelData.label
                            color: Theme.on_surface
                            font.pixelSize: 13
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.handleKey({
                            key: 0,
                            text: action.modelData.key,
                            modifiers: Qt.NoModifier
                        })
                    }
                }
            }
        }
    }
}
