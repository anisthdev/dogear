#include "TextFile.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QStandardPaths>

TextFile::TextFile(QObject *parent)
    : QObject(parent)
{
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, &TextFile::reload);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, &TextFile::reload);
}

QString TextFile::configPath(const QString &name) const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + "/dogear/" + name;
}

bool TextFile::createIfMissing(const QString &text)
{
    if (m_path.isEmpty() || QFileInfo::exists(m_path))
        return false;
    QDir().mkpath(QFileInfo(m_path).absolutePath());
    QFile file(m_path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Text))
        return false;
    file.write(text.toUtf8());
    file.close();
    reload();
    return true;
}

void TextFile::setPath(const QString &path)
{
    if (path == m_path)
        return;
    if (!m_watcher.files().isEmpty())
        m_watcher.removePaths(m_watcher.files());
    if (!m_watcher.directories().isEmpty())
        m_watcher.removePaths(m_watcher.directories());
    m_path = path;
    emit pathChanged();
    reload();
}

void TextFile::reload()
{
    const QString dir = QFileInfo(m_path).absolutePath();
    if (QFileInfo::exists(dir) && !m_watcher.directories().contains(dir))
        m_watcher.addPath(dir);

    QFile file(m_path);
    const bool exists = file.open(QIODevice::ReadOnly);
    const QString text = exists ? QString::fromUtf8(file.readAll()) : QString();
    // A rewrite drops the file from the watch list on some editors and tools
    if (exists && !m_watcher.files().contains(m_path))
        m_watcher.addPath(m_path);

    if (text == m_text && exists == m_exists)
        return;
    m_text = text;
    m_exists = exists;
    emit textChanged();
}
