import QtQuick
import Dogear

// Online catalogues (see Catalog): the list of them, then their feeds, one
// on top of the other. Every feed is one list of headings, places to go
// and books; a feed that's one book opens as that book. h/q/Esc go back.
Item {
    id: root

    property var dialog
    property var confirm

    signal leave
    signal openBook(string path)
    signal toast(string message)

    readonly property var catalog: Library.catalog
    // The way here: { title, rows, next, search, web, index }; the first
    // is the list of catalogues
    property var pages: []
    readonly property var page: pages.length ? pages[pages.length - 1] : null
    property var rows: []
    readonly property var current: list.currentIndex >= 0 ? rows[list.currentIndex] ?? null : null

    // The load under way: { kind: "open" | "more" | "add", request, title }
    property var pending: null
    property int serial: 0
    readonly property bool loading: pending !== null && pending.kind !== "more"

    readonly property var booksById: {
        const out = {};
        for (const b of Library.books)
            out[b.id] = b;
        return out;
    }

    function ours(book) {
        return booksById[catalog.held[book.id]] ?? null;
    }

    function format(bytes) {
        return bytes >= 1048576 ? `${(bytes / 1048576).toFixed(1)} MB` : `${Math.max(1, Math.round(bytes / 1024))} KB`;
    }

    // What's happening with a book, in words: "" for nothing
    function bookState(book) {
        const d = catalog.downloads[book.id];
        if (d)
            return d.total > 0 ? `${Math.round(100 * d.received / d.total)}%` : format(d.received);
        if (ours(book))
            return "✓ In library";
        return book.formats.length ? "" : "No free EPUB";
    }

    function homeRows() {
        return catalog.catalogs.map(c => ({
                    kind: "catalog",
                    title: c.title,
                    url: c.url
                }));
    }

    function show() {
        pages = [
            {
                title: "Catalogues",
                rows: homeRows(),
                index: 0
            }
        ];
        display(0);
    }

    // Shows the top page, the cursor at `index`
    function display(index) {
        rows = page.rows;
        rowModel.clear();
        for (let i = 0; i < rows.length; ++i)
            rowModel.append({
                i: i
            });
        list.currentIndex = -1;
        list.currentIndex = settled(Math.min(index, rows.length - 1), 1);
        list.positionViewAtIndex(list.currentIndex, ListView.Contain);
    }

    // The nearest row from `at` that isn't a heading
    function settled(at, by) {
        for (let i = at; i >= 0 && i < rows.length; i += by)
            if (rows[i].kind !== "heading")
                return i;
        for (let i = at; i >= 0 && i < rows.length; i -= by)
            if (rows[i].kind !== "heading")
                return i;
        return rows.length ? at : -1;
    }

    function start(kind, title, load) {
        pending = {
            kind: kind,
            title: title,
            request: `${++serial}`
        };
        load(pending.request);
    }

    function go(url, title) {
        start("open", title, request => catalog.load(request, url));
    }

    function searchNearest() {
        for (let i = pages.length - 1; i > 0; --i)
            if (pages[i].search)
                return pages[i].search;
        return "";
    }

    function search() {
        const link = searchNearest();
        if (!link) {
            toast(pages.length > 1 ? "This catalogue has no search" : "Open a catalogue first");
            return;
        }
        dialog.ask(`Search ${pages[1].title}`, "", "", "Search", text => {
            const q = text.trim();
            if (q)
                start("open", `“${q}”`, request => catalog.search(request, link, q));
        });
    }

    function moreIfNear() {
        if (page?.next && pending === null && list.currentIndex >= rows.length - 6)
            start("more", "", request => catalog.load(request, page.next));
    }

    function feedArrived(feed) {
        const was = pending;
        pending = null;
        if (!feed.ok) {
            toast(feed.error);
            return;
        }
        if (was.kind === "add") {
            catalog.add(feed.url, feed.title || was.title);
            toast(`Added ${feed.title || was.title}`);
            return;
        }
        if (was.kind === "more") {
            const from = rows.length;
            page.next = feed.next ?? "";
            page.rows = rows.concat(feed.items);
            rows = page.rows;
            for (let i = from; i < rows.length; ++i)
                rowModel.append({
                    i: i
                });
            return;
        }
        const books = feed.items.filter(r => r.kind === "book");
        if (books.length === 1 && feed.items.length === 1) {
            sheet.show(books[0]);
            return;
        }
        page.index = list.currentIndex;
        const next = {
            title: was.title || feed.title,
            rows: feed.items,
            next: feed.next ?? "",
            search: feed.search ?? "",
            web: feed.web ?? "",
            index: 0
        };
        pages = pages.concat([next]);
        display(0);
    }

    function back() {
        if (pending !== null) {
            catalog.stop();
            const wasLoading = loading;
            pending = null;
            if (wasLoading)
                return;
        }
        if (pages.length <= 1) {
            leave();
            return;
        }
        pages = pages.slice(0, -1);
        if (pages.length === 1)
            page.rows = homeRows();
        display(page.index);
    }

    function openCurrent() {
        const r = current;
        if (!r)
            return;
        if (r.kind === "book")
            sheet.show(r);
        else
            go(r.url, r.title);
    }

    function download(book, format) {
        if (!format)
            toast("There's no free EPUB of this one");
        else if (ours(book))
            toast("It's in the library");
        else if (!catalog.downloads[book.id])
            catalog.download(book, format);
    }

    function addCatalog() {
        dialog.ask("Add a catalogue", "The address of an OPDS feed.", "", "Add", text => {
            let url = text.trim();
            if (!url)
                return;
            if (!url.includes("://"))
                url = `https://${url}`;
            start("add", url.replace(/^\w+:\/\/([^/]*).*/, "$1"), request => catalog.load(request, url));
        });
    }

    function renameCurrent() {
        const r = current;
        dialog.ask("Rename", "", r.title, "Save", text => {
            if (text.trim())
                catalog.rename(r.url, text.trim());
        });
    }

    function removeCurrent() {
        const r = current;
        confirm.ask("Remove this catalogue?", `${r.title} goes from the list. Books downloaded from it stay.`, "Remove", () => {
            catalog.remove(r.url);
        });
    }

    function handleKey(e) {
        if (sheet.open)
            return sheet.handleKey(e);
        const before = list.currentIndex;
        if (keys.handle(e)) {
            if (list.currentIndex !== before)
                list.currentIndex = settled(list.currentIndex, list.currentIndex > before ? 1 : -1);
            moreIfNear();
            return true;
        }
        const t = e.text;
        if (e.key === Qt.Key_Escape || e.key === Qt.Key_Backspace || e.key === Qt.Key_Left || t === "h" || t === "q") {
            back();
            return true;
        }
        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter || e.key === Qt.Key_Right || t === "l" || t === "i") {
            openCurrent();
            return true;
        }
        const home = pages.length === 1;
        switch (t) {
        case "/":
            search();
            return true;
        case "d":
            if (current?.kind === "book")
                download(current, current.formats[0]);
            else
                openCurrent();
            return true;
        case "o":
            if (current?.web || page.web)
                Qt.openUrlExternally(current?.web || page.web);
            return true;
        case "a":
            if (home)
                addCatalog();
            return true;
        case "r":
            if (home && current)
                renameCurrent();
            return true;
        case "x":
            if (home && current)
                removeCurrent();
            return true;
        }
        return true;
    }

    Connections {
        target: root.catalog

        function onLoaded(request, feed) {
            if (root.pending?.request === request)
                root.feedArrived(feed);
        }

        function onCatalogsChanged() {
            if (root.pages.length !== 1)
                return;
            const at = list.currentIndex;
            root.page.rows = root.homeRows();
            root.display(Math.max(0, at));
        }

        function onFinished(id, title, ok, error) {
            root.toast(ok ? `“${title}” is in the library` : `Couldn't get “${title}”: ${error}`);
        }
    }

    ListKeys {
        id: keys

        list: list
        halfPage: Math.max(1, Math.floor(list.height / 88 / 2))
    }

    ListModel {
        id: rowModel
    }

    Rectangle {
        anchors.fill: parent
        color: Theme.surface
    }

    Item {
        id: column

        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        width: Math.min(parent.width - 48, 860)

        Label {
            id: title

            anchors.verticalCenter: undefined
            y: 26
            width: parent.width
            elide: Text.ElideRight
            text: root.page?.title ?? ""
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }

        Label {
            id: trail

            anchors.top: title.bottom
            anchors.topMargin: 4
            anchors.verticalCenter: undefined
            width: parent.width
            elide: Text.ElideMiddle
            text: root.pages.length > 1 ? root.pages.slice(0, -1).map(p => p.title).join("  ›  ") : "Books from the web, free to keep"
            color: Theme.on_surface_variant
            font.pixelSize: 13
        }

        LinearProgress {
            id: progress

            anchors.top: trail.bottom
            anchors.topMargin: 6
            width: parent.width
            indeterminate: true
            thickness: 4
            opacity: root.pending !== null ? 1 : 0

            Behavior on opacity {
                NumberAnimation {
                    duration: Theme.animFast
                }
            }
        }

        ListView {
            id: list

            anchors.top: progress.bottom
            anchors.topMargin: 4
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: hints.top
            anchors.bottomMargin: 10
            clip: true
            spacing: 2
            model: rowModel
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds
            onAtYEndChanged: if (atYEnd)
                root.moreIfNear()

            delegate: Rectangle {
                id: row

                required property int i
                required property int index
                readonly property var item: root.rows[i] ?? ({})
                readonly property bool heading: item.kind === "heading"
                readonly property bool current: ListView.isCurrentItem
                readonly property bool book: item.kind === "book"
                readonly property bool pictured: book || !!item.thumb
                readonly property string sub: {
                    if (item.kind === "catalog")
                        return item.url.replace(/^\w+:\/\/([^/]*).*/, "$1");
                    const authors = (item.authors ?? []).join(", ");
                    if (authors)
                        return authors;
                    return (item.summary ?? "").split("\n")[0];
                }
                readonly property string state_: book ? root.bookState(item) : ""

                width: ListView.view.width
                height: heading ? 46 : pictured ? 92 : sub ? 58 : 46
                radius: Theme.radius
                color: current ? Theme.secondary_container : "transparent"

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.animFast
                    }
                }

                Label {
                    visible: row.heading
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    anchors.leftMargin: 14
                    anchors.verticalCenter: undefined
                    text: row.item.title ?? ""
                    color: Theme.primary
                    font.pixelSize: 15
                    font.weight: Theme.titleWeight
                }

                Cover {
                    id: thumb

                    x: 12
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !row.heading && row.pictured
                    width: 52
                    height: 76
                    radius: 6
                    source: row.pictured ? row.item.thumb ?? "" : ""
                    fallback: row.item.icon ?? ""
                    measure: true
                    title: ""
                }

                Column {
                    visible: !row.heading
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left
                    anchors.leftMargin: thumb.visible ? 80 : 16
                    anchors.right: end.left
                    anchors.rightMargin: 12
                    spacing: 3

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        elide: Text.ElideRight
                        text: row.item.title ?? ""
                        color: row.current ? Theme.on_secondary_container : Theme.on_surface
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        visible: text !== ""
                        elide: Text.ElideRight
                        text: row.sub
                        color: row.current ? Theme.on_secondary_container : Theme.on_surface_variant
                        font.pixelSize: 13
                    }
                }

                Label {
                    id: end

                    visible: !row.heading
                    anchors.right: parent.right
                    anchors.rightMargin: 16
                    text: row.book ? row.state_ : "›"
                    color: row.current ? Theme.on_secondary_container : row.state_.startsWith("✓") ? Theme.primary : Theme.on_surface_variant
                    font.pixelSize: row.book ? 12 : 18
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: !row.heading
                    onClicked: {
                        list.currentIndex = row.index;
                        root.openCurrent();
                    }
                }
            }
        }

        Label {
            anchors.centerIn: list
            visible: root.rows.length === 0 && root.pending === null
            text: root.pages.length > 1 ? "Nothing here" : "No catalogues: a adds one"
            color: Theme.on_surface_variant
        }

        Label {
            id: hints

            anchors.bottom: parent.bottom
            anchors.bottomMargin: 18
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: undefined
            text: root.pages.length === 1 ? "Enter open · a add · r rename · x remove · q back" : "Enter open · d download · / search · o in the browser · q back"
            color: Theme.on_surface_variant
            font.pixelSize: 12
        }
    }

    CatalogBook {
        id: sheet

        view: root
    }
}
