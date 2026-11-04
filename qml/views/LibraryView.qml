import QtQuick
import QtCore
import Dogear

// The library: every book in the library folders as a cover grid or a
// list, newest-read first by default, so Enter carries on reading. A
// series (two books or more) shows as one stack; Enter opens it, its books
// in order.
//
// Keys: h j k l and the arrows move (in the list, j/k), gg G, Ctrl+d/u,
// Page Up/Down; Enter/o open (l too in the list); / filters by title,
// author or series (Enter keeps the filter and gives the keys back, Esc
// clears it); t picks a tag; s sort, v grid or list, z stacks on or off;
// Space selects; e sets the series, T the tags (of the selection, else the
// current book or stack); a add books, R rescan; q/Backspace leave a
// series; Esc lets go of the selection, then the filter, the tag and the
// series.
Item {
    id: root

    signal openBook(string path)
    signal addBooks
    signal toast(string message)
    // QML focus should go back to the window's key handler
    signal keysBack

    // Set by the window: the dialog for series and tags, the tag picker
    property InputDialog dialog
    property ConfirmDialog confirm
    property TagPanel tagPanel

    Settings {
        id: prefs

        location: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/dogear/dogear.conf"
        category: "library"

        property string view: "grid"
        property string sort: "recent"
        property bool stacks: true
    }

    readonly property var sorts: ["recent", "title", "author", "added", "progress"]
    readonly property var sortNames: ({
            recent: "Recently read",
            title: "Title",
            author: "Author",
            added: "Recently added",
            progress: "Progress"
        })
    readonly property string sort: sorts.includes(prefs.sort) ? prefs.sort : "recent"
    readonly property bool grid: prefs.view !== "list"

    // The series being looked into ("" for the whole library)
    property string openSeries: ""
    // Only books with this tag ("" for all)
    property string tag: ""
    // Selected book ids (Space), as { id: true }
    property var selected: ({})
    readonly property int selectedCount: Object.keys(selected).length
    // The item under the cursor, kept across re-sorts, filters and rescans
    property string currentId: ""

    readonly property var byTitle: (a, b) => a.title.localeCompare(b.title, undefined, {
            numeric: true,
            sensitivity: "base"
        })
    readonly property var bySeriesOrder: (a, b) => ((a.seriesIndex || 1e9) - (b.seriesIndex || 1e9)) || byTitle(a, b)

    // The books the filter and tag let through
    readonly property var words: input.text.toLowerCase().split(/\s+/).filter(Boolean)
    readonly property var filtered: {
        const tag = root.tag.toLowerCase();
        return Library.books.filter(b => {
            if (tag && !b.tags.some(t => t.toLowerCase() === tag))
                return false;
            const hay = `${b.title} ${b.authors} ${b.series}`.toLowerCase();
            return words.every(w => hay.includes(w));
        });
    }

    // Books as shown in a section: series of two or more as one stack (a
    // stack looks like a book to the sort: its latest reading and adding,
    // its series name as title, the book to read next as cover), sorted
    function stacked(books) {
        let list = books;
        if (prefs.stacks && words.length === 0) {
            const groups = new Map();
            for (const b of books)
                if (b.series)
                    groups.set(b.series, (groups.get(b.series) ?? []).concat([b]));
            list = books.filter(b => !b.series || groups.get(b.series).length < 2);
            for (const [name, members] of groups) {
                if (members.length < 2)
                    continue;
                members.sort(bySeriesOrder);
                // Next to read: the one being read, else the first not
                // finished, else the first
                const reading = members.filter(b => b.fraction > 0 && b.fraction < 0.995).sort((a, b) => b.openedAt - a.openedAt)[0];
                const next = reading ?? members.find(b => b.fraction < 0.995) ?? members[0];
                const authors = [...new Set(members.map(b => b.authors).filter(Boolean))];
                list.push({
                    isSeries: true,
                    id: `series:${name}`,
                    title: name,
                    series: name,
                    seriesIndex: 0,
                    authors: authors.length === 1 ? authors[0] : authors.length > 1 ? "Various authors" : "",
                    authorsSort: members[0].authorsSort,
                    cover: next.cover,
                    next: next,
                    books: members,
                    category: members[0].category,
                    openedAt: Math.max(...members.map(b => b.openedAt)),
                    addedAt: Math.max(...members.map(b => b.addedAt)),
                    fraction: members.reduce((s, b) => s + b.fraction, 0) / members.length,
                    finished: members.filter(b => b.fraction >= 0.995).length,
                    started: members.filter(b => b.fraction > 0 && b.fraction < 0.995).length
                });
            }
        }
        const compare = {
            recent: (a, b) => (b.openedAt - a.openedAt) || (b.addedAt - a.addedAt) || byTitle(a, b),
            title: byTitle,
            author: (a, b) => a.authorsSort.localeCompare(b.authorsSort, undefined, {
                    sensitivity: "base"
                }) || a.series.localeCompare(b.series) || (a.seriesIndex - b.seriesIndex) || byTitle(a, b),
            added: (a, b) => (b.addedAt - a.addedAt) || byTitle(a, b),
            progress: (a, b) => (b.fraction - a.fraction) || (b.openedAt - a.openedAt) || byTitle(a, b)
        }[sort];
        return list.slice().sort(compare);
    }

    readonly property var categories: [["academic", "Academic"], ["nonacademic", "Non-academic"]]

    // What's shown, top to bottom: { key, title, row (one sideways row),
    // items }. Continue reading (books started, not finished, latest
    // first; they show in their own section too), then a section per
    // category. Inside a series: just its books.
    readonly property var sections: {
        if (openSeries)
            return [{
                    key: "series",
                    title: openSeries,
                    row: false,
                    items: filtered.filter(b => b.series === openSeries).sort(bySeriesOrder)
                }];
        const out = [];
        const reading = filtered.filter(b => b.fraction > 0 && b.fraction < 0.995).sort((a, b) => b.openedAt - a.openedAt);
        if (reading.length)
            out.push({
                key: "continue",
                title: "Continue reading",
                row: true,
                items: reading
            });
        for (const [key, title] of categories) {
            const items = stacked(filtered.filter(b => b.category === key));
            if (items.length)
                out.push({
                    key: key,
                    title: title,
                    row: false,
                    items: items
                });
        }
        return out;
    }

    // Every place the cursor can be, in order: { sec, idx, item, key }
    readonly property var slots: {
        const out = [];
        sections.forEach((s, sec) => s.items.forEach((item, idx) => out.push({
                        sec: sec,
                        idx: idx,
                        item: item,
                        key: `${s.key}:${item.id}`
                    })));
        return out;
    }
    readonly property var sectionStart: {
        const out = [];
        let n = 0;
        for (const s of sections) {
            out.push(n);
            n += s.items.length;
        }
        return out;
    }

    property int cursor: 0
    // The slot under the cursor, kept across re-sorts, filters and rescans
    property string currentKey: ""
    readonly property var current: slots[cursor]?.item ?? null

    // As many columns as fit at ~180px, filling the width
    readonly property int columns: Math.max(2, Math.floor(flick.width / 180))
    readonly property real cellWidth: Math.floor(flick.width / columns)

    onSlotsChanged: Qt.callLater(restoreCurrent)
    onGridChanged: Qt.callLater(restoreCurrent)

    function restoreCurrent() {
        let i = slots.findIndex(s => s.key === currentKey);
        const id = currentKey.slice(currentKey.indexOf(":") + 1);
        if (i < 0)
            i = slots.findIndex(s => s.item.id === id);
        // A book read inside a stack: the stack
        if (i < 0)
            i = slots.findIndex(s => s.item.isSeries && s.item.books.some(m => m.id === id));
        setCurrent(Math.max(0, i));
    }

    // Every book shown once, in order, a stack's in its own (QML's JS has
    // no flatMap); Continue reading's are in their sections too
    function allBooks() {
        const out = [];
        const seen = {};
        for (const s of sections) {
            if (s.key === "continue")
                continue;
            for (const it of s.items)
                for (const b of (it.isSeries ? it.books : [it]))
                    if (!seen[b.id]) {
                        seen[b.id] = true;
                        out.push(b);
                    }
        }
        return out;
    }

    function setCurrent(i) {
        if (slots.length === 0)
            return;
        cursor = Math.max(0, Math.min(slots.length - 1, i));
        currentKey = slots[cursor].key;
    }

    function goTo(sec, idx) {
        setCurrent(sectionStart[sec] + Math.max(0, Math.min(sections[sec].items.length - 1, idx)));
    }

    // Columns of a section (a sideways row has no rows)
    function colsOf(sec) {
        return !grid ? 1 : sections[sec].row ? 1e9 : columns;
    }

    // h / l: along a row of covers; nothing in the list
    function horizontal(d) {
        const s = slots[cursor];
        if (!s || !grid)
            return;
        goTo(s.sec, s.idx + d);
    }

    // j / k: a row down or up, into the next or previous section at the
    // same column
    function vertical(d) {
        const s = slots[cursor];
        if (!s)
            return;
        const n = sections[s.sec].items.length;
        const c = colsOf(s.sec);
        const col = c >= 1e9 ? Math.min(s.idx, columns - 1) : s.idx % c;
        if (c < 1e9) {
            const next = s.idx + d * c;
            if (next >= 0 && next < n)
                return goTo(s.sec, next);
            // Into a shorter last row
            if (d > 0 && Math.floor((n - 1) / c) > Math.floor(s.idx / c))
                return goTo(s.sec, n - 1);
        }
        const ts = s.sec + d;
        if (ts < 0 || ts >= sections.length)
            return;
        const tn = sections[ts].items.length;
        const tc = colsOf(ts);
        if (d > 0 || tc >= 1e9)
            goTo(ts, Math.min(col, tn - 1));
        else
            goTo(ts, Math.min(Math.floor((tn - 1) / tc) * tc + col, tn - 1));
    }

    function jumpSection(d) {
        const s = slots[cursor];
        if (!s)
            return;
        const ts = Math.max(0, Math.min(sections.length - 1, s.sec + d));
        goTo(ts, 0);
    }

    // Keep an item in view as the cursor reaches it
    function reveal(item) {
        const p = item.mapToItem(column, 0, 0);
        const top = p.y - (item.headerRoom ?? 0);
        if (top < flick.contentY)
            flick.contentY = Math.max(0, top - 8);
        else if (p.y + item.height > flick.contentY + flick.height)
            flick.contentY = Math.min(Math.max(0, column.implicitHeight - flick.height + 24), p.y + item.height - flick.height + 16);
    }

    function ago(secs) {
        if (!secs)
            return "";
        const d = Date.now() / 1000 - secs;
        if (d < 60)
            return "just now";
        if (d < 3600)
            return `${Math.round(d / 60)} min ago`;
        if (d < 86400)
            return `${Math.round(d / 3600)} h ago`;
        if (d < 2 * 86400)
            return "yesterday";
        if (d < 30 * 86400)
            return `${Math.round(d / 86400)} days ago`;
        return new Date(secs * 1000).toLocaleDateString(Qt.locale(), Locale.ShortFormat);
    }

    function finished(b) {
        return b.isSeries ? b.finished === b.books.length : b.fraction >= 0.995;
    }

    // x: forget progress in the selection (or this book, or a stack's
    // books), after asking; they leave Continue reading
    function resetProgress() {
        const books = targets().filter(b => b.fraction > 0 || b.openedAt > 0);
        if (books.length === 0) {
            toast("Not started yet");
            return;
        }
        const what = books.length === 1 ? `“${books[0].title}”` : `${books.length} books`;
        confirm.ask("Forget progress?", `${what} will start from the beginning and leave Continue reading. Highlights and bookmarks stay.`, "Forget", () => {
            Library.resetProgress(books.map(b => b.id));
            selected = {};
            toast(books.length === 1 ? "Progress forgotten" : `Progress forgotten in ${books.length} books`);
        });
    }

    // c: the selection (or this book, or a stack's books) into the other
    // section; C: back to the guess from their tags
    function toggleCategory(reset) {
        const books = targets();
        if (books.length === 0)
            return;
        const ids = books.map(b => b.id);
        if (reset) {
            Library.setCategory(ids, "");
            toast("Section as their tags say");
        } else {
            const to = books.every(b => b.category === "academic") ? "nonacademic" : "academic";
            Library.setCategory(ids, to);
            toast(`${books.length === 1 ? `“${books[0].title}”` : `${books.length} books`} in ${to === "academic" ? "Academic" : "Non-academic"}`);
        }
        selected = {};
    }

    // Select a book by id (after reading it, say): where it first shows
    function select(id) {
        currentKey = `:${id}`;
        restoreCurrent();
    }

    function openCurrent() {
        const it = current;
        if (!it)
            return;
        if (it.isSeries) {
            enterSeries(it);
            return;
        }
        openBook(it.path);
    }

    function enterSeries(stack) {
        openSeries = stack.series;
        currentId = stack.next.id;
        Qt.callLater(restoreCurrent);
    }

    function leaveSeries() {
        const name = openSeries;
        openSeries = "";
        currentId = `series:${name}`;
        Qt.callLater(restoreCurrent);
    }

    // The books an edit applies to: the selection, else the current book,
    // or every book of the current stack
    function targets() {
        const ids = Object.keys(selected);
        if (ids.length > 0)
            return Library.books.filter(b => selected[b.id]);
        const it = current;
        if (!it)
            return [];
        return it.isSeries ? it.books : [it];
    }

    function toggleSelected() {
        const it = current;
        if (!it)
            return;
        const s = Object.assign({}, selected);
        const ids = it.isSeries ? it.books.map(b => b.id) : [it.id];
        const on = !ids.every(id => s[id]);
        for (const id of ids) {
            if (on)
                s[id] = true;
            else
                delete s[id];
        }
        selected = s;
        setCurrent(cursor + 1);
    }

    function isSelected(it) {
        return it.isSeries ? it.books.every(b => selected[b.id]) : !!selected[it.id];
    }

    function editSeries(given) {
        const books = given ?? targets();
        if (books.length === 0)
            return;
        const names = [...new Set(books.map(b => b.series))];
        let text = names.length === 1 ? names[0] : "";
        if (books.length === 1 && books[0].seriesIndex)
            text += ` #${books[0].seriesIndex}`;
        const what = books.length === 1 ? `“${books[0].title}”` : `${books.length} books`;
        dialog.ask("Series", `For ${what}. A name, and #number for its place (several books without a number are numbered in the order shown). Empty for none; “auto” for what the book or its folder says.`, text, "Save", answer => {
            const m = answer.trim().match(/^(.*?)(?:\s*#\s*(\d+(?:\.\d+)?))?$/);
            const name = (m?.[1] ?? "").trim();
            const ids = books.map(b => b.id);
            if (name.toLowerCase() === "auto") {
                Library.resetSeries(ids);
                toast("Series as the books say");
                return;
            }
            let indexes;
            if (m?.[2])
                indexes = books.map(() => parseFloat(m[2]));
            else if (books.length === 1)
                indexes = [books[0].series === name ? books[0].seriesIndex : 0];
            else {
                const order = root.allBooks().map(b => b.id);
                const sorted = books.slice().sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
                indexes = books.map(b => sorted.indexOf(b) + 1);
            }
            Library.setSeries(ids, name, indexes);
            selected = {};
            toast(name ? `In “${name}”` : "No series");
        });
    }

    function editTags(given) {
        const books = given ?? targets();
        if (books.length === 0)
            return;
        // Tags every one of them has; editing changes those, leaving the
        // rest of each book's own
        const lower = b => b.tags.map(t => t.toLowerCase());
        const common = books[0].tags.filter(t => books.every(b => lower(b).includes(t.toLowerCase())));
        const what = books.length === 1 ? `“${books[0].title}”` : `${books.length} books (the tags they share)`;
        dialog.ask("Tags", `For ${what}, separated by commas.`, common.join(", "), "Save", answer => {
            const wanted = answer.split(",").map(t => t.trim()).filter(Boolean);
            const wantedLower = wanted.map(t => t.toLowerCase());
            const dropped = common.map(t => t.toLowerCase()).filter(t => !wantedLower.includes(t));
            for (const b of books) {
                const kept = b.tags.filter(t => !dropped.includes(t.toLowerCase()));
                const added = wanted.filter(t => !kept.some(k => k.toLowerCase() === t.toLowerCase()));
                Library.setTags(b.id, kept.concat(added));
            }
            selected = {};
            toast("Tags saved");
        });
    }

    property bool pendingG: false

    Timer {
        id: gTimer

        interval: 600
        onTriggered: root.pendingG = false
    }

    function handleKey(e) {
        const t = e.text;
        const ctrl = e.modifiers & Qt.ControlModifier;
        const rows = Math.max(1, Math.floor(flick.height / (grid ? cellWidth * 1.5 + 80 : 64)));
        const repeat = (n, d) => {
            for (let k = 0; k < n; ++k)
                vertical(d);
        };

        if (t === "g" && !ctrl) {
            if (pendingG) {
                pendingG = false;
                setCurrent(0);
            } else {
                pendingG = true;
                gTimer.restart();
            }
            return true;
        }
        pendingG = false;

        if (ctrl) {
            switch (e.key) {
            case Qt.Key_D:
                repeat(Math.max(1, Math.floor(rows / 2)), 1);
                return true;
            case Qt.Key_U:
                repeat(Math.max(1, Math.floor(rows / 2)), -1);
                return true;
            case Qt.Key_B:
                repeat(rows, -1);
                return true;
            case Qt.Key_N:
            case Qt.Key_J:
                vertical(1);
                return true;
            case Qt.Key_P:
            case Qt.Key_K:
                vertical(-1);
                return true;
            }
            return false;
        }

        switch (t) {
        case "j":
            vertical(1);
            return true;
        case "k":
            vertical(-1);
            return true;
        case "h":
            horizontal(-1);
            return true;
        case "l":
            if (grid)
                horizontal(1);
            else
                openCurrent();
            return true;
        case "]":
            jumpSection(1);
            return true;
        case "[":
            jumpSection(-1);
            return true;
        case "G":
            setCurrent(slots.length - 1);
            return true;
        case "o":
            openCurrent();
            return true;
        case "/":
            input.forceActiveFocus();
            return true;
        case "t":
            tagPanel.current = tag;
            tagPanel.show();
            return true;
        case "s":
            prefs.sort = sorts[(sorts.indexOf(sort) + 1) % sorts.length];
            toast(`Sorted by ${sortNames[sort].toLowerCase()}`);
            return true;
        case "S":
            prefs.sort = sorts[(sorts.indexOf(sort) - 1 + sorts.length) % sorts.length];
            toast(`Sorted by ${sortNames[sort].toLowerCase()}`);
            return true;
        case "v":
            prefs.view = grid ? "list" : "grid";
            return true;
        case "z":
            prefs.stacks = !prefs.stacks;
            if (!prefs.stacks && openSeries)
                openSeries = "";
            toast(prefs.stacks ? "Series stacked" : "Every book on its own");
            return true;
        case "c":
            toggleCategory(false);
            return true;
        case "x":
            resetProgress();
            return true;
        case "C":
            toggleCategory(true);
            return true;
        case " ":
            toggleSelected();
            return true;
        case "e":
            editSeries();
            return true;
        case "T":
            editTags();
            return true;
        case "a":
            addBooks();
            return true;
        case "R":
            Library.rescan();
            toast("Looking for new books");
            return true;
        case "q":
            if (openSeries) {
                leaveSeries();
                return true;
            }
            return false;
        }

        switch (e.key) {
        case Qt.Key_Return:
        case Qt.Key_Enter:
            openCurrent();
            return true;
        case Qt.Key_Backspace:
            if (openSeries)
                leaveSeries();
            return true;
        case Qt.Key_Down:
            vertical(1);
            return true;
        case Qt.Key_Up:
            vertical(-1);
            return true;
        case Qt.Key_Left:
            horizontal(-1);
            return true;
        case Qt.Key_Right:
            horizontal(1);
            return true;
        case Qt.Key_PageDown:
            repeat(rows, 1);
            return true;
        case Qt.Key_PageUp:
            repeat(rows, -1);
            return true;
        case Qt.Key_Home:
            setCurrent(0);
            return true;
        case Qt.Key_End:
            setCurrent(slots.length - 1);
            return true;
        case Qt.Key_Escape:
            // One thing at a time: selection, filter, tag, series
            if (selectedCount > 0)
                selected = {};
            else if (input.text !== "")
                input.text = "";
            else if (tag !== "")
                tag = "";
            else if (openSeries)
                leaveSeries();
            return true;
        }
        return false;
    }

    function percent(b) {
        if (b.isSeries) {
            const parts = [`${b.books.length} books`];
            if (b.finished)
                parts.push(`${b.finished} read`);
            if (b.started)
                parts.push(`${b.started} started`);
            return parts.join(" · ");
        }
        if (b.fraction >= 0.995)
            return "Finished";
        if (b.fraction > 0)
            return `${Math.max(1, Math.round(b.fraction * 100))}%`;
        return b.openedAt > 0 ? "Started" : "";
    }

    function subtitle(b) {
        if (b.isSeries)
            return [b.authors, percent(b)].filter(Boolean).join(" · ");
        const parts = [b.authors];
        if (openSeries && b.seriesIndex)
            parts.unshift(`#${b.seriesIndex}`);
        parts.push(percent(b));
        return parts.filter(Boolean).join(" · ");
    }

    // Header: where we are, and what's shown
    Row {
        id: title

        x: 28
        y: 26
        spacing: 10

        Label {
            anchors.verticalCenter: undefined
            text: "Library"
            color: root.openSeries ? Theme.on_surface_variant : Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness

            MouseArea {
                anchors.fill: parent
                enabled: root.openSeries !== ""
                onClicked: root.leaveSeries()
            }
        }

        Label {
            anchors.verticalCenter: undefined
            visible: root.openSeries !== ""
            text: "›"
            color: Theme.on_surface_variant
            font.pixelSize: 26
        }

        Label {
            anchors.verticalCenter: undefined
            visible: root.openSeries !== ""
            text: root.openSeries
            color: Theme.primary
            font.pixelSize: 26
            font.weight: Theme.titleWeight
            roundness: Theme.titleRoundness
        }
    }

    Label {
        anchors.right: parent.right
        anchors.rightMargin: 28
        anchors.bottom: title.bottom
        anchors.bottomMargin: 6
        anchors.verticalCenter: undefined
        text: {
            const books = root.allBooks().length;
            const total = Library.books.length;
            const parts = [];
            if (root.selectedCount)
                parts.push(`${root.selectedCount} selected`);
            parts.push(books === total ? `${total} ${total === 1 ? "book" : "books"}` : `${books} of ${total} books`);
            if (root.tag)
                parts.push(`tagged ${root.tag}`);
            parts.push(root.openSeries ? "Series order" : root.sortNames[root.sort]);
            return parts.join(" · ");
        }
        color: Theme.on_surface_variant
        font.pixelSize: 12
    }

    LinearProgress {
        anchors.top: title.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 28
        anchors.rightMargin: 28
        thickness: 3
        indeterminate: true
        opacity: Library.scanning ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.animNormal
            }
        }
    }

    // The filter, hidden until / (or while it holds text)
    Rectangle {
        id: field

        readonly property bool shown: input.activeFocus || input.text !== ""

        anchors.top: title.bottom
        anchors.topMargin: 16
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 20
        height: shown ? 42 : 0
        visible: shown
        radius: Theme.radius
        color: Theme.surface_container_high

        TextInput {
            id: input

            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 18
            verticalAlignment: TextInput.AlignVCenter
            color: Theme.on_surface
            selectionColor: Theme.primary_container
            selectedTextColor: Theme.on_primary_container
            font.family: Theme.fontFamily
            font.pixelSize: 14
            clip: true

            onTextChanged: root.setCurrent(0)

            Keys.onPressed: event => {
                const ctrl = event.modifiers & Qt.ControlModifier;
                if (event.key === Qt.Key_Escape) {
                    text = "";
                    root.keysBack();
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.keysBack();
                } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab || (ctrl && (event.key === Qt.Key_J || event.key === Qt.Key_N))) {
                    root.vertical(1);
                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) {
                    root.vertical(-1);
                } else {
                    return;
                }
                event.accepted = true;
            }

            Label {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                visible: !input.text
                text: "Filter by title, author or series"
                color: Theme.on_surface_variant
            }
        }
    }

    // A tick on selected books
    component Check: Rectangle {
        width: 24
        height: 24
        radius: 12
        color: Theme.primary
        border.width: 2
        border.color: Theme.surface

        Label {
            anchors.centerIn: parent
            text: "✓"
            color: Theme.on_primary
            font.pixelSize: 13
            font.weight: Font.Bold
        }
    }

    readonly property real bigWidth: Math.min(260, Math.round(cellWidth * 1.3))

    // A tick on finished books
    component Finished: Rectangle {
        width: finishedLabel.implicitWidth + 14
        height: 22
        radius: 11
        color: Qt.alpha(Theme.surface, 0.88)

        Label {
            id: finishedLabel

            anchors.centerIn: parent
            text: "✓ Read"
            color: Theme.primary
            font.pixelSize: 11
        }
    }

    // A book or stack as a cover, in a grid or the Continue reading row
    component BookCell: Item {
        id: cell

        required property var modelData
        required property int index
        property int base: 0
        property bool big: false
        // Room above it for a section heading, kept in view with it
        property real headerRoom: 0
        readonly property int slot: base + index
        readonly property bool current: root.cursor === slot
        readonly property bool stack: !!modelData.isSeries
        // A stack's cover sits lower and narrower, two cards behind it
        readonly property int lift: stack ? 8 : 0

        width: big ? root.bigWidth : root.cellWidth
        height: Math.round((width - 20) * 1.5) + 86

        // After the layout has caught up
        Timer {
            id: revealLater

            interval: 0
            onTriggered: root.reveal(cell)
        }

        onCurrentChanged: if (current)
            revealLater.restart()

        Rectangle {
            anchors.fill: parent
            anchors.margins: 2
            radius: Theme.cardRadius
            color: cell.current ? Theme.secondary_container : "transparent"

            Behavior on color {
                ColorAnimation {
                    duration: Theme.animFast
                }
            }
        }

        // Behind a stack's cover, the series' next two, dimmed
        Repeater {
            model: cell.stack ? cell.modelData.books.filter(b => b.id !== cell.modelData.next.id).slice(0, 2).reverse() : []

            Item {
                id: behind

                required property var modelData
                required property int index
                readonly property int depth: cell.modelData.books.length > 2 ? 2 - index : 1

                x: cover.x + depth * cell.lift
                y: cover.y - depth * cell.lift
                width: cover.width
                height: cover.height

                Cover {
                    anchors.fill: parent
                    source: behind.modelData.cover
                    title: ""
                    authors: ""
                }

                Rectangle {
                    anchors.fill: parent
                    radius: 8
                    color: Qt.alpha(Theme.surface, 0.25 + 0.2 * behind.depth)
                    border.width: 1
                    border.color: Qt.alpha(Theme.outline, 0.5)
                }
            }
        }

        Cover {
            id: cover

            x: 10
            y: 10 + 2 * cell.lift
            width: cell.width - 20 - 2 * cell.lift
            height: Math.round((cell.width - 20) * 1.5) - 2 * cell.lift
            source: cell.modelData.cover
            title: cell.modelData.isSeries ? cell.modelData.next.title : cell.modelData.title
            authors: cell.modelData.authors
        }

        Check {
            anchors.right: cover.right
            anchors.top: cover.top
            anchors.margins: -6
            visible: root.isSelected(cell.modelData)
        }

        Finished {
            anchors.left: cover.left
            anchors.bottom: cover.bottom
            anchors.margins: 6
            visible: root.finished(cell.modelData)
        }

        // How far through, along the cover's foot
        LinearProgress {
            anchors.left: cover.left
            anchors.right: cover.right
            anchors.top: cover.bottom
            anchors.topMargin: 4
            visible: cell.modelData.fraction > 0 && !root.finished(cell.modelData)
            thickness: 3
            progress: cell.modelData.fraction
            color: Theme.primary
            trackColor: cell.current ? Qt.alpha(Theme.on_secondary_container, 0.15) : Theme.surface_container_highest
        }

        Column {
            anchors.left: cover.left
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.top: cover.bottom
            anchors.topMargin: 16
            spacing: 2

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                text: cell.modelData.title
                color: cell.current ? Theme.on_secondary_container : Theme.on_surface
                font.pixelSize: cell.big ? 14 : 13
                font.weight: cell.stack ? Theme.titleWeight : Font.Medium
            }

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                elide: Text.ElideRight
                // In Continue reading: how far, and when
                text: cell.big ? [root.percent(cell.modelData), root.ago(cell.modelData.openedAt)].filter(Boolean).join(" · ") : root.subtitle(cell.modelData)
                color: cell.current ? Qt.alpha(Theme.on_secondary_container, 0.8) : Theme.on_surface_variant
                font.pixelSize: 12
            }
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.setCurrent(cell.slot)
            onDoubleClicked: {
                root.setCurrent(cell.slot);
                root.openCurrent();
            }
        }
    }

    // A book or stack as a row of the list
    component BookRow: Rectangle {
        id: row

        required property var modelData
        required property int index
        property int base: 0
        property real headerRoom: 0
        readonly property int slot: base + index
        readonly property bool current: root.cursor === slot

        width: parent?.width ?? 0
        height: 62
        radius: Theme.radius
        color: current ? Theme.secondary_container : Theme.surface_container_low

        // After the layout has caught up
        Timer {
            id: revealLater

            interval: 0
            onTriggered: root.reveal(row)
        }

        onCurrentChanged: if (current)
            revealLater.restart()

        Behavior on color {
            ColorAnimation {
                duration: Theme.animFast
            }
        }

        // A stack's thumbnail has a card behind it
        Rectangle {
            visible: !!row.modelData.isSeries
            x: thumb.x + 4
            y: thumb.y - 4
            width: thumb.width
            height: thumb.height
            radius: 4
            color: Theme.surface_container_highest
            border.width: 1
            border.color: Theme.outline_variant
        }

        Cover {
            id: thumb

            x: 12
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: row.modelData.isSeries ? 2 : 0
            height: 48
            width: 32
            radius: 4
            source: row.modelData.cover
            title: ""
            authors: ""
        }

        Check {
            anchors.right: thumb.right
            anchors.top: thumb.top
            anchors.margins: -8
            scale: 0.8
            visible: root.isSelected(row.modelData)
        }

        Column {
            anchors.left: thumb.right
            anchors.leftMargin: 20
            anchors.right: rowPercent.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 3

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                elide: Text.ElideRight
                text: row.modelData.title
                color: row.current ? Theme.on_secondary_container : Theme.on_surface
                font.pixelSize: 14
                font.weight: row.modelData.isSeries ? Theme.titleWeight : Font.Medium
            }

            Label {
                anchors.verticalCenter: undefined
                width: parent.width
                elide: Text.ElideRight
                text: {
                    const b = row.modelData;
                    if (b.isSeries)
                        return b.authors;
                    const series = b.series && !root.openSeries ? `${b.series}${b.seriesIndex ? " #" + b.seriesIndex : ""}` : "";
                    const place = root.openSeries && b.seriesIndex ? `#${b.seriesIndex}` : "";
                    return [place, b.authors, series].filter(Boolean).join(" · ");
                }
                color: row.current ? Qt.alpha(Theme.on_secondary_container, 0.8) : Theme.on_surface_variant
                font.pixelSize: 12
            }
        }

        Label {
            id: rowPercent

            anchors.right: parent.right
            anchors.rightMargin: 18
            text: root.finished(row.modelData) && !row.modelData.isSeries ? "✓ Read" : root.percent(row.modelData)
            color: row.current ? Theme.on_secondary_container : root.finished(row.modelData) ? Theme.primary : Theme.on_surface_variant
            font.pixelSize: 12
        }

        MouseArea {
            anchors.fill: parent
            onClicked: root.setCurrent(row.slot)
            onDoubleClicked: {
                root.setCurrent(row.slot);
                root.openCurrent();
            }
        }
    }

    Item {
        id: content

        anchors.top: field.shown ? field.bottom : title.bottom
        anchors.topMargin: 16
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 16
        anchors.rightMargin: 16

        Flickable {
            id: flick

            anchors.fill: parent
            contentHeight: column.implicitHeight + 24
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Behavior on contentY {
                NumberAnimation {
                    duration: Theme.animNormal
                    easing.type: Easing.BezierSpline
                    easing.bezierCurve: Theme.emphasizedDecel
                }
            }

            Column {
                id: column

                width: flick.width
                spacing: 10

                Repeater {
                    model: root.sections

                    Column {
                        id: section

                        required property var modelData
                        required property int index
                        readonly property int base: root.sectionStart[index] ?? 0
                        readonly property bool sideways: root.grid && modelData.row

                        width: column.width
                        spacing: 6

                        // The section's name and size (not inside a series:
                        // the header names it)
                        Row {
                            visible: section.modelData.key !== "series"
                            x: 12
                            topPadding: section.index === 0 ? 0 : 18
                            spacing: 10

                            Label {
                                anchors.verticalCenter: undefined
                                text: section.modelData.title
                                color: Theme.on_surface
                                font.pixelSize: 17
                                font.weight: Theme.titleWeight
                                roundness: Theme.titleRoundness
                            }

                            Label {
                                anchors.verticalCenter: undefined
                                anchors.baseline: parent.children[0].baseline
                                text: {
                                    let n = 0;
                                    for (const it of section.modelData.items)
                                        n += it.isSeries ? it.books.length : 1;
                                    return n;
                                }
                                color: Theme.on_surface_variant
                                font.pixelSize: 13
                            }
                        }

                        // Continue reading: one row of bigger covers
                        ListView {
                            id: shelf

                            visible: section.sideways
                            width: section.width
                            height: visible ? Math.round((root.bigWidth - 20) * 1.5) + 86 : 0
                            orientation: ListView.Horizontal
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: visible ? section.modelData.items : []
                            interactive: contentWidth > width
                            highlightFollowsCurrentItem: false
                            readonly property int at: {
                                const s = root.slots[root.cursor];
                                return s && s.sec === section.index ? s.idx : -1;
                            }
                            // Sideways only as far as it takes to show the
                            // cursor: where ListView would put it, eased to
                            onAtChanged: {
                                if (at < 0)
                                    return;
                                const from = contentX;
                                slide.stop();
                                positionViewAtIndex(at, ListView.Contain);
                                const to = contentX;
                                if (Math.abs(to - from) < 1)
                                    return;
                                contentX = from;
                                slide.from = from;
                                slide.to = to;
                                slide.start();
                            }
                            // Laid out (or out again): straight to the cursor,
                            // else the start
                            function place() {
                                slide.stop();
                                if (at >= 0)
                                    positionViewAtIndex(at, ListView.Contain);
                                else
                                    positionViewAtBeginning();
                            }
                            onWidthChanged: Qt.callLater(place)
                            onContentWidthChanged: Qt.callLater(place)
                            onModelChanged: Qt.callLater(place)

                            NumberAnimation {
                                id: slide

                                target: shelf
                                property: "contentX"
                                duration: Theme.animNormal
                                easing.type: Easing.BezierSpline
                                easing.bezierCurve: Theme.emphasizedDecel
                            }

                            delegate: BookCell {
                                base: section.base
                                big: true
                                headerRoom: 44
                            }
                        }

                        // A grid of covers
                        Grid {
                            visible: root.grid && !section.modelData.row
                            columns: root.columns

                            Repeater {
                                model: parent.visible ? section.modelData.items : []

                                BookCell {
                                    base: section.base
                                    headerRoom: index < root.columns ? 44 : 0
                                }
                            }
                        }

                        // The list
                        Column {
                            visible: !root.grid
                            width: section.width
                            spacing: 2

                            Repeater {
                                model: parent.visible ? section.modelData.items : []

                                BookRow {
                                    base: section.base
                                    headerRoom: index === 0 ? 44 : 0
                                }
                            }
                        }
                    }
                }
            }
        }

        Column {
            anchors.centerIn: parent
            visible: root.slots.length === 0 && !Library.scanning
            spacing: 8

            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: undefined
                text: input.text || root.tag ? "No books match" : "No books yet"
                color: Theme.on_surface
                font.pixelSize: 18
            }

            Label {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: undefined
                visible: !input.text && !root.tag
                text: `Put EPUBs in ${Library.folders.join(", ").replace(StandardPaths.writableLocation(StandardPaths.HomeLocation).toString().replace("file://", ""), "~")}, or press a to add some`
                color: Theme.on_surface_variant
            }
        }
    }
}
