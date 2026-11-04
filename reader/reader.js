// The reader page: foliate-js showing one book, driven from QML over
// Qt's web channel.
//
// QML -> page: the bridge's `command(name, json)` signal.
// Page -> QML: calls on the bridge, each with one JSON string: ready,
// opened (book details, contents), relocated (where we are), key (every
// key pressed here, which QML handles), error.

import './foliate/view.js'
import { Overlayer } from './foliate/overlayer.js'
import * as CFI from './foliate/epubcfi.js'

// foliate's paginator keeps its scrolling container in a closed shadow
// root; open ones let us hide its scrollbar and scroll it ourselves
// (see Scroller) without editing the vendored code. Elements are made
// after this runs, so every root foliate creates is open.
const attachShadow = Element.prototype.attachShadow
Element.prototype.attachShadow = function (init) {
    return attachShadow.call(this, { ...init, mode: 'open' })
}

let bridge = null
let view = null
let style = null

const send = (name, data) => bridge?.[name](JSON.stringify(data ?? null))

const formatLanguageMap = x => {
    if (!x) return ''
    if (typeof x === 'string') return x
    return x[Object.keys(x)[0]] ?? ''
}
const formatContributor = c => Array.isArray(c)
    ? c.map(formatContributor).filter(Boolean).join(', ')
    : typeof c === 'string' ? c : formatLanguageMap(c?.name)

// The book's own styles stay; ours set the colours, size and spacing over
// them. Text colours are inherited everywhere so a book that hard-codes
// black stays readable on a dark page.
// A family for CSS: generic names bare, others quoted
const cssFamily = f => ['serif', 'sans-serif'].includes(f)
    ? f : `"${f.replace(/["\\]/g, '')}"`

const fontCSS = f => !f ? '' : `
    body, body *:not(pre, pre *, code, code *, kbd, kbd *, samp, samp *, tt, tt *) {
        font-family: ${cssFamily(f)} !important;
    }`

const bookCSS = s => `
    @namespace epub "http://www.idpf.org/2007/ops";
    html {
        color-scheme: ${s.dark ? 'dark' : 'light'};
        color: ${s.foreground} !important;
        background: ${s.background} !important;
        font-size: ${s.fontScale}% !important;
    }
    body {
        background: transparent !important;
    }
    body :not(a, a *) {
        color: inherit !important;
    }
    a:any-link, a:any-link * {
        color: ${s.link} !important;
    }
    ::selection {
        background: color-mix(in srgb, ${s.link} 35%, transparent);
    }
    p, li, blockquote, dd {
        line-height: ${s.lineHeight};
        text-align: ${s.justify ? 'justify' : 'start'};
        -webkit-hyphens: ${s.hyphenate ? 'auto' : 'manual'};
        hyphens: ${s.hyphenate ? 'auto' : 'manual'};
        -webkit-hyphenate-limit-before: 3;
        -webkit-hyphenate-limit-after: 2;
        -webkit-hyphenate-limit-lines: 2;
        hanging-punctuation: allow-end last;
        widows: 2;
    }
    [align="left"] { text-align: left; }
    [align="right"] { text-align: right; }
    [align="center"] { text-align: center; }
    [align="justify"] { text-align: justify; }
    pre {
        white-space: pre-wrap !important;
    }
    ${s.dark ? imageCSS[s.images] ?? imageCSS.dim : imageCSS.light}
    ${fontCSS(s.fontFamily)}
    aside[epub|type~="endnote"],
    aside[epub|type~="footnote"],
    aside[epub|type~="note"],
    aside[epub|type~="rearnote"] {
        display: none;
    }
`

