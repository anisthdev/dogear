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

    // What's shown: books, and stacks standing for a series. A stack looks
    // like a book to the sort: its latest reading and adding, its series
    // name as title, the book to read next as cover.
    readonly property var items: {
        const words = input.text.toLowerCase().split(/\s+/).filter(Boolean);
        const tag = root.tag.toLowerCase();
        let books = Library.books.filter(b => {
            if (tag && !b.tags.some(t => t.toLowerCase() === tag))
                return false;
            const hay = `${b.title} ${b.authors} ${b.series}`.toLowerCase();
            return words.every(w => hay.includes(w));
        });
        if (openSeries)
            return books.filter(b => b.series === openSeries).sort(bySeriesOrder);

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

    readonly property var view: grid ? gridView : listView
    readonly property var current: items[view.currentIndex] ?? null

    onItemsChanged: Qt.callLater(restoreCurrent)
    onGridChanged: Qt.callLater(restoreCurrent)

    function restoreCurrent() {
        let i = items.findIndex(b => b.id === currentId);
        // A book read inside a stack: the stack
        if (i < 0)
            i = items.findIndex(b => b.isSeries && b.books.some(m => m.id === currentId));
        if (i < 0)
            i = 0;
        view.currentIndex = i;
        view.positionViewAtIndex(i, ListView.Contain);
    }

    function setCurrent(i) {
        if (items.length === 0)
            return;
        i = Math.max(0, Math.min(items.length - 1, i));
        view.currentIndex = i;
        currentId = items[i].id;
    }

    function move(by) {
        setCurrent(view.currentIndex + by);
    }

    // Select a book by id (after reading it, say)
    function select(id) {
        currentId = id;
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
        move(1);
    }

    function isSelected(it) {
        return it.isSeries ? it.books.every(b => selected[b.id]) : !!selected[it.id];
    }

    function editSeries() {
        const books = targets();
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
                const order = items.flatMap(it => it.isSeries ? it.books : [it]).map(b => b.id);
                const sorted = books.slice().sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
                indexes = books.map(b => sorted.indexOf(b) + 1);
            }
            Library.setSeries(ids, name, indexes);
            selected = {};
            toast(name ? `In “${name}”` : "No series");
        });
    }

    function editTags() {
        const books = targets();
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
        const cols = grid ? gridView.columns : 1;
        const rows = Math.max(1, Math.floor(view.height / (grid ? gridView.cellHeight : 64)));

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
                move(cols * Math.max(1, Math.floor(rows / 2)));
                return true;
            case Qt.Key_U:
                move(-cols * Math.max(1, Math.floor(rows / 2)));
                return true;
            case Qt.Key_F:
                move(cols * rows);
                return true;
            case Qt.Key_B:
                move(-cols * rows);
                return true;
            case Qt.Key_N:
            case Qt.Key_J:
                move(cols);
                return true;
            case Qt.Key_P:
            case Qt.Key_K:
                move(-cols);
                return true;
            }
            return false;
        }

        switch (t) {
        case "j":
            move(cols);
            return true;
        case "k":
            move(-cols);
            return true;
        case "h":
            if (grid)
                move(-1);
            return true;
        case "l":
            if (grid)
                move(1);
            else
                openCurrent();
            return true;
        case "G":
            setCurrent(items.length - 1);
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
            move(cols);
            return true;
        case Qt.Key_Up:
            move(-cols);
            return true;
        case Qt.Key_Left:
            if (grid)
                move(-1);
            return true;
        case Qt.Key_Right:
            if (grid)
                move(1);
            return true;
        case Qt.Key_PageDown:
            move(cols * rows);
            return true;
        case Qt.Key_PageUp:
            move(-cols * rows);
            return true;
        case Qt.Key_Home:
            setCurrent(0);
            return true;
        case Qt.Key_End:
            setCurrent(items.length - 1);
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
            const books = root.items.reduce((n, it) => n + (it.isSeries ? it.books.length : 1), 0);
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
                    root.move(root.grid ? gridView.columns : 1);
                } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab || (ctrl && (event.key === Qt.Key_K || event.key === Qt.Key_P))) {
                    root.move(root.grid ? -gridView.columns : -1);
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

    Item {
        id: content

        anchors.top: field.shown ? field.bottom : title.bottom
        anchors.topMargin: 16
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: 16
        anchors.rightMargin: 16

        GridView {
            id: gridView

            // As many columns as fit at ~180px, filling the width
            readonly property int columns: Math.max(2, Math.floor(width / 180))

            anchors.fill: parent
            visible: root.grid
            clip: true
            model: root.grid ? root.items : []
            cellWidth: Math.floor(width / columns)
            cellHeight: Math.round((cellWidth - 20) * 1.5) + 86
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds
            bottomMargin: 16
            keyNavigationEnabled: false

            delegate: Item {
                id: cell

                required property var modelData
                required property int index
                readonly property bool current: GridView.isCurrentItem && root.grid
                readonly property bool stack: !!modelData.isSeries
                // A stack's cover sits lower and narrower, two cards behind it
                readonly property int lift: stack ? 8 : 0

                width: GridView.view.cellWidth
                height: GridView.view.cellHeight

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

                // How far through, along the cover's foot
                LinearProgress {
                    anchors.left: cover.left
                    anchors.right: cover.right
                    anchors.top: cover.bottom
                    anchors.topMargin: 4
                    visible: cell.modelData.fraction > 0
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
                        font.pixelSize: 13
                        font.weight: cell.stack ? Theme.titleWeight : Font.Medium
                    }

                    Label {
                        anchors.verticalCenter: undefined
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.subtitle(cell.modelData)
                        color: cell.current ? Qt.alpha(Theme.on_secondary_container, 0.8) : Theme.on_surface_variant
                        font.pixelSize: 12
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.setCurrent(cell.index)
                    onDoubleClicked: root.openCurrent()
                }
            }
        }

        ListView {
            id: listView

            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            visible: !root.grid
            clip: true
            spacing: 2
            model: root.grid ? [] : root.items
            highlightMoveDuration: 0
            boundsBehavior: Flickable.StopAtBounds
            bottomMargin: 16
            keyNavigationEnabled: false

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index
                readonly property bool current: ListView.isCurrentItem && !root.grid

                width: ListView.view.width
                height: 62
                radius: Theme.radius
                color: current ? Theme.secondary_container : Theme.surface_container_low

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
                    text: root.percent(row.modelData)
                    color: row.current ? Theme.on_secondary_container : Theme.on_surface_variant
                    font.pixelSize: 12
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: root.setCurrent(row.index)
                    onDoubleClicked: root.openCurrent()
                }
            }
        }

        Column {
            anchors.centerIn: parent
            visible: root.items.length === 0 && !Library.scanning
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
