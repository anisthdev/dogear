cmake_minimum_required(VERSION 3.21)
project(dogear VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBZIP REQUIRED IMPORTED_TARGET libzip)
find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Network Qml Quick ShaderTools Sql WebEngineQuick WebChannel)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(dogear src/main.cpp)

# Before qt_add_qml_module, or they register as ordinary types
set_source_files_properties(qml/Theme.qml qml/ReadingTheme.qml qml/KeyEvents.qml
    PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

qt_add_qml_module(dogear
    URI Dogear
    VERSION 1.0
    SOURCES
        src/Library.h src/Library.cpp
        src/Database.h src/Database.cpp
        src/Epub.h src/Epub.cpp
        src/Scanner.h src/Scanner.cpp
        src/Online.h src/Online.cpp
        src/Dictionary.h src/Dictionary.cpp
        src/Catalog.h src/Catalog.cpp
        src/TextFile.h src/TextFile.cpp
        src/SchemeHandler.h src/SchemeHandler.cpp
        src/WindowWatch.h src/WindowWatch.cpp
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/ReadingTheme.qml
        qml/KeyEvents.qml
        qml/views/Reader.qml
        qml/views/PageCurl.qml
        qml/views/TocPanel.qml
        qml/views/FontPanel.qml
        qml/views/TagPanel.qml
        qml/views/SelectionMenu.qml
        qml/views/AnnotationsPanel.qml
        qml/views/SearchPanel.qml
        qml/views/BookPanel.qml
        qml/views/MatchPanel.qml
        qml/views/DefinitionCard.qml
        qml/views/CatalogView.qml
        qml/views/CatalogBook.qml
        qml/components/InputDialog.qml
        qml/components/ConfirmDialog.qml
        qml/components/TextButton.qml
        qml/views/LibraryView.qml
        qml/components/Cover.qml
        qml/components/Label.qml
        qml/components/LinearProgress.qml
        qml/components/ListKeys.qml
        qml/components/KeyHelp.qml
)

# The web side (our reader page and the vendored foliate-js), served from
# the binary's resources by SchemeHandler as dogear://app/...
file(GLOB_RECURSE READER_FILES RELATIVE ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURE_DEPENDS reader/*.html reader/*.js reader/*.css)
qt_add_resources(dogear reader PREFIX / FILES ${READER_FILES})

qt_add_shaders(dogear "shaders" PREFIX / FILES shaders/pagecurl.frag)

target_include_directories(dogear PRIVATE src)
target_compile_definitions(dogear PRIVATE DOGEAR_VERSION="${PROJECT_VERSION}")

target_link_libraries(dogear PRIVATE
    Qt6::Core Qt6::Gui Qt6::Network Qt6::Qml Qt6::Quick Qt6::Sql Qt6::WebEngineQuick Qt6::WebChannel PkgConfig::LIBZIP)

include(GNUInstallDirs)
install(TARGETS dogear RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
install(FILES io.github.anisthdev.Dogear.desktop DESTINATION ${CMAKE_INSTALL_DATADIR}/applications)
