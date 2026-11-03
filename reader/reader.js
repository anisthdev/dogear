// The reader page: foliate-js showing one book, driven from QML over
// Qt's web channel.
//
// QML -> page: the bridge's `command(name, json)` signal.
// Page -> QML: calls on the bridge, each with one JSON string: ready,
// opened (book details, contents), relocated (where we are), key (every
// key pressed here, which QML handles), error.

import './foliate/view.js'

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
    ${s.dark ? imageCSS[s.images] ?? imageCSS.dim : ''}
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
    if (style.animatePages) set('animated', '')
    else r.removeAttribute('animated')
    r.setStyles?.(bookCSS(style))
    Scroller.hideScrollbar()
    if (style.flow !== 'scrolled') Scroller.stop()
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
    send('key', { key: e.key, ctrl: e.ctrlKey, shift: e.shiftKey, alt: e.altKey, meta: e.metaKey })
}

// Clicks on the outer thirds of the page turn it, as in most readers;
// links and selections are left alone
function onClick(e, doc) {
    if (e.button !== 0 || e.defaultPrevented) return
    if (doc.getSelection()?.toString()) return
    if (e.target.closest?.('a[href]')) return
    if (style?.flow !== 'paginated') return
    const x = e.clientX - (doc.defaultView?.scrollX ?? 0)
    const width = view.getBoundingClientRect().width
    // The frame's coordinates are its own; map them to the view's
    const frame = doc.defaultView?.frameElement
    const left = frame ? frame.getBoundingClientRect().left + x : x
    if (left < width / 3) view.goLeft()
    else if (left > width * 2 / 3) view.goRight()
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
    if (e.deltaY > 0) view.next()
    else view.prev()
}

async function open({ url, position }) {
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
    })
    view.addEventListener('relocate', ({ detail }) => send('relocated', {
        cfi: detail.cfi,
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
    }))
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
    next: () => view?.next(),
    prev: () => view?.prev(),
    // j/k and the arrows: a page when paginated, a few lines when scrolling
    down: () => style?.flow === 'scrolled' ? Scroller.lines(1) : view?.next(),
    up: () => style?.flow === 'scrolled' ? Scroller.lines(-1) : view?.prev(),
    // Space, Page Down/Up: a page, or most of a screen when scrolling
    pageDown: () => style?.flow === 'scrolled' ? Scroller.pages(1) : view?.next(),
    pageUp: () => style?.flow === 'scrolled' ? Scroller.pages(-1) : view?.prev(),
    left: () => view?.goLeft(),
    right: () => view?.goRight(),
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