// Text size works by scaling the root font size, which only reaches sizes
// given relative to it. Many books use fixed ones (`font-size: medium`,
// `small`, `12px`, `10pt`), so those are rewritten to rem as each
// stylesheet and section loads. Keywords map to Chromium's sizes at a
// 16px medium.
const keywordRem = {
    'xx-small': 0.5625, 'x-small': 0.625, 'small': 0.8125, 'medium': 1,
    'large': 1.125, 'x-large': 1.5, 'xx-large': 2, 'xxx-large': 3,
}
const remOf = (n, unit) => {
    const px = unit === 'pt' ? n * 4 / 3 : n
    return `${+(px / 16).toFixed(4)}rem`
}
const relativeSizes = text => text
    .replace(/(font-size\s*:\s*)(xx-small|x-small|small|medium|large|x-large|xx-large|xxx-large)\b/gi,
        (_, prop, kw) => `${prop}${keywordRem[kw.toLowerCase()]}rem`)
    .replace(/(font-size\s*:\s*)(\d*\.?\d+)(px|pt)\b/gi,
        (_, prop, n, unit) => prop + remOf(parseFloat(n), unit.toLowerCase()))
    // The `font` shorthand: "font: 12px/1.4 serif", "font: bold small serif"
    .replace(/(font\s*:[^;{}]*?)\b(\d*\.?\d+)(px|pt)\b/gi,
        (_, before, n, unit) => before + remOf(parseFloat(n), unit.toLowerCase()))

// Pictures on dark pages. Inverting turns a drawing's white paper black
// (hue-rotate keeps colours roughly their own), and screen blending then
// lets the page's colour through where it's black; it needs the page's
// background on the section's own <html>, which bookCSS sets.
const imageCSS = {
    // Light pages: multiplying by the page makes a picture's white paper
    // the page's own colour (sepia's, a light palette's) and leaves the
    // rest nearly as it is; on a white page it changes nothing
    light: `
        img, svg image {
            mix-blend-mode: multiply;
        }`,
    dim: `
        img, svg image, video {
            filter: brightness(0.8);
        }`,
    invert: `
        img, svg image {
            filter: invert(1) hue-rotate(180deg);
            mix-blend-mode: screen;
        }`,
}

const rewritable = type => /css|html|xml/.test(type ?? '')

// Scrolling mode: steps of a few lines (or most of a screen), eased to
// their end. Each step moves the target, not the page, so a held or
// repeated key keeps one smooth movement going. At a section's end the
// renderer goes on to the next one.
const Scroller = {
    target: null,
    pos: 0,
    frame: 0,
    last: 0,
    container() {
        return view?.renderer.shadowRoot?.getElementById('container') ?? null
    },
    hideScrollbar() {
        const root = view?.renderer.shadowRoot
        if (!root || root.getElementById('dogear-style')) return
        const el = document.createElement('style')
        el.id = 'dogear-style'
        el.textContent = `
            #container { scrollbar-width: none; }
            #container::-webkit-scrollbar { display: none; }`
        root.append(el)
    },
    lineHeight() {
        return 16 * (style?.fontScale ?? 100) / 100 * (style?.lineHeight ?? 1.5)
    },
    by(dy) {
        const el = this.container()
        if (!el) return
        const max = el.scrollHeight - el.clientHeight
        // Pick up wherever the page is unless we're mid-movement
        if (this.target === null) this.pos = el.scrollTop
        const from = this.target ?? el.scrollTop
        if (dy > 0 && from >= max - 1) return this.cross(() => view.next())
        if (dy < 0 && from <= 1) return this.cross(() => view.prev())
        this.target = Math.max(0, Math.min(max, from + dy))
        if (!this.frame) {
            this.last = performance.now()
            this.frame = requestAnimationFrame(t => this.step(t))
        }
    },
    cross(go) {
        this.stop()
        go()
    },
    stop() {
        cancelAnimationFrame(this.frame)
        this.frame = 0
        this.target = null
    },
    // Exponential ease-out, frame-rate independent: each frame closes a
    // share of what's left, so it starts brisk and settles softly
    step(now) {
        const el = this.container()
        if (!el || this.target === null) return this.stop()
        const dt = Math.min(64, now - this.last)
        this.last = now
        const left = this.target - this.pos
        if (Math.abs(left) < 0.5) {
            el.scrollTop = this.target
            return this.stop()
        }
        this.pos += left * (1 - Math.pow(1 - 0.16, dt / 16.67))
        el.scrollTop = this.pos
        this.frame = requestAnimationFrame(t => this.step(t))
    },
    lines(n) {
        this.by(n * 3 * this.lineHeight())
    },
    pages(n) {
        const el = this.container()
        if (el) this.by(n * el.clientHeight * 0.85)
    },
}

