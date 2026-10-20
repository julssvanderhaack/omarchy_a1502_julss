#include "pathbar.h"
#include "fileops.h"
#include "icons.h"
#include "remote.h"
#include "settings.h"
#include <QAbstractItemView>
#include <QCompleter>
#include <QDir>
#include <QFileSystemModel>
#include <QHBoxLayout>
#include <QContextMenuEvent>
#include <QKeyEvent>
#include <QMouseEvent>
#include <QLineEdit>
#include <QStackedWidget>
#include <QToolButton>
#include <QTimer>
#include <QUrl>

PathBar::PathBar(QWidget *parent) : QWidget(parent)
{
    setObjectName("pathBar");
    setAttribute(Qt::WA_StyledBackground);
    auto *h = new QHBoxLayout(this);
    h->setContentsMargins(2, 0, 2, 0);
    h->setSpacing(0);
    m_stack = new QStackedWidget;
    m_stack->setAttribute(Qt::WA_TranslucentBackground);
    h->addWidget(m_stack, 1);
    m_crumbs = new QWidget;
    // The crumbs never dictate the bar's size: otherwise showing a new crumb
    // resizes the bar, which rebuilds the crumbs while one is being shown.
    m_crumbs->setSizePolicy(QSizePolicy::Ignored, QSizePolicy::Preferred);
    m_crumbLayout = new QHBoxLayout(m_crumbs);
    m_crumbLayout->setContentsMargins(0, 0, 0, 0);
    m_crumbLayout->setSpacing(0);
    m_stack->addWidget(m_crumbs);
    m_edit = new QLineEdit;
    m_edit->installEventFilter(this);
    m_edit->setPlaceholderText(QString::fromUtf8("Ruta o dirección (sftp://usuario@servidor, smb://, ftp://)"));
    auto *fsm = new QFileSystemModel(this);
    fsm->setFilter(QDir::Dirs | QDir::NoDotAndDotDot | QDir::Hidden);
    fsm->setRootPath("/");
    auto *comp = new QCompleter(fsm, this);
    comp->setCaseSensitivity(Qt::CaseInsensitive);
    m_edit->setCompleter(comp);
    m_stack->addWidget(m_edit);
    connect(m_edit, &QLineEdit::returnPressed, this, &PathBar::submit);

    m_connect = new QToolButton;
    m_connect->setIcon(Icons::get().ui("network"));
    m_connect->setToolTip(QString::fromUtf8("Conectar a un servidor (SSH, FTP, SMB…)"));
    m_connect->setAutoRaise(true);
    m_connect->setFocusPolicy(Qt::NoFocus);
    connect(m_connect, &QToolButton::clicked, this, [this] { emit connectRequested({}); });
    h->addWidget(m_connect);
    m_toggle = new QToolButton;
    m_toggle->setAutoRaise(true);
    m_toggle->setFocusPolicy(Qt::NoFocus);
    connect(m_toggle, &QToolButton::clicked, this, [this] {
        Settings::get().pathbarText = !m_textMode;
        Settings::get().save();
        setTextMode(!m_textMode);
        if (m_textMode) editPath();
    });
    h->addWidget(m_toggle);
    setFixedHeight(36);
    m_connect->setIconSize(QSize(18, 18));
    m_toggle->setIconSize(QSize(18, 18));
    setTextMode(Settings::get().pathbarText);
}

void PathBar::setTextMode(bool text)
{
    m_textMode = text;
    m_toggle->setIcon(Icons::get().ui(text ? "crumbs" : "edit"));
    m_toggle->setToolTip(text ? QString::fromUtf8("Mostrar la ruta como botones") : QString::fromUtf8("Escribir la ruta (Ctrl+L)"));
    m_edit->setText(m_path);
    m_stack->setCurrentWidget(text ? static_cast<QWidget *>(m_edit) : m_crumbs);
    setCursor(text ? Qt::IBeamCursor : Qt::ArrowCursor);
}

void PathBar::setPath(const QString &path)
{
    m_path = path;
    if (!m_edit->hasFocus()) m_edit->setText(path == FileOps::trashFiles() ? QString() : path);
    if (!m_textMode) m_stack->setCurrentWidget(m_crumbs);
    scheduleRebuild();
}

void PathBar::scheduleRebuild()
{
    if (m_rebuildPending) return;
    m_rebuildPending = true;
    QTimer::singleShot(0, this, [this] {
        m_rebuildPending = false;
        rebuild();
    });
}

void PathBar::editPath()
{
    m_edit->setText(m_path == FileOps::trashFiles() ? QString() : m_path);
    m_stack->setCurrentWidget(m_edit);
    m_edit->setFocus();
    m_edit->selectAll();
}

void PathBar::showCrumbs()
{
    if (!m_textMode) m_stack->setCurrentWidget(m_crumbs);
    else m_edit->setText(m_path);
}

void PathBar::submit()
{
    QString t = m_edit->text().trimmed();
    if (t.isEmpty()) return;
    if (t.startsWith("file://")) t = QUrl(t).toLocalFile();
    if (t.contains("://")) {
        showCrumbs();
        emit connectRequested(t);
        return;
    }
    if (t.startsWith("~")) t = QDir::homePath() + t.mid(1);
    showCrumbs();
    emit navigate(QDir::cleanPath(t));
}

