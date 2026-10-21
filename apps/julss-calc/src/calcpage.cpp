#include "pages.h"
#include "cas.h"
#include "theme.h"
#include "widgets.h"
#include "plot2d.h"
#include "mathrender.h"
#include <QComboBox>
#include <QFormLayout>
#include <QHBoxLayout>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QSpinBox>
#include <QSplitter>
#include <QTimer>

namespace {
struct Op {
    const char *id;
    const char *name;
    const char *example;
};
const Op kOps[] = {
    {"diff", "Derivada", "x^3·sen(x)"},
    {"int", "Integral indefinida (primitiva)", "x^2·e^x"},
    {"defint", "Integral definida", "sen(x)^2"},
    {"double", "Integral doble", "x·y^2"},
    {"limit", "Límite", "sen(x)/x"},
    {"taylor", "Serie de Taylor", "cos(x)"},
    {"sum", "Sumatorio", "1/n^2"},
    {"grad", "Gradiente, hessiana y puntos críticos", "x^3 - 3x + y^2"},
    {"polydiv", "División de polinomios", "x^4 - 3x^2 + 2x - 5"},
    {"ruffini", "Regla de Ruffini (y factorización)", "x^3 - 6x^2 + 11x - 6"},
};
}

CalcPage::CalcPage(Cas *cas, QWidget *parent) : Page(cas, parent)
{
    auto *root = new QHBoxLayout(this);
    root->setContentsMargins(12, 8, 12, 12);
    auto *split = new QSplitter(Qt::Horizontal);
    root->addWidget(split);

    auto *left = new QWidget;
    auto *v = new QVBoxLayout(left);
    v->setContentsMargins(0, 0, 6, 0);
    v->setSpacing(8);

    m_op = new QComboBox;
    for (const Op &o : kOps) m_op->addItem(QString::fromUtf8(o.name), QString::fromUtf8(o.id));
    v->addWidget(m_op);

    auto *frow = new QHBoxLayout;
    auto *fl = new QLabel("f =");
    QFont lf(Theme::get().serif);
    lf.setPixelSize(18);
    lf.setItalic(true);
    fl->setFont(lf);
    frow->addWidget(fl);
    m_f = new QLineEdit;
    QFont mf(Theme::get().mono);
    mf.setPixelSize(17);
    m_f->setFont(mf);
    m_f->setMinimumHeight(40);
    frow->addWidget(m_f, 1);
    v->addLayout(frow);
    m_preview = new FormulaView;
    m_preview->math()->setColor(Theme::get().fgDim);
    m_preview->setMinimumHeight(40);
    v->addWidget(m_preview);

    m_form = new QFormLayout;
    m_form->setLabelAlignment(Qt::AlignRight);
    auto line = [&](const QString &ph) {
        auto *e = new QLineEdit;
        e->setPlaceholderText(ph);
        connect(e, &QLineEdit::returnPressed, this, &CalcPage::compute);
        return e;
    };
    m_g = line({});
    m_var = line(QString::fromUtf8("automática"));
    m_order = new QSpinBox;
    m_order->setRange(1, 30);
    m_a = line("0");
    m_b = line("1");
    m_var2 = line("y");
    m_c = line("0");
    m_d = line("1");
    m_point = line(QString::fromUtf8("0   (admite ∞, −∞, π…)"));
    m_dir = new QComboBox;
    m_dir->addItems({QString::fromUtf8("Por ambos lados"), QString::fromUtf8("Por la derecha (x → a⁺)"),
                     QString::fromUtf8("Por la izquierda (x → a⁻)")});
    m_form->addRow(QString::fromUtf8("Divisor"), m_g);
    m_form->addRow(QString::fromUtf8("Variable"), m_var);
    m_form->addRow(QString::fromUtf8("Orden"), m_order);
    m_form->addRow(QString::fromUtf8("Desde"), m_a);
    m_form->addRow(QString::fromUtf8("Hasta"), m_b);
    m_form->addRow(QString::fromUtf8("2ª variable"), m_var2);
    m_form->addRow(QString::fromUtf8("Desde (2ª)"), m_c);
    m_form->addRow(QString::fromUtf8("Hasta (2ª)"), m_d);
    m_form->addRow(QString::fromUtf8("Punto"), m_point);
    m_form->addRow(QString::fromUtf8("Dirección"), m_dir);
    v->addLayout(m_form);

    auto *go = new QPushButton(QString::fromUtf8("Calcular"));
    go->setProperty("role", "primary");
    connect(go, &QPushButton::clicked, this, &CalcPage::compute);
    v->addWidget(go);

    m_results = new ResultList;
    m_results->setMessage(QString::fromUtf8("Elige la operación, escribe la función y pulsa Calcular (o Intro)."));
    v->addWidget(m_results, 1);
    split->addWidget(left);

    m_plot = new PlotStack;
    m_plot->plot2d()->setPlaceholder(QString::fromUtf8("Aquí se dibujan la función y el resultado"));
    split->addWidget(m_plot);
    split->setSizes({460, 500});

    m_previewTimer = new QTimer(this);
    m_previewTimer->setSingleShot(true);
    m_previewTimer->setInterval(120);
    connect(m_previewTimer, &QTimer::timeout, this, [this] {
        if (m_f->text().trimmed().isEmpty()) {
            m_preview->setFormula(nullptr);
            return;
        }
        Request rq;
        rq.kind = Request::Preview;
        rq.text = m_f->text();
        m_previewId = submit(rq);
    });
    connect(m_f, &QLineEdit::textChanged, this, [this] { m_previewTimer->start(); });
    connect(m_f, &QLineEdit::returnPressed, this, &CalcPage::compute);
    connect(m_op, &QComboBox::currentIndexChanged, this, &CalcPage::updateFields);
    updateFields();
}

