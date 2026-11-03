# Dogear

An ebook reader and library, like Foliate but ours. App ID `io.github.anisthdev.Dogear` (Wayland app ID and `.desktop` name). Primary target: Arch Linux + Hyprland, next to the shell (`~/Projects/quickbar`), whose look and keyboard-first style it shares. It's meant to work for anyone, so nothing depends on this machine: matugen colours are used when present, Material's baseline palette otherwise; no paths into ~/Projects at runtime.

## Phases

1. **Reader core** (done): open an EPUB, pages or scrolling, colour schemes, contents, position saved and restored, keys.
2. **Library**: folders (default `~/Books`) indexed in place and watched; importing copies into the main folder. Cover grid and list, sort, `/` filter, continue reading. EPUB metadata read in C++ (libzip + QXmlStreamReader).
3. **Annotations**: highlights, notes, bookmarks (foliate-js `Overlayer`, CFI ranges in SQLite), panel, Markdown export.
4. **Search**: in the book (foliate-js `search.js`), across the library (SQLite FTS5).
5. **Metadata online**: Open Library, then Google Books, EPUB's own as fallback. ISBN matches apply by themselves; title searches show a picker. Hand edits are never overwritten.
6. **Dictionary** (sdcv/StarDict, Wiktionary fallback) and **TTS** (speech-dispatcher, Piper if installed; foliate-js `tts.js` gives SSML).
7. **OPDS** catalogues (foliate-js `opds.js`).
8. **PDF** later, through pdf.js (left out of `reader/foliate/vendor` until then).

## How it runs

```
cmake -S . -B build -G Ninja && cmake --build build
build/dogear [book.epub]     # no book: reopens the last one
makepkg -si                  # installs totoro-dogear (provides dogear)
```