bool PathBar::eventFilter(QObject *o, QEvent *e)
{
    if (o == m_edit) {
        if (e->type() == QEvent::KeyPress && static_cast<QKeyEvent *>(e)->key() == Qt::Key_Escape) {
            showCrumbs();
            m_edit->setText(m_path);
            return true;
        }
        if (e->type() == QEvent::FocusOut && !m_edit->completer()->popup()->isVisible()) showCrumbs();
    }
    return QWidget::eventFilter(o, e);
}

void PathBar::mousePressEvent(QMouseEvent *e)
{
    if (e->button() == Qt::LeftButton) editPath();
}

void PathBar::contextMenuEvent(QContextMenuEvent *e)
{
    if (m_stack->currentWidget() == m_edit && m_edit->hasFocus()) return QWidget::contextMenuEvent(e);
    emit folderMenuRequested(e->globalPos());
}

void PathBar::resizeEvent(QResizeEvent *e)
{
    QWidget::resizeEvent(e);
    if (width() != m_lastWidth) {
        m_lastWidth = width();
        scheduleRebuild();
    }
}

void PathBar::rebuild()
{
    while (QLayoutItem *it = m_crumbLayout->takeAt(0)) {
        if (QWidget *w = it->widget()) {
            w->hide();
            w->deleteLater();   // may be the button whose click led us here
        }
        delete it;
    }
    const QString home = QDir::homePath();
    struct Crumb { QString label, path; QIcon icon; };
    QList<Crumb> crumbs;
    auto tail = [&](const QString &base, const QString &rest) {
        QString acc = base;
        for (const QString &part : rest.split('/', Qt::SkipEmptyParts)) crumbs << Crumb{part, acc += '/' + part, {}};
    };
    if (m_path == FileOps::trashFiles() || m_path.startsWith(FileOps::trashFiles() + '/')) {
        crumbs << Crumb{QString::fromUtf8("Papelera"), FileOps::trashFiles(), Icons::get().place("trash")};
        tail(FileOps::trashFiles(), m_path.mid(FileOps::trashFiles().size()));
    } else if (Remote::isRemotePath(m_path)) {
        const QString rel = m_path.mid(Remote::gvfsRoot().size() + 1);
        const QString mount = rel.section('/', 0, 0);
        const QString base = Remote::gvfsRoot() + '/' + mount;
        crumbs << Crumb{Remote::describe(mount), base, Icons::get().place("network")};
        tail(base, rel.mid(mount.size()));
    } else if (m_path == home || m_path.startsWith(home + '/')) {
        crumbs << Crumb{QString::fromUtf8("Carpeta personal"), home, Icons::get().place("home")};
        tail(home, m_path.mid(home.size()));
    } else {
        crumbs << Crumb{QString(), "/", Icons::get().place("root")};
        tail("", m_path);
    }
    QFontMetrics fm(font());
    int avail = width() - 90, used = 0;
    QList<int> widths;
    for (auto &c : crumbs) widths << fm.horizontalAdvance(c.label) + (c.icon.isNull() ? 30 : 48);
    for (int w : widths) used += w;
    int skipUntil = 1;
    while (used > avail && skipUntil < crumbs.size() - 1) used -= widths[skipUntil++];
    for (int i = 0; i < crumbs.size(); ++i) {
        if (i > 0 && i < skipUntil) {
            if (i == 1) {
                auto *dots = new QToolButton;
                dots->setText(QString::fromUtf8("…"));
                dots->setProperty("role", "crumb");
                dots->setAutoRaise(true);
                const QString p = crumbs[skipUntil - 1].path;
                connect(dots, &QToolButton::clicked, this, [this, p] { emit navigate(p); });
                m_crumbLayout->addWidget(dots);
            }
            continue;
        }
        if (i > 0) {
            auto *sep = new QToolButton;
            sep->setText("/");
            sep->setEnabled(false);
            sep->setAutoRaise(true);
            sep->setFocusPolicy(Qt::NoFocus);
            m_crumbLayout->addWidget(sep);
        }
        auto *b = new QToolButton;
        b->setProperty("role", "crumb");
        b->setAutoRaise(true);
        b->setFocusPolicy(Qt::NoFocus);
        b->setText(crumbs[i].label);
        if (!crumbs[i].icon.isNull()) {
            b->setIcon(crumbs[i].icon);
            b->setToolButtonStyle(crumbs[i].label.isEmpty() ? Qt::ToolButtonIconOnly : Qt::ToolButtonTextBesideIcon);
        }
        b->setCheckable(true);
        b->setChecked(i == crumbs.size() - 1);
        b->setCursor(Qt::PointingHandCursor);
        const QString p = crumbs[i].path;
        connect(b, &QToolButton::clicked, this, [this, p, b] {
            b->setChecked(true);
            emit navigate(p);
        });
        m_crumbLayout->addWidget(b);
    }
    m_crumbLayout->addStretch();
}
