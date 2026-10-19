#include "pages.h"
#include "cas.h"
#include "plot2d.h"
#include "theme.h"
#include "widgets.h"
#include <QGridLayout>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QScrollArea>
#include <QSplitter>
#include <QStyle>
#include <QToolButton>

namespace {

// Range fields accept plain numbers and multiples of π ("-2pi", "π/2").
double parseNum(QString s, double fallback)
{
    s = s.trimmed().replace(',', '.').replace(QString::fromUtf8("π"), "pi").replace(QString::fromUtf8("−"), "-");
    if (s.isEmpty()) return fallback;
    bool ok;
    double v = s.toDouble(&ok);
    if (ok) return v;
    QRegularExpression re("^([+-]?\\d*\\.?\\d*)\\s*\\*?\\s*pi\\s*(?:/\\s*(\\d+\\.?\\d*))?$");
    auto m = re.match(s);
    if (m.hasMatch()) {
        QString k = m.captured(1);
        double c = (k.isEmpty() || k == "+") ? 1 : k == "-" ? -1 : k.toDouble();
        double d = m.captured(2).isEmpty() ? 1 : m.captured(2).toDouble();
        return c * M_PI / d;
    }
    return fallback;
}

QString fmt(double v) { return QString::number(v, 'g', 4); }

const char *kHelp = R"HTML(<b>Qué puedes dibujar</b> (clic para añadir)<br>
<a href="sen(x)/x">sen(x)/x</a> — función y = f(x)<br>
<a href="y = x^3 - 3x">y = x³ − 3x</a><br>
<a href="x^2 + y^2 = 9">x² + y² = 9</a> — curva implícita<br>
<a href="y^2 = x^3 - x">y² = x³ − x</a> — curva elíptica<br>
<a href="y > x^2 - 2">y &gt; x² − 2</a> — región<br>
<a href="1 < x^2 + y^2 <= 4">1 &lt; x² + y² ≤ 4</a> — corona<br>
<a href="(cos(3t), sen(2t))">(cos 3t, sen 2t)</a> — paramétrica (usa t)<br>
<a href="sen(x)·cos(y)">sen(x)·cos(y)</a> — superficie 3D<br>
<a href="z = x^2 - y^2">z = x² − y²</a> — silla de montar<br>
<a href="x^2 + y^2 + z^2 = 9">x² + y² + z² = 9</a> — esfera (superficie implícita)<br>
<a href="(sqrt(x^2 + y^2) - 3)^2 + z^2 = 1">(√(x² + y²) − 3)² + z² = 1</a> — toro<br>
<a href="x^2 + y^2 - z^2 = 1">x² + y² − z² = 1</a> — hiperboloide<br>
<a href="(cos(t), sen(t), t/5)">(cos t, sen t, t/5)</a> — hélice 3D<br>
<a href="(z^2 - 1)/(z^2 + 1)">(z² − 1)/(z² + 1)</a> — función compleja (color = argumento)<br>
<a href="exp(i·x)">e^(i·x)</a> — partes real e imaginaria<br>
<span style="color:gray">Arrastra para mover · rueda para zoom (Mayús: solo x, Ctrl: solo y) · doble clic: vista inicial · clic derecho: guardar imagen</span>)HTML";

} // namespace

