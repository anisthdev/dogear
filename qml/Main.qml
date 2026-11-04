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
    title: mode === "reader" && reader.title ? `${reader.title} — Dogear` : "Dogear"
    color: mode === "reader" ? ReadingTheme.background : Theme.surface

    // "library", "catalog" or "reader"
    property string mode: "library"

    Behavior on color {
        ColorAnimation {
            duration: Theme.animNormal
        }
    }

    readonly property var libraryBindings: [
        ["h j k l  arrows", "Move"],
        ["gg  G", "First, last book"],
        ["Ctrl+d  Ctrl+u", "Half a page down, up"],
        ["Enter  o", "Read, or open a series"],
        ["q  Backspace", "Out of a series"],
        ["/", "Filter by title, author or series"],
        ["t", "Show one tag's books"],
        ["s  S", "Next, previous sort"],
        ["v", "Covers or list"],
        ["z", "Series stacked or not"],
        ["]  [", "Next, previous section"],
        ["c", "Move to the other section (Academic, Non-academic)"],
        ["C", "Section as the tags say"],
        ["x", "Forget progress (leaves Continue reading)"],
        ["Space", "Select"],
        ["e", "Series of the selection or this book"],
        ["T", "Tags of the selection or this book"],
        ["Esc", "Let go: selection, filter, tag, series"],
        ["a", "Add books (copied into the library folder)"],
        ["O", "Online catalogues"],
        ["R", "Look for new books"],
        ["Ctrl+f", "Search the text of every book"],
        ["i", "Details (f there: find it online)"],
        ["F", "Match books not found online yet, one by one"],
        ["?  F1", "These keys"],
        ["q  Ctrl+w", "Quit"]
    ]

    readonly property var catalogBindings: [
        ["j k  gg  G", "Move"],
        ["Ctrl+d  Ctrl+u", "Half a page down, up"],
        ["Enter  l", "Open"],
        ["h  q  Esc", "Back"],
        ["/", "Search the catalogue"],
        ["d", "Download this book"],
        ["o", "In the browser"],
        ["a  r  x", "List of catalogues: add, rename, remove"],
        ["Tab", "A book: choose its EPUB"],
        ["x", "A book: cancel its download"],
        ["?", "This list"]
    ]

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
        ["v", "Visual mode: select with h l w b e j k ( ) { } 0 $, y to finish, d to define"],
        ["m", "Bookmark this page (again: take it off)"],
        ["a", "Highlights and bookmarks"],
        ["/", "Search this book (w: whole words)"],
        ["n  N", "Next, previous match"],
        ["Esc", "Clear the search"],
        ["Ctrl+f", "Search the text of every book"],
        ["s", "Pages or scrolling"],
        ["i", "Dim or invert pictures (dark pages)"],
        ["o", "Open a book"],
        ["F11  f", "Full screen"],
        ["?  F1", "These keys"],
        ["q", "Back to the library"],
        ["Ctrl+w", "Quit"]
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
        if (!reader.openFile(path))
            return;
        toc.open = false;
        fonts.open = false;
        mode = "reader";
        reader.focusPage();
    }

    function showLibrary() {
        toc.open = false;
        fonts.open = false;
        mode = "library";
        library.select(reader.bookId);
        keyCatcher.forceActiveFocus();
    }

    function editNote(a) {
        const what = a.kind === "bookmark" ? "this bookmark" : `“${a.text.length > 80 ? a.text.slice(0, 80) + "…" : a.text}”`;
        inputDialog.ask("Note", `On ${what}. Empty takes it off.`, a.note ?? "", "Save", note => {
            reader.setNote(a.id, note.trim());
            toast(note.trim() ? "Note saved" : "Note taken off");
        });
    }

    function addFiles(urls) {
        const n = Library.add(urls);
        toast(n === 0 ? "No books added" : n === 1 ? "Added a book" : `Added ${n} books`);
    }

    function handleKey(e) {
        if (confirmDialog.open)
            return confirmDialog.handleKey(e);
        if (inputDialog.open)
            return inputDialog.handleKey(e);
        if (definition.open)
            return definition.handleKey(e);
        if (selectionMenu.open)
            return selectionMenu.handleKey(e);
        if (matchPanel.open)
            return matchPanel.handleKey(e);
        if (bookPanel.open)
            return bookPanel.handleKey(e);
        if (bookSearch.open)
            return bookSearch.handleKey(e);
        if (librarySearch.open)
            return librarySearch.handleKey(e);
        if (annotationsPanel.open)
            return annotationsPanel.handleKey(e);
        if (help.open)
            return help.handleKey(e);
        if (tagPanel.open)
            return tagPanel.handleKey(e);
        if (toc.open)
            return toc.handleKey(e);
        if (fonts.open)
            return fonts.handleKey(e);

        const t = e.text;
        const ctrl = e.modifiers & Qt.ControlModifier;
        const shift = e.modifiers & Qt.ShiftModifier;

        if (ctrl && (e.key === Qt.Key_W || e.key === Qt.Key_Q)) {
            win.close();
            return true;
        }
        if (ctrl && e.key === Qt.Key_F) {
            librarySearch.show();
            return true;
        }
        if (t === "?" || e.key === Qt.Key_F1) {
            help.open = true;
            return true;
        }
        if (mode === "catalog")
            return catalog.handleKey(e);
        if (mode === "library") {
            if (t === "O") {
                catalog.show();
                mode = "catalog";
                return true;
            }
            if (t === "i" && library.current) {
                const c = library.current;
                bookPanel.show(c.isSeries ? c.next.id : c.id);
                return true;
            }
            if (t === "F") {
                // Not matched, not set aside, in the order shown
                const shown = library.allBooks();
                matchPanel.review(shown.filter(b => !b.onlineKey && b.online !== "skipped" && b.online !== "pending").map(b => b.id));
                return true;
            }
            if (library.handleKey(e))
                return true;
            if (t === "q") {
                win.close();
                return true;
            }
            return false;
        }

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
        case "v":
            reader.send("visual");
            return true;
        case "/":
            bookSearch.show(reader.searchQuery);
            return true;
        case "n":
            if (reader.searchHits.length)
                reader.nextHit(1);
            else if (reader.searchQuery)
                toast("No matches");
            return true;
        case "N":
            if (reader.searchHits.length)
                reader.nextHit(-1);
            return true;
        case "m":
            toast(reader.toggleBookmark() ? "Bookmarked" : "Bookmark taken off");
            return true;
        case "a":
            annotationsPanel.show();
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
            showLibrary();
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
        case Qt.Key_Escape:
            if (reader.searchQuery) {
                reader.clearSearch();
                toast("Search cleared");
            }
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
        visible: win.mode === "reader" && hasBook
        onKeyPressed: event => win.handleKey(event)
        onSelected: selectionMenu.show()
        onDefineSelection: win.define()
        onFailed: message => win.toast(message)
    }

    LibraryView {
        id: library

        anchors.fill: parent
        visible: win.mode === "library"
        onOpenBook: path => win.openBook(path)
        onAddBooks: addDialog.open()
        onToast: message => win.toast(message)
        onKeysBack: keyCatcher.forceActiveFocus()
        dialog: inputDialog
        confirm: confirmDialog
        tagPanel: tagPanel
    }

    CatalogView {
        id: catalog

        anchors.fill: parent
        visible: win.mode === "catalog"
        dialog: inputDialog
        confirm: confirmDialog
        onLeave: win.mode = "library"
        onOpenBook: path => win.openBook(path)
        onToast: message => win.toast(message)
    }

    function define() {
        const s = reader.selection;
        if (!s)
            return;
        definition.lookup(s.text, s.rect, reader.details?.language ?? "");
        reader.clearSelection();
    }

    DefinitionCard {
        id: definition

        reader: reader
        onToast: message => win.toast(message)
        onOpenChanged: if (!open && win.mode === "reader")
            reader.focusPage()
    }

    SelectionMenu {
        id: selectionMenu

        reader: reader
        onDefine: win.define()
        onToast: message => win.toast(message)
        onEditNote: annotation => win.editNote(annotation)
        onOpenChanged: if (!open && win.mode === "reader")
            reader.focusPage()
    }

    AnnotationsPanel {
        id: annotationsPanel

        reader: reader
        onToast: message => win.toast(message)
        onEditNote: annotation => win.editNote(annotation)
        onChosen: cfi => reader.send("goTo", cfi)
        onOpenChanged: if (!open && win.mode === "reader")
            reader.focusPage()
    }

    // Visual mode's reminder, while it's on
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - height - 60
        width: visualLabel.implicitWidth + 32
        height: 36
        radius: 18
        color: Theme.primary_container
        opacity: reader.visual && win.mode === "reader" ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        Label {
            id: visualLabel

            anchors.centerIn: parent
            text: "Visual · h l w b e j k ( ) { } 0 $ to select · o other end · y done · d define · Esc cancel"
            color: Theme.on_primary_container
            font.pixelSize: 12
        }
    }

    // Searching the open book: matches under their chapters
    SearchPanel {
        id: bookSearch

        title: "Search this book"
        placeholder: "Words to find"
        busy: reader.searching
        status: {
            const n = reader.searchHits.length;
            if (!reader.searchQuery.trim())
                return "Case and accents don't matter";
            return n === 0 ? (reader.searching ? "" : "No matches") : `${n} ${n === 1 ? "match" : "matches"}`;
        }
        rows: {
            const rows = [];
            let chapter = null;
            reader.searchHits.forEach((h, i) => {
                if (h.chapter !== chapter) {
                    chapter = h.chapter;
                    rows.push({
                        header: true,
                        label: chapter || "Untitled"
                    });
                }
                rows.push({
                    before: h.before,
                    match: h.match,
                    after: h.after,
                    payload: i
                });
            });
            return rows;
        }
        onSearch: (query, whole) => query.trim() ? reader.search(query, whole) : reader.clearSearch()
        onChosen: i => {
            close();
            reader.goToHit(i);
        }
        onKeysBack: win.mode === "reader" ? reader.focusPage() : keyCatcher.forceActiveFocus()
    }

    // Searching every book's text (Library.searchText): passages under
    // their books
    SearchPanel {
        id: librarySearch

        property var results: []
        property string ran: ""

        title: "Search all books"
        placeholder: "A quote, a name, a phrase…"
        sheetWidth: 600
        status: {
            if (ran.trim().length < 2)
                return "Every book's text · case and accents don't matter";
            const books = new Set(results.map(r => r.book)).size;
            const n = results.length;
            return n === 0 ? "No passages found" : `${n >= 200 ? "200+" : n} ${n === 1 ? "passage" : "passages"} in ${books} ${books === 1 ? "book" : "books"}`;
        }
        rows: {
            // Books in the order of their best passage
            const order = [];
            const byBook = new Map();
            for (const r of results) {
                if (!byBook.has(r.book)) {
                    byBook.set(r.book, []);
                    order.push(r);
                }
                byBook.get(r.book).push(r);
            }
            const rows = [];
            // Within a book, in reading order
            for (const list of byBook.values())
                list.sort((a, b) => a.section - b.section);
            for (const first of order) {
                rows.push({
                    header: true,
                    label: first.title,
                    sub: first.authors,
                    cover: first.cover
                });
                for (const r of byBook.get(first.book))
                    rows.push({
                        before: r.before,
                        match: r.match,
                        after: r.after,
                        sub: r.chapter,
                        payload: r
                    });
            }
            return rows;
        }
        onSearch: (query, whole) => {
            ran = query;
            results = query.trim().length >= 2 ? Library.searchText(query, whole) : [];
        }
        onChosen: r => {
            close();
            if (reader.openAt(r.path, query, r.section, wholeWords, r.before)) {
                toc.open = false;
                fonts.open = false;
                mode = "reader";
                reader.focusPage();
            }
        }
        onKeysBack: win.mode === "reader" ? reader.focusPage() : keyCatcher.forceActiveFocus()
    }

    // Where n/N are, while a search has matches
    Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        y: parent.height - height - 60
        width: hitLabel.implicitWidth + 32
        height: 36
        radius: 18
        color: Theme.secondary_container
        opacity: win.mode === "reader" && reader.searchQuery && !bookSearch.open && !reader.visual ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animFast
            }
        }

        Label {
            id: hitLabel

            anchors.centerIn: parent
            text: {
                const n = reader.searchHits.length;
                const q = reader.searchQuery.length > 24 ? reader.searchQuery.slice(0, 24) + "…" : reader.searchQuery;
                if (n === 0)
                    return reader.searching ? `Searching “${q}”…` : `No matches for “${q}” · Esc`;
                const at = reader.searchAt >= 0 ? `${reader.searchAt + 1} of ${n}` : `${n} matches`;
                return `“${q}” · ${at}${reader.searching ? "+" : ""} · n N · Esc clears`;
            }
            color: Theme.on_secondary_container
            font.pixelSize: 12
        }
    }

    TagPanel {
        id: tagPanel

        onChosen: tag => {
            library.tag = tag;
            library.setCurrent(0);
        }
        onKeysBack: keyCatcher.forceActiveFocus()
    }

    BookPanel {
        id: bookPanel

        dialog: inputDialog
        onRead: path => win.openBook(path)
        onFindOnline: book => matchPanel.show(book)
        onEditSeries: book => library.editSeries([book])
        onEditTags: book => library.editTags([book])
        onToast: message => win.toast(message)
    }

    MatchPanel {
        id: matchPanel

        onToast: message => win.toast(message)
        onKeysBack: win.mode === "reader" ? reader.focusPage() : keyCatcher.forceActiveFocus()
    }

    ConfirmDialog {
        id: confirmDialog
    }

    InputDialog {
        id: inputDialog

        onClosed: win.mode === "reader" ? reader.focusPage() : keyCatcher.forceActiveFocus()
    }

    DropArea {
        anchors.fill: parent
        keys: ["text/uri-list"]
        // Into the library; in the reader, the first is also opened
        onDropped: drop => {
            const urls = drop.urls.map(u => u.toString()).filter(u => u.toLowerCase().endsWith(".epub"));
            if (urls.length === 0)
                return;
            drop.accept();
            win.addFiles(urls);
            if (win.mode === "reader")
                win.openBook(urls[0]);
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

        bindings: win.mode === "library" ? win.libraryBindings : win.mode === "catalog" ? win.catalogBindings : win.bindings
        onOpenChanged: if (!open && reader.hasBook && win.mode === "reader")
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

    FileDialog {
        id: addDialog

        title: "Add books"
        fileMode: FileDialog.OpenFiles
        nameFilters: ["EPUB books (*.epub)"]
        onAccepted: win.addFiles(selectedFiles.map(u => u.toString()))
    }

    // A book given on the command line opens; otherwise the library, on
    // the book read last (first in its default order)
    Component.onCompleted: {
        if (Library.startFile)
            openBook(Library.startFile);
    }
}
