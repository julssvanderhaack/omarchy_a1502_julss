#include "settingsdialog.h"
#include "icons.h"
#include "settings.h"
#include <QCheckBox>
#include <QComboBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QListWidget>
#include <QPushButton>
#include <QSpinBox>
#include <QStackedWidget>

namespace {
QCheckBox *check(const QString &text, bool &field)
{
    auto *c = new QCheckBox(text);
    c->setChecked(field);
    QObject::connect(c, &QCheckBox::toggled, c, [&field](bool on) {
        field = on;
        Settings::get().changed();
    });
    return c;
}

QComboBox *combo(const QStringList &items, int &field)
{
    auto *c = new QComboBox;
    c->addItems(items);
    c->setCurrentIndex(field);
    QObject::connect(c, &QComboBox::currentIndexChanged, c, [&field](int i) {
        field = i;
        Settings::get().changed();
    });
    return c;
}

QLabel *note(const QString &t)
{
    auto *l = new QLabel(t);
    l->setProperty("role", "dim");
    l->setWordWrap(true);
    return l;
}
}

SettingsDialog::SettingsDialog(QWidget *parent) : QDialog(parent)
{
    setWindowTitle("Ajustes de Luna");
    resize(720, 520);
    auto *h = new QHBoxLayout(this);
    m_nav = new QListWidget;
    m_nav->setObjectName("settingsNav");
    m_nav->setFixedWidth(190);
    m_nav->setIconSize(QSize(18, 18));
    m_pages = new QStackedWidget;
    h->addWidget(m_nav);
    h->addWidget(m_pages, 1);
    connect(m_nav, &QListWidget::currentRowChanged, m_pages, &QStackedWidget::setCurrentIndex);
    Settings &s = Settings::get();

    // ---- Vista
    QFormLayout *f = page("Vista", "icons");
    auto *mode = new QComboBox;
    mode->addItems({"Iconos", "Compacta", "Lista", "Lista detallada", QString::fromUtf8("Árbol"), "Columnas"});
    mode->setCurrentIndex(int(s.viewMode));
    connect(mode, &QComboBox::currentIndexChanged, this, [](int i) {
        Settings::get().viewMode = ViewMode(i);
        Settings::get().changed();
    });
    f->addRow("Vista predeterminada:", mode);
    f->addRow(QString::fromUtf8("Tamaño de los iconos:"), combo({"32 px", "48 px", "64 px", "96 px", "128 px", "192 px"}, s.iconZoom));
    f->addRow(QString::fromUtf8("Tamaño en listas:"), combo({"Muy pequeño", QString::fromUtf8("Pequeño"), "Mediano", "Grande"}, s.listZoom));
    f->addRow("Ordenar por:", combo({"Nombre", QString::fromUtf8("Tamaño"), "Tipo", QString::fromUtf8("Fecha de modificación"), "Permisos", "Propietario"}, s.sortColumn));
    f->addRow("", check("Orden descendente", s.sortDescending));
    f->addRow("", check("Carpetas antes que archivos", s.foldersFirst));
    f->addRow("", check("Mostrar archivos ocultos", s.showHidden));
    f->addRow("Fechas:", combo({"Relativas (hoy, ayer…)", "Fecha y hora", "ISO (2026-10-19 15:30)"}, s.dateFormat));
    auto *units = new QComboBox;
    units->addItems({QString::fromUtf8("Decimales (kB, MB, GB)"), QString::fromUtf8("Binarias (KiB, MiB, GiB)")});
    units->setCurrentIndex(s.sizeIEC ? 1 : 0);
    connect(units, &QComboBox::currentIndexChanged, this, [](int i) {
        Settings::get().sizeIEC = i == 1;
        Settings::get().changed();
    });
    f->addRow(QString::fromUtf8("Unidades de tamaño:"), units);
    f->addRow("", check(QString::fromUtf8("Mostrar cuántos elementos tiene cada carpeta"), s.showItemCounts));

    // ---- Apariencia
    f = page("Apariencia", "star");
    auto *style = new QComboBox;
    style->addItems({QString::fromUtf8("Iconos del tema GTK"), QString::fromUtf8("Glifos de Omarchy (Nerd Font, colores del tema)")});
    style->setCurrentIndex(s.iconStyle);
    connect(style, &QComboBox::currentIndexChanged, this, [](int i) {
        Settings::get().iconStyle = i;
        Settings::get().changed();
    });
    f->addRow("Estilo de iconos:", style);
    auto *theme = new QComboBox;
    theme->addItem(QString::fromUtf8("Seguir al sistema (%1)").arg(Icons::get().gtkTheme()), QString());
    for (const QString &t : Icons::installedThemes()) theme->addItem(t, t);
    theme->setCurrentIndex(std::max(0, theme->findData(s.iconTheme)));
    connect(theme, &QComboBox::currentIndexChanged, this, [theme](int) {
        Settings::get().iconTheme = theme->currentData().toString();
        Settings::get().changed();
    });
    f->addRow("Tema de iconos GTK:", theme);
    f->addRow("", note(QString::fromUtf8("«Seguir al sistema» usa el tema que pone Omarchy al cambiar de tema (gsettings). "
                                         "Los colores de la ventana salen siempre del tema activo de Omarchy.")));

    // ---- Barra lateral
    f = page("Barra lateral", "sidebar");
    auto *side = new QComboBox;
    side->addItems({"Izquierda", "Derecha"});
    side->setCurrentIndex(s.sidebarRight ? 1 : 0);
    connect(side, &QComboBox::currentIndexChanged, this, [](int i) {
        Settings::get().sidebarRight = i == 1;
        Settings::get().changed();
    });
    f->addRow(QString::fromUtf8("Posición:"), side);
    f->addRow("", check("Mostrar la barra lateral (F9)", s.sidebarVisible));
    f->addRow("", check("Lugares", s.showPlaces));
    f->addRow("", check("Marcadores", s.showBookmarks));
    f->addRow("", check("Dispositivos", s.showDevices));
    f->addRow("", note(QString::fromUtf8("Los marcadores son los de GTK (~/.config/gtk-3.0/bookmarks): los mismos que ve Nautilus y la barra. "
                                         "Arrastra carpetas a la barra para añadirlas y arrástralos para reordenarlos.")));

    // ---- Comportamiento
    f = page("Comportamiento", "settings");
    f->addRow("", check("Abrir con un solo clic", s.singleClick));
    f->addRow("", check(QString::fromUtf8("Clic central abre carpetas en pestaña nueva"), s.middleClickNewTab));
    f->addRow("", check(QString::fromUtf8("Escribir filtra la carpeta (si no, salta al nombre)"), s.typeToSearch));
    f->addRow("", check(QString::fromUtf8("Al buscar, incluir subcarpetas por defecto"), s.searchRecursiveDefault));
    f->addRow("", check(QString::fromUtf8("Preguntar antes de mover a la papelera"), s.confirmTrash));
    f->addRow("", check(QString::fromUtf8("Preguntar antes de eliminar definitivamente"), s.confirmDelete));
    f->addRow("", check(QString::fromUtf8("Recordar las pestañas al cerrar"), s.restoreSession));
    f->addRow("Programas y scripts:", combo({QString::fromUtf8("Preguntar qué hacer"), "Abrirlos como texto", "Ejecutarlos"}, s.executableText));

    // ---- Miniaturas
    f = page("Miniaturas", "icons");
    f->addRow("", check(QString::fromUtf8("Mostrar miniaturas"), s.thumbnails));
    f->addRow("", check(QString::fromUtf8("De vídeos y carátulas de música (ffmpegthumbnailer)"), s.thumbVideos));
    f->addRow("", check("De documentos PDF", s.thumbPdf));
    auto *mb = new QSpinBox;
    mb->setRange(1, 2000);
    mb->setSuffix(" MB");
    mb->setValue(s.thumbMaxMB);
    connect(mb, &QSpinBox::valueChanged, this, [](int v) {
        Settings::get().thumbMaxMB = v;
        Settings::get().changed();
    });
    f->addRow(QString::fromUtf8("Tamaño máximo de imagen:"), mb);
    f->addRow("", note(QString::fromUtf8("Las miniaturas se guardan en ~/.cache/thumbnails (compartidas con Nautilus) y se generan con "
                                         "dos hilos como máximo para no cargar la CPU.")));

    // ---- Terminal
    f = page("Terminal", "terminal");
    auto *term = new QLineEdit(s.terminal);
    connect(term, &QLineEdit::editingFinished, this, [term] {
        Settings::get().terminal = term->text().trimmed();
        Settings::get().changed();
    });
    f->addRow("Orden:", term);
    f->addRow("", note(QString::fromUtf8("Se ejecuta en la carpeta actual (F4). Por defecto xdg-terminal-exec, la terminal de Omarchy.")));

    m_nav->setCurrentRow(0);
}

QFormLayout *SettingsDialog::page(const QString &title, const QString &glyph)
{
    m_nav->addItem(new QListWidgetItem(Icons::get().ui(glyph), title));
    auto *w = new QWidget;
    auto *v = new QVBoxLayout(w);
    auto *t = new QLabel("<h2>" + title + "</h2>");
    v->addWidget(t);
    auto *form = new QFormLayout;
    form->setLabelAlignment(Qt::AlignRight);
    form->setVerticalSpacing(10);
    v->addLayout(form);
    v->addStretch();
    m_pages->addWidget(w);
    return form;
}
