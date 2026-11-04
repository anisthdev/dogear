#include "Catalog.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QRegularExpression>
#include <QSqlQuery>
#include <QTextDocumentFragment>
#include <QXmlStreamReader>
#include <algorithm>

#include "Database.h"

namespace {

const QByteArray userAgent = "Dogear/" DOGEAR_VERSION " (ebook reader; https://github.com/anisthdev/dogear)";
const QString acquisition = "http://opds-spec.org/acquisition";
// Feeds are text: anything bigger than this isn't one
const qint64 feedLimit = 32 * 1024 * 1024;

bool safe(const QUrl &url)
{
    return url.isValid() && (url.scheme() == "http" || url.scheme() == "https") && !url.host().isEmpty();
}

// A link of a feed made absolute; "" if it isn't http(s)
QString absolute(const QUrl &base, const QString &href)
{
    const QUrl url = base.resolved(QUrl(href.trimmed()));
    return safe(url) ? url.toString(QUrl::FullyEncoded) : QString();
}

// Images may also come inside the feed
QString image(const QUrl &base, const QString &href)
{
    return href.startsWith("data:image/") ? href : absolute(base, href);
}

// Paragraphs with blank lines between them and no other line breaks
QString tidy(const QString &text)
{
    static const QRegularExpression breaks(R"(\n\s*\n)");
    QStringList out;
    for (const QString &p : text.split(breaks, Qt::SkipEmptyParts))
        if (const QString s = p.simplified(); !s.isEmpty())
            out.append(s);
    return out.join("\n\n");
}

QString fromHtml(const QString &html)
{
    return tidy(QTextDocumentFragment::fromHtml(html).toPlainText().replace(QChar('\n'), "\n\n"));
}

QString yearOf(const QString &date)
{
    static const QRegularExpression four(R"(\b(\d{4})\b)");
    return four.match(date).captured(1);
}

// "Shelley, Mary" -> "Mary Shelley"; Library does the same to its own
QString person(const QString &name)
{
    const QStringList parts = name.split(", ");
    return parts.size() == 2 ? parts[1].simplified() + " " + parts[0].simplified() : name.simplified();
}

// Project Gutenberg's entries are a page of "Label: value" lines with the
// summary among them: just that, then
QString prose(const QString &text)
{
    for (const QString &p : text.split("\n\n"))
        if (p.startsWith("Summary: "))
            return p.mid(9);
    return text;
}

struct Link
{
    QStringList rels;
    QString href;
    QString type;
    QString title;
    qint64 size = 0;
};

// What Atom and JSON both say of an entry
struct Entry
{
    QString id, title, summary, publisher, published, language;
    QStringList authors, tags;
    QList<Link> links;
    QString cover, thumb;
};

bool isFeed(const Link &l)
{
    return l.type.startsWith("application/atom+xml") || l.type.startsWith("application/opds+json");
}

bool isFree(const QString &rel)
{
    return rel == acquisition || rel == acquisition + "/open-access";
}

bool offers(const Link &l)
{
    return std::any_of(l.rels.begin(), l.rels.end(), [](const QString &r) { return r.startsWith(acquisition); });
}

bool gratis(const Link &l)
{
    return std::any_of(l.rels.begin(), l.rels.end(), isFree);
}

QString formatName(const QString &type)
{
    static const QHash<QString, QString> names{
        {"application/pdf", "PDF"},
        {"application/x-mobipocket-ebook", "Kindle"},
        {"application/vnd.amazon.ebook", "Kindle"},
        {"application/x-mobi8-ebook", "Kindle"},
        {"application/x-fictionbook+xml", "FB2"},
        {"application/fb2+zip", "FB2"},
        {"application/vnd.comicbook+zip", "CBZ"},
        {"application/x-cbz", "CBZ"},
        {"text/html", "Web page"},
        {"text/plain", "Text"},
    };
    return names.value(type.section(';', 0, 0).trimmed().toLower());
}

// Lower first: whole books before ones without pictures, new before old
int rank(const QString &title, const QString &url)
{
    const QString s = (title + " " + url).toLower();
    return (s.contains("no images") || s.contains("noimages") ? 2 : 0) + (s.contains("older") ? 1 : 0);
}

QVariantMap toBook(const Entry &e)
{
    QVariantList formats;
    QStringList others;
    QString web;
    QList<Link> epubs;
    for (const Link &l : e.links) {
        if (l.rels.contains("alternate") && l.type.startsWith("text/html") && web.isEmpty())
            web = l.href;
        if (!offers(l))
            continue;
        const bool epub = l.type.startsWith("application/epub+zip")
            || (l.type.isEmpty() && QUrl(l.href).path().endsWith(".epub", Qt::CaseInsensitive));
        if (epub && gratis(l)) {
            epubs.append(l);
        } else if (const QString name = epub ? QStringLiteral("EPUB, not free") : formatName(l.type);
                   !name.isEmpty() && !others.contains(name)) {
            others.append(name);
        }
    }
    std::stable_sort(epubs.begin(), epubs.end(), [](const Link &a, const Link &b) {
        return rank(a.title, a.href) < rank(b.title, b.href);
    });
    for (const Link &l : epubs)
        formats.append(QVariantMap{{"url", l.href}, {"title", l.title.isEmpty() ? "EPUB" : l.title}, {"size", l.size}});
    return {
        {"kind", "book"},
        {"id", !e.id.isEmpty() ? e.id : epubs.isEmpty() ? e.title : epubs.first().href},
        {"title", e.title},
        {"authors", e.authors},
        {"summary", prose(e.summary)},
        {"cover", e.cover.isEmpty() ? e.thumb : e.cover},
        {"thumb", e.thumb.isEmpty() ? e.cover : e.thumb},
        {"publisher", e.publisher},
        {"published", yearOf(e.published)},
        {"language", e.language},
        {"tags", e.tags},
        {"web", web},
        {"formats", formats},
        {"others", others},
    };
}

// A catalogue's page of one book can list its editions as separate
// entries (Project Gutenberg: with and without pictures). One book, then.
QVariantList mergeEditions(const QVariantList &books)
{
    QVariantList out;
    QHash<QString, int> seen;
    for (const QVariant &v : books) {
        QVariantMap b = v.toMap();
        const QString key = b["title"].toString().toLower() + '\n' + b["authors"].toStringList().join(',').toLower();
        const auto at = seen.constFind(key);
        if (at == seen.constEnd()) {
            seen.insert(key, out.size());
            out.append(b);
            continue;
        }
        QVariantMap first = out[*at].toMap();
        QVariantList formats = first["formats"].toList();
        for (const QVariant &f : b["formats"].toList())
            if (std::none_of(formats.begin(), formats.end(), [&](const QVariant &g) { return g.toMap()["url"] == f.toMap()["url"]; }))
                formats.append(f);
        std::stable_sort(formats.begin(), formats.end(), [](const QVariant &a, const QVariant &b) {
            return rank(a.toMap()["title"].toString(), a.toMap()["url"].toString())
                < rank(b.toMap()["title"].toString(), b.toMap()["url"].toString());
        });
        first["formats"] = formats;
        QStringList others = first["others"].toStringList() + b["others"].toStringList();
        others.removeDuplicates();
        first["others"] = others;
        out[*at] = first;
    }
    return out;
}

// One section of a feed
struct Group
{
    QString title, url;
    QVariantList nav, books;
};

QVariantList flatten(const QList<Group> &groups)
{
    QVariantList items;
    for (const Group &g : groups) {
        const QVariantList books = mergeEditions(g.books);
        if (g.nav.isEmpty() && books.isEmpty() && g.url.isEmpty())
            continue;
        if (!g.title.isEmpty())
            items.append(QVariantMap{{"kind", "heading"}, {"title", g.title}});
        items.append(g.nav);
        items.append(books);
        if (!g.url.isEmpty())
            items.append(QVariantMap{{"kind", "nav"}, {"title", "See all"}, {"url", g.url}});
    }
    return items;
}

// ------ Atom (OPDS 1)

// What's inside the current element, as text. XHTML's blocks become
// paragraphs.
QString richText(QXmlStreamReader &xml)
{
    QString out;
    for (int depth = 1; depth > 0 && !xml.atEnd();) {
        switch (xml.readNext()) {
        case QXmlStreamReader::Characters:
            out += xml.text();
            break;
        case QXmlStreamReader::StartElement:
            ++depth;
            break;
        case QXmlStreamReader::EndElement:
            --depth;
            if (xml.name() == u"p" || xml.name() == u"div" || xml.name() == u"li" || xml.name() == u"br")
                out += "\n\n";
            break;
        default:
            break;
        }
    }
    return out;
}

QString content(QXmlStreamReader &xml)
{
    const QString type = xml.attributes().value("type").toString();
    const QString text = richText(xml);
    return type == "html" || type == "text/html" ? fromHtml(text) : tidy(text);
}

Link readLink(QXmlStreamReader &xml, const QUrl &base)
{
    const auto a = xml.attributes();
    Link l;
    l.rels = a.value("rel").toString().split(' ', Qt::SkipEmptyParts);
    l.type = a.value("type").toString().toLower();
    l.title = a.value("title").toString();
    l.size = a.value("length").toLongLong();
    const QString href = a.value("href").toString();
    l.href = l.type.startsWith("image/") ? image(base, href) : absolute(base, href);
    // Prices and such inside it
    xml.skipCurrentElement();
    return l;
}

Entry readEntry(QXmlStreamReader &xml, const QUrl &base)
{
    static const QStringList covers{"http://opds-spec.org/image", "http://opds-spec.org/cover", "x-stanza-cover-image"};
    static const QStringList thumbs{"http://opds-spec.org/image/thumbnail", "http://opds-spec.org/thumbnail", "x-stanza-cover-image-thumbnail"};
    Entry e;
    QString summary;
    while (xml.readNextStartElement()) {
        const QString name = xml.name().toString();
        if (name == "id") {
            e.id = xml.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
        } else if (name == "title") {
            e.title = richText(xml).simplified();
        } else if (name == "author") {
            while (xml.readNextStartElement())
                if (xml.name() == u"name")
                    e.authors.append(person(xml.readElementText(QXmlStreamReader::IncludeChildElements)));
                else
                    xml.skipCurrentElement();
        } else if (name == "content") {
            e.summary = content(xml);
        } else if (name == "summary") {
            summary = content(xml);
        } else if (name == "publisher") {
            e.publisher = xml.readElementText(QXmlStreamReader::IncludeChildElements).simplified();
        } else if (name == "issued" || (name == "published" && e.published.isEmpty()) || (name == "date" && e.published.isEmpty())) {
            e.published = xml.readElementText(QXmlStreamReader::IncludeChildElements);
        } else if (name == "language") {
            e.language = xml.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
        } else if (name == "category") {
            const auto a = xml.attributes();
            const QString tag = !a.value("label").isEmpty() ? a.value("label").toString() : a.value("term").toString();
            if (!tag.isEmpty() && !tag.startsWith("http") && !e.tags.contains(tag))
                e.tags.append(tag);
            xml.skipCurrentElement();
        } else if (name == "link") {
            const Link l = readLink(xml, base);
            if (l.href.isEmpty())
                continue;
            if (std::any_of(covers.begin(), covers.end(), [&](const QString &r) { return l.rels.contains(r); }))
                e.cover = l.href;
            else if (std::any_of(thumbs.begin(), thumbs.end(), [&](const QString &r) { return l.rels.contains(r); }))
                e.thumb = l.href;
            else
                e.links.append(l);
        } else {
            xml.skipCurrentElement();
        }
    }
    if (e.summary.isEmpty())
        e.summary = summary;
    return e;
}

void addEntry(Group &group, const Entry &e)
{
    const bool isBook = std::any_of(e.links.begin(), e.links.end(), [](const Link &l) {
        return offers(l) || l.rels.contains("preview");
    });
    if (isBook) {
        group.books.append(toBook(e));
        return;
    }
    // ManyBooks' search results call their feeds text/html: with no feed
    // link, a link with no rel is taken as the way in
    auto place = std::find_if(e.links.begin(), e.links.end(), [](const Link &l) {
        return isFeed(l) && !l.rels.contains("related");
    });
    if (place == e.links.end())
        place = std::find_if(e.links.begin(), e.links.end(), [](const Link &l) { return l.rels.isEmpty(); });
    if (place == e.links.end())
        return;
    group.nav.append(QVariantMap{
        {"kind", "nav"},
        {"title", e.title},
        {"summary", e.summary},
        {"authors", e.authors},
        {"thumb", e.thumb.isEmpty() ? e.cover : e.thumb},
        {"url", place->href},
    });
}

QVariantMap parseAtom(const QByteArray &body, const QUrl &base)
{
    QXmlStreamReader xml(body);
    if (!xml.readNextStartElement() || xml.name() != u"feed")
        return {{"ok", false}, {"error", "That isn't a catalogue"}};
    QVariantMap feed{{"ok", true}, {"url", base.toString(QUrl::FullyEncoded)}};
    QList<Group> groups{Group{}};
    while (xml.readNextStartElement()) {
        const QString name = xml.name().toString();
        if (name == "title") {
            feed["title"] = richText(xml).simplified();
        } else if (name == "subtitle") {
            feed["subtitle"] = richText(xml).simplified();
        } else if (name == "link") {
            const QString rel = xml.attributes().value("rel").toString();
            const QString href = xml.attributes().value("href").toString();
            if (rel == "search" && href.contains('{')) {
                // A template: QUrl would escape its braces
                const int brace = href.indexOf('{');
                feed["search"] = absolute(base, href.left(brace)) + href.mid(brace);
                xml.skipCurrentElement();
                continue;
            }
            const Link l = readLink(xml, base);
            if (l.href.isEmpty())
                continue;
            if (l.rels.contains("next"))
                feed["next"] = l.href;
            else if (l.rels.contains("search") && !feed.contains("search"))
                feed["search"] = l.href;
            else if (l.rels.contains("alternate") && l.type.startsWith("text/html"))
                feed["web"] = l.href;
        } else if (name == "entry") {
            const Entry e = readEntry(xml, base);
            // Sections: an entry says which one by a link
            const auto group = std::find_if(e.links.begin(), e.links.end(), [](const Link &l) {
                return l.rels.contains("http://opds-spec.org/group") || l.rels.contains("collection");
            });
            if (group == e.links.end() || std::none_of(e.links.begin(), e.links.end(), offers)) {
                addEntry(groups.first(), e);
                continue;
            }
            auto at = std::find_if(groups.begin(), groups.end(), [&](const Group &g) { return g.url == group->href; });
            if (at == groups.end()) {
                groups.append(Group{group->title, group->href, {}, {}});
                at = groups.end() - 1;
            }
            addEntry(*at, e);
        } else {
            xml.skipCurrentElement();
        }
    }
    if (xml.hasError() && !feed.contains("title"))
        return {{"ok", false}, {"error", "That isn't a catalogue"}};
    feed["items"] = flatten(groups);
    return feed;
}

// ------ JSON (OPDS 2)

// A string, or { "en": "…" } of its languages
QString textOf(const QJsonValue &v)
{
    if (v.isObject() && !v.toObject().isEmpty())
        return v.toObject().begin()->toString();
    return v.toString();
}

QJsonArray listOf(const QJsonValue &v)
{
    if (v.isArray())
        return v.toArray();
    return v.isUndefined() || v.isNull() ? QJsonArray() : QJsonArray{v};
}

QStringList namesOf(const QJsonValue &v)
{
    QStringList out;
    for (const QJsonValue &x : listOf(v))
        if (const QString s = x.isObject() ? textOf(x.toObject().value("name")) : x.toString(); !s.isEmpty())
            out.append(s);
    return out;
}

QList<Link> linksOf(const QJsonValue &v, const QUrl &base)
{
    QList<Link> out;
    for (const QJsonValue &x : v.toArray()) {
        const QJsonObject o = x.toObject();
        Link l;
        for (const QJsonValue &r : listOf(o.value("rel")))
            l.rels.append(r.toString());
        l.href = absolute(base, o.value("href").toString());
        l.type = o.value("type").toString().toLower();
        l.title = o.value("title").toString();
        l.size = o.value("properties").toObject().value("size").toVariant().toLongLong();
        if (!l.href.isEmpty())
            out.append(l);
    }
    return out;
}

QVariantList readNavigation(const QJsonValue &v, const QUrl &base)
{
    QVariantList out;
    for (const Link &l : linksOf(v, base))
        out.append(QVariantMap{{"kind", "nav"}, {"title", l.title}, {"url", l.href}});
    return out;
}

QVariantList readPublications(const QJsonValue &v, const QUrl &base)
{
    QVariantList out;
    for (const QJsonValue &x : v.toArray()) {
        const QJsonObject o = x.toObject();
        const QJsonObject m = o.value("metadata").toObject();
        Entry e;
        e.id = m.value("identifier").toString();
        e.title = textOf(m.value("title")).simplified();
        for (const QString &a : namesOf(m.value("author")))
            e.authors.append(person(a));
        e.summary = fromHtml(m.value("description").toString());
        e.publisher = namesOf(m.value("publisher")).join(", ");
        e.published = m.value("published").toString();
        e.language = namesOf(m.value("language")).value(0);
        e.tags = namesOf(m.value("subject"));
        e.links = linksOf(o.value("links"), base);
        // Smallest and largest of the images
        int small = 0, large = 0;
        for (const QJsonValue &i : o.value("images").toArray()) {
            const QString href = image(base, i.toObject().value("href").toString());
            const int width = i.toObject().value("width").toInt(1);
            if (href.isEmpty())
                continue;
            if (e.thumb.isEmpty() || width < small) {
                e.thumb = href;
                small = width;
            }
            if (e.cover.isEmpty() || width > large) {
                e.cover = href;
                large = width;
            }
        }
        out.append(toBook(e));
    }
    return out;
}

QVariantMap parseJson(const QByteArray &body, const QUrl &base)
{
    const QJsonObject root = QJsonDocument::fromJson(body).object();
    if (!root.contains("metadata") || !(root.contains("navigation") || root.contains("publications") || root.contains("groups")))
        return {{"ok", false}, {"error", "That isn't a catalogue"}};
    QVariantMap feed{
        {"ok", true},
        {"url", base.toString(QUrl::FullyEncoded)},
        {"title", textOf(root.value("metadata").toObject().value("title"))},
        {"subtitle", textOf(root.value("metadata").toObject().value("subtitle"))},
    };
    for (const QJsonValue &x : root.value("links").toArray()) {
        const QJsonObject o = x.toObject();
        QStringList rels;
        for (const QJsonValue &r : listOf(o.value("rel")))
            rels.append(r.toString());
        const QString href = o.value("href").toString();
        if (rels.contains("search") && !feed.contains("search")) {
            const int brace = href.indexOf('{');
            feed["search"] = brace < 0 ? absolute(base, href) : absolute(base, href.left(brace)) + href.mid(brace);
        } else if (rels.contains("next")) {
            feed["next"] = absolute(base, href);
        }
    }
    QList<Group> groups{Group{{}, {}, readNavigation(root.value("navigation"), base), readPublications(root.value("publications"), base)}};
    for (const QJsonValue &x : root.value("groups").toArray()) {
        const QJsonObject o = x.toObject();
        Group g;
        g.title = textOf(o.value("metadata").toObject().value("title"));
        for (const Link &l : linksOf(o.value("links"), base))
            if (l.rels.contains("self"))
                g.url = l.href;
        g.nav = readNavigation(o.value("navigation"), base);
        g.books = readPublications(o.value("publications"), base);
        groups.append(g);
    }
    feed["items"] = flatten(groups);
    return feed;
}

// An OpenSearch description: the template that answers with a feed
QString readOpenSearch(const QByteArray &body, const QUrl &base)
{
    QXmlStreamReader xml(body);
    if (!xml.readNextStartElement())
        return {};
    QString best, any;
    while (xml.readNextStartElement()) {
        if (xml.name() == u"Url") {
            const QString type = xml.attributes().value("type").toString();
            const QString t = xml.attributes().value("template").toString();
            if (type.contains("opds-catalog") || (best.isEmpty() && (type.startsWith("application/atom+xml") || type.startsWith("application/opds+json"))))
                best = t;
            else if (any.isEmpty() && !type.startsWith("text/html") && !type.contains("suggestions"))
                any = t;
        }
        xml.skipCurrentElement();
    }
    const QString t = best.isEmpty() ? any : best;
    const int brace = t.indexOf('{');
    return brace < 0 ? QString() : absolute(base, t.left(brace)) + t.mid(brace);
}

// {searchTerms}, {?query}, {count?}: OpenSearch's and URI templates'
QUrl fillTemplate(const QString &t, const QString &query)
{
    static const QRegularExpression slot(R"(\{([?&]?)([^}]*)\})");
    const QByteArray terms = QUrl::toPercentEncoding(query);
    QString out;
    qsizetype last = 0;
    for (auto it = slot.globalMatch(t); it.hasNext();) {
        const auto m = it.next();
        out += t.mid(last, m.capturedStart() - last);
        last = m.capturedEnd();
        QString name = m.captured(2);
        const QString start = m.captured(1);
        if (!start.isEmpty()) {
            // A URI template's {?a,b}: the first term that's the query
            const QStringList names = name.split(',');
            const QString q = names.contains("query") ? "query" : names.contains("q") ? "q" : names.first();
            out += start + q + "=" + QString::fromLatin1(terms);
            continue;
        }
        name.remove('?');
        name = name.section(':', -1);
        if (name == "searchTerms" || name == "query" || name == "q")
            out += QString::fromLatin1(terms);
        else if (name == "count")
            out += "50";
        else if (name == "startPage")
            out += "1";
        else if (name == "startIndex")
            out += "0";
    }
    return QUrl(out + t.mid(last));
}

QString filename(const QVariantMap &book)
{
    static const QRegularExpression bad(R"([/\\:*?"<>|\x00-\x1f])");
    const QStringList authors = book["authors"].toStringList();
    QString name = book["title"].toString();
    if (!authors.isEmpty())
        name = authors.first() + " - " + name;
    name.replace(bad, "_");
    name = name.simplified().left(150);
    while (name.startsWith('.'))
        name.remove(0, 1);
    return name.isEmpty() ? QStringLiteral("Book") : name;
}

} // namespace

