#include "Library.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QClipboard>
#include <QGuiApplication>
#include <QHash>
#include <QRegularExpression>
#include <QSettings>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QUrl>

#include "Database.h"
#include "Epub.h"
#include "Dictionary.h"
#include "Online.h"
#include "Scanner.h"

QString Library::s_startFile;

// id -> path for the scheme handler. Both run on the GUI thread.
static QHash<QString, QString> s_files;

static QSettings settings()
{
    return QSettings(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/dogear/dogear.conf",
                     QSettings::IniFormat);
}

QString Library::fileFor(const QString &id)
{
    return s_files.value(id);
}

Library::Library(QObject *parent)
    : QObject(parent)
{
    m_db = Database::connect("library");

    QSettings s = settings();
    m_folders = s.value("library/folders").toStringList();
    if (m_folders.isEmpty()) {
        const QString home = QDir::homePath();
        for (const QString &candidate : {"Books", "Ebooks", "eBooks", "Documents/Books"}) {
            if (QFileInfo(home + "/" + candidate).isDir())
                m_folders.append(home + "/" + candidate);
        }
        if (m_folders.isEmpty()) {
            QDir().mkpath(home + "/Books");
            m_folders.append(home + "/Books");
        }
        s.setValue("library/folders", m_folders);
    }

    m_scanner = new Scanner;
    m_scanner->moveToThread(&m_thread);
    connect(&m_thread, &QThread::finished, m_scanner, &QObject::deleteLater);
    connect(this, &Library::startScan, m_scanner, &Scanner::scan);
    connect(m_scanner, &Scanner::changed, this, &Library::reload);
    // Details from the web, for books with an ISBN after every scan
    m_online = new Online(this);
    m_online->setEnabled(s.value("metadata/online", true).toBool());
    m_online->setGoogleKey(s.value("metadata/googleKey").toString());
    connect(m_online, &Online::changed, this, &Library::reload);
    connect(m_online, &Online::matches, this, &Library::onlineMatches);
    connect(m_online, &Online::applied, this, &Library::onlineApplied);

    m_dictionary = new Dictionary(this);
    m_dictionary->setOnline(s.value("dictionary/online", true).toBool());
    connect(m_dictionary, &Dictionary::found, this, &Library::defined);

    connect(m_scanner, &Scanner::finished, this, [this] {
        m_online->autoMatch();
        reload();
        watch();
        setScanning(false);
        if (m_rescanQueued) {
            m_rescanQueued = false;
            rescan();
        }
    });
    m_thread.start(QThread::LowPriority);

    // Folder changes come in bursts (a copy, an unzip): one scan after
    m_rescanTimer.setSingleShot(true);
    m_rescanTimer.setInterval(1500);
    connect(&m_rescanTimer, &QTimer::timeout, this, &Library::rescan);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_rescanTimer, qOverload<>(&QTimer::start));

    reload();
    rescan();
}

Library::~Library()
{
    m_thread.quit();
    m_thread.wait();
}

void Library::setFolders(const QStringList &folders)
{
    if (folders == m_folders)
        return;
    m_folders = folders;
    settings().setValue("library/folders", m_folders);
    emit foldersChanged();
    rescan();
}

void Library::setScanning(bool scanning)
{
    if (scanning == m_scanning)
        return;
    m_scanning = scanning;
    emit scanningChanged();
}

void Library::rescan()
{
    if (m_scanning) {
        m_rescanQueued = true;
        return;
    }
    setScanning(true);
    emit startScan(m_folders);
}

