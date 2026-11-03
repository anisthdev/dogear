import QtQuick
import QtWebEngine
import QtWebChannel
import Dogear

// One book on the page: the reader page (reader/index.html, foliate-js)
// in a web view, with the book's title above and where you are below.
// Talks to the page over a web channel (`bridge`); see reader/reader.js.
Item {
    id: root

    // Every key pressed in the page, as a Qt-style event (KeyEvents.fromWeb)
    signal keyPressed(var event)
    signal failed(string message)

    property string bookId: ""
    // From the page once open: { title, authors, language, dir, toc, sectionFractions }
    property var details: null
    // From the page on every move: { cfi, fraction, tocLabel, tocHref, ... }
    property var where: null

    readonly property bool hasBook: bookId !== ""
    readonly property string title: details?.title ?? ""
    readonly property var toc: details?.toc ?? []

    property bool pageReady: false
    // What Library.open gave for the open book; sent to the page whenever
    // it (re)starts
    property var book: null

    function openFile(path) {
        const book = Library.open(path);
        if (!book.ok) {
            failed(book.error);
            return false;
        }
        root.book = book;
        bookId = book.id;
        details = null;
        where = {
            fraction: book.fraction
        };
        if (pageReady)
            send("open", book);
        return true;
    }

    function send(name, data) {
        bridge.command(name, JSON.stringify(data ?? null));
    }

    function focusPage() {
        web.forceActiveFocus();
    }

    QtObject {
        id: bridge

        WebChannel.id: "bridge"

        signal command(string name, string json)

        // The page has (re)started: on first load, after a reload or a
        // crash. Give it the book again, where the reader was.
        function ready(json) {
            root.pageReady = true;
            root.send("style", ReadingTheme.style);
            if (root.book)
                root.send("open", Object.assign({}, root.book, {
                    position: root.where?.cfi ?? root.book.position
                }));
        }

        function opened(json) {
            root.details = JSON.parse(json);
            Library.saveDetails(root.bookId, root.details.title, root.details.authors);
            root.focusPage();
        }

        function relocated(json) {
            const w = JSON.parse(json);
            root.where = w;
            if (w.cfi)
                Library.saveProgress(root.bookId, w.cfi, w.fraction ?? 0);
        }

        function key(json) {
            root.keyPressed(KeyEvents.fromWeb(JSON.parse(json)));
        }

        function error(json) {
            const e = JSON.parse(json);
            console.warn("page:", e.message);
            if (e.message?.startsWith("Can't open"))
                root.failed(e.message);
        }
    }

    WindowWatch {
        window: root.Window.window
        onShown: if (root.pageReady)
            root.send("repaint")
    }

    WebChannel {
        id: channel

        registeredObjects: [bridge]
    }

    Connections {
        target: ReadingTheme

        function onStyleChanged() {
            if (root.pageReady)
                root.send("style", ReadingTheme.style);
        }
    }

    // The bars above and below the page keep their room but show only
    // while the pointer is over them
    Item {
        id: header

        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40

        HoverHandler {
            id: headerHover
        }

        Label {
            anchors.centerIn: parent
            width: Math.min(implicitWidth, parent.width - 96)
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            text: root.title
            color: ReadingTheme.muted
            font.pixelSize: 12
            opacity: headerHover.hovered ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.animNormal
                }
            }
        }
    }

    WebEngineView {
        id: web

        anchors.fill: parent
        anchors.topMargin: header.height
        anchors.bottomMargin: footer.height
        url: "dogear://app/index.html"
        webChannel: channel
        backgroundColor: ReadingTheme.background
        settings.javascriptCanAccessClipboard: false
        settings.focusOnNavigationEnabled: true

        onJavaScriptConsoleMessage: (level, message, line, source) => console.log(`page: ${message} (${source}:${line})`)
        // Chromium's menu is a browser's (back, reload, view source); none
        // of it belongs here. Copy is Ctrl+c; our own menu comes with
        // annotations.
        onContextMenuRequested: request => request.accepted = true
        onLoadingChanged: info => {
            if (info.status === WebEngineView.LoadStartedStatus)
                root.pageReady = false;
        }
        onRenderProcessTerminated: (status, code) => {
            console.warn("reader page ended:", status, code);
            root.pageReady = false;
            reload();
        }
        // The page itself never leaves dogear://. Its frames (the book's
        // sections, as blob: URLs) load freely; links out of the book come
        // as new-window requests (foliate's external-link) and go to the
        // browser.
        onNavigationRequested: request => {
            if (!request.isMainFrame || request.url.toString().startsWith("dogear:"))
                return;
            request.action = WebEngineNavigationRequest.IgnoreRequest;
        }
        onNewWindowRequested: request => {
            const url = request.requestedUrl.toString();
            if (/^(https?|mailto):/.test(url))
                Qt.openUrlExternally(request.requestedUrl);
        }
    }

    Item {
        id: footer

        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 48

        readonly property real fraction: root.where?.fraction ?? 0

        HoverHandler {
            id: footerHover
        }

        Item {
            id: footerContent

            anchors.fill: parent
            opacity: footerHover.hovered ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.animNormal
                }
            }

            Label {
                anchors.left: parent.left
                anchors.right: percent.left
                anchors.leftMargin: 24
                anchors.rightMargin: 16
                anchors.verticalCenter: undefined
                y: 6
                elide: Text.ElideRight
                text: {
                    const parts = [root.where?.tocLabel ?? ""];
                    const left = root.where?.minutesLeftInSection;
                    if (left > 0)
                        parts.push(left < 1 ? "under a minute left" : `${Math.round(left)} min left`);
                    return parts.filter(Boolean).join(" · ");
                }
                color: ReadingTheme.muted
                font.pixelSize: 12
            }

            Label {
                id: percent

                anchors.right: parent.right
                anchors.rightMargin: 24
                anchors.verticalCenter: undefined
                y: 6
                // The printed book's page when the EPUB has a page list, the
                // screen in this chapter, and how far through the book
                text: {
                    if (!root.hasBook)
                        return "";
                    const w = root.where ?? {};
                    const parts = [];
                    if (w.page)
                        parts.push(`Page ${w.page}`);
                    if (w.sectionPages)
                        parts.push(`${w.sectionPage} of ${w.sectionPages} in chapter`);
                    parts.push(`${Math.round(footer.fraction * 100)}%`);
                    return parts.join(" · ");
                }
                color: ReadingTheme.muted
                font.pixelSize: 12
            }

            LinearProgress {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 24
                anchors.rightMargin: 24
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 6
                visible: root.hasBook
                thickness: 4
                progress: footer.fraction
                color: ReadingTheme.isAuto ? Theme.primary : Qt.alpha(ReadingTheme.foreground, 0.55)
                trackColor: ReadingTheme.isAuto ? Theme.secondary_container : Qt.alpha(ReadingTheme.foreground, 0.12)
            }
        }
    }
}