void CalcPage::updateFields()
{
    const QString op = m_op->currentData().toString();
    auto show = [&](QWidget *w, bool on) { m_form->setRowVisible(w, on); };
    const bool poly = op == "polydiv" || op == "ruffini";
    show(m_g, poly);
    m_g->setPlaceholderText(op == "ruffini" ? QString::fromUtf8("x − 2   (o solo 2; vacío = factorizar)") : "x^2 - x + 1");
    show(m_var, true);
    show(m_order, op == "diff" || op == "taylor");
    show(m_a, op == "defint" || op == "double" || op == "sum");
    show(m_b, op == "defint" || op == "double" || op == "sum");
    show(m_var2, op == "double");
    show(m_c, op == "double");
    show(m_d, op == "double");
    show(m_point, op == "limit" || op == "taylor");
    show(m_dir, op == "limit");
    m_order->setValue(op == "taylor" ? 5 : 1);
    m_var->setPlaceholderText(op == "diff" ? QString::fromUtf8("x   (o x, y para derivadas cruzadas)")
                              : op == "grad" ? QString::fromUtf8("x, y   (automáticas)")
                              : op == "sum" ? "n" : QString::fromUtf8("automática"));
    m_b->setPlaceholderText(op == "sum" ? QString::fromUtf8("∞") : "1");
    m_a->setPlaceholderText(op == "sum" ? "1" : "0");
    for (const Op &o : kOps)
        if (op == o.id) m_f->setPlaceholderText(QString::fromUtf8("p. ej.  ") + QString::fromUtf8(o.example));
}

void CalcPage::compute()
{
    QString f = m_f->text().trimmed();
    if (f.isEmpty()) f = m_f->placeholderText().section("  ", 1).trimmed();
    if (f.isEmpty()) return;
    if (m_f->text().trimmed().isEmpty()) m_f->setText(f);
    const QString op = m_op->currentData().toString();
    auto val = [](QLineEdit *e) { return e->text().trimmed().isEmpty() ? e->placeholderText().section(' ', 0, 0) : e->text().trimmed(); };
    Request rq;
    rq.kind = Request::Calc;
    rq.params["op"] = op;
    rq.params["f"] = f;
    rq.params["var"] = m_var->text();
    rq.params["g"] = op == "polydiv" && m_g->text().trimmed().isEmpty() ? m_g->placeholderText() : m_g->text();
    rq.params["order"] = m_order->value();
    rq.params["a"] = val(m_a);
    rq.params["b"] = op == "sum" && m_b->text().trimmed().isEmpty() ? "inf" : val(m_b);
    rq.params["var2"] = m_var2->text();
    rq.params["c"] = val(m_c);
    rq.params["d"] = val(m_d);
    rq.params["point"] = m_point->text().trimmed().isEmpty() ? "0" : m_point->text();
    rq.params["dir"] = m_dir->currentIndex() == 1 ? 1 : m_dir->currentIndex() == 2 ? -1 : 0;
    m_last = submit(rq);
    m_results->setMessage(QString::fromUtf8("Calculando…"));
}

void CalcPage::onResponse(const Response &r)
{
    if (r.kind == Request::Preview) {
        if (r.id == m_previewId) m_preview->setFormula(r.ok ? r.preview : nullptr, 19);
        return;
    }
    if (r.id != m_last) return;
    if (!r.ok) {
        m_results->setError(r.error);
        return;
    }
    m_results->setItems(r.items);
    if (r.plot) m_plot->setSpec(r.plot);
    else m_plot->clear();
}

void CalcPage::save(QJsonObject &o) const
{
    o["op"] = m_op->currentIndex();
    o["f"] = m_f->text();
    o["var"] = m_var->text();
    o["g"] = m_g->text();
    o["a"] = m_a->text();
    o["b"] = m_b->text();
    o["point"] = m_point->text();
}

void CalcPage::load(const QJsonObject &o)
{
    m_op->setCurrentIndex(o["op"].toInt());
    m_f->setText(o["f"].toString());
    m_var->setText(o["var"].toString());
    m_g->setText(o["g"].toString());
    m_a->setText(o["a"].toString());
    m_b->setText(o["b"].toString());
    m_point->setText(o["point"].toString());
}