// Every folder and folder under them, so a book dropped anywhere in the
// library is noticed
void Library::watch()
{
    QStringList dirs;
    for (const QString &folder : m_folders) {
        if (!QFileInfo(folder).isDir())
            continue;
        dirs.append(folder);
        QDirIterator it(folder, QDir::Dirs | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
        while (it.hasNext() && dirs.size() < 4000)
            dirs.append(it.next());
    }
    const QStringList watched = m_watcher.directories();
    QStringList add, remove;
    for (const QString &d : dirs)
        if (!watched.contains(d))
            add.append(d);
    for (const QString &d : watched)
        if (!dirs.contains(d))
            remove.append(d);
    if (!remove.isEmpty())
        m_watcher.removePaths(remove);
    if (!add.isEmpty())
        m_watcher.addPaths(add);
}

void Library::reload()
{
    QSqlQuery q(m_db);
    QHash<QString, QStringList> tags;
    {
        QSqlQuery t(m_db);
        t.exec("SELECT book, tag FROM tags WHERE removed = 0 ORDER BY tag COLLATE NOCASE");
        while (t.next())
            tags[t.value(0).toString()].append(t.value(1).toString());
    }
    q.exec(R"(SELECT id, path, title, authors, authors_sort,
                     CASE WHEN user_series IS NOT NULL THEN user_series
                          ELSE coalesce(nullif(series, ''), folder_series, '') END,
                     CASE WHEN user_series IS NOT NULL THEN user_series_index
                          WHEN nullif(series, '') IS NOT NULL THEN series_index
                          ELSE folder_series_index END,
                     language, description, publisher, published, isbn, cover, fraction,
                     added_at, opened_at,
                     CASE WHEN user_series IS NOT NULL THEN 'user'
                          WHEN nullif(series, '') IS NOT NULL THEN 'book'
                          WHEN folder_series IS NOT NULL THEN 'folder' ELSE '' END,
                     online_status, online_key
              FROM books WHERE missing = 0)");
    // Details from elsewhere: book -> field -> source -> value
    QHash<QString, QHash<QString, QHash<QString, QString>>> fields;
    {
        QSqlQuery f(m_db);
        f.exec("SELECT book, field, source, value FROM book_fields");
        while (f.next())
            fields[f.value(0).toString()][f.value(1).toString()][f.value(2).toString()] = f.value(3).toString();
    }
    QVariantList books;
    while (q.next()) {
        const QString id = q.value(0).toString();
        const QString path = q.value(1).toString();
        const auto &extra = fields[id];
        // A field's value and where it came from: the first source in
        // `order` that has it ("book" is the EPUB's own column value)
        auto pick = [&](const QString &field, const QString &own, const QStringList &order) -> std::pair<QString, QString> {
            for (const QString &source : order) {
                const QString v = source == "book" ? own : extra.value(field).value(source);
                if (!v.trimmed().isEmpty())
                    return {v, source};
            }
            return {};
        };
        // The book's own name and authors come before the web's (the web's
        // may be another edition's); the web's description and publishing
        // details come before the book's (often missing or thin)
        const QStringList named{"user", "book", "online", "file"};
        const QStringList described{"user", "online", "book"};
        const auto [title, titleFrom] = pick("title", q.value(2).toString(), named);
        const auto [authors, authorsFrom] = pick("authors", q.value(3).toString(), named);
        const auto [cover, coverFrom] = pick("cover", q.value(12).toString(), {"user", "book", "online"});
        QString authorsSort = authorsFrom == "book" ? q.value(4).toString() : QString();
        if (authorsSort.isEmpty()) {
            const QString first = authors.section(',', 0, 0).trimmed();
            const int space = first.lastIndexOf(' ');
            authorsSort = space > 0 ? first.mid(space + 1) + ", " + first.left(space) : first;
        }
        books.append(QVariantMap{
            {"id", q.value(0)},
            {"path", path},
            // Untitled books go by their file's name
            {"title", title.isEmpty() ? QFileInfo(path).completeBaseName() : title},
            {"titleFrom", titleFrom},
            {"authors", authors},
            {"authorsFrom", authorsFrom},
            {"authorsSort", authorsSort},
            {"online", q.value(17).toString()},
            {"onlineKey", q.value(18).toString()},
            {"coverFrom", coverFrom},
            {"series", q.value(5).toString()},
            {"seriesIndex", q.value(6).toDouble()},
            {"language", q.value(7).toString()},
            {"description", pick("description", q.value(8).toString(), described).first},
            {"descriptionFrom", pick("description", q.value(8).toString(), described).second},
            {"publisher", pick("publisher", q.value(9).toString(), described).first},
            {"published", pick("published", q.value(10).toString(), described).first},
            {"isbn", pick("isbn", q.value(11).toString(), {"user", "book", "online"}).first},
            {"cover", cover.isEmpty() ? QString() : QUrl::fromLocalFile(cover).toString()},
            {"fraction", q.value(13).toDouble()},
            {"addedAt", q.value(14).toLongLong()},
            {"openedAt", q.value(15).isNull() ? 0 : q.value(15).toLongLong()},
            {"seriesSource", q.value(5).toString().isEmpty() ? QString() : q.value(16).toString()},
            {"tags", tags.value(q.value(0).toString())},
        });
    }
    m_books = books;
    emit booksChanged();
}

QVariantMap Library::open(const QString &pathOrUrl)
{
    const QUrl url(pathOrUrl);
    const QString path = url.isLocalFile() ? url.toLocalFile() : pathOrUrl;
    const QFileInfo info(path);
    if (!info.isFile())
        return {{"ok", false}, {"error", "No such file: " + path}};
    const QString id = Scanner::record(info.absoluteFilePath(), "library", m_folders);
    if (id.isEmpty())
        return {{"ok", false}, {"error", "Can't read " + path}};

    QSqlQuery q(m_db);
    q.prepare("UPDATE books SET opened_at = ? WHERE id = ?");
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(id);
    q.exec();
    q.prepare("SELECT position, fraction FROM books WHERE id = ?");
    q.addBindValue(id);
    q.exec();
    const bool found = q.next();

    s_files.insert(id, info.absoluteFilePath());
    reload();
    return {
        {"ok", true},
        {"id", id},
        {"path", info.absoluteFilePath()},
        {"url", QStringLiteral("dogear://app/book/") + id},
        {"position", found ? q.value(0).toString() : QString()},
        {"fraction", found ? q.value(1).toDouble() : 0.0},
    };
}

QString Library::lastBook() const
{
    QSqlQuery q(m_db);
    q.exec("SELECT path FROM books WHERE opened_at IS NOT NULL AND missing = 0 ORDER BY opened_at DESC LIMIT 10");
    while (q.next()) {
        const QString path = q.value(0).toString();
        if (QFileInfo(path).isFile())
            return path;
    }
    return {};
}

void Library::saveProgress(const QString &id, const QString &position, double fraction)
{
    QSqlQuery q(m_db);
    q.prepare("UPDATE books SET position = ?, fraction = ? WHERE id = ?");
    q.addBindValue(position);
    q.addBindValue(fraction);
    q.addBindValue(id);
    if (!q.exec())
        qWarning() << "library:" << q.lastError().text();
    // Keep the library's copy in step without reloading everything
    for (QVariant &v : m_books) {
        QVariantMap book = v.toMap();
        if (book.value("id") == id) {
            book["fraction"] = fraction;
            v = book;
            break;
        }
    }
}

void Library::setField(const QString &id, const QString &field, const QString &value)
{
    static const QStringList known{"title", "authors", "description", "publisher", "published", "isbn"};
    if (!known.contains(field))
        return;
    QSqlQuery q(m_db);
    if (value.trimmed().isEmpty()) {
        q.prepare("DELETE FROM book_fields WHERE book = ? AND field = ? AND source = 'user'");
        q.addBindValue(id);
        q.addBindValue(field);
    } else {
        q.prepare("INSERT INTO book_fields (book, field, source, value) VALUES (?, ?, 'user', ?) "
                  "ON CONFLICT DO UPDATE SET value = excluded.value");
        q.addBindValue(id);
        q.addBindValue(field);
        q.addBindValue(value.trimmed());
    }
    q.exec();
    reload();
}

void Library::findOnline(const QString &request, const QString &query)
{
    m_online->search(request, query);
}

void Library::applyOnline(const QString &id, const QVariantMap &candidate)
{
    m_online->apply(id, candidate, true);
}

void Library::clearOnline(const QString &id)
{
    m_online->clear(id);
}

void Library::define(const QString &request, const QString &text, const QString &language)
{
    m_dictionary->lookup(request, text, language);
}

QString Library::dictionaryFolder() const
{
    return Dictionary::folder();
}

void Library::skipOnline(const QString &id)
{
    m_online->skip(id);
}

void Library::saveDetails(const QString &id, const QString &title, const QString &authors)
{
    QSqlQuery q(m_db);
    q.prepare("UPDATE books SET title = coalesce(title, ?), authors = coalesce(authors, ?) WHERE id = ?");
    q.addBindValue(title.isEmpty() ? QVariant() : title);
    q.addBindValue(authors.isEmpty() ? QVariant() : authors);
    q.addBindValue(id);
    q.exec();
}

void Library::setSeries(const QStringList &ids, const QString &name, const QVariantList &indexes)
{
    for (int i = 0; i < ids.size(); ++i) {
        QSqlQuery q(m_db);
        q.prepare("UPDATE books SET user_series = ?, user_series_index = ? WHERE id = ?");
        q.addBindValue(name.trimmed());
        const double index = i < indexes.size() ? indexes.at(i).toDouble() : 0;
        q.addBindValue(index > 0 && !name.trimmed().isEmpty() ? QVariant(index) : QVariant(QMetaType::fromType<double>()));
        q.addBindValue(ids.at(i));
        q.exec();
    }
    reload();
}

void Library::resetSeries(const QStringList &ids)
{
    for (const QString &id : ids) {
        QSqlQuery q(m_db);
        q.prepare("UPDATE books SET user_series = NULL, user_series_index = NULL WHERE id = ?");
        q.addBindValue(id);
        q.exec();
    }
    reload();
}

void Library::setTags(const QString &id, const QStringList &wanted)
{
    QStringList tags;
    for (const QString &t : wanted) {
        const QString tag = t.simplified();
        if (!tag.isEmpty() && !tags.contains(tag, Qt::CaseInsensitive))
            tags.append(tag);
    }
    QSqlQuery q(m_db);
    q.prepare("SELECT tag, source FROM tags WHERE book = ?");
    q.addBindValue(id);
    q.exec();
    QHash<QString, QString> existing; // lower-case tag -> source
    while (q.next())
        existing.insert(q.value(0).toString().toLower(), q.value(1).toString());

    for (auto it = existing.cbegin(); it != existing.cend(); ++it) {
        if (tags.contains(it.key(), Qt::CaseInsensitive))
            continue;
        QSqlQuery u(m_db);
        u.prepare(it.value() != "user" ? "UPDATE tags SET removed = 1 WHERE book = ? AND tag = ?"
                                       : "DELETE FROM tags WHERE book = ? AND tag = ?");
        u.addBindValue(id);
        u.addBindValue(it.key());
        u.exec();
    }
    for (const QString &tag : tags) {
        QSqlQuery u(m_db);
        if (existing.contains(tag.toLower())) {
            u.prepare("UPDATE tags SET removed = 0 WHERE book = ? AND tag = ?");
            u.addBindValue(id);
            u.addBindValue(tag);
        } else {
            u.prepare("INSERT INTO tags (book, tag, source) VALUES (?, ?, 'user')");
            u.addBindValue(id);
            u.addBindValue(tag);
        }
        u.exec();
    }
    reload();
}

static QVariantMap annotationAt(const QSqlQuery &q)
{
    return {
        {"id", q.value(0).toInt()},
        {"kind", q.value(1).toString()},
        {"cfi", q.value(2).toString()},
        {"color", q.value(3).toString()},
        {"style", q.value(4).toString()},
        {"text", q.value(5).toString()},
        {"note", q.value(6).toString()},
        {"chapter", q.value(7).toString()},
        {"fraction", q.value(8).toDouble()},
        {"created", q.value(9).toLongLong()},
        {"updated", q.value(10).toLongLong()},
    };
}

QVariantList Library::annotations(const QString &book) const
{
    QSqlQuery q(m_db);
    q.prepare(R"(SELECT id, kind, cfi, color, style, text, note, chapter, fraction, created, updated
                 FROM annotations WHERE book = ? ORDER BY fraction, created)");
    q.addBindValue(book);
    q.exec();
    QVariantList list;
    while (q.next())
        list.append(annotationAt(q));
    return list;
}

QVariantMap Library::addAnnotation(const QString &book, const QVariantMap &a)
{
    const qint64 now = QDateTime::currentSecsSinceEpoch();
    QSqlQuery q(m_db);
    q.prepare(R"(INSERT INTO annotations (book, kind, cfi, color, style, text, note, chapter, fraction, created, updated)
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?))");
    q.addBindValue(book);
    q.addBindValue(a.value("kind", "highlight"));
    q.addBindValue(a.value("cfi"));
    q.addBindValue(a.value("color"));
    q.addBindValue(a.value("style"));
    q.addBindValue(a.value("text"));
    q.addBindValue(a.value("note"));
    q.addBindValue(a.value("chapter"));
    q.addBindValue(a.value("fraction", 0.0));
    q.addBindValue(now);
    q.addBindValue(now);
    if (!q.exec()) {
        qWarning() << "annotations:" << q.lastError().text();
        return {};
    }
    QVariantMap saved = a;
    saved["id"] = q.lastInsertId().toInt();
    saved["created"] = now;
    saved["updated"] = now;
    return saved;
}

