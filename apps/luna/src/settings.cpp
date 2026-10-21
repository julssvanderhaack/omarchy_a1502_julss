#include "settings.h"
#include <QCoreApplication>
#include <QSettings>
#include <QTimer>

Settings &Settings::get()
{
    static Settings s;
    return s;
}

int Settings::iconSizeFor(int zoom)
{
    static const int sizes[] = {32, 48, 64, 96, 128, 192};
    return sizes[std::clamp(zoom, 0, 5)];
}

int Settings::listIconSizeFor(int zoom)
{
    static const int sizes[] = {16, 22, 32, 48};
    return sizes[std::clamp(zoom, 0, 3)];
}

void Settings::changed()
{
    // Zooming with the wheel changes settings many times a second: write once.
    if (!m_savePending) {
        m_savePending = true;
        QTimer::singleShot(500, this, [this] {
            if (m_savePending) save();
        });
        static bool hooked = false;
        if (!hooked) {
            hooked = true;
            connect(qApp, &QCoreApplication::aboutToQuit, this, [this] {
                if (m_savePending) save();
            });
        }
    }
    emit updated();
}

void Settings::load()
{
    QSettings q("luna", "luna");
    viewMode = ViewMode(q.value("view/mode", int(viewMode)).toInt());
    iconZoom = q.value("view/iconZoom", iconZoom).toInt();
    listZoom = q.value("view/listZoom", listZoom).toInt();
    showHidden = q.value("view/showHidden", showHidden).toBool();
    foldersFirst = q.value("view/foldersFirst", foldersFirst).toBool();
    sortColumn = q.value("view/sortColumn", sortColumn).toInt();
    sortDescending = q.value("view/sortDescending", sortDescending).toBool();
    dateFormat = q.value("view/dateFormat", dateFormat).toInt();
    sizeIEC = q.value("view/sizeIEC", sizeIEC).toBool();
    showItemCounts = q.value("view/showItemCounts", showItemCounts).toBool();
    iconStyle = q.value("look/iconStyle", iconStyle).toInt();
    iconTheme = q.value("look/iconTheme", iconTheme).toString();
    useOmarchyColors = q.value("look/omarchyColors", useOmarchyColors).toBool();
    sidebarRight = q.value("sidebar/right", sidebarRight).toBool();
    sidebarVisible = q.value("sidebar/visible", sidebarVisible).toBool();
    showPlaces = q.value("sidebar/places", showPlaces).toBool();
    showBookmarks = q.value("sidebar/bookmarks", showBookmarks).toBool();
    showDevices = q.value("sidebar/devices", showDevices).toBool();
    singleClick = q.value("behavior/singleClick", singleClick).toBool();
    confirmTrash = q.value("behavior/confirmTrash", confirmTrash).toBool();
    confirmDelete = q.value("behavior/confirmDelete", confirmDelete).toBool();
    middleClickNewTab = q.value("behavior/middleClickNewTab", middleClickNewTab).toBool();
    restoreSession = q.value("behavior/restoreSession", restoreSession).toBool();
    typeToSearch = q.value("behavior/typeToSearch", typeToSearch).toBool();
    searchRecursiveDefault = q.value("behavior/searchRecursive", searchRecursiveDefault).toBool();
    executableText = q.value("behavior/executableText", executableText).toInt();
    thumbnails = q.value("thumbs/enabled", thumbnails).toBool();
    thumbMaxMB = q.value("thumbs/maxMB", thumbMaxMB).toInt();
    thumbVideos = q.value("thumbs/videos", thumbVideos).toBool();
    thumbPdf = q.value("thumbs/pdf", thumbPdf).toBool();
    terminal = q.value("terminal/command", terminal).toString();
    pathbarText = q.value("view/pathbarText", pathbarText).toBool();
    toolbarStyle = q.value("toolbar/style", toolbarStyle).toInt();
    toolbarIconSize = q.value("toolbar/iconSize", toolbarIconSize).toInt();
    tbForward = q.value("toolbar/forward", tbForward).toBool();
    tbUp = q.value("toolbar/up", tbUp).toBool();
    tbSearch = q.value("toolbar/search", tbSearch).toBool();
    tbView = q.value("toolbar/view", tbView).toBool();
    tbSplit = q.value("toolbar/split", tbSplit).toBool();
    tbSidebar = q.value("toolbar/sidebar", tbSidebar).toBool();
    sessionTabs = q.value("session/tabs").toStringList();
    startSplit = q.value("session/split", startSplit).toBool();
}

void Settings::save() const
{
    m_savePending = false;
    QSettings q("luna", "luna");
    q.setValue("view/mode", int(viewMode));
    q.setValue("view/iconZoom", iconZoom);
    q.setValue("view/listZoom", listZoom);
    q.setValue("view/showHidden", showHidden);
    q.setValue("view/foldersFirst", foldersFirst);
    q.setValue("view/sortColumn", sortColumn);
    q.setValue("view/sortDescending", sortDescending);
    q.setValue("view/dateFormat", dateFormat);
    q.setValue("view/sizeIEC", sizeIEC);
    q.setValue("view/showItemCounts", showItemCounts);
    q.setValue("look/iconStyle", iconStyle);
    q.setValue("look/iconTheme", iconTheme);
    q.setValue("look/omarchyColors", useOmarchyColors);
    q.setValue("sidebar/right", sidebarRight);
    q.setValue("sidebar/visible", sidebarVisible);
    q.setValue("sidebar/places", showPlaces);
    q.setValue("sidebar/bookmarks", showBookmarks);
    q.setValue("sidebar/devices", showDevices);
    q.setValue("behavior/singleClick", singleClick);
    q.setValue("behavior/confirmTrash", confirmTrash);
    q.setValue("behavior/confirmDelete", confirmDelete);
    q.setValue("behavior/middleClickNewTab", middleClickNewTab);
    q.setValue("behavior/restoreSession", restoreSession);
    q.setValue("behavior/typeToSearch", typeToSearch);
    q.setValue("behavior/searchRecursive", searchRecursiveDefault);
    q.setValue("behavior/executableText", executableText);
    q.setValue("thumbs/enabled", thumbnails);
    q.setValue("thumbs/maxMB", thumbMaxMB);
    q.setValue("thumbs/videos", thumbVideos);
    q.setValue("thumbs/pdf", thumbPdf);
    q.setValue("terminal/command", terminal);
    q.setValue("view/pathbarText", pathbarText);
    q.setValue("toolbar/style", toolbarStyle);
    q.setValue("toolbar/iconSize", toolbarIconSize);
    q.setValue("toolbar/forward", tbForward);
    q.setValue("toolbar/up", tbUp);
    q.setValue("toolbar/search", tbSearch);
    q.setValue("toolbar/view", tbView);
    q.setValue("toolbar/split", tbSplit);
    q.setValue("toolbar/sidebar", tbSidebar);
    q.setValue("session/tabs", sessionTabs);
    q.setValue("session/split", startSplit);
}