Catalog::Catalog(QObject *parent)
    : QObject(parent)
{
    m_db = Database::connect("catalog");
    reloadCatalogs();
    QSqlQuery q(m_db);
    q.exec("SELECT entry, book FROM catalog_books");
    while (q.next())
        m_held[q.value(0).toString()] = q.value(1);
}

Catalog::~Catalog()
{
    for (Job *job : std::as_const(m_jobs)) {
        if (job->reply) {
            job->reply->disconnect(this);
            job->reply->abort();
        }
        // The QSaveFile takes its unfinished file with it
        delete job;
    }
}

void Catalog::reloadCatalogs()
{
    m_catalogs.clear();
    QSqlQuery q(m_db);
    q.exec("SELECT url, title FROM catalogs ORDER BY position, rowid");
    while (q.next())
        m_catalogs.append(QVariantMap{{"url", q.value(0)}, {"title", q.value(1)}});
    emit catalogsChanged();
}

void Catalog::add(const QString &url, const QString &title)
{
    QSqlQuery q(m_db);
    q.prepare("INSERT OR REPLACE INTO catalogs (url, title, position) "
              "VALUES (?, ?, (SELECT coalesce(max(position), 0) + 1 FROM catalogs))");
    q.addBindValue(url);
    q.addBindValue(title);
    q.exec();
    reloadCatalogs();
}

