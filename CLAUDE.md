# Dogear

An ebook reader and library, like Foliate but ours. App ID `io.github.anisthdev.Dogear` (Wayland app ID and `.desktop` name). Primary target: Arch Linux + Hyprland, next to the shell (`~/Projects/quickbar`), whose look and keyboard-first style it shares. It's meant to work for anyone, so nothing depends on this machine: matugen colours are used when present, Material's baseline palette otherwise; no paths into ~/Projects at runtime.

## Phases

1. **Reader core** (done): open an EPUB, pages or scrolling, colour schemes, contents, position saved and restored, keys.
2. **Library** (done): folders indexed in place and watched; adding copies into the first folder. Cover grid and list, sort, `/` filter; it opens on the book read last.
3. **Annotations** (done): highlights, notes, bookmarks, visual mode, one panel, Markdown to the clipboard.
4. **Search** (done): in the book (`/`, panel + n/N), across every book's text (Ctrl+f, FTS5).
5. **Metadata online** (done): Open Library (Google Books with a key); ISBN matches by themselves, the rest by `F`/`f` with a picker; hand edits win.
6. **Dictionary** (done): StarDict through sdcv, then Wiktionary (`d`). No text-to-speech: the user decided Dogear won't have it.
7. **OPDS** (done): public catalogues, browsed in `O`; free EPUBs download into the library. No logins yet, no facets.
8. **PDF** later, through pdf.js (left out of `reader/foliate/vendor` until then). Internet Archive (`https://archive.org/services/opds`) offers only PDFs as open access, so it joins the suggested catalogues then.

## How it runs

```
cmake -S . -B build -G Ninja && cmake --build build
build/dogear [book.epub]     # no book: the library
makepkg -si                  # installs totoro-dogear (provides dogear)
```

