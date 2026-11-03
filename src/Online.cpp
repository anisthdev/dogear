#include "Online.h"

#include <QDateTime>
#include <QJsonArray>
#include <QJsonObject>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSqlError>
#include <QSqlQuery>
#include <QUrlQuery>

#include "Database.h"

namespace {

// Open Library asks clients to say who they are; no personal details
const QByteArray userAgent = "Dogear/" DOGEAR_VERSION " (ebook reader; https://github.com/anisthdev/dogear)";

QString text(const QJsonValue &v)
{
    // Open Library gives text either as a string or as { type, value }
    if (v.isObject())
        return v.toObject().value("value").toString();
    return v.toString();
}

QStringList strings(const QJsonValue &v)
{
    QStringList out;
    for (const QJsonValue &x : v.toArray())
        if (!x.toString().isEmpty())
            out.append(x.toString());
    return out;
}

QString year(const QString &date)
{
    static const QRegularExpression four(R"(\b(1[5-9]\d\d|20\d\d)\b)");
    const auto m = four.match(date);
    return m.hasMatch() ? m.captured(1) : QString();
}

} // namespace

Online::Online(QObject *parent)
    : QObject(parent)
{
    m_db = Database::connect("online");
    // Gentle on Open Library: one request at a time, a little apart
    m_pace.setSingleShot(true);
    m_pace.setInterval(350);
    connect(&m_pace, &QTimer::timeout, this, [this] {
        m_busy = false;
        pump();
    });
}

void Online::getBytes(const QUrl &url, std::function<void(const QByteArray &, int)> done)
{
    m_queue.enqueue({url, std::move(done)});
    pump();
}

void Online::get(const QUrl &url, Reply done, bool front)
{
    Job job{url, [done](const QByteArray &body, int status) {
                done(status == 200 ? QJsonDocument::fromJson(body) : QJsonDocument(), status);
            }};
    if (front)
        m_queue.prepend(job);
    else
        m_queue.enqueue(job);
    pump();
}

void Online::pump()
{
    if (m_busy || m_queue.isEmpty())
        return;
    m_busy = true;
    const Job job = m_queue.dequeue();
    QNetworkRequest request(job.url);
    request.setHeader(QNetworkRequest::UserAgentHeader, userAgent);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(20000);
    QNetworkReply *reply = m_nam.get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply, job] {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        reply->deleteLater();
        job.done(body, reply->error() == QNetworkReply::NoError || status ? status : -1);
        m_pace.start();
    });
}

void Online::autoMatch()
{
    if (!m_enabled)
        return;
    QSqlQuery q(m_db);
    // With a Google key, books Open Library alone didn't know ('none') get
    // one more try; Google's answer, found or not, ends it ('none-google')
    q.exec(m_googleKey.isEmpty()
               ? R"(SELECT id, isbn FROM books
                    WHERE missing = 0 AND online_checked IS NULL AND isbn IS NOT NULL AND isbn <> '')"
               : R"(SELECT id, isbn FROM books
                    WHERE missing = 0 AND isbn IS NOT NULL AND isbn <> '' AND online_key IS NULL
                      AND (online_checked IS NULL OR online_status = 'none'))");
    QList<QPair<QString, QString>> todo;
    while (q.next())
        todo.append({q.value(0).toString(), q.value(1).toString()});
    // Books with no ISBN: nothing to look up by; they wait for the review
    QSqlQuery none(m_db);
    none.exec(R"(UPDATE books SET online_checked = strftime('%s'), online_status = 'none'
                 WHERE missing = 0 AND online_checked IS NULL AND (isbn IS NULL OR isbn = ''))");
    for (const auto &[book, isbn] : todo) {
        // Marked first, so a second scan doesn't queue it again
        markChecked(book, "pending");
        lookupIsbn(book, isbn);
    }
}

