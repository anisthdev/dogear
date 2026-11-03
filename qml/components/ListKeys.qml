import QtQuick

// Copied from Seedling (082d977), itself from quickbar (9e7052b), with tremc's extra keys: Ctrl+n/Ctrl+p,
// and Ctrl+f/Ctrl+b (and PageDown/PageUp) for a whole page.
//
// Vim movement for a ListView: j/k (and the arrows), gg and G for the
// ends, Ctrl+d/Ctrl+u for half a page. Call handle(event) from a Keys
// handler; it says whether it took the key.
QtObject {
    id: root

    required property var list
    // Rows in half a page
    property int halfPage: 3
    // Rows in a whole page
    property int page: 2 * halfPage

    // The first g of a gg
    property bool pendingG: false
    property var gTimer: Timer {
        interval: 600
        onTriggered: root.pendingG = false
    }

    function move(by) {
        if (list.count === 0)
            return;
        list.currentIndex = Math.max(0, Math.min(list.count - 1, list.currentIndex + by));
    }

    function handle(event) {
        const ctrl = event.modifiers & Qt.ControlModifier;
        // A capital can come without Shift held (some layouts, wtype)
        const shift = (event.modifiers & Qt.ShiftModifier) || event.text === "G";
        const g = event.key === Qt.Key_G && !ctrl && !shift;
        if (!g)
            pendingG = false;
        switch (event.key) {
        case Qt.Key_N:
            if (!ctrl)
                return false;
            move(1);
            return true;
        case Qt.Key_P:
            if (!ctrl)
                return false;
            move(-1);
            return true;
        case Qt.Key_F:
            if (!ctrl)
                return false;
            move(page);
            return true;
        case Qt.Key_B:
            if (!ctrl)
                return false;
            move(-page);
            return true;
        case Qt.Key_PageDown:
            move(page);
            return true;
        case Qt.Key_PageUp:
            move(-page);
            return true;
        case Qt.Key_J:
        case Qt.Key_Down:
            if (ctrl && event.key === Qt.Key_J)
                return false;
            move(1);
            return true;
        case Qt.Key_K:
        case Qt.Key_Up:
            if (ctrl && event.key === Qt.Key_K)
                return false;
            move(-1);
            return true;
        case Qt.Key_D:
            if (!ctrl)
                return false;
            move(halfPage);
            return true;
        case Qt.Key_U:
            if (!ctrl)
                return false;
            move(-halfPage);
            return true;
        case Qt.Key_G:
            if (shift) {
                move(list.count);
                return true;
            }
            if (ctrl)
                return false;
            if (pendingG) {
                pendingG = false;
                move(-list.count);
            } else {
                pendingG = true;
                gTimer.restart();
            }
            return true;
        case Qt.Key_Home:
            move(-list.count);
            return true;
        case Qt.Key_End:
            move(list.count);
            return true;
        }
        return false;
    }
}