There's no live reload as in the Quickshell apps: QML and the reader page are compiled into the binary's resources, so rebuild and restart after a change. Start it with `QT_FORCE_STDERR_LOGGING=1`, or Qt sends its logs (and the page's console, prefixed `page:`) to the journal.

## Layout

```
src/main.cpp           WebEngine set-up (must come before the app), command line, scheme handler, QML
src/Library.*          QML singleton: SQLite ($XDG_DATA_HOME/dogear/library.db), book ids, progress
src/SchemeHandler.*    dogear://app/...: reader page from :/reader, qwebchannel.js, books as /book/<id>
src/TextFile.*         watched text file (Quickshell's FileView isn't available here): colors.css, fonts.conf
src/WindowWatch.*      signals when the window is shown again (blank page after a hidden workspace)
qml/Main.qml           the window, overlays, every key binding (handleKey)
qml/Theme.qml          singleton: app palette (matugen or Material baseline), fonts, motion
qml/ReadingTheme.qml   singleton: page colours and type, settings in $XDG_CONFIG_HOME/dogear/dogear.conf
qml/KeyEvents.qml      singleton: the page's key events as Qt-style ones
qml/views/             Reader (web view + bars + bridge), TocPanel, EmptyPage
qml/components/        Label, LinearProgress, ListKeys (Seedling), KeyHelp (margin)
reader/index.html, reader.js   the page: foliate-js driven over the web channel
reader/foliate/        foliate-js, vendored (commit in VERSION, MIT); don't edit, update whole
```

Every QML file imports `Dogear` (its own module) rather than relative paths. Singletons need `QT_QML_SINGLETON_TYPE` set **before** `qt_add_qml_module` in CMakeLists.txt, or they register as plain types and every property reads undefined.

## The reader page

- The page, its scripts and the book all come from one origin, `dogear://app`, so `fetch` of the book and ES modules work without CORS. A book is served only after `Library.open` registered its id (`Library::fileFor`).
- foliate-js puts each section in a `blob:` iframe. `Reader.qml` only stops main-frame navigation away from `dogear:`; external links arrive as `window.open` (foliate's `external-link`) and go to the browser if http(s)/mailto.
- QML → page: the bridge's `command(name, json)` signal (`open`, `style`, `next`, `prev`, `left`, `right`, `nextSection`, `prevSection`, `goTo`, `fraction`, `back`, `forward`). Page → QML: `ready`, `opened`, `relocated`, `key`, `error`, each one JSON string.
- Styles: `bookCSS` in reader.js lays colours, size and spacing over the book's own CSS. Text colour is inherited everywhere (`!important`) so books that hard-code black stay readable on dark pages; links take the scheme's link colour.
- Positions are EPUB CFIs, saved on every `relocated`.
- Text size scales the root font size (`html { font-size: N% }`), which fixed sizes ignore. So `relativeSizes` in reader.js rewrites `font-size` keywords (`medium`, `small`, …), `px` and `pt` (also in the `font` shorthand) to `rem` as each stylesheet and section loads (foliate's `transformTarget` `data` event).
- Pictures on dark pages (`imageCSS` in reader.js, setting `images`, key `i`): `dim` (brightness 0.8, the default) or `invert` (invert + hue-rotate, then `mix-blend-mode: screen` so the drawing's paper takes the page's colour; that needs the page colour as the section's own `html` background, which `bookCSS` sets). Light pages leave pictures alone.
- `applyStyle` sets the renderer's attributes only when they change: `flow` and `max-inline-size` re-render the section from its start, losing the place.
- Hyprland suspends windows on hidden workspaces; Chromium drops the page's frame and draws none on return until something changes, leaving it blank. `WindowWatch` (C++) signals `shown` when the window is exposed again and Reader sends `repaint` (a one-frame opacity nudge).
- Footer: chapter and minutes left in it; the printed page (`Page N`, only when the EPUB has a page list), the screen within the chapter (`renderer.page` of `renderer.pages - 2`: the paginator keeps a blank page at each end), and percent of the book. There's no whole-book screen count: it would mean laying out every section.
- The bars above and below the page keep their room but show only while hovered (`HoverHandler`).
- Font (`F`, `FontPanel`, setting `fontFamily`): "" keeps the book's fonts; otherwise `fontCSS` sets the family on everything but code (`pre`, `code`, `kbd`, `samp`, `tt`). The list comes from `$XDG_CONFIG_HOME/dogear/fonts.conf` (one family per line, `#` comments, `*` adds every other installed body font; written from `ReadingTheme.defaultFonts` on first run), less families that aren't installed; Book's own, serif and sans-serif always lead. Moving through the list previews on the page through `ReadingTheme.previewFont`, which is never saved; Enter saves, Esc drops the preview. Literata's italic capitals are barely sloped: an all-caps italic heading looking upright in it is the font, not a bug (DevTools' `CSS.getPlatformFontsForNode` shows the face used; run with `QTWEBENGINE_REMOTE_DEBUGGING=127.0.0.1:9333`).
- Scrolling mode (`s`): reader.js opens every shadow root (it wraps `attachShadow` before foliate makes any) to reach the paginator's `#container`, hide its scrollbar (`Scroller.hideScrollbar`) and scroll it itself. `Scroller` eases to a moving target (exponential ease-out, frame-rate independent), so held or repeated keys make one smooth movement: j/k/arrows (`down`/`up` commands) three lines, Space/PageDown (`pageDown`/`pageUp`) 85% of a screen; past a section's end it calls `view.next()`/`prev()`. Mouse-wheel notches (line mode or |deltaY| ≥ 50) become three-line steps; touchpads' fine deltas scroll natively. In paginated mode the same commands turn pages.
- Page turns slide (foliate's `animated` attribute: 300 ms ease-out, within a section only; a new section appears at once). Setting `animatePages` in dogear.conf turns it off. foliate ignores turns while one is sliding, so a held key turns about three pages a second.
- The page can restart (a reload, a renderer crash): it calls `ready` again and `Reader` resends the open book at `where.cfi`. Chromium's own context menu (back, reload, view source) is suppressed.

## Keyboard

Everything from the keyboard, vim style; mouse secondary (outer thirds of the page turn it, wheel turns pages in paginated mode).

- Keys come from two places and meet in `Main.handleKey`: Qt's events while a QML item has focus, and the page's keydown (in the page and each section's frame), forwarded over the bridge and made Qt-shaped by `KeyEvents.fromWeb`. So the page normally has focus, and overlays get their keys through `handleKey`, not QML focus.
- Match letters on `event.text`, special keys on `event.key`. An open overlay takes every key until it closes.
- `?`/F1 lists the keys (`Main.bindings`); keep it in sync when adding one.
- No focus rings: the current row is shown by its fill (`secondary_container`).

## Design

Look like the shell's menus and margin; check `~/Projects/margin` and `~/Projects/seedling` before designing something new.

- Colours: `Theme` properties named after Material roles, from `~/.config/dogear/colors.css` (matugen's `[templates.dogear]`), opaque (a normal window). Never hard-code hues in the app's chrome. The page's own schemes (`ReadingTheme.papers`: light, sepia, dark, black) are the exception; Auto uses `Theme.surface`/`on_surface`/`primary`.
- The window and the bars around the page take the page's colours, so the whole window is one paper; overlays (contents, keys, snackbar) use `Theme`.
- Type: `Label` (Google Sans Flex); panel titles 26px `Theme.titleWeight` in `primary`; rows 14px, sub-rows 13px `on_surface_variant`.
- Motion: `Theme.emphasizedDecel`/`Accel`, `animFast`, `animNormal`.

## Testing

Run it on the user's screen (`hyprctl dispatch "hl.dsp.exec_cmd('…')"` inside `systemd-inhibit --what=idle`), screenshot only its window, keys only to it (`hl.dsp.send_shortcut({ mods = "", key = "l", window = "class:io.github.anisthdev.Dogear" })`). `?` is `key = "slash", mods = "SHIFT"`. `q` closes the app. Stop it with `pkill -x dogear` (not `-f`, which matches the shell running it).