void Catalog::rename(const QString &url, const QString &title)
{
    QSqlQuery q(m_db);
    q.prepare("UPDATE catalogs SET title = ? WHERE url = ?");
    q.addBindValue(title);
    q.addBindValue(url);
    q.exec();
    reloadCatalogs();
}

void Catalog::remove(const QString &url)
{
    QSqlQuery q(m_db);
    q.prepare("DELETE FROM catalogs WHERE url = ?");
    q.addBindValue(url);
    q.exec();
    reloadCatalogs();
}

void Catalog::stop()
{
    if (m_fetch) {
        m_fetch->disconnect(this);
        m_fetch->abort();
        m_fetch->deleteLater();
    }
    m_fetch = nullptr;
}

void Catalog::fetch(const QUrl &url, Done done)
{
    stop();
    if (!safe(url)) {
        done({}, url, "That isn't a web address");
        return;
    }
    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::UserAgentHeader, userAgent);
    request.setRawHeader("Accept", "application/opds+json, application/atom+xml;q=0.9, application/xml;q=0.8, */*;q=0.5");
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(30000);
    QNetworkReply *reply = m_nam.get(request);
    m_fetch = reply;
    connect(reply, &QNetworkReply::downloadProgress, this, [reply](qint64 received, qint64) {
        if (received > feedLimit)
            reply->abort();
    });
    connect(reply, &QNetworkReply::finished, this, [this, reply, done] {
        reply->deleteLater();
        m_fetch = nullptr;
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        QString error;
        if (status == 401 || status == 403)
            error = "This catalogue doesn't let Dogear in";
        else if (status >= 400)
            error = QStringLiteral("The catalogue said no (%1)").arg(status);
        else if (reply->error() != QNetworkReply::NoError)
            error = "Couldn't reach the catalogue";
        done(error.isEmpty() ? reply->readAll() : QByteArray(), reply->url(), error);
    });
}

