#include "pages.h"
#include "cas.h"
#include "theme.h"
#include "widgets.h"
#include "plot2d.h"
#include "mathrender.h"
#include <QComboBox>
#include <QHBoxLayout>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QPlainTextEdit>
#include <QPushButton>
#include <QSplitter>
#include <QToolButton>

namespace {
struct Example {
    const char *name;
    const char *text;
    bool complex;
};
const Example kExamples[] = {
    {"Ecuación de 2º grado", "x^2 - 5x + 6 = 0", false},
    {"Trigonométrica (soluciones periódicas)", "2 sen(x) = 1", false},
    {"Raíces complejas", "x^4 = 16", true},
    {"Sin fórmula exacta (numérica)", "cos(x) = x", false},
    {"Sistema lineal 2×2", "2x + 3y = 7\nx - y = 1", false},
    {"Sistema lineal 3×3", "x + y + z = 6\n2x - y + z = 3\nx + 2y - z = 2", false},
    {"Sistema compatible indeterminado", "x + y + z = 1\n2x + 2y + 2z = 2", false},
    {"Sistema incompatible", "x + y = 1\nx + y = 3", false},
    {"Sistema no lineal", "x^2 + y^2 = 25\ny = x + 1", false},
    {"Inecuación racional", "(x - 1)/(x + 2) >= 0", false},
    {"Sistema de inecuaciones (1 incógnita)", "x^2 < 9\n2x + 1 > 0", false},
    {"Inecuación con valor absoluto", "abs(x - 1) <= 2", false},
    {"Región del plano (programación lineal)", "x + y <= 6\nx - y >= -2\nx >= 0\ny >= 0", false},
    {"Región no lineal", "y > x^2 - 4\nx^2 + y^2 < 16", false},
};
}

EqPage::EqPage(Cas *cas, QWidget *parent) : Page(cas, parent)
{
    auto *root = new QHBoxLayout(this);
    root->setContentsMargins(12, 8, 12, 12);
    auto *split = new QSplitter(Qt::Horizontal);
    root->addWidget(split);

    auto *left = new QWidget;
    auto *v = new QVBoxLayout(left);
    v->setContentsMargins(0, 0, 6, 0);
    v->setSpacing(8);
    auto *hint = new QLabel(QString::fromUtf8("Una ecuación o inecuación por línea. Usa =, <, >, <=, >= (o ≤ ≥). "
                                              "Se admiten cadenas como 1 < x ≤ 3."));
    hint->setProperty("role", "dim");
    hint->setWordWrap(true);
    v->addWidget(hint);
    m_text = new QPlainTextEdit;
    QFont mf(Theme::get().mono);
    mf.setPixelSize(16);
    m_text->setFont(mf);
    m_text->setPlaceholderText("2x + 3y = 7\nx - y = 1");
    m_text->setMinimumHeight(110);
    m_text->setMaximumHeight(200);
    m_text->installEventFilter(this);
    v->addWidget(m_text);

    auto *row = new QHBoxLayout;
    m_vars = new QLineEdit;
    m_vars->setPlaceholderText(QString::fromUtf8("Incógnitas (automático)"));
    m_vars->setToolTip(QString::fromUtf8("Opcional: x, y, z… Si lo dejas vacío se detectan solas"));
    connect(m_vars, &QLineEdit::returnPressed, this, &EqPage::solve);
    row->addWidget(m_vars, 1);
    m_domain = new QComboBox;
    m_domain->addItems({QString::fromUtf8("Reales  ℝ"), QString::fromUtf8("Complejos  ℂ")});
    row->addWidget(m_domain);
    auto *ex = new QToolButton;
    ex->setText(QString::fromUtf8("Ejemplos ▾"));
    ex->setPopupMode(QToolButton::InstantPopup);
    auto *menu = new QMenu(ex);
    for (const Example &e : kExamples) {
        menu->addAction(QString::fromUtf8(e.name), this, [this, e] {
            m_text->setPlainText(QString::fromUtf8(e.text));
            m_vars->clear();
            m_domain->setCurrentIndex(e.complex ? 1 : 0);
            solve();
        });
    }
    ex->setMenu(menu);
    row->addWidget(ex);
    auto *go = new QPushButton(QString::fromUtf8("Resolver"));
    go->setProperty("role", "primary");
    go->setToolTip(QString::fromUtf8("Ctrl+Intro"));
    connect(go, &QPushButton::clicked, this, &EqPage::solve);
    row->addWidget(go);
    v->addLayout(row);

    m_results = new ResultList;
    m_results->setMessage(QString::fromUtf8("Escribe el problema y pulsa Resolver (Ctrl+Intro). En «Ejemplos» tienes casos de todo tipo."));
    v->addWidget(m_results, 1);
    split->addWidget(left);

    m_plot = new PlotStack;
    m_plot->plot2d()->setPlaceholder(QString::fromUtf8("Aquí se representan las ecuaciones y regiones (1 o 2 incógnitas reales)"));
    split->addWidget(m_plot);
    split->setStretchFactor(0, 1);
    split->setStretchFactor(1, 1);
    split->setSizes({480, 480});
}

bool EqPage::eventFilter(QObject *o, QEvent *e)
{
    if (o == m_text && e->type() == QEvent::KeyPress) {
        auto *k = static_cast<QKeyEvent *>(e);
        if ((k->key() == Qt::Key_Return || k->key() == Qt::Key_Enter) && (k->modifiers() & Qt::ControlModifier)) {
            solve();
            return true;
        }
    }
    return Page::eventFilter(o, e);
}

void EqPage::solve()
{
    QStringList lines = m_text->toPlainText().split('\n', Qt::SkipEmptyParts);
    if (lines.isEmpty()) return;
    Request rq;
    rq.kind = Request::Solve;
    rq.lines = lines;
    rq.params["vars"] = m_vars->text();
    rq.params["complex"] = m_domain->currentIndex() == 1;
    m_last = submit(rq);
    m_results->setMessage(QString::fromUtf8("Resolviendo…"));
}

void EqPage::onResponse(const Response &r)
{
    if (r.id != m_last) return;
    if (!r.ok) {
        m_results->setError(r.error);
        return;
    }
    m_results->setItems(r.items);
    if (r.plot && !r.plot->series.empty()) m_plot->setSpec(r.plot);
    else m_plot->clear();
}

void EqPage::save(QJsonObject &o) const
{
    o["text"] = m_text->toPlainText();
    o["vars"] = m_vars->text();
    o["complex"] = m_domain->currentIndex() == 1;
}

void EqPage::load(const QJsonObject &o)
{
    m_text->setPlainText(o["text"].toString());
    m_vars->setText(o["vars"].toString());
    m_domain->setCurrentIndex(o["complex"].toBool() ? 1 : 0);
}
