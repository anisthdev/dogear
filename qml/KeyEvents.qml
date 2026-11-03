pragma Singleton

import QtQuick

// Keys reach Dogear two ways: Qt's own events while a QML item has focus,
// and the page's keydown events (forwarded over the bridge) while the
// reader has it. `fromWeb` turns the latter into the shape of the former
// ({ key, text, modifiers }), so every handler, ListKeys included, takes
// one kind of event.
QtObject {
    readonly property var named: ({
            ArrowDown: Qt.Key_Down,
            ArrowUp: Qt.Key_Up,
            ArrowLeft: Qt.Key_Left,
            ArrowRight: Qt.Key_Right,
            PageDown: Qt.Key_PageDown,
            PageUp: Qt.Key_PageUp,
            Home: Qt.Key_Home,
            End: Qt.Key_End,
            Enter: Qt.Key_Return,
            Escape: Qt.Key_Escape,
            Backspace: Qt.Key_Backspace,
            Delete: Qt.Key_Delete,
            Tab: Qt.Key_Tab,
            F1: Qt.Key_F1,
            F11: Qt.Key_F11,
            " ": Qt.Key_Space
        })
    readonly property var symbols: ({
            "?": Qt.Key_Question,
            "[": Qt.Key_BracketLeft,
            "]": Qt.Key_BracketRight,
            "{": Qt.Key_BraceLeft,
            "}": Qt.Key_BraceRight,
            "+": Qt.Key_Plus,
            "=": Qt.Key_Equal,
            "-": Qt.Key_Minus,
            "/": Qt.Key_Slash
        })

    function fromWeb(e) {
        let modifiers = Qt.NoModifier;
        if (e.ctrl)
            modifiers |= Qt.ControlModifier;
        if (e.shift)
            modifiers |= Qt.ShiftModifier;
        if (e.alt)
            modifiers |= Qt.AltModifier;
        if (e.meta)
            modifiers |= Qt.MetaModifier;
        let key = 0;
        let text = "";
        if (e.key === "Enter")
            text = "\r";
        else if (e.key.length === 1)
            text = e.ctrl || e.alt || e.meta ? "" : e.key;
        if (named[e.key] !== undefined)
            key = named[e.key];
        else if (/^[a-zA-Z]$/.test(e.key))
            key = Qt.Key_A + e.key.toUpperCase().charCodeAt(0) - 65;
        else if (/^[0-9]$/.test(e.key))
            key = Qt.Key_0 + e.key.charCodeAt(0) - 48;
        else if (symbols[e.key] !== undefined)
            key = symbols[e.key];
        return {
            key: key,
            text: text,
            modifiers: modifiers,
            accepted: false
        };
    }
}