void Catalog::load(const QString &request, const QString &url)
{
    fetch(QUrl(url), [this, request](const QByteArray &body, const QUrl &at, const QString &error) {
        if (!error.isEmpty()) {
            emit loaded(request, {{"ok", false}, {"error", error}});
            return;
        }
        const bool json = body.trimmed().startsWith('{');
        emit loaded(request, json ? parseJson(body, at) : parseAtom(body, at));
    });
}

void Catalog::search(const QString &request, const QString &link, const QString &query)
{
    if (link.contains('{')) {
        load(request, fillTemplate(link, query).toString(QUrl::FullyEncoded));
        return;
    }
    fetch(QUrl(link), [this, request, query](const QByteArray &body, const QUrl &at, const QString &error) {
        const QString t = error.isEmpty() ? readOpenSearch(body, at) : QString();
        if (t.isEmpty())
            emit loaded(request, {{"ok", false}, {"error", error.isEmpty() ? "This catalogue's search doesn't work" : error}});
        else
            load(request, fillTemplate(t, query).toString(QUrl::FullyEncoded));
    });
}

QVariantMap Catalog::downloads() const
{
    QVariantMap out;
    for (auto it = m_jobs.begin(); it != m_jobs.end(); ++it)
        out[it.key()] = QVariantMap{{"title", it.value()->book["title"]}, {"received", it.value()->received}, {"total", it.value()->total}};
    return out;
}