There's no live reload as in the Quickshell apps: QML and the reader page are compiled into the binary's resources, so rebuild and restart after a change. Start it with `QT_FORCE_STDERR_LOGGING=1`, or Qt sends its logs (and the page's console, prefixed `page:`) to the journal.

## Layout

```
src/main.cpp           WebEngine set-up (must come before the app), command line, scheme handler, QML
src/Library.*          QML singleton: the books QML sees, folders, watching, opening, progress, adding
src/Database.*         the SQLite file ($XDG_DATA_HOME/dogear/library.db), its schema (user_version), cover thumbnails
src/Scanner.*          library scan on its own thread; record() hashes, reads and upserts one file
src/Online.*           Open Library / Google Books: ISBN lookups, searches, applying a match (book_fields 'online', tags, cover)
src/Catalog.*          OPDS: feeds (Atom and JSON) in one shape for QML, search, the catalogues, downloads
src/Dictionary.*       word lookups: sdcv (StarDict) first, then Wiktionary's REST definitions
src/Epub.*             what an EPUB says (OPF metadata, series, cover) and its sections' text with chapter labels (nav/NCX), read from the zip with libzip
src/SchemeHandler.*    dogear://app/...: reader page from :/reader, qwebchannel.js, books as /book/<id>
src/TextFile.*         watched text file (Quickshell's FileView isn't available here): colors.css, fonts.conf
src/WindowWatch.*      signals when the window is shown again (blank page after a hidden workspace)
qml/Main.qml           the window, overlays, every key binding (handleKey)
qml/Theme.qml          singleton: app palette (matugen or Material baseline), fonts, motion
qml/ReadingTheme.qml   singleton: page colours and type, settings in $XDG_CONFIG_HOME/dogear/dogear.conf
qml/KeyEvents.qml      singleton: the page's key events as Qt-style ones
qml/views/             LibraryView (grid/list, keys), Reader (web view + bars + bridge), TocPanel, FontPanel, TagPanel, SelectionMenu, AnnotationsPanel, SearchPanel (both searches), BookPanel (i: details), MatchPanel (f/F: online match), CatalogView (O: catalogues and feeds), CatalogBook (a catalogue's book)
qml/components/        Cover (rounded, placeholder card); Label, LinearProgress, ListKeys (Seedling), KeyHelp (margin)
reader/index.html, reader.js   the page: foliate-js driven over the web channel
reader/foliate/        foliate-js, vendored (commit in VERSION, MIT); don't edit, update whole
licenses/              the licences of foliate's vendored zip.js and fflate, which it doesn't carry; installed by the PKGBUILD. pdf.js (Apache) needs its own here in phase 8
```

Every QML file imports `Dogear` (its own module) rather than relative paths. Singletons need `QT_QML_SINGLETON_TYPE` set **before** `qt_add_qml_module` in CMakeLists.txt, or they register as plain types and every property reads undefined.

## The library

- Folders: `[library] folders` in dogear.conf. First run: whichever of ~/Books, ~/Ebooks, ~/eBooks, ~/Documents/Books exist, else a new ~/Books.
- Rows are keyed by the file's SHA-256: a moved or renamed file keeps its place; a file gone is `missing` (hidden, kept); a file changed in place gets a new row that takes the old one's reading. A scan skips files with the same path, size and mtime whose `scanned` is at least `Scanner::version`; bump the version when `Epub::read` or what's stored changes, and every book is read again.
- Books opened from outside the folders (command line, `o`) are recorded too and show in the library while their file exists.
- The watcher covers every folder under the library folders; changes are debounced into one rescan (1.5 s).
- Covers: thumbnails (≤720 px tall, JPEG) in $XDG_CACHE_HOME/dogear/covers/<id>.jpg, made once.
- Authors given in sort form ("Kleppmann, Martin") show as "Martin Kleppmann"; sort uses file-as, else the derived "Last, First".
- Series: shown is the user's (`user_series`, NULL = not set, '' = none), else the EPUB's (`series`: Calibre or EPUB 3 collection), else the folder's (`folder_series`: a numbered file — leading number, or "Book 4", "#4", "Vol. 4" — in a subfolder of a library folder holding two EPUBs or more). Kept in separate columns so a rescan never undoes an edit; `e` sets the user's ("Name #3"; several books without a number are numbered in the order shown; empty = none; "auto" clears the override).
- Stacks (`z`, `[library] stacks`): a series with two books or more in view is one item (`isSeries`, `books`, `next` = the one being read, else the first unfinished); it sorts by its latest reading/adding and its name. Enter opens it (`openSeries`, books by series index); q/Backspace/Esc leave. A text filter shows single books.
- Tags: table `tags` (book, tag NOCASE, source 'book'|'user', removed). The EPUB's dc:subject (split on , ;) are 'book' tags, refreshed on each scan; removing one sets `removed`, so a rescan keeps it off; user tags are deleted outright. `t` filters by a tag (TagPanel, counts), `T` edits the tags of the selection or current book (for several: the tags they share).
- Books with no title in their metadata take it from the file name, less site tags like "(z-lib.org)", with "… by Author" split off.
- Sections (`LibraryView.sections`): *Continue reading* (started, not finished, latest first; one sideways row of bigger covers, `bigWidth`; its books also show in their own section), then *Academic* and *Non-academic*, each a grid (or the list's rows) in the chosen sort with series stacked. Inside a series, just its books. A book's section is `user_category` (schema v7, set with `c`, `C` clears) else `guessCategory` in Library.cpp from its tags: fiction-like tags win over study ones (1984 has both), and no clue means Non-academic. Finished books stay where they are, marked "✓ Read".
- The cursor is a slot (`slots`: section, index, item; `currentKey` = section key + id, so a book in two sections is two places). j/k move a row and cross into the next or previous section at the same column (`vertical`), h/l along a row (`horizontal`), ] [ to a section's first item. Delegates are inline components (`BookCell`, `BookRow`) that reveal themselves when current; inside inline components, closures handed to `Qt.callLater` lose the file's ids (`root` is undefined there), so they use a zero-interval Timer.
- The Continue reading row is a horizontal ListView positioned by `positionViewAtIndex` (its origin isn't 0, so setting contentX directly drifts), animated from the old contentX, and placed again whenever its width, content or model change.
- Keys (LibraryView.handleKey): h j k l/arrows move (j/k by a row of the grid), gg G, Ctrl+d/u/f/b, Enter/o open (l too in the list), / filter, t tag, s/S sort (recent, title, author+series, added, progress), v grid/list, z stacks, c/C section, x forget progress (ConfirmDialog; position, fraction and opened_at cleared, annotations kept), ] [ sections, Space select (a stack: all its books), e series, T tags, a add (FileDialog), R rescan, Esc lets go of selection → filter → tag → series, q leaves a series, else quits. In the reader q goes back to the library. `[library] view`, `sort` and `stacks` are remembered.

## Annotations

- Table `annotations` (schema v4): kind 'highlight' (a CFI range) or 'bookmark' (the CFI of the page's start, `CFI.collapse` of the relocate CFI), color (yellow green blue pink purple), style ('highlight' | 'underline'), text, note, chapter and fraction (for lists and export without the book open). Library.annotations/addAnnotation/updateAnnotation/removeAnnotation; Reader keeps the book's list and tells the page what to draw.
- Page side (reader.js `Notes`): annotations by CFI and by section index; foliate's `create-overlay` asks for a section's highlights as it's laid out, `draw-annotation` for each one's look (`Overlayer.highlight`/`underline`), `show-annotation` reports a click on one (which then doesn't turn the page). Every `open` must carry `annotations`, or nothing is drawn.
- Selections reach QML as `selection` { cfi, text, rect in page coordinates, annotation id when a highlight was clicked } and open `SelectionMenu` beside them: 1–5 colour, u highlight/underline, n note (highlights first), c/y copy, d/Delete delete, Enter the last colour, Esc/q let go. The last colour and style are `[reading] highlightColor/highlightStyle`.
- Overlaps (reader.js `announce`): a selection inside one highlight is that highlight (its menu, as a click); one overlapping highlights reaches over all of them and carries their ids as `merges`, which Reader deletes when saving it (notes joined). So two highlights never share a CFI: the page keys drawings by CFI, and a duplicate left a row with nothing drawn.
- Visual mode (`v`, reader.js `Visual`): starts on the page's first word (skipping empty text nodes), grows with `Selection.modify` (h l w e b j k ( ) { } 0 ^ $, o swaps ends), turns the page or scrolls to keep the moving end in view; y/Enter hand it to the menu, Esc/v/q drop it. While on, the page keeps its keys.
- `m` bookmarks the page or takes its bookmark off; a ribbon hangs at the page's top left while it has one (`relocated.bookmark`: a bookmark's CFI inside the page's range).
- `a` opens AnnotationsPanel: reading order, Enter goes there, n note, y copy, dd delete, Y copies everything as Markdown (chapter headings, highlights as quotes with notes below, bookmarks as items).

## Search

- In the book (`/`): foliate's `view.search` (case and accents ignored; whole words with `w` in the list, Alt+w in the field) streams matches per chapter as `searchResults`, outlined on the page. The page keeps the CFIs (`hits`) and does n/N itself (`hit`: after the last one gone to, else after `lastLocation`, by `CFI.compare`), answering `hitAt` for the counter. Esc in the reader clears it.
- Every book (Ctrl+f, anywhere): FTS5 table `book_text` (schema v5; book, section = spine index, chapter, text; unicode61 remove_diacritics 2), filled by `Scanner::record` from `Epub::sections`. `Library.searchText` makes the words one phrase (`"a b c" *`, no `*` for whole words), `snippet()` marks the match with \x01/\x02, best 200 by rank; the panel groups by book (best first), passages in reading order. Opening one runs the book search with `jumpSection` and `near` (the passage's text before the match) and goes to that match.
- SearchPanel: typing searches after 250 ms; Enter/Down to the results (cursor on the first match of each new search, set after the list has the rows); j/k skip headings, Enter/l opens, / back to the field, q/Esc close.
- `sqlite3` on this machine's PATH is the Android SDK's, without FTS5: use /usr/bin/sqlite3 or Python to look at `book_text`.

## Book details and online metadata

- Sources, kept apart (schema v6): the EPUB's own columns on `books` ('book'); `book_fields` (book, field, source, value) for 'user' (typed in, `i` then t a p y I), 'online' and 'file' (the file name, only for books that don't say). `Library.reload` picks per field: title/authors user → book → online → file; description/publisher/published user → online → book → catalog; cover user → book → online; each book carries `…From` for the sheet. Nothing overwrites another source; `setField(id, f, "")` drops the user's.
- `Online` (one request at a time, 350 ms apart, User-Agent naming Dogear): after each scan, books with an ISBN not yet tried get `/isbn/{isbn}.json` (an edition: its publisher, date, ISBN) + its author + its work (description, subjects); books without one are marked 'none' for the review. `online_status`: pending isbn picked none skipped error; a new ISBN from a rescan of an unmatched book clears `online_checked`, so it's tried again.
- By hand: `f` in the details, or `F` in the library for every unmatched, unskipped book in turn (Esc next, x never ask, q stop). `/search.json?q=` (every word must match: the field starts as title less any subtitle + first author's surname, and a search finding nothing retries with the last word dropped, up to 3 times). A search gives a *work*: its publishers and ISBNs are every edition's, so only work-level fields are kept (title, authors, description, first year, cover, tags).
- Google Books only with `[metadata] googleKey` (its keyless quota is shared and spent); `[metadata] online=false` turns lookups off.
- Tags from the web (source 'online', replaced with each match, removable like the book's): genres named in the subjects (a fixed list in `Online::cleanSubjects`; in a list over 20 a genre must be named twice), else up to five short English topics. A tag the book already has stays the book's.
- Covers from the web are kept as `<id>-online.jpg`; the EPUB's comes first.
- QML's JavaScript here has no `Array.prototype.flatMap`: use loops (`LibraryView.allBooks`).

## Dictionary

- `d` in the selection menu (delete is `x` there now) or in visual mode (straight to the card, `intent: 'define'`) looks the selection up; DefinitionCard sits under the word (over it if there's no room): j/k scroll, o Wiktionary page, y copy, q/Esc/Enter close.
- `Dictionary::forms`: the selection less surrounding punctuation, lower case, then plural/tense endings stripped (ies→y, es, s, doubled consonant + ed/ing, ed, ing, 's); each form is tried, offline then online.
- Offline: `sdcv -n -j -e -0 -1 -2 <$XDG_DATA_HOME/dogear/dictionaries> word` (it also reads ~/.stardict/dic, /usr/share/stardict/dic, $STARDICT_DATA_DIR); each dictionary's answer is one entry, senses split on blank lines. Install StarDict files (.ifo/.idx/.dict[.dz]) in any of those folders.
- Online: `en.wiktionary.org/api/rest_v1/page/definition/{word}`, the section for the book's language (else English), up to six senses per part of speech, HTML made plain. `[dictionary] online=false` turns it off.

## Catalogues

- `O` in the library: `win.mode` "catalog". `Library.catalog` (Catalog) has the kept catalogues, `catalogs` table (schema v8, public ones seeded once, so one removed stays gone); `a r x` in the list add (after the address loads as a feed), rename, remove.
- Feeds are parsed in C++, not by foliate's `opds.js`: that needs a DOM, and the library has no page. Both formats become { title, next, search, web, items }, items being heading, nav or book rows (top comment in Catalog.h). Every URL goes through `absolute`: http(s) only (`data:image/` for images), so a feed can't reach local files. Text shows as `Text.PlainText`, so a feed can't load remote images through its HTML.
- Real feeds bend the spec: Gutenberg's book page has one entry per edition (`mergeEditions`, by title and authors, formats sorted by `rank`) and a page of "Label: value" lines as content (`prose` keeps the Summary); ManyBooks' search results call their feeds text/html (a link with no rel counts as the way in) and it wraps titles in XHTML (`richText`). ManyBooks refuses covers to Qt's default User-Agent, hence `NetworkFactory` in main.cpp.
- Gutenberg's lists give every book one 22 px icon, so `gutenbergCover` builds the cover's address from the book's number (`thumb`), the icon staying as `icon` for books with none (Cover's `fallback`). With `measure` (catalogue rows), a picture under 60% of Cover's height sits on the card at its own size (`tiny`), not stretched. It's off in the library: `sourceSize` makes Qt scale small pictures up, which hides their size, and the grid needs it to load covers small.
- A feed that's one book opens as the sheet (CatalogBook), with no new page. `CatalogView.pages` is the way here, kept in memory; going back doesn't refetch. The list's model is only indexes (`i`, into `rows`), so the next page (`moreIfNear`, 6 rows from the end) appends without rebuilding the rows.
- Search: `/` uses the nearest page's `search`, a template or an OpenSearch description (fetched for its feed template); `fillTemplate` handles `{searchTerms}`, `{?query}` and optional slots.
- Downloads: free EPUBs only (`acquisition`, `acquisition/open-access`; buy, borrow, subscribe and sample aren't offered). Written through QSaveFile into the first library folder, so the unfinished file doesn't end in .epub; the first bytes must be a zip's; hashed as they arrive, so the book's id is known without reading the file again. If that book is already there the file is dropped. `catalog_books` maps a feed's book id to ours (`held`), which is how rows know "✓ In library". The catalogue's description and publisher go in `book_fields` as 'catalog', after the book's own.
- Standard Ebooks' OPDS needs a login (401) and Feedbooks refuses non-browsers (403), so neither is suggested.

## The reader page

- The page, its scripts and the book all come from one origin, `dogear://app`, so `fetch` of the book and ES modules work without CORS. A book is served only after `Library.open` registered its id (`Library::fileFor`).
- foliate-js puts each section in a `blob:` iframe. `Reader.qml` only stops main-frame navigation away from `dogear:`; external links arrive as `window.open` (foliate's `external-link`) and go to the browser if http(s)/mailto.
- QML → page: the bridge's `command(name, json)` signal (`open`, `style`, `next`, `prev`, `left`, `right`, `nextSection`, `prevSection`, `goTo`, `fraction`, `back`, `forward`). Page → QML: `ready`, `opened`, `relocated`, `key`, `error`, each one JSON string.
- Styles: `bookCSS` in reader.js lays colours, size and spacing over the book's own CSS. Text colour is inherited everywhere (`!important`) so books that hard-code black stay readable on dark pages; links take the scheme's link colour.
- Positions are EPUB CFIs, saved on every `relocated`.
- Text size scales the root font size (`html { font-size: N% }`), which fixed sizes ignore. So `relativeSizes` in reader.js rewrites `font-size` keywords (`medium`, `small`, …), `px` and `pt` (also in the `font` shorthand) to `rem` as each stylesheet and section loads (foliate's `transformTarget` `data` event).
- Pictures on light pages: `mix-blend-mode: multiply` (`imageCSS.light`), so a picture's white paper takes the page's colour (sepia, a light palette); the Light paper is pure #ffffff because books' pictures are, and an off-white page showed their edges.
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
