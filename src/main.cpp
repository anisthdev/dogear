#include <QCommandLineParser>
#include <QDir>
#include <QGuiApplication>
#include <QNetworkAccessManager>
#include <QNetworkRequest>
#include <QQmlApplicationEngine>
#include <QQmlNetworkAccessManagerFactory>
#include <QQuickWindow>
#include <QWebEngineUrlScheme>
#include <QtWebEngineQuick/QQuickWebEngineProfile>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>

#include "Library.h"
#include "SchemeHandler.h"

namespace {

// Images in QML say who's asking too: some catalogues refuse covers to
// Qt's default "Mozilla/5.0"
class NetworkManager : public QNetworkAccessManager
{
public:
    using QNetworkAccessManager::QNetworkAccessManager;

protected:
    QNetworkReply *createRequest(Operation op, const QNetworkRequest &original, QIODevice *data) override
    {
        QNetworkRequest request(original);
        request.setHeader(QNetworkRequest::UserAgentHeader, "Dogear/" DOGEAR_VERSION " (ebook reader)");
        return QNetworkAccessManager::createRequest(op, request, data);
    }
};

class NetworkFactory : public QQmlNetworkAccessManagerFactory
{
public:
    QNetworkAccessManager *create(QObject *parent) override
    {
        return new NetworkManager(parent);
    }
};

} // namespace

int main(int argc, char *argv[])
{
    // Both must happen before the application exists
    SchemeHandler::registerScheme();
    QtWebEngineQuick::initialize();

    QGuiApplication app(argc, argv);
    app.setApplicationName("dogear");
    app.setApplicationDisplayName("Dogear");
    app.setApplicationVersion(DOGEAR_VERSION);
    app.setOrganizationName("dogear");
    // The Wayland app ID, matching the .desktop file
    app.setDesktopFileName("io.github.anisthdev.Dogear");

    QCommandLineParser parser;
    parser.setApplicationDescription("An ebook reader");
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument("book", "An EPUB to open");
    parser.process(app);
    if (!parser.positionalArguments().isEmpty())
        Library::setStartFile(QDir::current().absoluteFilePath(parser.positionalArguments().first()));

    auto *profile = QQuickWebEngineProfile::defaultProfile();
    profile->installUrlSchemeHandler(SchemeHandler::scheme, new SchemeHandler(&app));

    QQmlApplicationEngine engine;
    NetworkFactory networkFactory;
    engine.setNetworkAccessManagerFactory(&networkFactory);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Dogear", "Main");
    return app.exec();
}
