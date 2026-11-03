#include "Scanner.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QRegularExpression>
#include <QSet>
#include <QSqlError>
#include <QSqlQuery>

#include "Database.h"
#include "Epub.h"

namespace {

QString hashFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file))
        return {};
    return QString::fromLatin1(hash.result().toHex());
}

// A numbered book in a subfolder of the library is taken as part of a
// series named after the folder: "Harry Potter/03 Harry Potter and the…",
// "Discworld/Book 4 - Mort.epub". Only with two books or more there, and
// only for numbered files, so a folder of loose books isn't a series.
std::pair<QString, double> folderSeries(const QFileInfo &fi, const QStringList &folders)
{
    const QString dir = fi.absolutePath();
    bool inside = false;
    for (const QString &folder : folders) {
        const QString root = QDir(folder).absolutePath();
        if (dir != root && dir.startsWith(root + "/"))
            inside = true;
    }
    if (!inside)
        return {};
    static const QRegularExpression leading(R"(^\s*(\d{1,3}(?:\.\d)?)(?=[\s._)\]-]))");
    static const QRegularExpression named(R"(\b(?:book|vol(?:ume)?\.?|part|no\.?|#)\s*(\d{1,3}(?:\.\d)?)\b)",
                                          QRegularExpression::CaseInsensitiveOption);
    const QString name = fi.completeBaseName();
    auto m = leading.match(name);
    if (!m.hasMatch())
        m = named.match(name);
    if (!m.hasMatch())
        return {};
    if (QDir(dir).entryList({"*.epub", "*.EPUB"}, QDir::Files).size() < 2)
        return {};
    return {QFileInfo(dir).fileName(), m.captured(1).toDouble()};
}

// For books that don't say what they are: the title (and author) from the
// file's name, less site tags. "System Design Interview An Insider's Guide
// by Alex Xu (z-lib.org)" -> title "System Design Interview An Insider's
// Guide", author "Alex Xu".
std::pair<QString, QString> fromFileName(const QFileInfo &fi)
{
    QString name = fi.completeBaseName();
    name.remove(QRegularExpression(R"(\s*[\(\[][^\)\]]*\.(org|com|net|ru|io)[^\)\]]*[\)\]])", QRegularExpression::CaseInsensitiveOption));
    name.replace('_', ' ');
    name = name.simplified();
    const int by = name.lastIndexOf(" by ", -1, Qt::CaseInsensitive);
    if (by > 0 && name.size() - by < 60)
        return {name.left(by).trimmed(), name.mid(by + 4).trimmed()};
    return {name, {}};
}

QVariant orNull(const QString &s)
{
    return s.isEmpty() ? QVariant(QMetaType::fromType<QString>()) : QVariant(s);
}

} // namespace

