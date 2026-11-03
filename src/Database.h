#pragma once

#include <QSqlDatabase>
#include <QString>

// The library database, $XDG_DATA_HOME/dogear/library.db, and the cover
// thumbnails beside it in $XDG_CACHE_HOME/dogear/covers. Each thread opens
// its own connection (SQLite's rule); WAL lets them share the file.
namespace Database {
// A connection by name, opened and brought up to the current schema
QSqlDatabase connect(const QString &name);
// Save an EPUB's cover as a thumbnail named after the book; its path, or
// "" when there's no usable image
QString saveCover(const QString &id, const QByteArray &image, bool replace = false);
QString coverPath(const QString &id);
} // namespace Database
