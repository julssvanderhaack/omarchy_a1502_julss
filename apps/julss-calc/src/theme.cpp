#include "theme.h"
#include <QDir>
#include <QFile>
#include <QFontDatabase>
#include <QHash>
#include <QRegularExpression>
#include <QTextStream>

Theme &Theme::get()
{
    static Theme t;
    return t;
}

static QHash<QString, QString> readColors()
{
    QHash<QString, QString> c;
    const QStringList paths = {
        QDir::homePath() + "/.local/state/omarchy/current/theme/colors.toml",
        QDir::homePath() + "/.config/omarchy/current/theme/colors.toml",
    };
    for (const QString &p : paths) {
        QFile f(p);
        if (!f.open(QIODevice::ReadOnly)) continue;
        static const QRegularExpression re("^\\s*([A-Za-z_]+)\\s*=\\s*\"([^\"]*)\"");
        QTextStream in(&f);
        while (!in.atEnd()) {
            auto m = re.match(in.readLine());
            if (m.hasMatch()) c.insert(m.captured(1), m.captured(2));
        }
        break;
    }
    return c;
}

void Theme::load()
{
    auto c = readColors();
    auto col = [&](const char *k, const char *fallback) {
        QColor q(c.value(k, fallback));
        return q.isValid() ? q : QColor(fallback);
    };
    bg = col("background", "#1a1b26");
    bgDark = col("dark_background", bg.darker(120).name().toLatin1().constData());
    bgLight = col("lighter_background", bg.lighter(140).name().toLatin1().constData());
    fg = col("foreground", "#c0caf5");
    fgDim = col("dark_foreground", "#7a7f9a");
    fgLight = col("light_foreground", fg.name().toLatin1().constData());
    accent = col("accent", "#7aa2f7");
    selection = col("selection", bgLight.name().toLatin1().constData());
    muted = col("muted", bgLight.lighter(130).name().toLatin1().constData());
    dark = bg.lightness() < 128;

    // Pick visibly different colours for series, skipping near-duplicates.
    plot.clear();
    for (const char *k : {"accent", "cyan", "magenta", "yellow", "blue", "orange", "red", "green",
                          "bright_cyan", "bright_magenta", "bright_yellow", "bright_blue", "bright_red"}) {
        if (!c.contains(k)) continue;
        QColor q(c.value(k));
        if (!q.isValid()) continue;
        bool close = false;
        for (const QColor &p : plot) {
            int d = std::abs(p.red() - q.red()) + std::abs(p.green() - q.green()) + std::abs(p.blue() - q.blue());
            close |= d < 90;
        }
        if (!close) plot << q;
    }
    for (const char *f : {"#7aa2f7", "#f7768e", "#e0af68", "#9ece6a", "#bb9af7", "#2ac3de"}) {
        if (plot.size() >= 5) break;
        plot << QColor(f);
    }
    ramp = {QColor(c.value("blue", "#3d59a1")), QColor(c.value("cyan", "#2ac3de")), accent,
            QColor(c.value("yellow", "#e0af68"))};
    for (auto &r : ramp)
        if (!r.isValid()) r = accent;

    const QStringList fams = QFontDatabase::families();
    serif = fams.contains("DejaVu Serif") ? "DejaVu Serif" : QFontDatabase::systemFont(QFontDatabase::GeneralFont).family();
    mono = QFontDatabase::systemFont(QFontDatabase::FixedFont).family();
}

