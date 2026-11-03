#include "SchemeHandler.h"

#include <QFile>
#include <QFileInfo>
#include <QWebEngineUrlRequestJob>
#include <QWebEngineUrlScheme>

#include "Library.h"

void SchemeHandler::registerScheme()
{
    QWebEngineUrlScheme s(scheme);
    s.setSyntax(QWebEngineUrlScheme::Syntax::Host);
    s.setFlags(QWebEngineUrlScheme::SecureScheme | QWebEngineUrlScheme::CorsEnabled
               | QWebEngineUrlScheme::FetchApiAllowed);
    QWebEngineUrlScheme::registerScheme(s);
}

static QByteArray mimeFor(const QString &path)
{
    const QString ext = QFileInfo(path).suffix().toLower();
    if (ext == "html")
        return "text/html";
    if (ext == "js" || ext == "mjs")
        return "text/javascript";
    if (ext == "css")
        return "text/css";
    if (ext == "json")
        return "application/json";
    if (ext == "svg")
        return "image/svg+xml";
    return "application/octet-stream";
}

void SchemeHandler::requestStarted(QWebEngineUrlRequestJob *job)
{
    const QUrl url = job->requestUrl();
    if (url.host() != "app" || job->requestMethod() != "GET") {
        job->fail(QWebEngineUrlRequestJob::UrlInvalid);
        return;
    }

    const QString path = url.path();
    QString file;
    QByteArray mime;
    if (path.startsWith("/book/")) {
        file = Library::fileFor(path.mid(6));
        mime = "application/epub+zip";
    } else if (path == "/qwebchannel.js") {
        file = ":/qtwebchannel/qwebchannel.js";
        mime = "text/javascript";
    } else if (!path.contains("..")) {
        file = ":/reader" + path;
        mime = mimeFor(path);
    }

    if (file.isEmpty() || !QFile::exists(file)) {
        job->fail(QWebEngineUrlRequestJob::UrlNotFound);
        return;
    }
    auto *device = new QFile(file, job);
    if (!device->open(QIODevice::ReadOnly)) {
        job->fail(QWebEngineUrlRequestJob::RequestDenied);
        return;
    }
    job->reply(mime, device);
}
