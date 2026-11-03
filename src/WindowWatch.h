#pragma once

#include <QObject>
#include <QPointer>
#include <QQmlEngine>
#include <QQuickWindow>

// Tells when a window is shown again. Hyprland suspends windows on hidden
// workspaces; Chromium then drops the page's frame and, with nothing on
// the page changing, doesn't draw a new one when the window comes back,
// leaving it blank. Reader nudges the page on `shown`.
class WindowWatch : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QQuickWindow *window READ window WRITE setWindow NOTIFY windowChanged)

public:
    using QObject::QObject;

    QQuickWindow *window() const { return m_window; }
    void setWindow(QQuickWindow *window);

signals:
    void windowChanged();
    void shown();

protected:
    bool eventFilter(QObject *watched, QEvent *event) override;

private:
    QPointer<QQuickWindow> m_window;
    bool m_exposed = true;
};
