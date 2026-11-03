#include "Epub.h"

#include <QFile>
#include <QHash>
#include <QRegularExpression>
#include <QSet>
#include <QUrl>
#include <QXmlStreamReader>
#include <zip.h>

namespace {

class Zip
{
public:
    explicit Zip(const QString &path)
    {
        int error = 0;
        m_zip = zip_open(QFile::encodeName(path).constData(), ZIP_RDONLY, &error);
    }
    ~Zip()
    {
        if (m_zip)
            zip_discard(m_zip);
    }
    bool ok() const { return m_zip != nullptr; }

    // A member's bytes, or nothing; refuses anything over `limit`
    std::optional<QByteArray> read(const QString &name, qint64 limit = 32 << 20) const
    {
        zip_stat_t st;
        zip_stat_init(&st);
        const QByteArray n = name.toUtf8();
        if (zip_stat(m_zip, n.constData(), ZIP_FL_ENC_GUESS, &st) != 0 || !(st.valid & ZIP_STAT_SIZE)
            || st.size > quint64(limit))
            return std::nullopt;
        zip_file_t *file = zip_fopen(m_zip, n.constData(), ZIP_FL_ENC_GUESS);
        if (!file)
            return std::nullopt;
        QByteArray data(qsizetype(st.size), Qt::Uninitialized);
        const zip_int64_t got = zip_fread(file, data.data(), st.size);
        zip_fclose(file);
        if (got != zip_int64_t(st.size))
            return std::nullopt;
        return data;
    }

private:
    zip_t *m_zip = nullptr;
};

// The OPF's path, from META-INF/container.xml
QString rootFile(const Zip &zip)
{
    const auto container = zip.read("META-INF/container.xml");
    if (!container)
        return {};
    QXmlStreamReader xml(*container);
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement() && xml.name() == u"rootfile") {
            const auto type = xml.attributes().value("media-type");
            if (type.isEmpty() || type == u"application/oebps-package+xml")
                return xml.attributes().value("full-path").toString();
        }
    }
    return {};
}

// A manifest href, relative to the OPF, as a path in the zip
QString resolve(const QString &opfPath, const QString &href)
{
    const QString dir = opfPath.contains('/') ? opfPath.left(opfPath.lastIndexOf('/') + 1) : QString();
    const QString decoded = QUrl::fromPercentEncoding(href.toUtf8()).section('#', 0, 0);
    QStringList parts;
    for (const QString &part : (dir + decoded).split('/')) {
        if (part == "..") {
            if (!parts.isEmpty())
                parts.removeLast();
        } else if (!part.isEmpty() && part != ".") {
            parts.append(part);
        }
    }
    return parts.join('/');
}

QString isbnOf(const QString &value, const QString &scheme)
{
    QString digits = value;
    digits.remove(QRegularExpression("^urn:isbn:", QRegularExpression::CaseInsensitiveOption));
    digits.remove(QRegularExpression("[\\s-]"));
    static const QRegularExpression isbn13("^97[89]\\d{10}$"), isbn10("^\\d{9}[\\dXx]$");
    if (isbn13.match(digits).hasMatch())
        return digits;
    if (isbn10.match(digits).hasMatch() && (scheme.compare("isbn", Qt::CaseInsensitive) == 0 || value.startsWith("urn:isbn:", Qt::CaseInsensitive)))
        return digits.toUpper();
    return {};
}

// "J. K. Rowling" -> "Rowling, J. K."
QString sortName(const QString &name)
{
    if (name.contains(','))
        return name;
    const int space = name.lastIndexOf(' ');
    return space > 0 ? name.mid(space + 1) + ", " + name.left(space) : name;
}

struct Manifest
{
    QString href;
    QString type;
    QString properties;
};

} // namespace

