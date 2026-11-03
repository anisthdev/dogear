#pragma once

#include <QFileSystemWatcher>
#include <QObject>
#include <QQmlEngine>

// A text file's contents, kept up to date as it changes (Quickshell's
// FileView does this in the shell): the matugen palette for Theme, the
// font list for ReadingTheme. Watches the folder too, so a file that's
// replaced rather than rewritten, or that appears later, is picked up.
class TextFile : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString path READ path WRITE setPath NOTIFY pathChanged)
    Q_PROPERTY(QString text READ text NOTIFY textChanged)
    Q_PROPERTY(bool exists READ exists NOTIFY textChanged)

public:
    explicit TextFile(QObject *parent = nullptr);

    QString path() const { return m_path; }
    void setPath(const QString &path);
    QString text() const { return m_text; }
    bool exists() const { return m_exists; }

    // $XDG_CONFIG_HOME/dogear/<name>
    Q_INVOKABLE QString configPath(const QString &name) const;
    // Write `text` to the file if there's none yet (making its folder)
    Q_INVOKABLE bool createIfMissing(const QString &text);

signals:
    void pathChanged();
    void textChanged();

private:
    void reload();

    QString m_path;
    QString m_text;
    bool m_exists = false;
    QFileSystemWatcher m_watcher;
};