function applyStyle() {
    if (!style) return
    document.documentElement.style.setProperty('--page-bg', style.background)
    document.documentElement.style.colorScheme = style.dark ? 'dark' : 'light'
    const r = view?.renderer
    if (!r) return
    // Only what changed: `flow` and `max-inline-size` re-render the
    // section from its start, losing the place, even when set to the
    // value they already have
    const set = (name, value) => {
        if (r.getAttribute(name) !== value) r.setAttribute(name, value)
    }
    set('flow', style.flow)
    set('max-inline-size', `${style.maxWidth}px`)
    set('max-column-count', String(style.columns))
    set('gap', '6%')
    set('margin', '32px')
    // foliate slides pages within a section when `animated` is present
    if (style.pageTurn === 'slide') set('animated', '')
    else r.removeAttribute('animated')
    r.setStyles?.(bookCSS(style))
    Scroller.hideScrollbar()
    if (style.flow !== 'scrolled') Scroller.stop()
}

// Highlights and bookmarks. QML keeps them (Library) and tells the page
// what to draw: addAnnotation, updateAnnotation, removeAnnotation, each
// with the saved annotation { id, kind, cfi, color, style, … }. The page
// reports selections (`selection`, with where on screen) for QML's menu,
// and with every move whether the page holds a bookmark.
const colors = {
    yellow: '#f2c94c',
    green: '#6fcf97',
    blue: '#56a8f0',
    pink: '#f28cb5',
    purple: '#b18cf0',
}
const Notes = {
    byCfi: new Map(),
    byIndex: new Map(),
    // A click on a highlight, so the same click doesn't turn the page
    clickedAt: 0,
    // The selection QML's menu is about: { doc, range }
    current: null,
    reset(list) {
        this.byCfi.clear()
        this.byIndex.clear()
        this.current = null
        for (const a of list ?? []) this.put(a)
    },
    indexOf(a) {
        try {
            return view.resolveCFI(a.cfi).index
        } catch {
            return -1
        }
    },
    put(a) {
        this.byCfi.set(a.cfi, a)
        const index = this.indexOf(a)
        this.byIndex.set(index, (this.byIndex.get(index) ?? []).filter(x => x.id !== a.id).concat([a]))
    },
    drop(a) {
        this.byCfi.delete(a.cfi)
        const index = this.indexOf(a)
        this.byIndex.set(index, (this.byIndex.get(index) ?? []).filter(x => x.id !== a.id))
    },
    draw(a) {
        if (a.kind === 'highlight') view.addAnnotation({ value: a.cfi })
    },
    add(a) {
        this.put(a)
        this.draw(a)
        clearSelection()
        refreshBookmark()
    },
    update(a) {
        this.put(a)
        this.draw(a)
        clearSelection()
    },
    remove(a) {
        const old = this.byCfi.get(a.cfi) ?? a
        this.drop(old)
        if (old.kind === 'highlight') view.deleteAnnotation({ value: old.cfi })
        clearSelection()
        refreshBookmark()
    },
    // foliate asks for a section's highlights when it lays the section
    // out, and for each one's look when drawing it
    attach() {
        view.addEventListener('create-overlay', ({ detail: { index } }) => {
            for (const a of this.byIndex.get(index) ?? []) this.draw(a)
        })
        view.addEventListener('draw-annotation', ({ detail: { draw, annotation } }) => {
            const a = this.byCfi.get(annotation.value)
            if (!a) return
            const color = colors[a.color] ?? colors.yellow
            if (a.style === 'underline') draw(Overlayer.underline, { color, width: 2.5 })
            else draw(Overlayer.highlight, { color })
        })
        view.addEventListener('show-annotation', ({ detail: { value, range } }) => {
            this.clickedAt = Date.now()
            const a = this.byCfi.get(value)
            if (a) announce(range.startContainer.ownerDocument ?? range.commonAncestorContainer.ownerDocument, range, a)
        })
    },
}

// Where a range is, in the page's coordinates (the section's frame sits
// somewhere in the page, scrolled by the paginator)
function rectOf(doc, range) {
    const r = range.getBoundingClientRect()
    const frame = doc.defaultView?.frameElement?.getBoundingClientRect() ?? { left: 0, top: 0 }
    const page = view.getBoundingClientRect()
    // A range across pages has a box that spans them; keep it on screen
    const left = Math.max(page.left, Math.min(page.right, frame.left + r.left))
    const right = Math.max(page.left, Math.min(page.right, frame.left + r.right))
    return { x: left, y: frame.top + r.top, width: Math.max(1, right - left), height: r.height }
}

