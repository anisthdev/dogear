import QtQuick
import QtQuick.Window
import QtQuick.Dialogs
import Dogear

// The window: the reader, its overlays, and every key binding.
//
// Keys arrive at handleKey from two places, as one kind of event: Qt's,
// while a QML item has focus (before a book is open), and the page's,
// forwarded by Reader while the book has focus. An open overlay takes
// every key until it closes.
Window {
    id: win

    width: 1100
    height: 820
    minimumWidth: 420
    minimumHeight: 360
    visible: true
    title: reader.title ? `${reader.title} — Dogear` : "Dogear"
    color: ReadingTheme.background

    Behavior on color {
        ColorAnimation {
            duration: Theme.animNormal
        }
    }

    readonly property var bindings: [
        ["l  Right  Space", "Next page"],
        ["h  Left  Shift+Space", "Previous page"],
        ["j  k  Down  Up", "Next, previous page (a few lines when scrolling)"],
        ["]  [", "Next, previous chapter"],
        ["gg  G", "Start, end of the book"],
        ["Ctrl+o  Ctrl+i", "Back, forward (after a jump)"],
        ["t", "Contents"],
        ["c  C", "Next, previous colours"],
        ["+  -  0", "Larger, smaller, normal text"],
        ["F", "Font (/ filters)"],
        ["s", "Pages or scrolling"],
        ["i", "Dim or invert pictures (dark pages)"],
        ["o", "Open a book"],
        ["F11  f", "Full screen"],
        ["?  F1", "These keys"],
        ["q  Ctrl+w", "Close"]
    ]

    property bool pendingG: false

    Timer {
        id: gTimer

        interval: 600
        onTriggered: win.pendingG = false
    }

    function toast(message) {
        snack.text = message;
        snack.shown = true;
        snackTimer.restart();
    }

    function openBook(path) {
        if (reader.openFile(path))
            toc.open = false;
    }

    function handleKey(e) {
        if (help.open)
            return help.handleKey(e);
        if (toc.open)
            return toc.handleKey(e);
        if (fonts.open)
            return fonts.handleKey(e);

        const t = e.text;
        const ctrl = e.modifiers & Qt.ControlModifier;
        const shift = e.modifiers & Qt.ShiftModifier;

        if (t === "g" && !ctrl) {
            if (pendingG) {
                pendingG = false;
                reader.send("fraction", 0);
            } else {
                pendingG = true;
                gTimer.restart();
            }
            return true;
        }
        pendingG = false;

        if (ctrl) {
            switch (e.key) {
            case Qt.Key_W:
            case Qt.Key_Q:
                win.close();
                return true;
            case Qt.Key_O:
                reader.send("back");
                return true;
            case Qt.Key_I:
            case Qt.Key_Tab:
                reader.send("forward");
                return true;
            }
            return false;
        }

        switch (t) {
        case "l":
            reader.send("right");
            return true;
        case "h":
            reader.send("left");
            return true;
        case "j":
            reader.send("down");
            return true;
        case "k":
            reader.send("up");
            return true;
        case " ":
            reader.send(shift ? "pageUp" : "pageDown");
            return true;
        case "]":
            reader.send("nextSection");
            return true;
        case "[":
            reader.send("prevSection");
            return true;
        case "G":
            reader.send("fraction", 0.99999);
            return true;
        case "t":
            if (reader.hasBook) {
                toc.currentHref = reader.where?.tocHref ?? "";
                toc.show();
            }
            return true;
        case "c":
            ReadingTheme.cycleScheme(1);
            toast(`Colours: ${ReadingTheme.schemeNames[ReadingTheme.scheme]}`);
            return true;
        case "C":
            ReadingTheme.cycleScheme(-1);
            toast(`Colours: ${ReadingTheme.schemeNames[ReadingTheme.scheme]}`);
            return true;
        case "+":
        case "=":
            ReadingTheme.zoom(10);
            toast(`Text ${ReadingTheme.settings.fontScale}%`);
            return true;
        case "-":
            ReadingTheme.zoom(-10);
            toast(`Text ${ReadingTheme.settings.fontScale}%`);
            return true;
        case "0":
            ReadingTheme.zoom(0);
            toast("Text 100%");
            return true;
        case "s":
            ReadingTheme.settings.flow = ReadingTheme.settings.flow === "paginated" ? "scrolled" : "paginated";
            toast(ReadingTheme.settings.flow === "paginated" ? "Pages" : "Scrolling");
            return true;
        case "i":
            ReadingTheme.toggleImages();
            if (!ReadingTheme.dark)
                toast("Pictures change only on dark pages");
            else
                toast(ReadingTheme.settings.images === "invert" ? "Pictures inverted" : "Pictures dimmed");
            return true;
        case "F":
            if (reader.hasBook)
                fonts.show();
            return true;
        case "o":
            fileDialog.open();
            return true;
        case "f":
            win.visibility = win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen;
            return true;
        case "?":
            help.open = true;
            return true;
        case "q":
            win.close();
            return true;
        }

        switch (e.key) {
        case Qt.Key_Right:
            reader.send("right");
            return true;
        case Qt.Key_Left:
            reader.send("left");
            return true;
        case Qt.Key_Down:
            reader.send("down");
            return true;
        case Qt.Key_Up:
            reader.send("up");
            return true;
        case Qt.Key_PageDown:
            reader.send("pageDown");
            return true;
        case Qt.Key_PageUp:
            reader.send("pageUp");
            return true;
        case Qt.Key_Home:
            reader.send("fraction", 0);
            return true;
        case Qt.Key_End:
            reader.send("fraction", 0.99999);
            return true;
        case Qt.Key_F11:
            win.visibility = win.visibility === Window.FullScreen ? Window.Windowed : Window.FullScreen;
            return true;
        case Qt.Key_F1:
            help.open = true;
            return true;
        }
        return false;
    }

    // Keys while no page has focus
    Item {
        id: keyCatcher

        anchors.fill: parent
        focus: true
        Keys.onPressed: event => event.accepted = win.handleKey(event)
    }

    Reader {
        id: reader

        anchors.fill: parent
        visible: hasBook
        onKeyPressed: event => win.handleKey(event)
        onFailed: message => win.toast(message)
    }

    EmptyPage {
        anchors.fill: parent
        visible: !reader.hasBook
    }

    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        onDropped: drop => {
            const url = drop.urls.find(u => u.toString().toLowerCase().endsWith(".epub"));
            if (url) {
                drop.accept();
                win.openBook(url.toString());
            }
        }
    }

    TocPanel {
        id: toc

        items: reader.toc
        onChosen: href => reader.send("goTo", href)
        onOpenChanged: if (!open && reader.hasBook)
            reader.focusPage()
    }

    FontPanel {
        id: fonts

        onKeysBack: keyCatcher.forceActiveFocus()
        onOpenChanged: if (!open && reader.hasBook)
            reader.focusPage()
    }

    KeyHelp {
        id: help

        bindings: win.bindings
        onOpenChanged: if (!open && reader.hasBook)
            reader.focusPage()
    }

    Rectangle {
        id: snack

        property alias text: snackLabel.text
        property bool shown: false

        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - (shown ? height + 64 : 0)
        width: snackLabel.implicitWidth + 40
        height: 44
        radius: Theme.radius
        color: Theme.inverse_surface
        opacity: shown ? 1 : 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        Label {
            id: snackLabel

            anchors.centerIn: parent
            color: Theme.inverse_on_surface
        }

        Timer {
            id: snackTimer

            interval: 2500
            onTriggered: snack.shown = false
        }
    }

    FileDialog {
        id: fileDialog

        title: "Open a book"
        nameFilters: ["EPUB books (*.epub)", "All files (*)"]
        onAccepted: win.openBook(selectedFile.toString())
    }

    Component.onCompleted: {
        const start = Library.startFile || Library.lastBook();
        if (start)
            openBook(start);
    }
}
