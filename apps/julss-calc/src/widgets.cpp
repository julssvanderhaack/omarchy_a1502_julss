#include "widgets.h"
#include "mathrender.h"
#include "plot2d.h"
#include "plot3d.h"
#include "theme.h"
#include <QApplication>
#include <QClipboard>
#include <QHBoxLayout>
#include <QScrollBar>
#include <QToolButton>

FormulaView::FormulaView(QWidget *parent) : QScrollArea(parent)
{
    m_math = new MathWidget;
    setWidget(m_math);
    setWidgetResizable(true);
    setHorizontalScrollBarPolicy(Qt::ScrollBarAsNeeded);
    setVerticalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    setFrameShape(QFrame::NoFrame);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Fixed);
    viewport()->setAutoFillBackground(false);
    m_math->setAutoFillBackground(false);
}

void FormulaView::setFormula(MPtr f, double px)
{
    m_math->setPixelSize(px);
    m_math->setFormula(std::move(f));
    updateGeometry();
}

void FormulaView::setAlignment(Qt::Alignment a)
{
    m_math->setAlignment(a);
    QScrollArea::setAlignment(a | Qt::AlignVCenter);
}

QSize FormulaView::sizeHint() const
{
    QSize s = m_math->sizeHint();
    return QSize(std::min(s.width(), 2000), s.height() + horizontalScrollBar()->sizeHint().height());
}

QSize FormulaView::minimumSizeHint() const
{
    return QSize(60, sizeHint().height());
}

QWidget *copyButtons(const ResultItem &it, QWidget *parent)
{
    auto *w = new QWidget(parent);
    auto *h = new QHBoxLayout(w);
    h->setContentsMargins(0, 0, 0, 0);
    h->setSpacing(2);
    h->addStretch();
    auto add = [&](const QString &label, const QString &tip, const QString &text) {
        if (text.isEmpty()) return;
        auto *b = new QToolButton(w);
        b->setText(label);
        b->setToolTip(tip);
        b->setProperty("role", "tiny");
        b->setCursor(Qt::PointingHandCursor);
        QObject::connect(b, &QToolButton::clicked, b, [text] { QApplication::clipboard()->setText(text); });
        h->addWidget(b);
    };
    add("Copiar", QString::fromUtf8("Copiar como texto (se puede pegar como entrada)"), it.text);
    add("LaTeX", QString::fromUtf8("Copiar en LaTeX"), it.latex);
    return w;
}

ResultList::ResultList(QWidget *parent) : QScrollArea(parent)
{
    m_body = new QWidget;
    m_layout = new QVBoxLayout(m_body);
    m_layout->setContentsMargins(4, 4, 4, 4);
    m_layout->setSpacing(10);
    m_layout->addStretch();
    setWidget(m_body);
    setWidgetResizable(true);
    setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
}

void ResultList::clear()
{
    while (m_layout->count() > 1) {
        QLayoutItem *it = m_layout->takeAt(0);
        delete it->widget();
        delete it;
    }
}

void ResultList::setMessage(const QString &msg)
{
    clear();
    auto *l = new QLabel(msg);
    l->setWordWrap(true);
    l->setProperty("role", "dim");
    m_layout->insertWidget(0, l);
}

void ResultList::setError(const QString &msg)
{
    clear();
    auto *l = new QLabel(msg);
    l->setWordWrap(true);
    l->setProperty("role", "error");
    l->setTextInteractionFlags(Qt::TextSelectableByMouse);
    m_layout->insertWidget(0, l);
}

void ResultList::setItems(const std::vector<ResultItem> &items)
{
    clear();
    int pos = 0;
    bool first = true;
    for (const ResultItem &it : items) {
        auto *card = new QFrame;
        card->setProperty("role", "card");
        auto *v = new QVBoxLayout(card);
        v->setContentsMargins(12, 8, 12, 6);
        v->setSpacing(2);
        if (!it.caption.isEmpty()) {
            auto *cap = new QLabel(it.caption);
            cap->setProperty("role", "caption");
            cap->setWordWrap(true);
            v->addWidget(cap);
        }
        if (it.formula) {
            auto *f = new FormulaView;
            const bool table = it.formula && it.formula->kind == MNode::Matrix && !it.formula->text.isEmpty();   // Ruffini / long division
            f->setFormula(it.formula, first || table ? 22 : 19);
            v->addWidget(f);
        }
        if (!it.text.isEmpty() || !it.latex.isEmpty()) v->addWidget(copyButtons(it, card));
        m_layout->insertWidget(pos++, card);
        first = false;
    }
    verticalScrollBar()->setValue(0);
}

PlotStack::PlotStack(QWidget *parent) : QStackedWidget(parent)
{
    m_2d = new Plot2D;
    m_3d = new Plot3D;
    addWidget(m_2d);
    addWidget(m_3d);
}

void PlotStack::setSpec(PlotPtr spec, bool resetView)
{
    if (spec && spec->is3D) {
        m_3d->setSpec(spec);
        if (resetView) m_3d->resetView();
        setCurrentWidget(m_3d);
    } else {
        m_2d->setSpec(spec, resetView);
        setCurrentWidget(m_2d);
    }
}

void PlotStack::clear()
{
    m_2d->setSpec(nullptr);
    m_3d->setSpec(nullptr);
    setCurrentWidget(m_2d);
}
