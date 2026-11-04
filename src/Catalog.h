#pragma once

#include <QCryptographicHash>
#include <QElapsedTimer>
#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QSaveFile>
#include <QSqlDatabase>
#include <QUrl>
#include <QVariantList>
#include <QVariantMap>
#include <functional>
#include <memory>

class QNetworkReply;

// OPDS catalogues: online bookshops and libraries, public ones for now.
// Feeds come as Atom (OPDS 1) or JSON (OPDS 2) and reach QML in one shape,
// parsed here because the fetching is here and the library has no web page
// to run foliate's opds.js in.
//
// A feed: { ok, error, url, title, subtitle, web, next, search, items }.
// `search` is a template, or an OpenSearch description to fetch; pass it
// to search(). An item is one of:
//   { kind: "heading", title }
//   { kind: "nav", title, summary, authors, thumb, url }
//   { kind: "book", id, title, authors (list), summary, cover, thumb,
//     publisher, published, language, tags (list), web, formats, others }
// where formats are the free EPUBs, best first ({ url, title, size }), and
// others name what else is offered ("PDF", "Kindle"). Every URL in a feed
// is checked here: only http(s), so a feed can't point at local files.
class Catalog : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Reached through Library.catalog")
    // The catalogues kept: { url, title }
    Q_PROPERTY(QVariantList catalogs READ catalogs NOTIFY catalogsChanged)
    // In progress, by book id: { title, received, total }
    Q_PROPERTY(QVariantMap downloads READ downloads NOTIFY downloadsChanged)
    // What was downloaded: a feed's book id -> the library's book id
    Q_PROPERTY(QVariantMap held READ held NOTIFY heldChanged)

public:
    explicit Catalog(QObject *parent = nullptr);
    ~Catalog() override;

    // Where downloads go: the first library folder
    void setFolder(const QString &folder) { m_folder = folder; }

    QVariantList catalogs() const { return m_catalogs; }
    QVariantMap downloads() const;
    QVariantMap held() const { return m_held; }

    // One feed at a time: a new load drops the one before. The answer
    // comes as loaded(request, feed).
    Q_INVOKABLE void load(const QString &request, const QString &url);
    Q_INVOKABLE void search(const QString &request, const QString &link, const QString &query);
    Q_INVOKABLE void stop();

    Q_INVOKABLE void add(const QString &url, const QString &title);
    Q_INVOKABLE void rename(const QString &url, const QString &title);
    Q_INVOKABLE void remove(const QString &url);

    // Into the library folder, then the library rescans
    Q_INVOKABLE void download(const QVariantMap &book, const QVariantMap &format);
    Q_INVOKABLE void cancel(const QString &id);

signals:
    void catalogsChanged();
    void downloadsChanged();
    void heldChanged();
    void loaded(const QString &request, const QVariantMap &feed);
    // A download ended, well or not; not said of one cancelled
    void finished(const QString &id, const QString &title, bool ok, const QString &error);
    // There's a new file in the library folder
    void saved();

private:
    struct Job
    {
        QVariantMap book;
        QPointer<QNetworkReply> reply;
        std::unique_ptr<QSaveFile> file;
        QCryptographicHash hash{QCryptographicHash::Sha256};
        QByteArray head;
        QString error;
        qint64 received = 0;
        qint64 total = 0;
        QElapsedTimer shown;
    };
    using Done = std::function<void(const QByteArray &body, const QUrl &url, const QString &error)>;
    void fetch(const QUrl &url, Done done);
    void reloadCatalogs();
    void store(const Job &job, const QString &book);
    void end(const QString &id, bool ok, const QString &error);

    QSqlDatabase m_db;
    QNetworkAccessManager m_nam;
    QPointer<QNetworkReply> m_fetch;
    QVariantList m_catalogs;
    QVariantMap m_held;
    QHash<QString, Job *> m_jobs;
    QString m_folder;
};
