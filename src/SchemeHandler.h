#pragma once

#include <QWebEngineUrlSchemeHandler>

// dogear://app/... for the reader page: its own files from the binary's
// resources (":/reader/..."), Qt's qwebchannel.js, and the books
// themselves as dogear://app/book/<id> (the file Library registered for
// that id). One host, so the page can fetch the book without CORS.
class SchemeHandler : public QWebEngineUrlSchemeHandler
{
    Q_OBJECT

public:
    static constexpr const char *scheme = "dogear";

    using QWebEngineUrlSchemeHandler::QWebEngineUrlSchemeHandler;

    static void registerScheme();
    void requestStarted(QWebEngineUrlRequestJob *job) override;
};