function indexOfDoc(doc) {
    return view.renderer.getContents?.().find(c => c.doc === doc)?.index
}

// Range helpers: is point p before point q, and do two ranges overlap
const before = (doc, [pn, po], [qn, qo]) => {
    const r = doc.createRange()
    r.setStart(pn, po)
    return r.comparePoint(qn, qo) === 1
}
const startOf = r => [r.startContainer, r.startOffset]
const endOf = r => [r.endContainer, r.endOffset]

// The section's highlights a range touches, with their ranges
function overlapping(doc, index, range) {
    const out = []
    for (const a of Notes.byIndex.get(index) ?? []) {
        if (a.kind !== 'highlight') continue
        let r
        try {
            r = view.resolveCFI(a.cfi).anchor(doc)
        } catch {
            continue
        }
        if (!r?.startContainer) continue
        if (before(doc, startOf(range), endOf(r)) && before(doc, startOf(r), endOf(range)))
            out.push({ a, r })
    }
    return out
}

// Tell QML about a selection (new, or an existing highlight clicked). A
// selection over highlights already there becomes one with them: inside
// a single one, it's that one (as if clicked); otherwise it reaches from
// the earliest start to the latest end, and they're replaced by it.
function announce(doc, range, existing, intent = null) {
    const index = indexOfDoc(doc)
    if (index == null) return
    let merges = []
    if (!existing) {
        const hits = overlapping(doc, index, range)
        const inside = hits.find(({ r }) => !before(doc, startOf(range), startOf(r)) && !before(doc, endOf(r), endOf(range)))
        if (inside) {
            existing = inside.a
            range = inside.r
        } else if (hits.length) {
            const union = range.cloneRange()
            for (const { r } of hits) {
                if (before(doc, startOf(r), startOf(union))) union.setStart(...startOf(r))
                if (before(doc, endOf(union), endOf(r))) union.setEnd(...endOf(r))
            }
            range = union
            merges = hits.map(({ a }) => a.id)
        }
    }
    Notes.current = { doc, range }
    send('selection', {
        intent,
        merges,
        cfi: existing?.cfi ?? view.getCFI(index, range),
        text: existing?.text ?? range.toString().replace(/\s+/g, ' ').trim(),
        rect: rectOf(doc, range),
        annotation: existing?.id ?? null,
        color: existing?.color ?? null,
        style: existing?.style ?? null,
    })
}

function clearSelection() {
    const doc = Notes.current?.doc
    doc?.getSelection()?.removeAllRanges()
    for (const { doc } of view?.renderer.getContents?.() ?? []) doc.getSelection()?.removeAllRanges()
    Notes.current = null
    Visual.stop(false)
}

// A mouse selection, once the button's up
function onPointerUp(doc) {
    if (Visual.active) return
    setTimeout(() => {
        const sel = doc.getSelection()
        if (!sel || sel.isCollapsed || !sel.toString().trim()) return
        announce(doc, sel.getRangeAt(0))
    }, 0)
}

// Whether the page shows a bookmark: its id, or null
let lastLocation = null
function bookmarkOn(detail) {
    const range = detail?.range
    if (!range) return null
    const doc = range.startContainer.ownerDocument
    const index = indexOfDoc(doc)
    for (const a of Notes.byIndex.get(index) ?? []) {
        if (a.kind !== 'bookmark') continue
        try {
            const at = view.resolveCFI(a.cfi).anchor(doc)
            const node = at.startContainer ?? at
            const offset = at.startOffset ?? 0
            if (range.comparePoint(node, offset) === 0) return a.id
        } catch {}
    }
    return null
}

function refreshBookmark() {
    if (lastLocation) send('bookmark', { id: bookmarkOn(lastLocation) })
}

