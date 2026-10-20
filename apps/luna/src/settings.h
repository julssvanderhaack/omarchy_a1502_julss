// User preferences, persisted with QSettings (~/.config/luna/luna.conf).
#pragma once
#include <QObject>
#include <QString>
#include <QStringList>

enum class ViewMode { Icons, Compact, List, Details, Tree, Columns };

class Settings : public QObject {
    Q_OBJECT
public:
    static Settings &get();
    void load();
    void save() const;
    void changed() { save(); emit updated(); }

    // Vista
    ViewMode viewMode = ViewMode::Icons;
    int iconZoom = 2;              // 0..5, see iconSizeFor()
    int listZoom = 1;              // 0..3
    bool showHidden = false;
    bool foldersFirst = true;
    int sortColumn = 0;            // FsModel::Column
    bool sortDescending = false;
    int dateFormat = 0;            // 0 relativo, 1 local corto, 2 ISO
    bool sizeIEC = false;          // KiB vs kB
    bool showItemCounts = true;    // folder size column shows number of items
    // Apariencia
    int iconStyle = 0;             // 0 iconos GTK, 1 glifos Omarchy
    QString iconTheme;             // empty = follow GTK (gsettings)
    bool useOmarchyColors = true;
    // Barra lateral
    bool sidebarRight = true;
    bool sidebarVisible = true;
    bool showPlaces = true, showBookmarks = true, showDevices = true;
    // Comportamiento
    bool singleClick = false;
    bool confirmTrash = false;
    bool confirmDelete = true;
    bool middleClickNewTab = true;
    bool restoreSession = true;
    bool typeToSearch = true;      // typing filters (false: jumps to name)
    bool searchRecursiveDefault = false;
    int executableText = 0;        // 0 preguntar, 1 abrir, 2 ejecutar
    // Miniaturas
    bool thumbnails = true;
    int thumbMaxMB = 50;
    bool thumbVideos = true;
    bool thumbPdf = true;
    // Barra de ruta: false = botones (migas), true = texto editable
    bool pathbarText = false;
    // Terminal
    QString terminal = "xdg-terminal-exec";
    // Sesión
    QStringList sessionTabs;
    bool startSplit = false;

    static int iconSizeFor(int zoom);
    static int listIconSizeFor(int zoom);

signals:
    void updated();
};
