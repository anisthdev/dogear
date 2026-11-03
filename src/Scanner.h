#pragma once

#include <QObject>
#include <QStringList>

// Walks the library folders for EPUBs on its own thread and brings the
// database up to date: new and changed files are hashed and read (title,
// authors, series, cover…), unchanged ones (same path, size and time) are
// skipped, moved ones keep their row (the id is the content's hash) and
// gone ones are marked missing, not dropped, so their progress stays.
class Scanner : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    // Kept in each row's `scanned`; rows read by an older version are read
    // again, so a better reader (say, of authors' names) reaches every book.
    // Bump it whenever Epub::read or what's stored changes.
    static constexpr int version = 5;

    // Hash, read and record one file; its id, or "" if it can't be read.
    // Used by the scan and by Library::open (books outside the folders).
    // `folders` are the library folders, for series inferred from them.
    static QString record(const QString &path, const QString &connection, const QStringList &folders);

public slots:
    void scan(const QStringList &folders);

signals:
    // Some books were added or changed (sent in batches while scanning)
    void changed();
    void finished();
};