GraphPage::GraphPage(Cas *cas, QWidget *parent) : Page(cas, parent)
{
    auto *root = new QHBoxLayout(this);
    root->setContentsMargins(12, 8, 12, 12);
    auto *split = new QSplitter(Qt::Horizontal);
    root->addWidget(split);

    auto *left = new QWidget;
    auto *v = new QVBoxLayout(left);
    v->setContentsMargins(0, 0, 6, 0);
    v->setSpacing(8);

    auto *rowsHost = new QWidget;
    m_rowsLayout = new QVBoxLayout(rowsHost);
    m_rowsLayout->setContentsMargins(0, 0, 0, 0);
    m_rowsLayout->setSpacing(4);
    m_rowsLayout->addStretch();
    auto *rowsScroll = new QScrollArea;
    rowsScroll->setWidget(rowsHost);
    rowsScroll->setWidgetResizable(true);
    rowsScroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    v->addWidget(rowsScroll, 1);

    auto *btns = new QHBoxLayout;
    auto *add = new QPushButton(QString::fromUtf8("+ Añadir"));
    connect(add, &QPushButton::clicked, this, [this] {
        addRow();
        m_rows.back().edit->setFocus();
    });
    btns->addWidget(add);
    btns->addStretch();
    auto *go = new QPushButton(QString::fromUtf8("Dibujar"));
    go->setProperty("role", "primary");
    connect(go, &QPushButton::clicked, this, &GraphPage::draw);
    btns->addWidget(go);
    v->addLayout(btns);

    auto *ranges = new QGridLayout;
    ranges->setHorizontalSpacing(6);
    auto field = [&](const QString &ph) {
        auto *e = new QLineEdit;
        e->setPlaceholderText(ph);
        e->setMaximumWidth(90);
        connect(e, &QLineEdit::returnPressed, this, &GraphPage::draw);
        return e;
    };
    m_xmin = field("-10");
    m_xmax = field("10");
    m_ymin = field("auto");
    m_ymax = field("auto");
    m_tmin = field("-10");
    m_tmax = field("10");
    auto lab = [](const QString &s) {
        auto *l = new QLabel(s);
        l->setProperty("role", "dim");
        return l;
    };
    ranges->addWidget(lab(QString::fromUtf8("x desde")), 0, 0);
    ranges->addWidget(m_xmin, 0, 1);
    ranges->addWidget(lab("hasta"), 0, 2);
    ranges->addWidget(m_xmax, 0, 3);
    ranges->addWidget(lab(QString::fromUtf8("y desde")), 1, 0);
    ranges->addWidget(m_ymin, 1, 1);
    ranges->addWidget(lab("hasta"), 1, 2);
    ranges->addWidget(m_ymax, 1, 3);
    ranges->addWidget(lab(QString::fromUtf8("t desde")), 2, 0);
    ranges->addWidget(m_tmin, 2, 1);
    ranges->addWidget(lab("hasta"), 2, 2);
    ranges->addWidget(m_tmax, 2, 3);
    ranges->setColumnStretch(4, 1);
    v->addLayout(ranges);

    auto *help = new QLabel(QString::fromUtf8(kHelp));
    help->setWordWrap(true);
    help->setTextFormat(Qt::RichText);
    help->setStyleSheet(QString("QLabel { color: %1; font-size: 12px; } a { color: %2; }").arg(Theme::get().fgDim.name(), Theme::get().accent.name()));
    help->setText(help->text().replace("<a ", QString("<a style=\"color:%1; text-decoration:none\" ").arg(Theme::get().accent.name())));
    connect(help, &QLabel::linkActivated, this, [this](const QString &link) {
        for (auto &r : m_rows) {
            if (r.edit->text().trimmed().isEmpty()) {
                r.edit->setText(link);
                draw();
                return;
            }
        }
        addRow(link);
        draw();
    });
    auto *helpScroll = new QScrollArea;
    helpScroll->setWidget(help);
    helpScroll->setWidgetResizable(true);
    helpScroll->setMaximumHeight(300);
    v->addWidget(helpScroll);
    split->addWidget(left);

    m_plot = new PlotStack;
    split->addWidget(m_plot);
    split->setSizes({330, 640});
    split->setStretchFactor(1, 1);

    connect(m_plot->plot2d(), &Plot2D::viewChanged, this, [this](double x0, double x1, double y0, double y1) {
        m_syncing = true;
        m_xmin->setText(fmt(x0));
        m_xmax->setText(fmt(x1));
        m_ymin->setText(fmt(y0));
        m_ymax->setText(fmt(y1));
        m_syncing = false;
    });
}

void GraphPage::addRow(const QString &text)
{
    Row r;
    r.box = new QWidget;
    auto *g = new QGridLayout(r.box);
    g->setContentsMargins(0, 0, 0, 0);
    g->setHorizontalSpacing(6);
    g->setVerticalSpacing(0);
    r.swatch = new QLabel;
    r.swatch->setFixedSize(14, 14);
    r.edit = new QLineEdit(text);
    QFont mf(Theme::get().mono);
    mf.setPixelSize(15);
    r.edit->setFont(mf);
    r.edit->setPlaceholderText(QString::fromUtf8("f(x), ecuación, región…"));
    connect(r.edit, &QLineEdit::returnPressed, this, &GraphPage::draw);
    auto *del = new QToolButton;
    del->setText(QString::fromUtf8("✕"));
    del->setProperty("role", "tiny");
    del->setToolTip(QString::fromUtf8("Quitar"));
    QWidget *box = r.box;
    connect(del, &QToolButton::clicked, this, [this, box] { removeRow(box); });
    r.error = new QLabel;
    r.error->setProperty("role", "error");
    r.error->setWordWrap(true);
    r.error->hide();
    QFont ef = r.error->font();
    ef.setPixelSize(11);
    r.error->setFont(ef);
    g->addWidget(r.swatch, 0, 0);
    g->addWidget(r.edit, 0, 1);
    g->addWidget(del, 0, 2);
    g->addWidget(r.error, 1, 1, 1, 2);
    m_rowsLayout->insertWidget(m_rowsLayout->count() - 1, r.box);
    m_rows.push_back(r);
    recolor();
}

