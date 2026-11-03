#pragma once

#include <QNetworkAccessManager>
#include <QObject>
#include <QStringList>
#include <QVariantMap>
#include <functional>

// Looking words up: offline StarDict dictionaries through `sdcv` first
// (any in ~/.stardict/dic, /usr/share/stardict/dic, $STARDICT_DATA_DIR, or
// $XDG_DATA_HOME/dogear/dictionaries), then English Wiktionary (`[dictionary]
// online` in dogear.conf, on by default). Each form of the word is tried in
// turn: as selected, in lower case, then without a plural or tense ending.
//
// A result: { word (the form found), source ("Wiktionary" or the
// dictionary's name), url (the Wiktionary page, if any), entries: [{ pos
// (part of speech, may be ""), senses: [{ text, example }] }] }, or {
// entries: [] } with `error` saying why.
class Dictionary : public QObject
{
    Q_OBJECT

public:
    explicit Dictionary(QObject *parent = nullptr);

    void setOnline(bool on) { m_online = on; }
    // `language`: the book's (BCP 47, "en-GB"), to pick Wiktionary's section
    void lookup(const QString &request, const QString &text, const QString &language);
    // Where Dogear's own dictionaries go
    static QString folder();
    // Whether any offline dictionary is installed (sdcv -l lists one)
    bool hasOffline() const;

signals:
    void found(const QString &request, const QVariantMap &result);

private:
    static QStringList forms(const QString &text);
    QVariantMap offline(const QString &word) const;
    void online(const QString &request, const QStringList &forms, int at, const QString &language);

    QNetworkAccessManager m_nam;
    bool m_online = true;
    QString m_sdcv;
};
