#include "WindowWatch.h"

#include <QEvent>

void WindowWatch::setWindow(QQuickWindow *window)
{
    if (window == m_window)
        return;
    if (m_window)
        m_window->removeEventFilter(this);
    m_window = window;
    if (m_window) {
        m_window->installEventFilter(this);
        m_exposed = m_window->isExposed();
    }
    emit windowChanged();
}

bool WindowWatch::eventFilter(QObject *watched, QEvent *event)
{
    if (watched == m_window && (event->type() == QEvent::Expose || event->type() == QEvent::Show)) {
        const bool exposed = m_window->isExposed();
        if (exposed && !m_exposed)
            emit shown();
        m_exposed = exposed;
    }
    return QObject::eventFilter(watched, event);
}
