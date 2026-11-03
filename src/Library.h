#pragma once

#include <QObject>
#include <QQmlEngine>
#include <QSqlDatabase>
#include <QVariantMap>

// The books Dogear knows, in SQLite at $XDG_DATA_HOME/dogear/library.db.
// A book's id is the SHA-256 of its file, so its place and progress
// survive the file being renamed or moved.
//
// Phase 1 keeps only what reading needs: where each book is and where you
// were in it. The library proper (folders, scanning, metadata) comes next.
class Library : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    // The book given on the command line, if any
    Q_PROPERTY(QString startFile READ startFile CONSTANT)

public:
    explicit Library(QObject *parent = nullptr);

    static void setStartFile(const QString &path) { s_startFile = path; }
    QString startFile() const { return s_startFile; }

    // The file served as dogear://app/book/<id>; empty if not opened
    static QString fileFor(const QString &id);

    // Open a file (a path or file:// URL): { ok, id, url, position,
    // fraction } or { ok: false, error }
    Q_INVOKABLE QVariantMap open(const QString &pathOrUrl);
    // The most recently opened book's path that still exists, or ""
    Q_INVOKABLE QString lastBook() const;
    Q_INVOKABLE void saveProgress(const QString &id, const QString &position, double fraction);
    Q_INVOKABLE void saveDetails(const QString &id, const QString &title, const QString &authors);

private:
    bool migrate();

    QSqlDatabase m_db;
    static QString s_startFile;
};