void Catalog::download(const QVariantMap &book, const QVariantMap &format)
{
    const QString id = book["id"].toString();
    const QString title = book["title"].toString();
    const QUrl url(format["url"].toString());
    if (m_jobs.contains(id))
        return;
    if (!safe(url) || m_folder.isEmpty()) {
        emit finished(id, title, false, "Nowhere to get it from");
        return;
    }
    QDir().mkpath(m_folder);
    const QString name = filename(book);
    QString to = m_folder + "/" + name + ".epub";
    for (int n = 2; QFileInfo::exists(to); ++n)
        to = QStringLiteral("%1/%2 (%3).epub").arg(m_folder, name).arg(n);

    auto *job = new Job;
    job->book = book;
    // Its name while unfinished doesn't end in .epub, so no scan sees it
    job->file = std::make_unique<QSaveFile>(to);
    job->file->setDirectWriteFallback(false);
    if (!job->file->open(QIODevice::WriteOnly)) {
        delete job;
        emit finished(id, title, false, "Can't write in the library folder");
        return;
    }
    job->shown.start();
    m_jobs.insert(id, job);

    QNetworkRequest request(url);
    request.setHeader(QNetworkRequest::UserAgentHeader, userAgent);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::NoLessSafeRedirectPolicy);
    request.setTransferTimeout(60000);
    QNetworkReply *reply = m_nam.get(request);
    job->reply = reply;
    emit downloadsChanged();

    connect(reply, &QNetworkReply::readyRead, this, [job, reply] {
        const QByteArray chunk = reply->readAll();
        // A catalogue's error page isn't a book; an EPUB is a zip
        if (job->head.size() < 4) {
            job->head += chunk.left(4 - job->head.size());
            if (job->head.size() == 4 && job->head != QByteArray("PK\x03\x04", 4)) {
                job->error = "That wasn't an EPUB";
                reply->abort();
                return;
            }
        }
        job->hash.addData(chunk);
        job->received += chunk.size();
        if (job->file->write(chunk) != chunk.size()) {
            job->error = "Can't write in the library folder";
            reply->abort();
        }
    });
    connect(reply, &QNetworkReply::downloadProgress, this, [this, job](qint64, qint64 total) {
        job->total = total;
        if (job->shown.elapsed() > 150) {
            job->shown.restart();
            emit downloadsChanged();
        }
    });
    connect(reply, &QNetworkReply::finished, this, [this, id, job, reply] {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError || job->head.size() < 4) {
            const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
            job->file->cancelWriting();
            end(id, false, !job->error.isEmpty() ? job->error : status >= 400 ? QStringLiteral("The catalogue said no (%1)").arg(status) : QStringLiteral("The download stopped"));
            return;
        }
        const QString book = QString::fromLatin1(job->hash.result().toHex());
        // A book's id is its content's hash: this very file may be here
        QSqlQuery q(m_db);
        q.prepare("SELECT 1 FROM books WHERE id = ? AND missing = 0");
        q.addBindValue(book);
        q.exec();
        if (q.next()) {
            job->file->cancelWriting();
        } else if (!job->file->commit()) {
            end(id, false, "Can't write in the library folder");
            return;
        }
        store(*job, book);
        end(id, true, {});
    });
}