void Online::markChecked(const QString &book, const QString &status)
{
    QSqlQuery q(m_db);
    q.prepare("UPDATE books SET online_checked = ?, online_status = ? WHERE id = ?");
    q.addBindValue(QDateTime::currentSecsSinceEpoch());
    q.addBindValue(status);
    q.addBindValue(book);
    q.exec();
}

void Online::lookupIsbn(const QString &book, const QString &isbn)
{
    get(QUrl("https://openlibrary.org/isbn/" + isbn + ".json"), [this, book, isbn](const QJsonDocument &doc, int status) {
        if (status != 200 || !doc.isObject()) {
            if (!m_googleKey.isEmpty())
                googleIsbn(book, isbn);
            else
                markChecked(book, status == 404 ? "none" : "error"), emit changed();
            return;
        }
        const QJsonObject e = doc.object();
        const QJsonArray works = e.value("works").toArray();
        const QJsonArray covers = e.value("covers").toArray();
        QVariantMap c{
            {"source", "openlibrary"},
            {"key", works.isEmpty() ? QString() : works.first().toObject().value("key").toString()},
            {"title", e.value("title").toString()},
            {"year", year(e.value("publish_date").toString())},
            {"published", e.value("publish_date").toString()},
            {"publisher", strings(e.value("publishers")).value(0)},
            {"isbn", isbn},
            {"coverId", covers.isEmpty() || covers.first().toInt() <= 0 ? 0 : covers.first().toInt()},
        };
        // The edition names its authors by key only
        const QJsonArray authors = e.value("authors").toArray();
        const QString authorKey = authors.isEmpty() ? QString() : authors.first().toObject().value("key").toString();
        if (authorKey.isEmpty()) {
            apply(book, c, false);
            return;
        }
        get(QUrl("https://openlibrary.org" + authorKey + ".json"), [this, book, c](const QJsonDocument &a, int) mutable {
            const QString name = a.object().value("name").toString();
            if (!name.isEmpty())
                c["authors"] = QStringList{name};
            apply(book, c, false);
        });
    });
}

void Online::googleIsbn(const QString &book, const QString &isbn)
{
    QUrl url("https://www.googleapis.com/books/v1/volumes");
    url.setQuery({{"q", "isbn:" + isbn}, {"key", m_googleKey}});
    get(url, [this, book](const QJsonDocument &doc, int status) {
        const QJsonArray items = doc.object().value("items").toArray();
        if (status != 200 || items.isEmpty()) {
            markChecked(book, status == 200 ? "none-google" : "error");
            emit changed();
            return;
        }
        apply(book, fromGoogle(items.first().toObject()), false);
    });
}

QVariantMap Online::fromGoogle(const QJsonObject &item)
{
    const QJsonObject v = item.value("volumeInfo").toObject();
    QString isbn;
    for (const QJsonValue &id : v.value("industryIdentifiers").toArray()) {
        const QJsonObject o = id.toObject();
        if (o.value("type").toString() == "ISBN_13" || (isbn.isEmpty() && o.value("type").toString() == "ISBN_10"))
            isbn = o.value("identifier").toString();
    }
    QString cover = v.value("imageLinks").toObject().value("thumbnail").toString();
    cover.replace("http://", "https://");
    // Categories come as "Fiction / Fantasy / General": the parts are tags
    QStringList subjects;
    for (const QString &c : strings(v.value("categories")))
        subjects += c.split(" / ");
    return {
        {"source", "google"},
        {"key", item.value("id").toString()},
        {"title", v.value("subtitle").toString().isEmpty() ? v.value("title").toString()
                                                            : v.value("title").toString() + ": " + v.value("subtitle").toString()},
        {"authors", strings(v.value("authors"))},
        {"year", year(v.value("publishedDate").toString())},
        {"published", v.value("publishedDate").toString()},
        {"publisher", v.value("publisher").toString()},
        {"isbn", isbn},
        {"cover", cover},
        {"coverLarge", cover.isEmpty() ? QString() : QString(cover).replace("zoom=1", "zoom=3")},
        {"description", v.value("description").toString()},
        {"subjects", subjects},
        {"complete", true},
    };
}

