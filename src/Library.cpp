#include "Library.h"

#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QRegularExpression>
#include <QSettings>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QUrl>

#include "Database.h"
#include "Epub.h"
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
    connect(m_scanner, &Scanner::finished, this, [this] {
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
                          WHEN folder_series IS NOT NULL THEN 'folder' ELSE '' END
              FROM books WHERE missing = 0)");
    QVariantList books;
    while (q.next()) {
        const QString path = q.value(1).toString();
        const QString cover = q.value(12).toString();
        books.append(QVariantMap{
            {"id", q.value(0)},
            {"path", path},
            // Untitled books go by their file's name
            {"title", q.value(2).toString().isEmpty() ? QFileInfo(path).completeBaseName() : q.value(2).toString()},
            {"authors", q.value(3).toString()},
            {"authorsSort", q.value(4).toString().isEmpty() ? q.value(3).toString() : q.value(4).toString()},
            {"series", q.value(5).toString()},
            {"seriesIndex", q.value(6).toDouble()},
            {"language", q.value(7).toString()},
            {"description", q.value(8).toString()},
            {"publisher", q.value(9).toString()},
            {"published", q.value(10).toString()},
            {"isbn", q.value(11).toString()},
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
        u.prepare(it.value() == "book" ? "UPDATE tags SET removed = 1 WHERE book = ? AND tag = ?"
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
