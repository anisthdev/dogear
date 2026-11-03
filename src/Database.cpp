#include "Database.h"

#include <QDir>
#include <QFileInfo>
#include <QImage>
#include <QPainter>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>

namespace {

bool migrate(QSqlDatabase &db)
{
    QSqlQuery q(db);
    q.exec("PRAGMA journal_mode=WAL");
    q.exec("PRAGMA busy_timeout=5000");
    q.exec("PRAGMA user_version");
    const int version = q.next() ? q.value(0).toInt() : 0;
    if (version < 1) {
        if (!q.exec(R"(CREATE TABLE books (
                id TEXT PRIMARY KEY,      -- SHA-256 of the file
                path TEXT NOT NULL,
                title TEXT,
                authors TEXT,
                position TEXT,            -- EPUB CFI
                fraction REAL NOT NULL DEFAULT 0,
                added_at INTEGER NOT NULL,
                opened_at INTEGER
            ))"))
            return false;
        q.exec("PRAGMA user_version = 1");
    }
    if (version < 2) {
        // The library: what the file is (to skip unchanged ones on a
        // rescan), what the EPUB says, and whether it's still there
        const char *columns[] = {
            "size INTEGER", "mtime INTEGER", "scanned INTEGER NOT NULL DEFAULT 0",
            "missing INTEGER NOT NULL DEFAULT 0", "authors_sort TEXT", "language TEXT",
            "description TEXT", "publisher TEXT", "published TEXT", "isbn TEXT",
            "series TEXT", "series_index REAL", "cover TEXT",
        };
        for (const char *column : columns) {
            if (!q.exec(QStringLiteral("ALTER TABLE books ADD COLUMN ") + column))
                return false;
        }
        q.exec("PRAGMA user_version = 2");
    }
    if (version < 3) {
        // Series from three places, kept apart so a rescan never undoes a
        // hand edit: the EPUB's (series), the folder's (a numbered file in
        // a subfolder) and the user's (NULL: not set; '': no series)
        const char *columns[] = {
            "folder_series TEXT", "folder_series_index REAL",
            "user_series TEXT", "user_series_index REAL",
        };
        for (const char *column : columns) {
            if (!q.exec(QStringLiteral("ALTER TABLE books ADD COLUMN ") + column))
                return false;
        }
        // Tags: the book's subjects (source 'book') and the user's ('user').
        // Removing a book's own tag marks it removed, so rescans keep it off.
        if (!q.exec(R"(CREATE TABLE tags (
                book TEXT NOT NULL,
                tag TEXT NOT NULL COLLATE NOCASE,
                source TEXT NOT NULL,
                removed INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (book, tag)
            ))"))
            return false;
        q.exec("PRAGMA user_version = 3");
    }
    return true;
}

} // namespace

QSqlDatabase Database::connect(const QString &name)
{
    if (QSqlDatabase::contains(name))
        return QSqlDatabase::database(name);
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/dogear";
    QDir().mkpath(dir);
    QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", name);
    db.setDatabaseName(dir + "/library.db");
    if (!db.open() || !migrate(db))
        qWarning() << "library database:" << db.lastError().text();
    return db;
}

QString Database::coverPath(const QString &id)
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + "/dogear/covers/" + id + ".jpg";
}

QString Database::saveCover(const QString &id, const QByteArray &image)
{
    const QString path = coverPath(id);
    if (QFileInfo::exists(path))
        return path;
    QImage img = QImage::fromData(image);
    if (img.isNull())
        return {};
    // Enough for a big grid cell on a HiDPI screen
    if (img.height() > 720)
        img = img.scaledToHeight(720, Qt::SmoothTransformation);
    if (img.hasAlphaChannel()) {
        QImage flat(img.size(), QImage::Format_RGB32);
        flat.fill(Qt::white);
        QPainter(&flat).drawImage(0, 0, img);
        img = flat;
    }
    QDir().mkpath(QFileInfo(path).absolutePath());
    return img.save(path, "JPG", 88) ? path : QString();
}