void Library::updateAnnotation(int id, const QVariantMap &changes)
{
    for (const char *field : {"color", "style", "note"}) {
        if (!changes.contains(field))
            continue;
        QSqlQuery q(m_db);
        q.prepare(QStringLiteral("UPDATE annotations SET %1 = ?, updated = ? WHERE id = ?").arg(field));
        q.addBindValue(changes.value(field));
        q.addBindValue(QDateTime::currentSecsSinceEpoch());
        q.addBindValue(id);
        q.exec();
    }
}

void Library::removeAnnotation(int id)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM annotations WHERE id = ?");
    q.addBindValue(id);
    q.exec();
}

QVariantList Library::searchText(const QString &query, bool wholeWords, int limit) const
{
    // The query's words as one FTS phrase; quotes and operators can't get in
    static const QRegularExpression word(R"([\p{L}\p{N}]+)");
    QStringList words;
    for (auto it = word.globalMatch(query); it.hasNext();)
        words.append(it.next().captured());
    if (words.isEmpty())
        return {};
    const QString phrase = '"' + words.join(' ') + '"' + (wholeWords ? QString() : QStringLiteral(" *"));

    QSqlQuery q(m_db);
    q.prepare(R"(SELECT t.book, t.section, t.chapter,
                        snippet(book_text, 3, char(1), char(2), '…', 14),
                        b.title, b.authors, b.cover, b.path
                 FROM book_text t JOIN books b ON b.id = t.book
                 WHERE book_text MATCH ? AND b.missing = 0
                 ORDER BY rank LIMIT ?)");
    q.addBindValue(phrase);
    q.addBindValue(limit);
    if (!q.exec()) {
        qWarning() << "search:" << q.lastError().text();
        return {};
    }
    QVariantList out;
    while (q.next()) {
        // snippet marks the match with \x01 … \x02
        const QString s = q.value(3).toString();
        const int a = s.indexOf(QChar(1)), b = s.indexOf(QChar(2));
        const QString cover = q.value(6).toString();
        out.append(QVariantMap{
            {"book", q.value(0)},
            {"section", q.value(1).toInt()},
            {"chapter", q.value(2).toString()},
            {"before", a < 0 ? s : s.left(a)},
            {"match", a < 0 ? QString() : s.mid(a + 1, b - a - 1)},
            {"after", b < 0 ? QString() : QString(s.mid(b + 1)).remove(QChar(1)).remove(QChar(2))},
            {"title", q.value(4).toString()},
            {"authors", q.value(5).toString()},
            {"cover", cover.isEmpty() ? QString() : QUrl::fromLocalFile(cover).toString()},
            {"path", q.value(7).toString()},
        });
    }
    return out;
}

