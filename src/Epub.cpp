#include "Epub.h"

#include <QFile>
#include <QHash>
#include <QRegularExpression>
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