std::optional<EpubInfo> Epub::read(const QString &path)
{
    Zip zip(path);
    if (!zip.ok())
        return std::nullopt;
    const QString opfPath = rootFile(zip);
    const auto opf = opfPath.isEmpty() ? std::nullopt : zip.read(opfPath);
    if (!opf)
        return std::nullopt;

    EpubInfo info;
    QHash<QString, Manifest> manifest;
    QString coverId;
    QString coverByProperty;
    QString collectionId;
    // EPUB 3 refinements: id -> property -> value
    QHash<QString, QHash<QString, QString>> refines;
    // Creators in order, with their ids and roles
    struct Creator
    {
        QString id, name, role, fileAs;
    };
    QList<Creator> creators;

    QXmlStreamReader xml(*opf);
    bool inMetadata = false;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isEndElement() && xml.name() == u"metadata")
            inMetadata = false;
        if (!xml.isStartElement())
            continue;
        const auto name = xml.name();
        const auto attrs = xml.attributes();
        if (name == u"metadata") {
            inMetadata = true;
        } else if (name == u"item") {
            manifest.insert(attrs.value("id").toString(),
                            {attrs.value("href").toString(), attrs.value("media-type").toString(),
                             attrs.value("properties").toString()});
            if (attrs.value("properties").contains(u"cover-image"))
                coverByProperty = attrs.value("id").toString();
        } else if (inMetadata && name == u"meta") {
            const QString metaName = attrs.value("name").toString();
            const QString content = attrs.value("content").toString();
            const QString property = attrs.value("property").toString();
            if (metaName == "cover")
                coverId = content;
            else if (metaName == "calibre:series")
                info.series = content;
            else if (metaName == "calibre:series_index")
                info.seriesIndex = content.toDouble();
            else if (!property.isEmpty()) {
                const QString refined = attrs.value("refines").toString().remove(0, 1);
                const QString id = attrs.value("id").toString();
                const QString text = xml.readElementText().trimmed();
                if (!refined.isEmpty())
                    refines[refined][property] = text;
                else if (property == "belongs-to-collection") {
                    collectionId = id;
                    if (info.series.isEmpty())
                        info.series = text;
                }
            }
        } else if (inMetadata) {
            const QString id = attrs.value("id").toString();
            const QString scheme = attrs.value("scheme").toString();
            const QString role = attrs.value("role").toString();
            const QString fileAs = attrs.value("file-as").toString();
            const QString text = xml.readElementText(QXmlStreamReader::IncludeChildElements).trimmed();
            if (name == u"title" && info.title.isEmpty())
                info.title = text;
            else if (name == u"creator")
                creators.append({id, text, role, fileAs});
            else if (name == u"language" && info.language.isEmpty())
                info.language = text;
            else if (name == u"description" && info.description.isEmpty())
                info.description = text;
            else if (name == u"publisher" && info.publisher.isEmpty())
                info.publisher = text;
            else if (name == u"date" && info.published.isEmpty())
                info.published = text;
            else if (name == u"identifier" && info.isbn.isEmpty())
                info.isbn = isbnOf(text, scheme);
            else if (name == u"subject") {
                for (QString part : text.split(QRegularExpression("[,;]"))) {
                    part = part.simplified();
                    if (!part.isEmpty() && part.size() <= 60
                        && !info.subjects.contains(part, Qt::CaseInsensitive))
                        info.subjects.append(part);
                }
            }
        }
    }
    if (xml.hasError() && info.title.isEmpty())
        return std::nullopt;

    // Authors: creators whose role (attribute, or EPUB 3 refinement) is
    // the author's or unstated
    QStringList sorts;
    for (const Creator &c : creators) {
        const QString role = !c.role.isEmpty() ? c.role : refines.value(c.id).value("role");
        if (!role.isEmpty() && role != "aut")
            continue;
        if (c.name.isEmpty())
            continue;
        QString shown = c.name;
        // Some books give the sort form ("Kleppmann, Martin") as the name
        static const QRegularExpression inverted(R"(^([^,]+),\s*([^,]+)$)");
        if (const auto m = inverted.match(c.name); m.hasMatch() && !m.captured(2).contains(QRegularExpression(R"(^(Jr|Sr|[IVX]+)\.?$)")))
            shown = m.captured(2) + " " + m.captured(1);
        info.authors.append(shown);
        const QString fileAs = !c.fileAs.isEmpty() ? c.fileAs : refines.value(c.id).value("file-as");
        sorts.append(!fileAs.isEmpty() ? fileAs : sortName(c.name));
    }
    info.authorsSort = sorts.join(" & ");
    if (!collectionId.isEmpty()) {
        const QString position = refines.value(collectionId).value("group-position");
        if (!position.isEmpty())
            info.seriesIndex = position.toDouble();
    }

    // Cover: EPUB 3's cover-image item, else EPUB 2's <meta name="cover">
    // (an item id, or now and then a path), else an image named cover
    QString coverHref;
    if (manifest.contains(coverByProperty))
        coverHref = manifest.value(coverByProperty).href;
    else if (manifest.contains(coverId))
        coverHref = manifest.value(coverId).href;
    else if (!coverId.isEmpty() && coverId.contains('.'))
        coverHref = coverId;
    else {
        for (const Manifest &m : manifest) {
            if (m.type.startsWith("image/") && m.href.contains("cover", Qt::CaseInsensitive)) {
                coverHref = m.href;
                break;
            }
        }
    }
    if (!coverHref.isEmpty()) {
        if (const auto bytes = zip.read(resolve(opfPath, coverHref), 16 << 20))
            info.cover = *bytes;
    }
    return info;
}