void Library::copy(const QString &text) const
{
    QGuiApplication::clipboard()->setText(text);
}

int Library::add(const QVariantList &files)
{
    if (m_folders.isEmpty())
        return 0;
    const QString target = m_folders.first();
    QDir().mkpath(target);
    int added = 0;
    for (const QVariant &f : files) {
        const QUrl url(f.toString());
        const QString from = url.isLocalFile() ? url.toLocalFile() : f.toString();
        const QFileInfo fi(from);
        if (!fi.isFile())
            continue;
        // Already in the library: nothing to copy
        bool inside = false;
        for (const QString &folder : m_folders)
            if (fi.absoluteFilePath().startsWith(QDir(folder).absolutePath() + "/"))
                inside = true;
        if (inside) {
            ++added;
            continue;
        }
        // "Author - Title.epub", from what the book says, else its name
        QString name = fi.completeBaseName();
        if (const auto info = Epub::read(from); info && !info->title.isEmpty())
            name = info->authors.isEmpty() ? info->title : info->authors.first() + " - " + info->title;
        name.replace(QRegularExpression(R"([/\\:*?"<>|\x00-\x1f])"), "_");
        QString to = target + "/" + name + ".epub";
        for (int n = 2; QFileInfo::exists(to); ++n)
            to = QStringLiteral("%1/%2 (%3).epub").arg(target, name).arg(n);
        if (QFile::copy(from, to))
            ++added;
        else
            qWarning() << "library: can't copy" << from << "to" << to;
    }
    if (added)
        rescan();
    return added;
}
