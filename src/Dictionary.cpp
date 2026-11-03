#include "Dictionary.h"

#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkReply>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>
#include <QTextDocumentFragment>
#include <QUrl>

namespace {

const QByteArray userAgent = "Dogear/" DOGEAR_VERSION " (ebook reader; https://github.com/anisthdev/dogear)";

// Markup (Wiktionary's HTML, some dictionaries') as plain text
QString plain(const QString &html)
{
    if (!html.contains('<') && !html.contains('&'))
        return html.trimmed();
    return QTextDocumentFragment::fromHtml(html).toPlainText().simplified();
}

} // namespace

Dictionary::Dictionary(QObject *parent)
    : QObject(parent)
{
    m_sdcv = QStandardPaths::findExecutable("sdcv");
    QDir().mkpath(folder());
}

QString Dictionary::folder()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + "/dogear/dictionaries";
}

bool Dictionary::hasOffline() const
{
    if (m_sdcv.isEmpty())
        return false;
    QProcess p;
    p.start(m_sdcv, {"-n", "-l", "-2", folder()});
    if (!p.waitForFinished(3000))
        return false;
    // The first line is a header
    return QString::fromUtf8(p.readAllStandardOutput()).trimmed().count('\n') >= 1;
}

QStringList Dictionary::forms(const QString &text)
{
    // The selection less quotes and punctuation round it
    QString word = text.simplified();
    word.remove(QRegularExpression(R"(^[^\p{L}\p{N}]+|[^\p{L}\p{N}]+$)"));
    word.replace(QRegularExpression("[’‘]"), "'");
    QStringList out;
    auto add = [&](const QString &w) {
        if (!w.isEmpty() && !out.contains(w))
            out.append(w);
    };
    add(word);
    add(word.toLower());
    // "owls" "boxes" "flies" "stopped" "turned" "running" "reading"; only
    // for single words
    if (!word.contains(' ')) {
        const QString w = word.toLower();
        static const QList<std::pair<QRegularExpression, QString>> endings{
            {QRegularExpression("ies$"), "y"}, {QRegularExpression("(s|x|z|ch|sh)es$"), "\\1"},
            {QRegularExpression("([^s])s$"), "\\1"}, {QRegularExpression("([a-z])\\1ed$"), "\\1"},
            {QRegularExpression("ied$"), "y"}, {QRegularExpression("ed$"), ""}, {QRegularExpression("ed$"), "e"},
            {QRegularExpression("([a-z])\\1ing$"), "\\1"}, {QRegularExpression("ing$"), ""},
            {QRegularExpression("ing$"), "e"}, {QRegularExpression("'s$"), ""},
        };
        for (const auto &[re, by] : endings)
            if (re.match(w).hasMatch() && w.size() > 3)
                add(QString(w).replace(re, by));
    }
    return out.mid(0, 8);
}

QVariantMap Dictionary::offline(const QString &word) const
{
    if (m_sdcv.isEmpty())
        return {};
    QProcess p;
    p.start(m_sdcv, {"-n", "-j", "-e", "-0", "-1", "-2", folder(), word});
    if (!p.waitForFinished(4000))
        return {};
    const QJsonArray hits = QJsonDocument::fromJson(p.readAllStandardOutput()).array();
    if (hits.isEmpty())
        return {};
    // Each dictionary's answer as an entry, named after the dictionary
    QVariantList entries;
    QStringList names;
    for (const QJsonValue &h : hits) {
        const QJsonObject o = h.toObject();
        QVariantList senses;
        for (const QString &part : o.value("definition").toString().split(QRegularExpression("\n\\s*\n"))) {
            const QString text = plain(QString(part).replace('\n', "<br>"));
            if (!text.isEmpty())
                senses.append(QVariantMap{{"text", text}, {"example", QString()}});
        }
        if (senses.isEmpty())
            continue;
        names.append(o.value("dict").toString());
        entries.append(QVariantMap{{"pos", o.value("dict").toString()}, {"senses", senses}});
    }
    if (entries.isEmpty())
        return {};
    names.removeDuplicates();
    return {{"word", word}, {"source", names.join(", ")}, {"url", QString()}, {"entries", entries}};
}