// Visual mode, vim's: v starts a selection on the page's first word, the
// motions grow it (h l by letter, w e b by word, j k by line, ( ) by
// sentence, { } by paragraph, 0 $ to the line's ends, o swaps its ends),
// y or Enter hand it to QML's menu, Esc or v let go. Its keys stay here;
// everything else goes to QML as usual.
const Visual = {
    active: false,
    doc: null,
    start() {
        const range = lastLocation?.range
        if (!range) return
        const doc = range.startContainer.ownerDocument
        const sel = doc.getSelection()
        this.doc = doc
        // A mouse selection already there carries on; else the first word
        if (sel.isCollapsed || !sel.toString().trim()) {
            // The page's first text with letters in it: a page often
            // starts in an empty element (a page break, an anchor)
            const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT, {
                acceptNode: n => /\S/.test(n.data) && range.intersectsNode(n)
                    ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT,
            })
            const first = walker.nextNode()
            if (!first) return
            const at = first === range.startContainer ? range.startOffset : 0
            const skip = first.data.slice(at).search(/\S/)
            sel.collapse(first, at + Math.max(0, skip))
            sel.modify('extend', 'forward', 'word')
        }
        this.active = true
        send('visual', { active: true })
    },
    stop(clear = true) {
        if (!this.active) return
        if (clear) this.doc?.getSelection()?.removeAllRanges()
        this.active = false
        send('visual', { active: false })
    },
    motions: {
        h: ['backward', 'character'], ArrowLeft: ['backward', 'character'],
        l: ['forward', 'character'], ArrowRight: ['forward', 'character'],
        w: ['forward', 'word'], e: ['forward', 'word'], b: ['backward', 'word'],
        j: ['forward', 'line'], ArrowDown: ['forward', 'line'],
        k: ['backward', 'line'], ArrowUp: ['backward', 'line'],
        ')': ['forward', 'sentence'], '(': ['backward', 'sentence'],
        '}': ['forward', 'paragraph'], '{': ['backward', 'paragraph'],
        '0': ['backward', 'lineboundary'], '^': ['backward', 'lineboundary'],
        '$': ['forward', 'lineboundary'],
    },
    key(e) {
        const sel = this.doc?.getSelection()
        if (!sel) return this.stop()
        const k = e.key
        if (k === 'Escape' || k === 'v' || k === 'q') return this.stop()
        if (k === 'y' || k === 'Enter' || k === 'd') {
            if (sel.isCollapsed) return this.stop()
            this.active = false
            send('visual', { active: false })
            // d: straight to the dictionary, no menu
            announce(this.doc, sel.getRangeAt(0), null, k === 'd' ? 'define' : null)
            return
        }
        if (k === 'o') {
            sel.setBaseAndExtent(sel.focusNode, sel.focusOffset, sel.anchorNode, sel.anchorOffset)
            return this.reveal()
        }
        const m = this.motions[k]
        if (!m) return
        sel.modify('extend', ...m)
        this.reveal()
    },
    // Keep the moving end on screen: turn the page (or scroll) after it
    reveal() {
        const sel = this.doc.getSelection()
        if (!sel.focusNode) return
        const r = this.doc.createRange()
        r.setStart(sel.focusNode, sel.focusOffset)
        r.collapse(true)
        const rects = r.getClientRects()
        const box = rects.length ? rects[0] : r.getBoundingClientRect()
        const frame = this.doc.defaultView.frameElement.getBoundingClientRect()
        const page = view.getBoundingClientRect()
        if (style?.flow === 'scrolled') {
            const y = frame.top + box.top
            if (y > page.bottom - 40) Scroller.by(y - page.bottom + 120)
            else if (y < page.top + 40) Scroller.by(y - page.top - 120)
            return
        }
        const x = frame.left + box.left
        if (x > page.right) view.renderer.next()
        else if (x < page.left) view.renderer.prev()
    },
}

// Searching the book: foliate finds matches section by section and
// outlines them on the page; each section's arrive as `searchResults`
// { query, chapter, items: [{ cfi, before, match, after }] }, then
// `searchDone` { query, count }. A newer search makes an older one stop.
const norm = t => (t ?? '').replace(/…/g, '').replace(/\s+/g, ' ').trim().toLowerCase()
let searchRun = 0
// Every match's CFI, in book order, and the one n/N went to last
let hits = []
let hitAt = -1