void Online::search(const QString &request, const QString &query)
{
    m_lastSearch = request;
    if (!m_enabled) {
        emit matches(request, {}, "Online details are off ([metadata] online in dogear.conf)");
        return;
    }
    searchOpenLibrary(request, query, 3);
}

void Online::searchOpenLibrary(const QString &request, const QString &query, int retries)
{
    QUrl url("https://openlibrary.org/search.json");
    url.setQuery({{"q", query},
                  {"limit", "12"},
                  {"fields", "key,title,subtitle,author_name,first_publish_year,cover_i,isbn,publisher,subject"}});
    get(url, [this, request, query, retries](const QJsonDocument &doc, int status) {
        if (request != m_lastSearch)
            return;
        // Every word has to match; a subtitle or a name spelled another way
        // finds nothing, so fewer words are tried
        const QStringList words = query.split(' ', Qt::SkipEmptyParts);
        if (status == 200 && doc.object().value("docs").toArray().isEmpty() && retries > 0 && words.size() > 2) {
            searchOpenLibrary(request, words.mid(0, words.size() - 1).join(' '), retries - 1);
            return;
        }
        QVariantList found;
        for (const QJsonValue &d : doc.object().value("docs").toArray()) {
            const QJsonObject o = d.toObject();
            const int cover = o.value("cover_i").toInt();
            found.append(QVariantMap{
                {"source", "openlibrary"},
                {"key", o.value("key").toString()},
                {"title", o.value("title").toString()},
                {"authors", strings(o.value("author_name"))},
                {"year", o.contains("first_publish_year") ? QString::number(o.value("first_publish_year").toInt()) : QString()},
                // A search finds the work, with every edition's publishers
                // and ISBNs mixed: none of them is this book's
                {"work", true},
                {"coverId", cover},
                {"cover", cover > 0 ? QStringLiteral("https://covers.openlibrary.org/b/id/%1-M.jpg").arg(cover) : QString()},
            });
        }
        if (m_googleKey.isEmpty()) {
            emit matches(request, found, status == 200 || !found.isEmpty() ? QString() : "Open Library didn't answer");
            return;
        }
        QUrl g("https://www.googleapis.com/books/v1/volumes");
        g.setQuery({{"q", query}, {"maxResults", "8"}, {"key", m_googleKey}});
        get(g, [this, request, found](const QJsonDocument &doc, int) mutable {
            if (request != m_lastSearch)
                return;
            for (const QJsonValue &item : doc.object().value("items").toArray())
                found.append(fromGoogle(item.toObject()));
            emit matches(request, found, QString());
        }, true);
    }, true);
}

void Online::apply(const QString &book, const QVariantMap &c, bool byHand)
{
    const QString status = byHand ? "picked" : "isbn";
    // Open Library's description and subjects live on the work
    if (c.value("source") == "openlibrary" && !c.value("complete").toBool() && !c.value("key").toString().isEmpty()) {
        get(QUrl("https://openlibrary.org" + c.value("key").toString() + ".json"),
            [this, book, c, status](const QJsonDocument &doc, int code) {
                QVariantMap full = c;
                const QJsonObject w = doc.object();
                full["description"] = text(w.value("description"));
                full["subjects"] = strings(w.value("subjects"));
                if (full.value("coverId").toInt() <= 0) {
                    const QJsonArray covers = w.value("covers").toArray();
                    if (!covers.isEmpty() && covers.first().toInt() > 0)
                        full["coverId"] = covers.first().toInt();
                }
                if (code != 200 && code != 404) {
                    emit applied(book, false, "Open Library didn't answer");
                    markChecked(book, "error");
                    return;
                }
                store(book, full, status);
            },
            byHand);
        return;
    }
    store(book, c, status);
}