void Dictionary::lookup(const QString &request, const QString &text, const QString &language)
{
    const QStringList tries = forms(text);
    if (tries.isEmpty()) {
        emit found(request, {{"entries", QVariantList()}, {"error", "Nothing to look up"}});
        return;
    }
    for (const QString &w : tries) {
        const QVariantMap r = offline(w);
        if (!r.isEmpty()) {
            emit found(request, r);
            return;
        }
    }
    if (!m_online) {
        emit found(request, {{"word", tries.first()}, {"entries", QVariantList()},
                             {"error", m_sdcv.isEmpty() ? "No dictionary: sdcv isn't installed" : "Not in your dictionaries"}});
        return;
    }
    online(request, tries, 0, language.section('-', 0, 0).toLower());
}

void Dictionary::online(const QString &request, const QStringList &tries, int at, const QString &language)
{
    if (at >= tries.size()) {
        emit found(request, {{"word", tries.first()}, {"entries", QVariantList()}, {"error", "Not found in your dictionaries or Wiktionary"}});
        return;
    }
    const QString word = tries.at(at);
    // Wiktionary's titles use underscores for spaces; the rest is escaped
    const QString title = QString(word).replace(' ', '_');
    QNetworkRequest req(QUrl("https://en.wiktionary.org/api/rest_v1/page/definition/" + QUrl::toPercentEncoding(title)));
    req.setHeader(QNetworkRequest::UserAgentHeader, userAgent);
    req.setTransferTimeout(15000);
    QNetworkReply *reply = m_nam.get(req);
    connect(reply, &QNetworkReply::finished, this, [this, reply, request, tries, at, language, word, title] {
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        const QByteArray body = reply->readAll();
        const bool failed = reply->error() != QNetworkReply::NoError && status == 0;
        reply->deleteLater();
        if (failed) {
            emit found(request, {{"word", word}, {"entries", QVariantList()}, {"error", "Couldn't reach Wiktionary"}});
            return;
        }
        const QJsonObject all = QJsonDocument::fromJson(body).object();
        // The book's language, else English, else whatever there is
        QJsonArray sections = all.value(language).toArray();
        if (sections.isEmpty())
            sections = all.value("en").toArray();
        if (sections.isEmpty() && !all.isEmpty())
            sections = all.begin().value().toArray();
        QVariantList entries;
        for (const QJsonValue &s : sections) {
            const QJsonObject o = s.toObject();
            QVariantList senses;
            for (const QJsonValue &d : o.value("definitions").toArray()) {
                const QJsonObject def = d.toObject();
                const QString text = plain(def.value("definition").toString());
                if (text.isEmpty())
                    continue;
                const QJsonArray examples = def.value("examples").toArray();
                const QJsonArray parsed = def.value("parsedExamples").toArray();
                QString example = !parsed.isEmpty() ? parsed.first().toObject().value("example").toString()
                                                    : examples.isEmpty() ? QString() : examples.first().toString();
                senses.append(QVariantMap{{"text", text}, {"example", plain(example)}});
                if (senses.size() >= 6)
                    break;
            }
            if (!senses.isEmpty())
                entries.append(QVariantMap{{"pos", o.value("partOfSpeech").toString()}, {"senses", senses}});
        }
        if (entries.isEmpty()) {
            online(request, tries, at + 1, language);
            return;
        }
        emit found(request, {{"word", word},
                             {"source", "Wiktionary"},
                             {"url", "https://en.wiktionary.org/wiki/" + QString::fromUtf8(QUrl::toPercentEncoding(title))},
                             {"entries", entries}});
    });
}