// n / N: from the match gone to last, else from where the reader is
function hit({ by = 1, index = null }) {
    if (!hits.length) return
    if (index != null) hitAt = index
    else if (hitAt < 0) {
        const here = lastLocation?.cfi
        const after = here ? hits.findIndex(c => CFI.compare(c, here) > 0) : 0
        hitAt = by > 0 ? (after < 0 ? 0 : after) : (after <= 0 ? hits.length - 1 : after - 1)
    } else hitAt = (hitAt + by + hits.length) % hits.length
    view.goTo(hits[hitAt])
    send('hitAt', { index: hitAt })
}

// `jumpSection`: go to the first match in that section as soon as it's
// found (a passage picked in the library's search)
async function search({ query, wholeWords = false, section = null, jumpSection = null, near = '' }) {
    const run = ++searchRun
    await opening
    view.clearSearch()
    hits = []
    hitAt = -1
    if (!query?.trim()) return
    let count = 0
    let first = null  // index in hits of the jumped-to match
    const iter = view.search({
        query,
        matchCase: false,
        matchDiacritics: false,
        matchWholeWords: wholeWords,
        ...(section != null ? { index: section } : {}),
    })
    for await (const result of iter) {
        if (run !== searchRun) return
        if (result === 'done') break
        // A whole-book search: one chapter's matches at a time
        const group = result.subitems ?? (result.cfi ? [result] : null)
        if (!group) continue
        const items = group.map(({ cfi, excerpt }) => ({
            cfi,
            before: excerpt?.pre ?? '',
            match: excerpt?.match ?? '',
            after: excerpt?.post ?? '',
        }))
        const from = hits.length
        hits.push(...items.map(i => i.cfi))
        count += items.length
        send('searchResults', { query, chapter: result.label ?? '', items })
        if (jumpSection != null && first == null) {
            let index = -1
            try {
                index = view.resolveCFI(items[0].cfi).index
            } catch {}
            if (index === jumpSection) {
                // The match whose text before it is the passage's, else the
                // chapter's first
                const tail = norm(near).slice(-24)
                const at = tail ? items.findIndex(i => norm(i.before).endsWith(tail)) : -1
                first = from + Math.max(0, at)
                hit({ index: first })
            }
        }
    }
    if (run !== searchRun) return
    send('searchDone', { query, count })
    // From the library's search: straight to the passage
    // The section had no match the book's search could find (the index
    // and foliate split words a little differently): its first anyway
    if (jumpSection != null && first == null && hits.length) hit({ index: 0 })
}

const flatten = (items, depth = 0, out = []) => {
    for (const item of items ?? []) {
        out.push({ label: (item.label ?? '').trim(), href: item.href ?? '', depth })
        flatten(item.subitems, depth + 1, out)
    }
    return out
}