QStringList Online::cleanSubjects(const QStringList &subjects, const QString &language)
{
    // Open Library's subjects are many libraries' headings, in their own
    // order ("Vampires" can come before "Fantasy" for Harry Potter). Kept:
    // the genres named in them, then (if there aren't two) a few topics.
    static const QList<std::pair<QRegularExpression, QString>> genres = [] {
        QList<std::pair<QRegularExpression, QString>> g;
        const QList<std::pair<const char *, const char *>> names{
            {R"(\bfantasy\b)", "Fantasy"},
            {R"(science fiction|\bsci-fi\b)", "Science fiction"},
            {R"(\bdystopia)", "Dystopia"},
            {R"(\b(mystery|detective)\b)", "Mystery"},
            {R"(\bthriller|suspense)", "Thriller"},
            {R"(\bhorror\b)", "Horror"},
            {R"(\bromance\b|love stories)", "Romance"},
            {R"(historical fiction|history.*fiction)", "Historical fiction"},
            {R"(\bclassics?\b)", "Classics"},
            {R"(\bbiograph|memoir|autobiograph)", "Biography"},
            {R"(\bhumou?r\b)", "Humour"},
            {R"(\bpoetry\b)", "Poetry"},
            {R"(\bphilosophy\b)", "Philosophy"},
            {R"(^history$|^(world|military|social) history$)", "History"},
            {R"(^(popular )?science$|^natural history$)", "Science"},
            {R"(^psychology$|^applied psychology$)", "Psychology"},
            {R"(\bself-help|personal development)", "Self-help"},
            {R"(^business|^business & economics$|^management$)", "Business"},
            {R"(\beconomics?\b)", "Economics"},
            {R"(computer|programming|software|databases?\b|distributed systems)", "Computing"},
            {R"(juvenile|children'?s|young adult)", "Young readers"},
        };
        for (const auto &[re, name] : names)
            g.append({QRegularExpression(re, QRegularExpression::CaseInsensitiveOption), name});
        return g;
    }();
    static const QRegularExpression junk(
        R"(electronic books|accessible book|protected daisy|in library|lending library|large type|open library|staff picks|overdrive|^nyt:|^series:|reading level|award|bestseller|translations|^ebook|^fiction$|general$|^juvenile|^long now|^american|^english)",
        QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression foreign(R"(\b(de|da|do|das|dos|van|und|der|die|het|la|le|les|des|del|y|e)\b|^\S{16,}$)",
                                            QRegularExpression::CaseInsensitiveOption);

    QStringList out;
    auto add = [&](const QString &t) {
        if (!out.contains(t, Qt::CaseInsensitive))
            out.append(t);
    };
    // A genre counts when it's named twice or more (or the list is short):
    // one stray heading ("Psychology" from a study of the book) doesn't
    QHash<QString, int> counts;
    QStringList order;
    for (const QString &s : subjects)
        for (const auto &[re, name] : genres)
            if (re.match(s).hasMatch()) {
                if (!counts.contains(name))
                    order.append(name);
                ++counts[name];
            }
    const int need = subjects.size() > 20 ? 2 : 1;
    for (const QString &name : order)
        if (counts.value(name) >= need)
            add(name);
    // Genres found: those are the tags. Otherwise a few of its topics.
    if (!out.isEmpty())
        return out.mid(0, 6);
    for (QString s : subjects) {
        s = s.section(" -- ", 0, 0).trimmed();
        s.remove(QRegularExpression(R"((,\s*|\s+in\s+)(juvenile\s+)?fiction$)", QRegularExpression::CaseInsensitiveOption));
        if (s.isEmpty() || s.size() > 30 || s.count(' ') > 2 || junk.match(s).hasMatch()
            || s.contains(QRegularExpression(R"([(),:;/\[\]\d])")))
            continue;
        if (language.startsWith("en") && (s.contains(QRegularExpression(R"([^\x00-\x7f])")) || foreign.match(s).hasMatch()))
            continue;
        s = s.toLower();
        s[0] = s[0].toUpper();
        add(s);
        if (out.size() >= 5)
            break;
    }
    return out;
}

void Online::store(const QString &book, const QVariantMap &c, const QString &status)
{
    auto finish = [this, book, c, status](const QString &coverPath) {
        const QStringList authors = c.value("authors").toStringList();
        // From a work (a search), the first published year stands for the
        // date; from an edition (an ISBN), its own publisher and date
        const bool work = c.value("work").toBool();
        const QHash<QString, QString> fields{
            {"title", c.value("title").toString()},
            {"authors", authors.join(", ")},
            {"description", c.value("description").toString()},
            {"publisher", work ? QString() : c.value("publisher").toString()},
            {"published", work || c.value("published").toString().isEmpty() ? c.value("year").toString() : c.value("published").toString()},
            {"isbn", work ? QString() : c.value("isbn").toString()},
            {"cover", coverPath},
        };
        m_db.transaction();
        QSqlQuery d(m_db);
        d.prepare("DELETE FROM book_fields WHERE book = ? AND source = 'online'");
        d.addBindValue(book);
        d.exec();
        for (auto it = fields.cbegin(); it != fields.cend(); ++it) {
            if (it.value().trimmed().isEmpty())
                continue;
            QSqlQuery i(m_db);
            i.prepare("INSERT INTO book_fields (book, field, source, value) VALUES (?, ?, 'online', ?)");
            i.addBindValue(book);
            i.addBindValue(it.key());
            i.addBindValue(it.value().trimmed());
            i.exec();
        }
        // Tags: this match's, replacing an earlier match's; one the user
        // took off stays off
        QSqlQuery t(m_db);
        t.prepare("DELETE FROM tags WHERE book = ? AND source = 'online' AND removed = 0");
        t.addBindValue(book);
        t.exec();
        QSqlQuery lang(m_db);
        lang.prepare("SELECT coalesce(language, '') FROM books WHERE id = ?");
        lang.addBindValue(book);
        lang.exec();
        const QString language = lang.next() ? lang.value(0).toString().toLower() : QString();
        for (const QString &tag : cleanSubjects(c.value("subjects").toStringList(), language.isEmpty() ? "en" : language)) {
            QSqlQuery i(m_db);
            i.prepare("INSERT INTO tags (book, tag, source) VALUES (?, ?, 'online') ON CONFLICT DO NOTHING");
            i.addBindValue(book);
            i.addBindValue(tag);
            i.exec();
        }
        QSqlQuery b(m_db);
        b.prepare("UPDATE books SET online_key = ?, online_status = ?, online_checked = ? WHERE id = ?");
        b.addBindValue(c.value("source").toString() + ":" + c.value("key").toString());
        b.addBindValue(status);
        b.addBindValue(QDateTime::currentSecsSinceEpoch());
        b.addBindValue(book);
        b.exec();
        m_db.commit();
        emit applied(book, true, QString());
        emit changed();
    };

    // The cover, kept beside the EPUB's (which still comes first)
    QString coverUrl = c.value("coverLarge").toString();
    if (coverUrl.isEmpty() && c.value("coverId").toInt() > 0)
        coverUrl = QStringLiteral("https://covers.openlibrary.org/b/id/%1-L.jpg").arg(c.value("coverId").toInt());
    if (coverUrl.isEmpty()) {
        finish({});
        return;
    }
    getBytes(QUrl(coverUrl), [book, finish](const QByteArray &bytes, int status) {
        QString path;
        if (status == 200 && bytes.size() > 1000)
            path = Database::saveCover(book + "-online", bytes, true);
        finish(path);
    });
}

void Online::clear(const QString &book)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM book_fields WHERE book = ? AND source = 'online'");
    q.addBindValue(book);
    q.exec();
    q.prepare("DELETE FROM tags WHERE book = ? AND source = 'online'");
    q.addBindValue(book);
    q.exec();
    q.prepare("UPDATE books SET online_key = NULL, online_status = 'none' WHERE id = ?");
    q.addBindValue(book);
    q.exec();
    emit changed();
}

void Online::skip(const QString &book)
{
    markChecked(book, "skipped");
    emit changed();
}
