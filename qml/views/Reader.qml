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

    // This book's highlights and bookmarks (Library.annotations)
    property var annotations: []
    // What the page has selected, for the menu: { cfi, text, rect (page
    // coordinates), annotation (id of a highlight clicked, or null),
    // color, style }; null when nothing is
    property var selection: null
    // Visual mode is on (the page has its keys)
    property bool visual: false
    // Where the page sits in this item, for placing the menu
    readonly property real pageX: web.x
    readonly property real pageY: web.y

    // The Book scheme: the page is a book's, alone on the desktop. Its
    // proportions hold on a wide window, room is kept for the boards and
    // page edges and the shadow,
    // and two pages show where the paginator will lay out two columns.
    readonly property bool bookLook: ReadingTheme.bookLook
    readonly property real roomWidth: width - 140
    readonly property real roomHeight: height - header.height - footer.height
    readonly property bool twoPages: roomWidth >= roomHeight && roomWidth > ReadingTheme.settings.maxWidth && ReadingTheme.settings.columns > 1
    readonly property real pageSide: bookLook ? (width - Math.min(roomWidth, roomHeight * (twoPages ? 1.56 : 0.78))) / 2 : 0
    readonly property bool rtl: details?.dir === "rtl"
    readonly property color barPlate: "#d91c1815"
    // The cover's colour, for the boards
    readonly property color boardColor: Library.coverTint(bookId)

    // A selection was made or a highlight clicked; `defined` when visual
    // mode's d asked for the dictionary instead of the menu
    signal selected
    signal defineSelection

    // The book's search: the query run, matches as they come ([{ cfi,
    // chapter, before, match, after }]), whether it's finished, and which
    // match n/N are on (-1 before the first jump)
    property string searchQuery: ""
    property var searchHits: []
    property bool searching: false
    property int searchAt: -1

    function search(query, wholeWords) {
        searchQuery = query;
        searchHits = [];
        searchAt = -1;
        searching = query.trim() !== "";
        send("search", {
            query: query,
            wholeWords: wholeWords
        });
    }

    function clearSearch() {
        searchQuery = "";
        searchHits = [];
        searchAt = -1;
        searching = false;
        send("clearSearch");
    }

    // Go to a match by its place in searchHits; n/N (by ±1) go from the
    // one last gone to, or from the page. The page knows the order.
    function goToHit(i) {
        send("hit", {
            index: i
        });
    }

    function nextHit(by) {
        send("hit", {
            by: by
        });
    }

    // From the library's search: open the book on that passage
    function openAt(path, query, section, wholeWords, near) {
        if (!openFile(path))
            return false;
        pendingJump = {
            query: query,
            section: section,
            wholeWords: wholeWords,
            near: near ?? ""
        };
        return true;
    }
    property var pendingJump: null

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
        annotations = Library.annotations(book.id);
        searchQuery = "";
        searchHits = [];
        searchAt = -1;
        searching = false;
        selection = null;
        visual = false;
        details = null;
        where = {
            fraction: book.fraction
        };
        if (pageReady)
            send("open", Object.assign({}, book, {
                annotations: annotations
            }));
        return true;
    }

    // Highlight the selection (or restyle the highlight it is); the
    // annotation saved
    function highlight(color, style) {
        const s = selection;
        if (!s)
            return null;
        if (s.annotation) {
            Library.updateAnnotation(s.annotation, {
                color: color,
                style: style
            });
            const a = Object.assign({}, annotations.find(x => x.id === s.annotation), {
                color: color,
                style: style
            });
            annotations = annotations.map(x => x.id === a.id ? a : x);
            send("updateAnnotation", a);
            selection = null;
            return a;
        }
        // Highlights this one grew over: replaced by it, their notes kept
        const merged = annotations.filter(x => (s.merges ?? []).includes(x.id));
        for (const old of merged)
            removeAnnotation(old.id);
        const saved = Library.addAnnotation(bookId, {
            kind: "highlight",
            cfi: s.cfi,
            color: color,
            style: style,
            text: s.text,
            note: merged.map(x => x.note).filter(Boolean).join("\n\n"),
            chapter: where?.tocLabel ?? "",
            fraction: where?.fraction ?? 0
        });
        if (!saved.id)
            return null;
        annotations = annotations.concat([saved]).sort((a, b) => a.fraction - b.fraction);
        send("addAnnotation", saved);
        selection = null;
        return saved;
    }

    function setNote(id, note) {
        Library.updateAnnotation(id, {
            note: note
        });
        annotations = annotations.map(x => x.id === id ? Object.assign({}, x, {
                note: note
            }) : x);
    }

    function removeAnnotation(id) {
        const a = annotations.find(x => x.id === id);
        if (!a)
            return;
        Library.removeAnnotation(id);
        annotations = annotations.filter(x => x.id !== id);
        send("removeAnnotation", a);
        selection = null;
    }

    function clearSelection() {
        selection = null;
        send("clearSelection");
    }

    // m: bookmark this page, or take its bookmark off. True when added.
    function toggleBookmark() {
        if (!where?.pageCfi)
            return false;
        if (where.bookmark) {
            removeAnnotation(where.bookmark);
            return false;
        }
        const saved = Library.addAnnotation(bookId, {
            kind: "bookmark",
            cfi: where.pageCfi,
            text: where.excerpt ?? "",
            note: "",
            chapter: where.tocLabel ?? "",
            fraction: where.fraction ?? 0
        });
        if (!saved.id)
            return false;
        annotations = annotations.concat([saved]).sort((a, b) => a.fraction - b.fraction);
        send("addAnnotation", saved);
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
                    position: root.where?.cfi ?? root.book.position,
                    annotations: root.annotations
                }));
        }

        function searchResults(json) {
            const r = JSON.parse(json);
            if (r.query !== root.searchQuery)
                return;
            root.searchHits = root.searchHits.concat(r.items.map(h => Object.assign(h, {
                    chapter: r.chapter
                })));
        }

        function hitAt(json) {
            root.searchAt = JSON.parse(json).index;
        }

        function searchDone(json) {
            const r = JSON.parse(json);
            if (r.query === root.searchQuery)
                root.searching = false;
        }

        function opened(json) {
            root.details = JSON.parse(json);
            if (root.pendingJump) {
                root.searchQuery = root.pendingJump.query;
                root.searchHits = [];
                root.searchAt = -1;
                root.searching = true;
                root.send("search", {
                    query: root.pendingJump.query,
                    wholeWords: root.pendingJump.wholeWords,
                    jumpSection: root.pendingJump.section,
                    near: root.pendingJump.near
                });
                root.pendingJump = null;
            }
            Library.saveDetails(root.bookId, root.details.title, root.details.authors);
            root.focusPage();
        }

        function relocated(json) {
            const w = JSON.parse(json);
            root.where = w;
            if (w.cfi)
                Library.saveProgress(root.bookId, w.cfi, w.fraction ?? 0);
        }

        function turnAsked(json) {
            curl.ask(JSON.parse(json));
        }

        function turnReady(json) {
            curl.turned(JSON.parse(json).moved);
        }

        function key(json) {
            root.keyPressed(KeyEvents.fromWeb(JSON.parse(json)));
        }

        function selection(json) {
            root.selection = JSON.parse(json);
            if (root.selection.intent === "define")
                root.defineSelection();
            else
                root.selected();
        }

        function visual(json) {
            root.visual = JSON.parse(json).active;
        }

        function bookmark(json) {
            if (root.where)
                root.where = Object.assign({}, root.where, {
                    bookmark: JSON.parse(json).id
                });
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

        z: 2
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 40

        HoverHandler {
            id: headerHover
        }

        // With no paper behind them, the bars bring their own
        Rectangle {
            anchors.centerIn: parent
            width: Math.min(title.implicitWidth, parent.width - 96) + 28
            height: 26
            radius: 13
            color: root.barPlate
            visible: root.bookLook
            opacity: title.opacity
        }

        Label {
            id: title

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

    // A ribbon hanging over the page's top corner while it's bookmarked
    Rectangle {
        z: 2
        anchors.left: parent.left
        anchors.leftMargin: 40
        // In a book, a bookmark is a dog-ear
        opacity: root.bookLook ? 0 : 1
        y: root.where?.bookmark ? 0 : -height
        width: 16
        height: 30
        radius: 3
        color: ReadingTheme.isAuto ? Theme.primary : ReadingTheme.link
        visible: y > -height

        Behavior on y {
            NumberAnimation {
                duration: Theme.animNormal
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.emphasizedDecel
            }
        }
    }

    ShaderEffect {
        anchors.fill: parent
        visible: root.bookLook

        property real spread: root.where?.spread ? 1 : 0
        property real mirror: root.rtl ? 1 : 0
        property real fraction: root.where?.fraction ?? 0
        property size area: Qt.size(width, height)
        property rect pageRect: Qt.rect(web.x, web.y, web.width, web.height)
        property color board: root.boardColor
        property color paper: ReadingTheme.background

        fragmentShader: "qrc:/shaders/bookcase.frag.qsb"
    }

    WebEngineView {
        id: web

        anchors.fill: parent
        anchors.leftMargin: root.pageSide
        anchors.rightMargin: root.pageSide
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

    // Over the page and under the bars, a whole window's worth of paper
    PageCurl {
        id: curl

        z: 1
        anchors.fill: parent
        page: web
        paper: ReadingTheme.background
        dark: ReadingTheme.dark
        sheetRect: root.bookLook ? Qt.rect(web.x, web.y, web.width, web.height) : Qt.rect(0, 0, width, height)
        onTurn: how => root.send("turnNow", how)
    }

    // The paper's look, over the page and the sheet alike
    ShaderEffect {
        x: web.x
        y: web.y
        z: 1.5
        width: web.width
        height: web.height
        visible: root.bookLook

        property real spread: root.where?.spread ? 1 : 0
        property real mirror: root.rtl ? 1 : 0
        // Folds once the page has settled
        property real dogear: root.where?.bookmark && curl.phase === "idle" ? 1 : 0
        property size area: Qt.size(width, height)
        property color paper: ReadingTheme.background
        property color board: root.boardColor

        fragmentShader: "qrc:/shaders/bookpage.frag.qsb"

        Behavior on dogear {
            NumberAnimation {
                duration: Theme.animNormal
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Theme.emphasizedDecel
            }
        }
    }

    Item {
        id: footer

        z: 2
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

            Rectangle {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                anchors.bottomMargin: 2
                radius: 12
                color: root.barPlate
                visible: root.bookLook
            }

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
                color: ReadingTheme.isAuto ? Theme.primary : Qt.alpha(ReadingTheme.bars, 0.55)
                trackColor: ReadingTheme.isAuto ? Theme.secondary_container : Qt.alpha(ReadingTheme.bars, 0.12)
            }
        }
    }
}
