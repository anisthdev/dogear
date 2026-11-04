pragma Singleton

import QtQuick
import QtCore
import Dogear

// How the page looks: its colours (one of `schemes`) and type, kept in
// $XDG_CONFIG_HOME/dogear/dogear.conf. `css` is what the reader page
// lays over the book's own styles.
QtObject {
    id: root

    // Auto follows the app's palette (the wallpaper's, through matugen,
    // else the system's light or dark); the others are fixed papers
    readonly property var schemes: ["auto", "light", "sepia", "dark", "black", "book"]
    readonly property var schemeNames: ({
            auto: "Auto",
            light: "Light",
            sepia: "Sepia",
            dark: "Dark",
            black: "Black",
            book: "Book"
        })
    readonly property var papers: ({
            light: {
                // Pure white, as books' pictures are: an off-white page
                // shows every picture's edge
                bg: "#ffffff",
                fg: "#1f1f1f",
                link: "#2f5fb3",
                dark: false
            },
            sepia: {
                bg: "#f3e9d2",
                fg: "#4b3a2a",
                link: "#8a4a22",
                dark: false
            },
            dark: {
                bg: "#1d1d1f",
                fg: "#d9d7d2",
                link: "#8ab4f8",
                dark: true
            },
            black: {
                bg: "#000000",
                fg: "#bdbbb6",
                link: "#7fa7e6",
                dark: true
            },
            // Matte cream; Reader lays the rest of the book around it
            book: {
                bg: "#f7ecd6",
                fg: "#2c2620",
                link: "#7a3b1d",
                dark: false
            }
        })

    property Settings settings: Settings {
        id: settings

        location: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/dogear/dogear.conf"
        category: "reading"

        property string scheme: "auto"
        // What toggleBook goes back to
        property string beforeBook: "auto"
        // Percent of the book's own sizes
        property int fontScale: 100
        property real lineHeight: 1.5
        property bool justify: true
        property bool hyphenate: true
        // "paginated" or "scrolled"
        property string flow: "paginated"
        // How pages turn: "curl" (like paper, PageCurl.qml), "slide"
        // (foliate's own 300 ms ease-out) or "none"
        property string pageTurn: "curl"
        // Older settings' way of saying "none"
        property bool animatePages: true
        // A column's widest, in px; two columns side by side when there's room
        property int maxWidth: 720
        property int columns: 2
        // Pictures on dark pages: "dim" (a little darker, safe for any
        // picture) or "invert" (black-on-white drawings become light lines
        // on the page; spoils photos). Light pages show them as they are.
        property string images: "dim"
        // "" keeps the book's own fonts; else a family name, or "serif" /
        // "sans-serif" for the system's defaults
        property string fontFamily: ""
        // What a new highlight looks like: the colour and style used last
        property string highlightColor: "yellow"
        property string highlightStyle: "highlight"
    }

    // A font being tried in the font list: shown on the page, not saved
    // (so a crash or kill mid-preview doesn't keep it); null when none
    property var previewFont: null

    readonly property string scheme: schemes.includes(settings.scheme) ? settings.scheme : "auto"
    readonly property bool isAuto: scheme === "auto"
    readonly property color background: isAuto ? Theme.surface : papers[scheme].bg
    readonly property color foreground: isAuto ? Theme.on_surface : papers[scheme].fg
    readonly property color link: isAuto ? Theme.primary : papers[scheme].link
    readonly property bool dark: isAuto ? Theme.dark : papers[scheme].dark
    // A book lying open on the desktop, only where there are pages to turn
    readonly property bool bookLook: scheme === "book" && settings.flow === "paginated"
    // The window around the page
    readonly property color surround: bookLook ? "transparent" : background
    // For the bars around the page: on a dark plate or on the paper
    readonly property color bars: bookLook ? "#d8ccba" : foreground
    readonly property color muted: Qt.alpha(bars, 0.6)

    // c and C go through the colours; the book has its own key. From the
    // book they carry on from the colours it left.
    function cycleScheme(by) {
        const plain = schemes.filter(s => s !== "book");
        const i = plain.indexOf(scheme === "book" ? settings.beforeBook : scheme);
        settings.scheme = plain[(i + by + plain.length) % plain.length];
    }

    // Into the book, in pages since it has no other form, and out to the
    // colours it left
    function toggleBook() {
        if (bookLook) {
            settings.scheme = schemes.includes(settings.beforeBook) && settings.beforeBook !== "book" ? settings.beforeBook : "auto";
            return;
        }
        if (scheme !== "book")
            settings.beforeBook = scheme;
        settings.scheme = "book";
        settings.flow = "paginated";
    }

    function toggleImages() {
        settings.images = settings.images === "invert" ? "dim" : "invert";
    }

    function zoom(by) {
        settings.fontScale = by === 0 ? 100 : Math.max(50, Math.min(300, settings.fontScale + by));
    }

    function hex(c) {
        const h = x => Math.round(x * 255).toString(16).padStart(2, "0");
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }

    // What the reader page needs, as plain values
    readonly property var style: ({
            background: hex(background),
            foreground: hex(foreground),
            link: hex(link),
            dark: dark,
            fontScale: settings.fontScale,
            lineHeight: settings.lineHeight,
            justify: settings.justify,
            hyphenate: settings.hyphenate,
            flow: settings.flow,
            pageTurn: settings.animatePages ? settings.pageTurn : "none",
            maxWidth: settings.maxWidth,
            columns: settings.columns,
            images: settings.images === "invert" ? "invert" : "dim",
            fontFamily: previewFont ?? settings.fontFamily
        })

    // The fonts F offers, from $XDG_CONFIG_HOME/dogear/fonts.conf: one
    // family per line, in order, # for comments. Families that aren't
    // installed are skipped. A line of just * adds every other installed
    // family fit for body text. Written with the defaults below on the
    // first run; edits apply the next time the list opens.
    readonly property string defaultFonts: `# Fonts that F offers in Dogear, one family per line, in this order.
# "Book's own fonts", serif and sans-serif always come first.
# Fonts that aren't installed are skipped. A line with just * adds every
# other installed font. Changes apply the next time the list opens.

# Serif, made for reading on screens
Literata
Source Serif 4
Merriweather
Noto Serif
Charis SIL

# Classic book faces
TeX Gyre Pagella
TeX Gyre Bonum
TeX Gyre Termes
Liberation Serif

# Sans-serif
Google Sans Flex
Noto Sans
Inter
Atkinson Hyperlegible
Liberation Sans

# Easier for some readers with dyslexia
OpenDyslexic
`

    property TextFile fontsFile: TextFile {
        path: configPath("fonts.conf")
        Component.onCompleted: createIfMissing(root.defaultFonts)
    }

    function readingFonts() {
        // Qt adds the foundry ("Nimbus Sans [URW ]") when two make a
        // family; the page knows it by the plain name
        const installed = [...new Set(Qt.fontFamilies().map(f => f.replace(/\s*\[.*\]$/, "")))];
        const byName = new Map(installed.map(f => [f.toLowerCase(), f]));
        const lines = (fontsFile.exists ? fontsFile.text : defaultFonts).split("\n").map(l => l.replace(/#.*/, "").trim()).filter(Boolean);
        const out = [];
        const seen = new Set();
        const add = f => {
            if (!seen.has(f.toLowerCase())) {
                seen.add(f.toLowerCase());
                out.push(f);
            }
        };
        for (const line of lines) {
            if (line === "*")
                continue;
            const f = byName.get(line.toLowerCase());
            if (f)
                add(f);
        }
        if (lines.includes("*"))
            for (const f of allBodyFonts(installed))
                add(f);
        return out;
    }

    // Every installed family fit for body text: less icon, symbol and
    // monospace fonts, Noto's per-script families (fallbacks, not choices)
    // and fontconfig's aliases (the generic choices cover them)
    function allBodyFonts(installed) {
        const skip = /emoji|symbol|icon|nerd|awesome|material|lucide|music|math|dingbat|fangsong|mono|code|consol|cursor|chorus|^z003|^d050000l/i;
        const script = /^Noto (Sans|Serif|Kufi|Naskh|Rashi|Looped|Nastaliq|Znamenny|Traditional|Fangsong)\s(?!Display$)/;
        const alias = /^(serif|sans|sans serif|sans-serif|monospace|system-ui)$/i;
        return installed.filter(f => !skip.test(f) && !script.test(f) && !alias.test(f)).sort((a, b) => a.localeCompare(b));
    }
}