void Catalog::store(const Job &job, const QString &book)
{
    const QString entry = job.book["id"].toString();
    QSqlQuery q(m_db);
    q.prepare("INSERT OR REPLACE INTO catalog_books (entry, book) VALUES (?, ?)");
    q.addBindValue(entry);
    q.addBindValue(book);
    q.exec();
    // What the catalogue said, for what the book doesn't say itself
    const QHash<QString, QString> said{{"description", job.book["summary"].toString()}, {"publisher", job.book["publisher"].toString()}};
    for (auto it = said.begin(); it != said.end(); ++it) {
        if (it.value().isEmpty())
            continue;
        q.prepare("INSERT OR REPLACE INTO book_fields (book, field, source, value) VALUES (?, ?, 'catalog', ?)");
        q.addBindValue(book);
        q.addBindValue(it.key());
        q.addBindValue(it.value());
        q.exec();
    }
    m_held[entry] = book;
    emit heldChanged();
    emit saved();
}

void Catalog::end(const QString &id, bool ok, const QString &error)
{
    Job *job = m_jobs.take(id);
    if (!job)
        return;
    const QString title = job->book["title"].toString();
    delete job;
    emit downloadsChanged();
    emit finished(id, title, ok, error);
}

void Catalog::cancel(const QString &id)
{
    Job *job = m_jobs.take(id);
    if (!job)
        return;
    if (job->reply) {
        job->reply->disconnect(this);
        job->reply->abort();
        job->reply->deleteLater();
    }
    delete job;
    emit downloadsChanged();
}