void GraphPage::removeRow(QWidget *box)
{
    for (size_t i = 0; i < m_rows.size(); ++i) {
        if (m_rows[i].box != box) continue;
        m_rows.erase(m_rows.begin() + long(i));
        box->deleteLater();
        break;
    }
    if (m_rows.empty()) addRow();
    recolor();
    draw();
}

void GraphPage::recolor()
{
    for (size_t i = 0; i < m_rows.size(); ++i)
        m_rows[i].swatch->setStyleSheet(QString("background:%1; border-radius:7px;").arg(Theme::get().series(int(i)).name()));
}

void GraphPage::draw()
{
    if (m_syncing) return;
    Request rq;
    rq.kind = Request::Plot;
    for (auto &r : m_rows) rq.lines << r.edit->text();
    double x0 = parseNum(m_xmin->text(), -10), x1 = parseNum(m_xmax->text(), 10);
    if (x1 <= x0) std::swap(x0, x1);
    if (x1 - x0 < 1e-12) x0 = -10, x1 = 10;
    rq.params["xauto"] = m_xmin->text().trimmed().isEmpty() && m_xmax->text().trimmed().isEmpty();
    rq.params["xmin"] = x0;
    rq.params["xmax"] = x1;
    double y0 = parseNum(m_ymin->text(), NAN), y1 = parseNum(m_ymax->text(), NAN);
    if (std::isfinite(y0) && std::isfinite(y1) && y1 > y0) {
        rq.params["ymin"] = y0;
        rq.params["ymax"] = y1;
    }
    rq.params["tmin"] = parseNum(m_tmin->text(), -10);
    rq.params["tmax"] = parseNum(m_tmax->text(), 10);
    m_last = submit(rq);
}

void GraphPage::onResponse(const Response &r)
{
    if (r.id != m_last) return;
    if (!r.ok) {
        if (!m_rows.empty()) {
            m_rows[0].error->setText(r.error);
            m_rows[0].error->show();
        }
        return;
    }
    for (size_t i = 0; i < m_rows.size(); ++i) {
        QString e = i < size_t(r.itemErrors.size()) ? r.itemErrors[int(i)] : QString();
        m_rows[i].error->setText(e);
        m_rows[i].error->setVisible(!e.isEmpty());
        m_rows[i].edit->setProperty("error", !e.isEmpty());
        m_rows[i].edit->style()->unpolish(m_rows[i].edit);
        m_rows[i].edit->style()->polish(m_rows[i].edit);
    }
    m_plot->setSpec(r.plot);
}

void GraphPage::save(QJsonObject &o) const
{
    QJsonArray rows;
    for (auto &r : m_rows) rows.append(r.edit->text());
    o["rows"] = rows;
    o["xmin"] = m_xmin->text();
    o["xmax"] = m_xmax->text();
    o["ymin"] = m_ymin->text();
    o["ymax"] = m_ymax->text();
    o["tmin"] = m_tmin->text();
    o["tmax"] = m_tmax->text();
}

void GraphPage::load(const QJsonObject &o)
{
    QJsonArray rows = o["rows"].toArray();
    if (rows.isEmpty()) {
        addRow(QString::fromUtf8("sen(x)"));
        addRow(QString::fromUtf8("x^2/8 - 1"));
    }
    for (auto v : rows) addRow(v.toString());
    if (m_rows.empty()) addRow();
    m_xmin->setText(o["xmin"].toString());
    m_xmax->setText(o["xmax"].toString());
    m_ymin->setText(o["ymin"].toString());
    m_ymax->setText(o["ymax"].toString());
    m_tmin->setText(o["tmin"].toString());
    m_tmax->setText(o["tmax"].toString());
    draw();
}
