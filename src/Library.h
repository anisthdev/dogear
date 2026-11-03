#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QQmlEngine>
#include <QSqlDatabase>
#include <QThread>
#include <QTimer>
#include <QVariantList>
#include <QVariantMap>

class Scanner;

// The books Dogear knows, in SQLite ($XDG_DATA_HOME/dogear/library.db),
// as QML sees them. A book's id is the SHA-256 of its file, so its place
// survives the file being renamed or moved.
//
// Books live where they are, in the library folders (`[library] folders`
// in dogear.conf; on first run, whichever of ~/Books, ~/Ebooks, ~/eBooks
// and ~/Documents/Books exist, else a new ~/Books). Scanner reads them on
// its own thread; the folders are watched, so new and moved files show up
// by themselves. Adding books copies them into the first folder.
class Library : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    // The book given on the command line, if any
    Q_PROPERTY(QString startFile READ startFile CONSTANT)
    Q_PROPERTY(QStringList folders READ folders WRITE setFolders NOTIFY foldersChanged)
    // Every book whose file is there: { id, path, title, authors,
    // authorsSort, series, seriesIndex, language, description, publisher,
    // published, isbn, cover, fraction, addedAt, openedAt, seriesSource
    // ("user", "book", "folder" or ""), tags }. The series is the user's
    // if set, else the EPUB's, else the folder's.
    Q_PROPERTY(QVariantList books READ books NOTIFY booksChanged)
    Q_PROPERTY(bool scanning READ scanning NOTIFY scanningChanged)

public:
    explicit Library(QObject *parent = nullptr);
    ~Library() override;

    static void setStartFile(const QString &path) { s_startFile = path; }
    QString startFile() const { return s_startFile; }

    QStringList folders() const { return m_folders; }
    void setFolders(const QStringList &folders);
    QVariantList books() const { return m_books; }
    bool scanning() const { return m_scanning; }

    // The file served as dogear://app/book/<id>; empty if not opened
    static QString fileFor(const QString &id);

    // Open a file (a path or file:// URL), recording it if it's new:
    // { ok, id, path, url, position, fraction } or { ok: false, error }
    Q_INVOKABLE QVariantMap open(const QString &pathOrUrl);
    // The most recently opened book's path that still exists, or ""
    Q_INVOKABLE QString lastBook() const;
    Q_INVOKABLE void saveProgress(const QString &id, const QString &position, double fraction);
    // What the page found, for books the scan couldn't read
    Q_INVOKABLE void saveDetails(const QString &id, const QString &title, const QString &authors);
    // Copy files (paths or file:// URLs) into the first folder; how many
    Q_INVOKABLE int add(const QVariantList &files);
    Q_INVOKABLE void rescan();
    // Set the series of books by hand: `name` "" means none; `indexes`
    // match `ids` (0 for no number). resetSeries goes back to the book's
    // own or the folder's.
    Q_INVOKABLE void setSeries(const QStringList &ids, const QString &name, const QVariantList &indexes);
    Q_INVOKABLE void resetSeries(const QStringList &ids);
    // A book's tags become exactly these; its own (from the EPUB) that are
    // left out are marked removed, so a rescan doesn't bring them back
    Q_INVOKABLE void setTags(const QString &id, const QStringList &tags);

    // A book's highlights and bookmarks, in reading order: { id, kind,
    // cfi, color, style, text, note, chapter, fraction, created, updated }
    Q_INVOKABLE QVariantList annotations(const QString &book) const;
    // Save a new one (fields as above, less id); it back with its id
    Q_INVOKABLE QVariantMap addAnnotation(const QString &book, const QVariantMap &annotation);
    // Change color, style or note
    Q_INVOKABLE void updateAnnotation(int id, const QVariantMap &changes);
    Q_INVOKABLE void removeAnnotation(int id);
    Q_INVOKABLE void copy(const QString &text) const;

signals:
    void foldersChanged();
    void booksChanged();
    void scanningChanged();
    void startScan(const QStringList &folders);

private:
    void reload();
    void watch();
    void setScanning(bool scanning);

    QSqlDatabase m_db;
    QStringList m_folders;
    QVariantList m_books;
    bool m_scanning = false;
    bool m_rescanQueued = false;
    QThread m_thread;
    Scanner *m_scanner = nullptr;
    QFileSystemWatcher m_watcher;
    QTimer m_rescanTimer;
    static QString s_startFile;
};
