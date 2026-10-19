#include "mainwindow.h"
#include "cas.h"
#include "pages.h"
#include <QCloseEvent>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLabel>
#include <QPushButton>
#include <QShortcut>
#include <QStandardPaths>
#include <QStatusBar>
#include <QTabWidget>

static QString statePath()
{
    QString dir = QDir::homePath() + "/.local/state/julss-calc";
    QDir().mkpath(dir);
    return dir + "/state.json";
}

MainWindow::MainWindow()
{
    setWindowTitle("Calculadora");
    resize(1100, 720);
    m_cas = new Cas(this);

    m_tabs = new QTabWidget;
    m_tabs->setDocumentMode(true);
    m_sci = new SciPage(m_cas);
    m_eq = new EqPage(m_cas);
    m_calc = new CalcPage(m_cas);
    m_graph = new GraphPage(m_cas);
    m_tabs->addTab(m_sci, QString::fromUtf8("Científica"));
    m_tabs->addTab(m_eq, QString::fromUtf8("Ecuaciones"));
    m_tabs->addTab(m_calc, QString::fromUtf8("Cálculo"));
    m_tabs->addTab(m_graph, QString::fromUtf8("Gráficas"));
    setCentralWidget(m_tabs);

    m_busy = new QLabel(QString::fromUtf8("Calculando…"));
    m_cancel = new QPushButton(QString::fromUtf8("Cancelar (Esc)"));
    m_cancel->setProperty("role", "danger");
    statusBar()->addPermanentWidget(m_busy);
    statusBar()->addPermanentWidget(m_cancel);
    statusBar()->setSizeGripEnabled(false);
    m_busy->hide();
    m_cancel->hide();
    statusBar()->showMessage(QString::fromUtf8("Ctrl+1…4 cambia de pestaña · ↑/↓ recupera operaciones anteriores"));
    connect(m_cancel, &QPushButton::clicked, m_cas, &Cas::cancel);
    connect(m_cas, &Cas::busyChanged, this, [this](bool b) {
        m_busy->setVisible(b);
        m_cancel->setVisible(b);
    });
    auto *esc = new QShortcut(QKeySequence(Qt::Key_Escape), this);
    connect(esc, &QShortcut::activated, this, [this] {
        if (m_cas->busy()) m_cas->cancel();
    });
    for (int i = 0; i < 4; ++i) {
        auto *sc = new QShortcut(QKeySequence(Qt::CTRL | Qt::Key(Qt::Key_1 + i)), this);
        connect(sc, &QShortcut::activated, this, [this, i] { m_tabs->setCurrentIndex(i); });
    }

    connect(m_sci, &SciPage::defined, this, &MainWindow::setDefinition);
    connect(m_sci, &SciPage::undefineRequested, this, &MainWindow::removeDefinition);

    loadState();
    m_sci->focusInput();
}

void MainWindow::setDefinition(const QString &name, const QString &src)
{
    const QString base = name.section('(', 0, 0);
    for (int i = 0; i < m_defNames.size(); ++i) {
        if (m_defNames[i].section('(', 0, 0) == base) {
            m_defNames.removeAt(i);
            m_defSrc.removeAt(i);
            break;
        }
    }
    m_defNames << name;
    m_defSrc << src;
    m_sci->setDefinitionNames(m_defNames);
    saveState();
}

void MainWindow::removeDefinition(const QString &base)
{
    for (int i = m_defNames.size() - 1; i >= 0; --i) {
        const QString b = m_defNames[i].section('(', 0, 0);
        if (!base.isEmpty() && b != base) continue;
        Request rq;
        rq.kind = Request::Undefine;
        rq.text = b;
        m_cas->submit(rq);
        m_defNames.removeAt(i);
        m_defSrc.removeAt(i);
    }
    m_sci->setDefinitionNames(m_defNames);
    saveState();
}

void MainWindow::loadState()
{
    QFile f(statePath());
    QJsonObject root;
    if (f.open(QIODevice::ReadOnly)) root = QJsonDocument::fromJson(f.readAll()).object();
    for (auto v : root["definitions"].toArray()) {
        QJsonObject d = v.toObject();
        m_defNames << d["name"].toString();
        m_defSrc << d["src"].toString();
    }
    m_cas->setDefinitions(m_defSrc);
    m_sci->setDefinitionNames(m_defNames);
    m_sci->load(root["scientific"].toObject());
    m_eq->load(root["equations"].toObject());
    m_calc->load(root["calculus"].toObject());
    m_graph->load(root["graphs"].toObject());
    m_tabs->setCurrentIndex(root["tab"].toInt());
}

void MainWindow::saveState() const
{
    QJsonObject root;
    QJsonArray defs;
    for (int i = 0; i < m_defNames.size(); ++i) defs.append(QJsonObject{{"name", m_defNames[i]}, {"src", m_defSrc[i]}});
    root["definitions"] = defs;
    QJsonObject s, e, c, g;
    m_sci->save(s);
    m_eq->save(e);
    m_calc->save(c);
    m_graph->save(g);
    root["scientific"] = s;
    root["equations"] = e;
    root["calculus"] = c;
    root["graphs"] = g;
    root["tab"] = m_tabs->currentIndex();
    QFile f(statePath());
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) f.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
}

void MainWindow::closeEvent(QCloseEvent *e)
{
    saveState();
    e->accept();
}
