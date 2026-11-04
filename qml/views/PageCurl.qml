import QtQuick
import Dogear

// A page turning like paper. The page can't photograph itself (the book
// sits in frames, inside Chromium), so this works from outside: freeze the
// page as it is, cover it with that picture, have it turn underneath, take
// a second picture, then roll one off the other (shaders/pagecurl.frag).
// Turning back is the same film run backwards, so the sheet is always
// whichever picture is the right-hand page lying flat.
//
//   idle → freezing → frozen → (turn) → turning → (turned) → capturing
//        → settled → curling → idle
//
// A turn asked for during one goes next, and hurries this one along, so a
// held key flips steadily. Nothing here touches the page: when it stops,
// the page underneath is already where the last picture showed it.
Item {
    id: root

    required property Item page
    required property color paper
    property bool dark: false

    // The picture's taken: turn the page, then call turned()
    signal turn(string how)

    readonly property int duration: 420

    property string phase: "idle"
    property var current: null
    property var waiting: null
    property real clock: 0

    // { how, forward, rtl, spread }, from the page
    function ask(request) {
        if (phase === "idle")
            start(request);
        else
            waiting = request;
    }

    function start(request) {
        current = request;
        waiting = null;
        clock = 0;
        phase = "freezing";
        before.scheduleUpdate();
    }

    // The page has moved, or couldn't
    function turned(moved) {
        if (phase !== "turning")
            return;
        if (!moved)
            return cancel();
        phase = "capturing";
        settle.restart();
    }

    function cancel() {
        phase = "idle";
        current = null;
        waiting = null;
    }

    function finish() {
        const next = waiting;
        phase = "idle";
        current = null;
        if (next)
            start(next);
    }

    // Eased time as the sheet's progress; backwards when turning back
    readonly property real eased: 1 - Math.pow(1 - clock, 2.6)

    // Size of the pictures, in real pixels
    readonly property size pictureSize: Qt.size(Math.ceil(page.width * Screen.devicePixelRatio), Math.ceil(page.height * Screen.devicePixelRatio))

    // The pictures are only ever seen through the shader, but one that
    // isn't visible never takes its picture; here they're visible and have
    // no room to show. Drawn freely they'd sit over the page.
    Item {
        width: 0
        height: 0
        clip: true

        ShaderEffectSource {
            id: before

            width: root.page.width
            height: root.page.height
            sourceItem: root.page
            textureSize: root.pictureSize
            live: false
            smooth: true
            onScheduledUpdateCompleted: if (root.phase === "freezing") {
                root.phase = "frozen";
                covered.restart();
            }
        }

        ShaderEffectSource {
            id: after

            width: root.page.width
            height: root.page.height
            sourceItem: root.page
            textureSize: root.pictureSize
            live: false
            smooth: true
            onScheduledUpdateCompleted: if (root.phase === "settled")
                root.phase = "curling"
        }
    }

    // A frame for the picture to reach the screen before the page moves
    // under it
    Timer {
        id: covered

        interval: 20
        onTriggered: if (root.phase === "frozen") {
            root.phase = "turning";
            root.turn(root.current.how);
        }
    }

    // And for the page's new frame to reach Qt
    Timer {
        id: settle

        interval: 34
        onTriggered: if (root.phase === "capturing") {
            root.phase = "settled";
            after.scheduleUpdate();
        }
    }

    // A page that stopped answering (a reload, a crash) mustn't leave its
    // last picture on the screen
    Timer {
        interval: 3000
        running: root.phase !== "idle" && root.phase !== "curling"
        onTriggered: root.cancel()
    }

    FrameAnimation {
        running: root.phase === "curling"
        onTriggered: {
            const speed = root.waiting ? 2.4 : 1;
            root.clock = Math.min(1, root.clock + Math.min(frameTime, 0.04) * 1000 * speed / root.duration);
            if (root.clock >= 1)
                root.finish();
        }
    }

    ShaderEffect {
        readonly property bool forward: root.current?.forward ?? true

        anchors.fill: parent
        visible: root.phase !== "idle" && root.phase !== "freezing"

        property var sheet: forward ? before : after
        property var under: forward ? after : before
        property real progress: forward ? root.eased : 1 - root.eased
        property real spread: root.current?.spread ? 1 : 0
        property real mirror: root.current?.rtl ? 1 : 0
        property real dark: root.dark ? 1 : 0
        property size area: Qt.size(width, height)
        property rect pageRect: Qt.rect(root.page.x, root.page.y, root.page.width, root.page.height)
        property color paper: root.paper

        fragmentShader: "qrc:/shaders/pagecurl.frag.qsb"
    }
}
