#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <optional>

// What an EPUB says about itself: its package document's (OPF) Dublin
// Core metadata, Calibre's and EPUB 3's series, and its cover image.
// Read straight from the zip, without rendering anything.
struct EpubInfo
{
    QString title;
    QStringList authors;
    // "Rowling, J. K." from opf:file-as / EPUB 3 file-as, else derived
    QString authorsSort;
    QString language;
    QString description; // may hold HTML
    QString publisher;
    QString published;
    QString isbn;
    QString series;
    double seriesIndex = 0;
    // dc:subject, split on commas and semicolons: the book's own tags
    QStringList subjects;
    QByteArray cover; // the image's bytes, as stored
};

namespace Epub {
std::optional<EpubInfo> read(const QString &path);
}