namespace {

// Text of an (X)HTML document: character data outside head, script and
// style, with a space after each block so words don't run together. Not
// well-formed? Tags stripped by pattern instead.
QString textOf(const QByteArray &html)
{
    static const QSet<QString> blocks = {"p", "div", "br", "li", "h1", "h2", "h3", "h4", "h5", "h6",
                                         "tr", "td", "th", "blockquote", "section", "article", "dd", "dt",
                                         "pre", "figcaption", "aside", "header", "footer", "hr", "title"};
    QString out;
    out.reserve(html.size() / 2);
    QXmlStreamReader xml(html);
    int skip = 0;
    while (!xml.atEnd()) {
        xml.readNext();
        if (xml.isStartElement()) {
            const auto n = xml.name();
            if (n == u"head" || n == u"script" || n == u"style")
                ++skip;
        } else if (xml.isEndElement()) {
            const auto n = xml.name();
            if (n == u"head" || n == u"script" || n == u"style")
                --skip;
            else if (blocks.contains(n.toString()))
                out += ' ';
        } else if (xml.isCharacters() && skip == 0) {
            out += xml.text();
        }
    }
    if (xml.hasError() && xml.error() != QXmlStreamReader::PrematureEndOfDocumentError) {
        QString s = QString::fromUtf8(html);
        static const QRegularExpression drop(R"(<(head|script|style)\b.*?</\1>)",
                                             QRegularExpression::DotMatchesEverythingOption | QRegularExpression::CaseInsensitiveOption);
        static const QRegularExpression tags("<[^>]*>");
        s.remove(drop);
        s.replace(tags, " ");
        out = s;
    }
    return out.simplified();
}

// href (in the zip, no fragment) -> chapter label, from EPUB 3's nav or
// EPUB 2's NCX; the first label pointing into a file wins
QHash<QString, QString> chapters(const Zip &zip, const QString &opfPath, const QString &navHref, const QString &ncxHref)
{
    QHash<QString, QString> out;
    auto note = [&](const QString &base, const QString &href, const QString &label) {
        const QString file = resolve(base, href);
        if (!label.trimmed().isEmpty() && !out.contains(file))
            out.insert(file, label.simplified());
    };
    if (!navHref.isEmpty()) {
        const QString navPath = resolve(opfPath, navHref);
        if (const auto nav = zip.read(navPath)) {
            QXmlStreamReader xml(*nav);
            bool inToc = false;
            while (!xml.atEnd()) {
                xml.readNext();
                if (xml.isStartElement() && xml.name() == u"nav")
                    inToc = xml.attributes().value("http://www.idpf.org/2007/ops", "type").contains(u"toc");
                else if (xml.isEndElement() && xml.name() == u"nav")
                    inToc = false;
                else if (inToc && xml.isStartElement() && xml.name() == u"a") {
                    const QString href = xml.attributes().value("href").toString();
                    note(navPath, href, xml.readElementText(QXmlStreamReader::IncludeChildElements));
                }
            }
        }
    }
    if (out.isEmpty() && !ncxHref.isEmpty()) {
        const QString ncxPath = resolve(opfPath, ncxHref);
        if (const auto ncx = zip.read(ncxPath)) {
            QXmlStreamReader xml(*ncx);
            QString label;
            while (!xml.atEnd()) {
                xml.readNext();
                if (!xml.isStartElement())
                    continue;
                if (xml.name() == u"text")
                    label = xml.readElementText();
                else if (xml.name() == u"content")
                    note(ncxPath, xml.attributes().value("src").toString(), label);
            }
        }
    }
    return out;
}

} // namespace

QList<EpubSection> Epub::sections(const QString &path)
{
    Zip zip(path);
    if (!zip.ok())
        return {};
    const QString opfPath = rootFile(zip);
    const auto opf = opfPath.isEmpty() ? std::nullopt : zip.read(opfPath);
    if (!opf)
        return {};

    QHash<QString, Manifest> manifest;
    QStringList spine;
    QString navHref, ncxId;
    QXmlStreamReader xml(*opf);
    while (!xml.atEnd()) {
        xml.readNext();
        if (!xml.isStartElement())
            continue;
        const auto attrs = xml.attributes();
        if (xml.name() == u"item") {
            const QString id = attrs.value("id").toString();
            manifest.insert(id, {attrs.value("href").toString(), attrs.value("media-type").toString(),
                                 attrs.value("properties").toString()});
            if (attrs.value("properties").contains(u"nav"))
                navHref = attrs.value("href").toString();
        } else if (xml.name() == u"spine") {
            ncxId = attrs.value("toc").toString();
        } else if (xml.name() == u"itemref") {
            spine.append(attrs.value("idref").toString());
        }
    }
    const QHash<QString, QString> labels = chapters(zip, opfPath, navHref, manifest.value(ncxId).href);

    QList<EpubSection> out;
    QString chapter;
    for (int i = 0; i < spine.size(); ++i) {
        const Manifest m = manifest.value(spine.at(i));
        const QString file = resolve(opfPath, m.href);
        // A section with no contents entry of its own carries on the last
        chapter = labels.value(file, chapter);
        if (!m.type.contains("html"))
            continue;
        const auto data = zip.read(file, 16 << 20);
        if (!data)
            continue;
        const QString text = textOf(*data);
        if (!text.isEmpty())
            out.append({i, chapter, text});
    }
    return out;
}