// Keys pressed in the page (and in each section's frame) go to QML, which
// owns every binding. Copy is left alone.
function onKeydown(e) {
    if (e.isComposing) return
    if (['Control', 'Shift', 'Alt', 'Meta', 'AltGraph', 'CapsLock'].includes(e.key)) return
    if (e.ctrlKey && (e.key === 'c' || e.key === 'C')) return
    e.preventDefault()
    if (Visual.active && !e.ctrlKey && !e.altKey) return Visual.key(e)
    send('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey })
}

// Clicks on the outer thirds of the page turn it, as in most readers;
// links and selections are left alone
function onClick(e, doc) {
    if (e.button !== 0 || e.defaultPrevented) return
    if (doc.getSelection()?.toString()) return
    if (e.target.closest?.('a[href]')) return
    if (style?.flow !== 'paginated') return
    if (Visual.active) return
    // After the highlight layer has had the click: one on a highlight
    // opens its menu instead
    setTimeout(() => turnFromClick(e, doc), 0)
}

function turnFromClick(e, doc) {
    if (Date.now() - Notes.clickedAt < 300) return
    if (doc.getSelection()?.toString()) return
    const x = e.clientX - (doc.defaultView?.scrollX ?? 0)
    const width = view.getBoundingClientRect().width
    // The frame's coordinates are its own; map them to the view's
    const frame = doc.defaultView?.frameElement
    const left = frame ? frame.getBoundingClientRect().left + x : x
    if (left < width / 3) turn('left')
    else if (left > width * 2 / 3) turn('right')
}

let wheelAt = 0
function onWheel(e) {
    if (style?.flow === 'scrolled') {
        // A mouse wheel's notches (lines, or big pixel jumps) become eased
        // steps of a few lines; a touchpad's fine deltas scroll natively
        if (e.ctrlKey) return
        if (e.deltaMode === 1 || Math.abs(e.deltaY) >= 50) {
            e.preventDefault()
            Scroller.lines(Math.sign(e.deltaY))
        }
        return
    }
    const now = Date.now()
    if (now - wheelAt < 250 || Math.abs(e.deltaY) < 4) return
    wheelAt = now
    turn(e.deltaY > 0 ? 'next' : 'prev')
}

// Turning a page. With the curl QML has to photograph the page first
// (PageCurl.qml), so it's asked, and says when: `turnNow`. `turnReady`
// goes back once the new page is laid out.
const turns = {
    next: () => view.next(),
    prev: () => view.prev(),
    left: () => view.goLeft(),
    right: () => view.goRight(),
}

const turnsForward = how => how === 'next'
    || how === (view.book.dir === 'rtl' ? 'left' : 'right')

function turn(how) {
    if (!view) return
    const r = view.renderer
    if (style?.pageTurn !== 'curl' || r.scrolled) return turns[how]()
    const forward = turnsForward(how)
    if (forward ? r.atEnd : r.atStart) return
    send('turnAsked', {
        how, forward,
        rtl: view.book.dir === 'rtl',
        spread: columnsShown() > 1,
    })
}

// How many columns the paginator fitted on the screen. It keeps the number
// to itself, but laid the section out with it.
function columnsShown() {
    const r = view.renderer
    const doc = r.getContents()[0]?.doc
    if (!doc) return 1
    const css = doc.defaultView.getComputedStyle(doc.documentElement)
    const column = parseFloat(css.columnWidth) + parseFloat(css.columnGap)
    return column > 0 ? Math.round(r.size / column) : 1
}

async function turnNow(how) {
    const r = view.renderer
    // Leaving the section: foliate moves to its blank end page, which is a
    // `relocate` of its own, and only then loads the next
    const leaving = turnsForward(how) ? r.page >= r.pages - 2 : r.page <= 1
    let moved = false
    const relocated = new Promise(resolve =>
        view.addEventListener('relocate', () => (moved = true, resolve()), { once: true }))
    // Otherwise not the whole turn: foliate holds its lock 100 ms longer
    await (leaving ? turns[how]() : Promise.race([relocated, turns[how]()]))
    if (leaving) await painted(r.getContents()[0].doc)
    await new Promise(requestAnimationFrame)
    await new Promise(requestAnimationFrame)
    send('turnReady', { moved })
}

// A new section is laid out well before it's on the screen, and a picture
// taken then is blank. Chromium says when its first text or image has been
// drawn; a page with neither never gets that, so don't wait long.
const painted = doc => new Promise(resolve => {
    const timeout = setTimeout(resolve, 400)
    new doc.defaultView.PerformanceObserver((list, observer) => {
        if (!list.getEntriesByName('first-contentful-paint').length) return
        observer.disconnect()
        clearTimeout(timeout)
        resolve()
    }).observe({ type: 'paint', buffered: true })
})

// Done when the book is open and laid out (search waits for it)
let opening = Promise.resolve()
function open(args) {
    searchRun++
    opening = openBook(args)
    return opening
}

async function openBook({ url, position, annotations }) {
    view?.remove()
    view = document.createElement('foliate-view')
    document.body.append(view)
    try {
        await view.open(url)
    } catch (e) {
        send('error', { message: `Can't open this book: ${e.message ?? e}` })
        return
    }
    const { book } = view
    Notes.reset(annotations)
    Notes.attach()
    book.transformTarget?.addEventListener('data', ({ detail }) => {
        const type = detail.type
        detail.data = Promise.resolve(detail.data)
            .then(data => typeof data === 'string' && rewritable(type) ? relativeSizes(data) : data)
            .catch(e => {
                console.error(`Failed to load ${detail.name}`, e)
                return ''
            })
    })
    view.addEventListener('load', ({ detail: { doc } }) => {
        doc.addEventListener('keydown', onKeydown)
        doc.addEventListener('click', e => onClick(e, doc))
        doc.addEventListener('wheel', onWheel, { passive: false })
        doc.addEventListener('pointerup', () => onPointerUp(doc))
    })
    view.addEventListener('relocate', ({ detail }) => (lastLocation = detail, send('relocated', {
        cfi: detail.cfi,
        // For a bookmark here: the page's start, and its first words
        pageCfi: detail.cfi ? CFI.collapse(detail.cfi) : '',
        excerpt: detail.range?.toString().replace(/\s+/g, ' ').trim().slice(0, 160) ?? '',
        bookmark: bookmarkOn(detail),
        fraction: detail.fraction,
        location: detail.location,
        section: detail.section,
        tocLabel: detail.tocItem?.label?.trim() ?? '',
        tocHref: detail.tocItem?.href ?? '',
        page: detail.pageItem?.label ?? '',
        // Screens in this section (paginated only); the renderer counts a
        // blank page at each end
        ...(view.renderer.scrolled ? {} : {
            sectionPage: view.renderer.page,
            sectionPages: Math.max(1, view.renderer.pages - 2),
        }),
        minutesLeftInSection: detail.time?.section,
        minutesLeft: detail.time?.total,
    })))
    applyStyle()

    send('opened', {
        title: formatLanguageMap(book.metadata?.title),
        authors: formatContributor(book.metadata?.author),
        language: book.metadata?.language ?? '',
        dir: book.dir ?? 'ltr',
        toc: flatten(book.toc),
        sectionFractions: view.getSectionFractions(),
    })

    try {
        await view.init({ lastLocation: position || null, showTextStart: true })
    } catch (e) {
        console.error('init', e)
        await view.init({ showTextStart: true })
    }
}

const commands = {
    open,
    style: s => { style = s; applyStyle() },
    next: () => turn('next'),
    prev: () => turn('prev'),
    // j/k and the arrows: a page when paginated, a few lines when scrolling
    down: () => style?.flow === 'scrolled' ? Scroller.lines(1) : turn('next'),
    up: () => style?.flow === 'scrolled' ? Scroller.lines(-1) : turn('prev'),
    // Space, Page Down/Up: a page, or most of a screen when scrolling
    pageDown: () => style?.flow === 'scrolled' ? Scroller.pages(1) : turn('next'),
    pageUp: () => style?.flow === 'scrolled' ? Scroller.pages(-1) : turn('prev'),
    left: () => turn('left'),
    right: () => turn('right'),
    turnNow,
    nextSection: () => view?.renderer.nextSection?.(),
    prevSection: () => view?.renderer.prevSection?.(),
    goTo: target => view?.goTo(target),
    fraction: f => view?.goToFraction(f),
    // Make the page draw again: after the window was hidden, Chromium has
    // dropped its frame and draws none until something changes
    repaint: () => {
        const root = document.documentElement
        root.style.opacity = '0.999'
        requestAnimationFrame(() => requestAnimationFrame(() => root.style.opacity = ''))
    },
    addAnnotation: a => Notes.add(a),
    updateAnnotation: a => Notes.update(a),
    removeAnnotation: a => Notes.remove(a),
    clearSelection: () => clearSelection(),
    visual: () => Visual.active ? Visual.stop() : Visual.start(),
    search,
    clearSearch: () => {
        searchRun++
        hits = []
        hitAt = -1
        view?.clearSearch()
    },
    hit,
    back: () => view?.history.back(),
    forward: () => view?.history.forward(),
}

document.addEventListener('keydown', onKeydown)
document.addEventListener('wheel', onWheel, { passive: false })
window.addEventListener('error', e => send('error', { message: e.message }))
window.addEventListener('unhandledrejection', e =>
    send('error', { message: String(e.reason?.message ?? e.reason) }))

new QWebChannel(qt.webChannelTransport, channel => {
    bridge = channel.objects.bridge
    bridge.command.connect((name, json) => {
        const fn = commands[name]
        if (!fn) return console.error('unknown command', name)
        Promise.resolve(fn(JSON.parse(json))).catch(e => console.error(name, e))
    })
    send('ready')
})
