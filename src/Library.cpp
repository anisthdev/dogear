#include "Library.h"

#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QSqlError>
#include <QSqlQuery>
#include <QStandardPaths>
#include <QUrl>

QString Library::s_startFile;

// id -> path for the scheme handler. Both run on the GUI thread.
static QHash<QString, QString> s_files;

QString Library::fileFor(const QString &id)
{
    return s_files.value(id);
}

Library::Library(QObject *parent)
    : QObject(parent)
{
    const QString dir = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/dogear";
    QDir().mkpath(dir);
    m_db = QSqlDatabase::addDatabase("QSQLITE", "library");
    m_db.setDatabaseName(dir + "/library.db");
    if (!m_db.open() || !migrate())
        qWarning() << "library:" << m_db.lastError().text();
}

bool Library::migrate()
{
    QSqlQuery q(m_db);
    q.exec("PRAGMA journal_mode=WAL");
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
    return true;
}

static QString hashFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    QCryptographicHash hash(QCryptographicHash::Sha256);
    if (!hash.addData(&file))
        return {};
    return QString::fromLatin1(hash.result().toHex());
}

QVariantMap Library::open(const QString &pathOrUrl)
{
    const QUrl url(pathOrUrl);
    const QString path = url.isLocalFile() ? url.toLocalFile() : pathOrUrl;
    const QFileInfo info(path);
    if (!info.isFile())
        return {{"ok", false}, {"error", "No such file: " + path}};
    const QString id = hashFile(info.absoluteFilePath());
    if (id.isEmpty())
        return {{"ok", false}, {"error", "Can't read " + path}};

    const qint64 now = QDateTime::currentSecsSinceEpoch();
    QSqlQuery q(m_db);
    q.prepare(R"(INSERT INTO books (id, path, added_at, opened_at) VALUES (?, ?, ?, ?)
                 ON CONFLICT (id) DO UPDATE SET path = excluded.path, opened_at = excluded.opened_at)");
    q.addBindValue(id);
    q.addBindValue(info.absoluteFilePath());
    q.addBindValue(now);
    q.addBindValue(now);
    if (!q.exec())
        qWarning() << "library:" << q.lastError().text();

    q.prepare("SELECT position, fraction FROM books WHERE id = ?");
    q.addBindValue(id);
    q.exec();
    const bool found = q.next();

    s_files.insert(id, info.absoluteFilePath());
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
    q.exec("SELECT path FROM books WHERE opened_at IS NOT NULL ORDER BY opened_at DESC LIMIT 10");
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
}

void Library::saveDetails(const QString &id, const QString &title, const QString &authors)
{
    QSqlQuery q(m_db);
    q.prepare("UPDATE books SET title = ?, authors = ? WHERE id = ?");
    q.addBindValue(title);
    q.addBindValue(authors);
    q.addBindValue(id);
    q.exec();
}