QString Scanner::record(const QString &path, const QString &connection, const QStringList &folders)
{
    const QFileInfo fi(path);
    const QString id = hashFile(fi.absoluteFilePath());
    if (id.isEmpty())
        return {};
    auto info = Epub::read(fi.absoluteFilePath());
    if (info && info->title.isEmpty()) {
        const auto [title, author] = fromFileName(fi);
        info->title = title;
        if (info->authors.isEmpty() && !author.isEmpty()) {
            info->authors = {author};
            const int space = author.lastIndexOf(' ');
            info->authorsSort = space > 0 ? author.mid(space + 1) + ", " + author.left(space) : author;
        }
    }
    const QString cover = info ? Database::saveCover(id, info->cover) : QString();
    const auto [folderName, folderIndex] = folderSeries(fi, folders);

    QSqlDatabase db = Database::connect(connection);
    QSqlQuery q(db);
    // A file seen again at a new path (moved, renamed, a second copy)
    // takes over the row; what the EPUB says is refreshed each time
    q.prepare(R"(INSERT INTO books (id, path, size, mtime, scanned, missing, added_at,
                    title, authors, authors_sort, language, description, publisher,
                    published, isbn, series, series_index, cover, folder_series, folder_series_index)
                 VALUES (?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                 ON CONFLICT (id) DO UPDATE SET
                    path = excluded.path, size = excluded.size, mtime = excluded.mtime,
                    scanned = excluded.scanned, missing = 0,
                    title = coalesce(excluded.title, title),
                    authors = coalesce(excluded.authors, authors),
                    authors_sort = excluded.authors_sort, language = excluded.language,
                    description = excluded.description, publisher = excluded.publisher,
                    published = excluded.published, isbn = excluded.isbn,
                    series = excluded.series, series_index = excluded.series_index,
                    cover = excluded.cover, folder_series = excluded.folder_series,
                    folder_series_index = excluded.folder_series_index)");
    q.addBindValue(id);
    q.addBindValue(fi.absoluteFilePath());
    q.addBindValue(fi.size());
    q.addBindValue(fi.lastModified().toSecsSinceEpoch());
    q.addBindValue(version);
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(orNull(info ? info->title : QString()));
    q.addBindValue(orNull(info ? info->authors.join(", ") : QString()));
    q.addBindValue(orNull(info ? info->authorsSort : QString()));
    q.addBindValue(orNull(info ? info->language : QString()));
    q.addBindValue(orNull(info ? info->description : QString()));
    q.addBindValue(orNull(info ? info->publisher : QString()));
    q.addBindValue(orNull(info ? info->published : QString()));
    q.addBindValue(orNull(info ? info->isbn : QString()));
    q.addBindValue(orNull(info ? info->series : QString()));
    q.addBindValue(info && !info->series.isEmpty() ? QVariant(info->seriesIndex) : QVariant(QMetaType::fromType<double>()));
    q.addBindValue(orNull(cover));
    q.addBindValue(orNull(folderName));
    q.addBindValue(folderName.isEmpty() ? QVariant(QMetaType::fromType<double>()) : QVariant(folderIndex));
    if (!q.exec()) {
        qWarning() << "scan:" << path << q.lastError().text();
        return {};
    }

    // The book's own tags: added if new, dropped if the book no longer has
    // them, but a tag the user removed stays removed
    if (info) {
        QSqlQuery t(db);
        t.prepare("SELECT tag FROM tags WHERE book = ? AND source = 'book' AND removed = 0");
        t.addBindValue(id);
        t.exec();
        QStringList stale;
        while (t.next())
            if (!info->subjects.contains(t.value(0).toString(), Qt::CaseInsensitive))
                stale.append(t.value(0).toString());
        for (const QString &tag : stale) {
            QSqlQuery d(db);
            d.prepare("DELETE FROM tags WHERE book = ? AND tag = ? AND source = 'book'");
            d.addBindValue(id);
            d.addBindValue(tag);
            d.exec();
        }
        for (const QString &tag : info->subjects) {
            QSqlQuery i(db);
            i.prepare("INSERT INTO tags (book, tag, source) VALUES (?, ?, 'book') ON CONFLICT DO NOTHING");
            i.addBindValue(id);
            i.addBindValue(tag);
            i.exec();
        }
    }

    // The text, for searching the library: replaced whole, in one go
    {
        const QList<EpubSection> sections = Epub::sections(fi.absoluteFilePath());
        db.transaction();
        QSqlQuery d(db);
        d.prepare("DELETE FROM book_text WHERE book = ?");
        d.addBindValue(id);
        d.exec();
        QSqlQuery i(db);
        i.prepare("INSERT INTO book_text (book, section, chapter, text) VALUES (?, ?, ?, ?)");
        for (const EpubSection &s : sections) {
            i.addBindValue(id);
            i.addBindValue(s.index);
            i.addBindValue(s.chapter);
            i.addBindValue(s.text);
            i.exec();
        }
        db.commit();
    }

    // The file changed in place (its metadata edited elsewhere, say): a
    // new hash, so a new row. It takes the old row's reading, which is
    // then hidden.
    QSqlQuery old(db);
    old.prepare("SELECT id, position, fraction, opened_at FROM books WHERE path = ? AND id <> ? AND missing = 0");
    old.addBindValue(fi.absoluteFilePath());
    old.addBindValue(id);
    old.exec();
    while (old.next()) {
        QSqlQuery carry(db);
        carry.prepare(R"(UPDATE books SET position = coalesce(position, ?),
                            fraction = CASE WHEN opened_at IS NULL THEN ? ELSE fraction END,
                            opened_at = coalesce(opened_at, ?) WHERE id = ?)");
        carry.addBindValue(old.value(1));
        carry.addBindValue(old.value(2));
        carry.addBindValue(old.value(3));
        carry.addBindValue(id);
        carry.exec();
        QSqlQuery hide(db);
        hide.prepare("UPDATE books SET missing = 1 WHERE id = ?");
        hide.addBindValue(old.value(0));
        hide.exec();
    }
    return id;
}

void Scanner::scan(const QStringList &folders)
{
    const QString connection = "scanner";
    QSqlDatabase db = Database::connect(connection);

    struct Known
    {
        qint64 size, mtime;
        int scanned;
    };
    QHash<QString, Known> known;
    {
        QSqlQuery q(db);
        q.exec("SELECT path, size, mtime, scanned FROM books");
        while (q.next())
            known.insert(q.value(0).toString(), {q.value(1).toLongLong(), q.value(2).toLongLong(), q.value(3).toInt()});
    }

    QSet<QString> seen;
    QElapsedTimer sinceChange;
    sinceChange.start();
    bool pending = false;
    for (const QString &folder : folders) {
        QDirIterator it(folder, {"*.epub", "*.EPUB"}, QDir::Files | QDir::Readable,
                        QDirIterator::Subdirectories | QDirIterator::FollowSymlinks);
        while (it.hasNext()) {
            const QFileInfo fi(it.next());
            const QString path = fi.absoluteFilePath();
            if (seen.contains(path))
                continue;
            seen.insert(path);
            const auto k = known.constFind(path);
            if (k != known.cend() && k->scanned >= version && k->size == fi.size()
                && k->mtime == fi.lastModified().toSecsSinceEpoch())
                continue;
            if (!record(path, connection, folders).isEmpty())
                pending = true;
            // Show books as they come in, without redrawing for each
            if (pending && sinceChange.elapsed() > 700) {
                emit changed();
                pending = false;
                sinceChange.restart();
            }
        }
    }

    // Rows whose file is gone: kept (with their progress) but hidden; a
    // file that's back (or found again elsewhere) clears it
    QSqlQuery q(db);
    q.exec("SELECT id, path, missing FROM books");
    QList<QPair<QString, bool>> updates;
    while (q.next()) {
        const bool gone = !seen.contains(q.value(1).toString()) && !QFileInfo::exists(q.value(1).toString());
        if (gone != q.value(2).toBool())
            updates.append({q.value(0).toString(), gone});
    }
    for (const auto &[id, gone] : updates) {
        QSqlQuery u(db);
        u.prepare("UPDATE books SET missing = ? WHERE id = ?");
        u.addBindValue(gone ? 1 : 0);
        u.addBindValue(id);
        u.exec();
    }
    if (pending || !updates.isEmpty())
        emit changed();
    emit finished();
}