QString Theme::styleSheet() const
{
    auto n = [](const QColor &c) { return c.name(QColor::HexArgb); };
    QColor hover = bgLight.lighter(dark ? 130 : 95);
    QColor accentText = accent.lightness() > 140 ? bg : fg;
    QString s = R"(
QWidget { background: %BG%; color: %FG%; }
QToolTip { background: %BGL%; color: %FG%; border: 1px solid %MUTED%; padding: 4px; }
QLineEdit, QPlainTextEdit, QSpinBox, QComboBox {
  background: %BGD%; border: 1px solid %MUTED%; border-radius: 7px; padding: 5px 8px;
  selection-background-color: %SEL%; selection-color: %FG%;
}
QLineEdit:focus, QPlainTextEdit:focus, QSpinBox:focus, QComboBox:focus { border-color: %ACC%; }
QLineEdit[error="true"] { border-color: #e06c75; }
QComboBox::drop-down { border: none; width: 20px; }
QComboBox QAbstractItemView { background: %BGL%; border: 1px solid %MUTED%; selection-background-color: %SEL%; }
QPushButton, QToolButton {
  background: %BGL%; border: 1px solid transparent; border-radius: 7px; padding: 5px 10px;
}
QPushButton:hover, QToolButton:hover { background: %HOVER%; }
QPushButton:pressed, QToolButton:pressed { background: %SEL%; }
QPushButton:checked { background: %SEL%; border-color: %ACC%; }
QPushButton:disabled { color: %DIM%; }
QPushButton[role="num"] { background: %BGD%; font-size: 16px; }
QPushButton[role="num"]:hover { background: %HOVER%; }
QPushButton[role="fn"] { font-size: 13px; padding: 4px 2px; }
QPushButton[role="op"] { background: %MUTED%; font-size: 16px; }
QPushButton[role="eq"], QPushButton[role="primary"] { background: %ACC%; color: %ACCT%; font-weight: bold; }
QPushButton[role="eq"] { font-size: 18px; }
QPushButton[role="eq"]:hover, QPushButton[role="primary"]:hover { background: %ACCH%; }
QPushButton[role="danger"]:hover { background: #a3414b; }
QToolButton[role="tiny"] { padding: 1px 6px; font-size: 11px; color: %DIM%; background: transparent; }
QToolButton[role="tiny"]:hover { color: %FG%; background: %BGL%; }
QToolButton::menu-indicator { image: none; width: 0; }
QTabWidget::pane { border: none; }
QTabBar::tab { background: transparent; color: %DIM%; padding: 8px 16px; border-bottom: 2px solid transparent; font-size: 14px; }
QTabBar::tab:selected { color: %FG%; border-bottom: 2px solid %ACC%; }
QTabBar::tab:hover { color: %FG%; }
QScrollArea { border: none; }
QScrollBar:vertical { background: transparent; width: 8px; margin: 0; }
QScrollBar::handle:vertical { background: %MUTED%; border-radius: 4px; min-height: 24px; }
QScrollBar:horizontal { background: transparent; height: 8px; margin: 0; }
QScrollBar::handle:horizontal { background: %MUTED%; border-radius: 4px; min-width: 24px; }
QScrollBar::add-line, QScrollBar::sub-line { width: 0; height: 0; }
QScrollBar::add-page, QScrollBar::sub-page { background: transparent; }
QSplitter::handle { background: %BG%; width: 6px; }
QMenu { background: %BGL%; border: 1px solid %MUTED%; padding: 4px; }
QMenu::item { padding: 5px 18px; border-radius: 5px; }
QMenu::item:selected { background: %SEL%; }
QLabel[role="dim"] { color: %DIM%; }
QLabel[role="caption"] { color: %DIM%; font-size: 12px; }
QLabel[role="error"] { color: #e06c75; }
QFrame[role="card"] { background: %BGD%; border-radius: 10px; }
QFrame[role="card"] QWidget, QFrame[role="card"] QLabel, QFrame[role="card"] QScrollArea { background: transparent; }
QStatusBar { color: %DIM%; }
QCheckBox::indicator { width: 14px; height: 14px; border: 1px solid %MUTED%; border-radius: 4px; background: %BGD%; }
QCheckBox::indicator:checked { background: %ACC%; border-color: %ACC%; }
)";
    s.replace("%BGD%", n(bgDark)).replace("%BGL%", n(bgLight)).replace("%BG%", n(bg));
    s.replace("%FG%", n(fg)).replace("%DIM%", n(fgDim)).replace("%MUTED%", n(muted));
    s.replace("%SEL%", n(selection)).replace("%ACCT%", n(accentText)).replace("%ACCH%", n(accent.lighter(115)));
    s.replace("%ACC%", n(accent)).replace("%HOVER%", n(hover));
    return s;
}
