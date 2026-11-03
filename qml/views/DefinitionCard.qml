import QtQuick
import Dogear

// What a word means, in a card by it: from your StarDict dictionaries,
// else Wiktionary. j/k scroll, o opens the full Wiktionary page, y copies
// the definition, q/Esc close.
Item {
    id: root

    property Reader reader
    property bool open: false
    property string word: ""
    property var result: null
    property bool busy: false
    property string request: ""
    // Where the word is on the page (page coordinates), or null
    property var rect: null

    signal toast(string message)

    function lookup(text, rect, language) {
        word = text.length > 60 ? text.slice(0, 60) + "…" : text;
        root.rect = rect;
        result = null;
        busy = true;
        flick.contentY = 0;
        open = true;
        request = `${Date.now()}`;
        Library.define(request, text, language ?? "");
    }

    function asText() {
        if (!result?.entries?.length)
            return "";
        const lines = [result.word];
        for (const e of result.entries) {
            if (e.pos)
                lines.push("", e.pos);
            e.senses.forEach((s, i) => lines.push(`${i + 1}. ${s.text}`));
        }
        return lines.join("\n");
    }

    Connections {
        target: Library

        function onDefined(request, result) {
            if (request !== root.request)
                return;
            root.busy = false;
            root.result = result;
        }
    }

    function handleKey(e) {
        const t = e.text;
        const step = 60;
        const max = Math.max(0, flick.contentHeight - flick.height);
        if (t === "j" || e.key === Qt.Key_Down)
            flick.contentY = Math.min(max, flick.contentY + step);
        else if (t === "k" || e.key === Qt.Key_Up)
            flick.contentY = Math.max(0, flick.contentY - step);
        else if (t === "o") {
            if (result?.url)
                Qt.openUrlExternally(result.url);
            else
                Qt.openUrlExternally(`https://en.wiktionary.org/wiki/${encodeURIComponent(word.replace(/ /g, "_"))}`);
        } else if (t === "y") {
            const text = asText();
            if (text) {
                Library.copy(text);
                toast("Definition copied");
            }
        } else if (t === "q" || t === "d" || e.key === Qt.Key_Escape || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
            open = false;
        }
        return true;
    }

    anchors.fill: parent
    visible: open || card.opacity > 0

    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.open = false
    }

    Rectangle {
        id: card

        readonly property real pageTop: root.reader ? root.reader.pageY : 0
        readonly property var r: root.rect ?? ({
                x: root.width / 2,
                y: root.height / 3,
                width: 0,
                height: 0
            })
        readonly property real below: pageTop + r.y + r.height + 12
        readonly property real above: pageTop + r.y - height - 12

        width: Math.min(440, root.width - 24)
        height: Math.min(Math.max(120, content.implicitHeight + 80), root.height * 0.55)
        x: Math.max(12, Math.min(root.width - width - 12, r.x + r.width / 2 - width / 2))
        // Under the word if it fits, else over it
        y: below + height <= root.height - 12 ? below : Math.max(12, above)
        radius: Theme.cardRadius
        color: Qt.alpha(Theme.surface_container_high, 1)
        border.width: 1
        border.color: Theme.outline_variant
        opacity: root.open ? 1 : 0
        scale: 0.96 + 0.04 * opacity

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        MouseArea {
            anchors.fill: parent
        }

        Label {
            id: head

            x: 20
            y: 16
            anchors.verticalCenter: undefined
            width: parent.width - 40
            elide: Text.ElideRight
            text: root.result?.word || root.word
            color: Theme.primary
            font.pixelSize: 20
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        Flickable {
            id: flick

            anchors.top: head.bottom
            anchors.topMargin: 8
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: foot.top
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            anchors.bottomMargin: 8
            contentHeight: content.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Behavior on contentY {
                NumberAnimation {
                    duration: Theme.animFast
                    easing.type: Easing.OutCubic
                }
            }

            Column {
                id: content

                width: flick.width
                spacing: 10

                Label {
                    anchors.verticalCenter: undefined
                    visible: root.busy || (root.result && !root.result.entries?.length)
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: root.busy ? "Looking it up…" : (root.result?.error ?? "Nothing found")
                    color: Theme.on_surface_variant
                }

                Repeater {
                    model: root.result?.entries ?? []

                    Column {
                        id: entry

                        required property var modelData

                        width: content.width
                        spacing: 6

                        Label {
                            anchors.verticalCenter: undefined
                            visible: !!entry.modelData.pos
                            text: entry.modelData.pos
                            color: Theme.on_surface_variant
                            font.pixelSize: 12
                            font.italic: true
                        }

                        Repeater {
                            model: entry.modelData.senses

                            Row {
                                id: sense

                                required property var modelData
                                required property int index

                                width: content.width
                                spacing: 8

                                Label {
                                    anchors.verticalCenter: undefined
                                    text: `${sense.index + 1}.`
                                    color: Theme.primary
                                    font.pixelSize: 13
                                }

                                Column {
                                    width: parent.width - 24
                                    spacing: 2

                                    Label {
                                        anchors.verticalCenter: undefined
                                        width: parent.width
                                        wrapMode: Text.Wrap
                                        text: sense.modelData.text
                                        color: Theme.on_surface
                                        font.pixelSize: 14
                                    }

                                    Label {
                                        anchors.verticalCenter: undefined
                                        visible: !!sense.modelData.example
                                        width: parent.width
                                        wrapMode: Text.Wrap
                                        text: `“${sense.modelData.example}”`
                                        color: Theme.on_surface_variant
                                        font.pixelSize: 13
                                        font.italic: true
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Label {
            id: foot

            anchors.bottom: parent.bottom
            anchors.bottomMargin: 12
            x: 20
            anchors.verticalCenter: undefined
            width: parent.width - 40
            elide: Text.ElideRight
            text: [root.result?.source ? `From ${root.result.source}` : "", "o Wiktionary · y copy · q close"].filter(Boolean).join(" · ")
            color: Theme.on_surface_variant
            font.pixelSize: 11
        }
    }
}
