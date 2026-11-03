#include <QCommandLineParser>
#include <QDir>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QWebEngineUrlScheme>
#include <QtWebEngineQuick/QQuickWebEngineProfile>
#include <QtWebEngineQuick/qtwebenginequickglobal.h>

#include "Library.h"
#include "SchemeHandler.h"

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
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.loadFromModule("Dogear", "Main");
    return app.exec();
}
