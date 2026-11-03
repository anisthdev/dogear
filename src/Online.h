#pragma once

#include <QHash>
#include <QJsonDocument>
#include <QNetworkAccessManager>
#include <QObject>
#include <QQueue>
#include <QSqlDatabase>
#include <QTimer>
#include <QVariantMap>
#include <functional>

// Details of books from the web: Open Library, and Google Books when
// there's an API key (`[metadata] googleKey` in dogear.conf; without one
// Google's shared quota is used up). Nothing here ever changes what the
// book or the user says: what's found is kept as the 'online' source in
// book_fields, and Library decides what shows.
//
// A book with an ISBN Open Library (or Google) knows is matched by itself,
// once (`autoMatch`, after each scan). Others are matched by hand: `search`
// gives candidates, `apply` keeps one.
//
// A candidate: { source: "openlibrary" | "google", key, title, authors
// (list), year, publisher, isbn, cover (a thumbnail URL), coverId,
// description and subjects (Google's come with them; Open Library's are
// fetched on apply) }.
class Online : public QObject
{
    Q_OBJECT

public:
    explicit Online(QObject *parent = nullptr);

    bool enabled() const { return m_enabled; }
    void setEnabled(bool on) { m_enabled = on; }
    void setGoogleKey(const QString &key) { m_googleKey = key; }

    // Look up every book with an ISBN that hasn't been tried
    void autoMatch();
    void search(const QString &request, const QString &query);
    void apply(const QString &book, const QVariantMap &candidate, bool byHand);
    // Forget what was found for a book (back to the book's own details)
    void clear(const QString &book);
    // Leave a book unmatched without asking again in the review
    void skip(const QString &book);

signals:
    void matches(const QString &request, const QVariantList &candidates, const QString &error);
    // A book's details changed
    void changed();
    void applied(const QString &book, bool ok, const QString &error);

private:
    using Reply = std::function<void(const QJsonDocument &, int status)>;
    void get(const QUrl &url, Reply done, bool front = false);
    void getBytes(const QUrl &url, std::function<void(const QByteArray &, int)> done);
    void pump();
    void searchOpenLibrary(const QString &request, const QString &query, int retries);

    void lookupIsbn(const QString &book, const QString &isbn);
    void googleIsbn(const QString &book, const QString &isbn);
    void store(const QString &book, const QVariantMap &details, const QString &status);
    void markChecked(const QString &book, const QString &status);
    static QStringList cleanSubjects(const QStringList &subjects, const QString &language);
    static QVariantMap fromGoogle(const QJsonObject &item);

    QSqlDatabase m_db;
    QNetworkAccessManager m_nam;
    struct Job
    {
        QUrl url;
        std::function<void(const QByteArray &, int)> done;
    };
    QQueue<Job> m_queue;
    QTimer m_pace;
    bool m_busy = false;
    bool m_enabled = true;
    QString m_googleKey;
    // Searches by request id: answers to an older one are dropped
    QString m_lastSearch;
};
