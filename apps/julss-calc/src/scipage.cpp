#include "pages.h"
#include "cas.h"
#include "mathrender.h"
#include "theme.h"
#include "widgets.h"
#include <QGridLayout>
#include <QHBoxLayout>
#include <QJsonArray>
#include <QKeyEvent>
#include <QLabel>
#include <QLineEdit>
#include <QMenu>
#include <QMouseEvent>
#include <QPushButton>
#include <QScrollArea>
#include <QScrollBar>
#include <QSpinBox>
#include <QTimer>
#include <QToolButton>

Page::Page(Cas *cas, QWidget *parent) : QWidget(parent), m_cas(cas)
{
    connect(cas, &Cas::finished, this, [this](const Response &r) {
        if (m_mine.remove(r.id)) onResponse(r);
    });
}

int Page::submit(Request r)
{
    int id = m_cas->submit(std::move(r));
    m_mine.insert(id);
    return id;
}

namespace {

struct Key {
    const char *label;
    const char *insert;   // '|' marks where the cursor goes
    const char *tip;
};

// Shown labels are pretty; inserted text is what the parser reads.
const Key kFunctions[] = {
    {"sen", "sen(|)", "Seno"}, {"cos", "cos(|)", "Coseno"}, {"tg", "tg(|)", "Tangente"},
    {"sen⁻¹", "arcsen(|)", "Arcoseno"}, {"cos⁻¹", "arccos(|)", "Arcocoseno"}, {"tg⁻¹", "arctg(|)", "Arcotangente"},
    {"senh", "senh(|)", "Seno hiperbólico"}, {"cosh", "cosh(|)", "Coseno hiperbólico"}, {"tgh", "tgh(|)", "Tangente hiperbólica"},
    {"ln", "ln(|)", "Logaritmo neperiano"}, {"log", "log(|)", "Logaritmo decimal"}, {"logₐ", "log(|, )", "Logaritmo en base a: log(x, a)"},
    {"x²", "^2", "Cuadrado"}, {"x³", "^3", "Cubo"}, {"xʸ", "^", "Potencia"},
    {"eˣ", "e^(|)", "Exponencial"}, {"10ˣ", "10^(|)", "Potencia de 10"}, {"1/x", "1/(|)", "Inverso"},
    {"√", "√(|)", "Raíz cuadrada"}, {"∛", "∛(|)", "Raíz cúbica (real)"}, {"ⁿ√", "surd(|, )", "Raíz n-ésima real: surd(x, n)"},
    {"|x|", "abs(|)", "Valor absoluto / módulo"}, {"n!", "!", "Factorial"}, {"nCr", "nCr(|, )", "Combinaciones"},
    {"π", "π", "Pi"}, {"e", "e", "Número e"}, {"i", "i", "Unidad imaginaria"},
    {"°", "°", "Grados (en modo RAD convierte a radianes)"}, {"mod", "mod(|, )", "Resto de la división entera"}, {"×10ⁿ", "*10^", "Notación científica"},
    {"Re", "Re(|)", "Parte real"}, {"Im", "Im(|)", "Parte imaginaria"}, {"arg", "arg(|)", "Argumento"},
    {"z̄", "conj(|)", "Conjugado"}, {"r∠θ", "polar(|, )", "Número complejo en forma polar: polar(r, θ)"}, {"ans", "ans", "Último resultado"},
};

struct NumKey {
    const char *label;
    const char *insert;
    const char *role;
    int colspan;
};

const NumKey kNumbers[] = {
    {"7", "7", "num", 1}, {"8", "8", "num", 1}, {"9", "9", "num", 1}, {"÷", "/", "op", 1}, {"⌫", "\b", "op", 1},
    {"4", "4", "num", 1}, {"5", "5", "num", 1}, {"6", "6", "num", 1}, {"×", "*", "op", 1}, {"C", "\f", "op", 1},
    {"1", "1", "num", 1}, {"2", "2", "num", 1}, {"3", "3", "num", 1}, {"−", "-", "op", 1}, {"(", "(", "op", 1},
    {"0", "0", "num", 1}, {".", ".", "num", 1}, {",", ", ", "num", 1}, {"+", "+", "op", 1}, {")", ")", "op", 1},
    {"x", "x", "num", 1}, {"◀", "\x01", "op", 1}, {"▶", "\x02", "op", 1}, {"=", "\n", "eq", 2},
};

class HistoryCard : public QFrame {
public:
    std::function<void()> onClick;
    using QFrame::QFrame;

protected:
    void mouseReleaseEvent(QMouseEvent *e) override
    {
        if (e->button() == Qt::LeftButton && onClick) onClick();
    }
};

} // namespace

SciPage::SciPage(Cas *cas, QWidget *parent) : Page(cas, parent)
{
    auto *root = new QHBoxLayout(this);
    root->setContentsMargins(12, 8, 12, 12);
    root->setSpacing(12);

    // ---- display column
    auto *displayCol = new QVBoxLayout;
    displayCol->setSpacing(6);
    m_histBody = new QWidget;
    m_histLayout = new QVBoxLayout(m_histBody);
    m_histLayout->setContentsMargins(0, 0, 4, 0);
    m_histLayout->setSpacing(6);
    m_histLayout->addStretch();
    m_scroll = new QScrollArea;
    m_scroll->setWidget(m_histBody);
    m_scroll->setWidgetResizable(true);
    m_scroll->setHorizontalScrollBarPolicy(Qt::ScrollBarAlwaysOff);
    displayCol->addWidget(m_scroll, 1);
    connect(m_scroll->verticalScrollBar(), &QScrollBar::rangeChanged, this, [this](int, int max) {
        m_scroll->verticalScrollBar()->setValue(max);
    });

    m_preview = new FormulaView;
    m_preview->setAlignment(Qt::AlignRight);
    m_preview->math()->setColor(Theme::get().fgDim);
    m_preview->setMinimumHeight(44);
    displayCol->addWidget(m_preview);

    auto *inputRow = new QHBoxLayout;
    m_input = new QLineEdit;
    QFont mf(Theme::get().mono);
    mf.setPixelSize(20);
    m_input->setFont(mf);
    m_input->setPlaceholderText(QString::fromUtf8("Escribe una operación: 2·sen(30°) + √2,  (3+4i)/(1−i),  f(x) = x²+1,  x² − 5x + 6 = 0 …"));
    m_input->setMinimumHeight(46);
    m_input->installEventFilter(this);
    inputRow->addWidget(m_input, 1);
    displayCol->addLayout(inputRow);

    // ---- options row
    auto *opts = new QHBoxLayout;
    m_angle = new QPushButton("RAD");
    m_angle->setCheckable(true);
    m_angle->setToolTip(QString::fromUtf8("Ángulos en radianes (RAD) o grados sexagesimales (DEG)"));
    m_angle->setFixedWidth(64);
    connect(m_angle, &QPushButton::toggled, this, [this](bool on) {
        m_angle->setText(on ? "DEG" : "RAD");
        requestPreview();
    });
    opts->addWidget(m_angle);
    auto *dl = new QLabel(QString::fromUtf8("Cifras"));
    dl->setProperty("role", "dim");
    opts->addWidget(dl);
    m_digits = new QSpinBox;
    m_digits->setRange(4, 60);
    m_digits->setValue(12);
    m_digits->setToolTip(QString::fromUtf8("Cifras significativas de los resultados decimales"));
    opts->addWidget(m_digits);
    m_memory = new QToolButton;
    m_memory->setText(QString::fromUtf8("Memoria ▾"));
    m_memory->setPopupMode(QToolButton::InstantPopup);
    m_memory->setToolTip(QString::fromUtf8("Variables y funciones guardadas (a = 5, f(x) = x² + 1)"));
    auto *menu = new QMenu(m_memory);
    m_memory->setMenu(menu);
    connect(menu, &QMenu::aboutToShow, this, [this, menu] {
        menu->clear();
        if (m_defNames.isEmpty()) {
            menu->addAction(QString::fromUtf8("No hay nada guardado. Prueba  a = 5  o  f(x) = x² + 1"))->setEnabled(false);
            return;
        }
        for (const QString &n : m_defNames) {
            menu->addAction(QString::fromUtf8("Usar  %1").arg(n), this, [this, n] {
                QString base = n.section('(', 0, 0);
                insert(n.contains('(') ? base + "(|)" : base);
            });
        }
        menu->addSeparator();
        auto *del = menu->addMenu(QString::fromUtf8("Borrar"));
        for (const QString &n : m_defNames)
            del->addAction(n, this, [this, n] { emit undefineRequested(n.section('(', 0, 0)); });
        del->addSeparator();
        del->addAction(QString::fromUtf8("Borrar todo"), this, [this] { emit undefineRequested(QString()); });
    });
    opts->addWidget(m_memory);
    opts->addStretch();
    auto *clear = new QPushButton(QString::fromUtf8("Limpiar historial"));
    connect(clear, &QPushButton::clicked, this, [this] {
        m_history.clear();
        while (m_histLayout->count() > 1) {
            QLayoutItem *it = m_histLayout->takeAt(0);
            delete it->widget();
            delete it;
        }
        m_pendingCards.clear();
    });
    opts->addWidget(clear);
    displayCol->addLayout(opts);
    root->addLayout(displayCol, 3);

    root->addWidget(buildKeypad(), 2);

    m_previewTimer = new QTimer(this);
    m_previewTimer->setSingleShot(true);
    m_previewTimer->setInterval(110);
    connect(m_previewTimer, &QTimer::timeout, this, &SciPage::requestPreview);
    connect(m_input, &QLineEdit::textChanged, this, [this] { m_previewTimer->start(); });
    connect(m_input, &QLineEdit::returnPressed, this, &SciPage::evaluate);
}

QWidget *SciPage::buildKeypad()
{
    auto *w = new QWidget;
    auto *v = new QVBoxLayout(w);
    v->setContentsMargins(0, 0, 0, 0);
    v->setSpacing(10);
    auto *fg = new QGridLayout;
    fg->setSpacing(5);
    int i = 0;
    for (const Key &k : kFunctions) {
        auto *b = new QPushButton(QString::fromUtf8(k.label));
        b->setProperty("role", "fn");
        b->setToolTip(QString::fromUtf8(k.tip));
        b->setFocusPolicy(Qt::NoFocus);
        b->setMinimumHeight(32);
        b->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        QString ins = QString::fromUtf8(k.insert);
        connect(b, &QPushButton::clicked, this, [this, ins] { insert(ins); });
        fg->addWidget(b, i / 6, i % 6);
        ++i;
    }
    v->addLayout(fg, 6);
    auto *ng = new QGridLayout;
    ng->setSpacing(5);
    int r = 0, c = 0;
    for (const NumKey &k : kNumbers) {
        auto *b = new QPushButton(QString::fromUtf8(k.label));
        b->setProperty("role", k.role);
        b->setFocusPolicy(Qt::NoFocus);
        b->setMinimumHeight(40);
        b->setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        QString ins = QString::fromUtf8(k.insert);
        connect(b, &QPushButton::clicked, this, [this, ins] {
            if (ins == "\n") evaluate();
            else if (ins == "\b") m_input->backspace();
            else if (ins == "\f") m_input->clear();
            else if (ins == "\x01") m_input->cursorBackward(false);
            else if (ins == "\x02") m_input->cursorForward(false);
            else insert(ins);
            m_input->setFocus();
        });
        ng->addWidget(b, r, c, 1, k.colspan);
        c += k.colspan;
        if (c >= 5) c = 0, ++r;
    }
    v->addLayout(ng, 5);
    return w;
}

void SciPage::focusInput() { m_input->setFocus(); }

void SciPage::insert(const QString &s)
{
    QString text = s;
    int cursorBack = 0;
    int bar = text.indexOf('|');
    QString sel = m_input->selectedText();
    if (bar >= 0) {
        text.remove(bar, 1);
        if (!sel.isEmpty()) text.insert(bar, sel), bar += sel.size();
        cursorBack = text.size() - bar;
    }
    m_input->insert(text);
    m_input->setCursorPosition(m_input->cursorPosition() - cursorBack);
    m_input->setFocus();
}

void SciPage::requestPreview()
{
    const QString t = m_input->text().trimmed();
    if (t.isEmpty()) {
        m_preview->setFormula(nullptr);
        return;
    }
    Request rq;
    rq.kind = Request::Preview;
    rq.text = t;
    rq.deg = m_angle->isChecked();
    m_previewId = submit(rq);
}

void SciPage::evaluate()
{
    const QString t = m_input->text().trimmed();
    if (t.isEmpty()) return;
    Request rq;
    rq.kind = Request::Eval;
    rq.text = t;
    rq.deg = m_angle->isChecked();
    rq.digits = m_digits->value();
    int id = submit(rq);

    auto *card = new QLabel(QString::fromUtf8("%1\nCalculando…").arg(t));
    card->setProperty("role", "dim");
    card->setAlignment(Qt::AlignRight);
    m_histLayout->insertWidget(m_histLayout->count() - 1, card);
    m_pendingCards[id] = card;
    m_pendingInput[id] = t;
    m_input->clear();
    m_recall = -1;
    m_preview->setFormula(nullptr);
}

void SciPage::onResponse(const Response &r)
{
    if (r.kind == Request::Preview) {
        if (r.id != m_previewId) return;
        m_preview->setFormula(r.ok ? r.preview : nullptr, 20);
        return;
    }
    auto it = m_pendingCards.find(r.id);
    if (it == m_pendingCards.end()) return;
    QWidget *placeholder = it->second;
    int index = m_histLayout->indexOf(placeholder);
    m_histLayout->removeWidget(placeholder);
    placeholder->deleteLater();
    m_pendingCards.erase(it);

    Entry e;
    e.input = m_pendingInput[r.id];
    m_pendingInput.erase(r.id);
    if (!r.ok) e.error = r.error;
    else e.items = r.items;
    if (r.ok && !r.definition.isEmpty()) emit defined(r.definedName, r.definition);
    m_history.push_back(e);
    if (m_history.size() > 200) m_history.erase(m_history.begin());
    addEntryWidget(e, index < 0 ? m_histLayout->count() - 1 : index);
}

void SciPage::addEntryWidget(const Entry &e, int index)
{
    auto *card = new HistoryCard;
    card->setProperty("role", "card");
    card->setCursor(Qt::PointingHandCursor);
    card->setToolTip(QString::fromUtf8("Clic para volver a editar"));
    QString input = e.input;
    card->onClick = [this, input] {
        m_input->setText(input);
        m_input->setFocus();
    };
    auto *v = new QVBoxLayout(card);
    v->setContentsMargins(12, 6, 12, 6);
    v->setSpacing(2);
    auto *in = new QLabel(e.input);
    in->setProperty("role", "dim");
    in->setAlignment(Qt::AlignRight);
    QFont mf(Theme::get().mono);
    mf.setPixelSize(13);
    in->setFont(mf);
    in->setWordWrap(true);
    v->addWidget(in);
    if (!e.error.isEmpty()) {
        auto *err = new QLabel(e.error);
        err->setProperty("role", "error");
        err->setAlignment(Qt::AlignRight);
        err->setWordWrap(true);
        v->addWidget(err);
    }
    bool first = true;
    for (const ResultItem &it : e.items) {
        if (!it.caption.isEmpty()) {
            auto *cap = new QLabel(it.caption);
            cap->setProperty("role", "caption");
            cap->setAlignment(Qt::AlignRight);
            v->addWidget(cap);
        }
        if (it.formula) {
            auto *f = new FormulaView;
            f->setAlignment(Qt::AlignRight);
            f->setFormula(it.formula, first ? 25 : 18);
            v->addWidget(f);
        }
        if (first) v->addWidget(copyButtons(it, card));
        first = false;
    }
    m_histLayout->insertWidget(index, card);
}

bool SciPage::eventFilter(QObject *o, QEvent *e)
{
    if (o == m_input && e->type() == QEvent::KeyPress) {
        auto *k = static_cast<QKeyEvent *>(e);
        if (k->key() == Qt::Key_Up || k->key() == Qt::Key_Down) {
            if (m_history.empty()) return true;
            if (m_recall < 0) m_draft = m_input->text();
            int n = int(m_history.size());
            if (k->key() == Qt::Key_Up) m_recall = m_recall < 0 ? n - 1 : std::max(0, m_recall - 1);
            else m_recall = m_recall < 0 ? -1 : m_recall + 1;
            if (m_recall >= n) m_recall = -1;
            m_input->setText(m_recall < 0 ? m_draft : m_history[m_recall].input);
            return true;
        }
    }
    return Page::eventFilter(o, e);
}

void SciPage::save(QJsonObject &o) const
{
    QJsonArray hist;
    size_t start = m_history.size() > 100 ? m_history.size() - 100 : 0;
    for (size_t i = start; i < m_history.size(); ++i) {
        const Entry &e = m_history[i];
        QJsonObject je;
        je["input"] = e.input;
        if (!e.error.isEmpty()) je["error"] = e.error;
        QJsonArray items;
        for (auto &it : e.items) {
            QJsonObject ji;
            ji["caption"] = it.caption;
            ji["text"] = it.text;
            ji["latex"] = it.latex;
            ji["formula"] = M::toJson(it.formula);
            items.append(ji);
        }
        je["items"] = items;
        hist.append(je);
    }
    o["history"] = hist;
    o["deg"] = m_angle->isChecked();
    o["digits"] = m_digits->value();
    o["draft"] = m_input->text();
}

void SciPage::load(const QJsonObject &o)
{
    m_angle->setChecked(o["deg"].toBool());
    if (o.contains("digits")) m_digits->setValue(o["digits"].toInt());
    for (auto v : o["history"].toArray()) {
        QJsonObject je = v.toObject();
        Entry e;
        e.input = je["input"].toString();
        e.error = je["error"].toString();
        for (auto iv : je["items"].toArray()) {
            QJsonObject ji = iv.toObject();
            ResultItem it;
            it.caption = ji["caption"].toString();
            it.text = ji["text"].toString();
            it.latex = ji["latex"].toString();
            it.formula = M::fromJson(ji["formula"]);
            e.items.push_back(it);
        }
        m_history.push_back(e);
    }
    // Only the latest entries get widgets; older ones stay recallable with ↑.
    size_t start = m_history.size() > 30 ? m_history.size() - 30 : 0;
    for (size_t i = start; i < m_history.size(); ++i) addEntryWidget(m_history[i], m_histLayout->count() - 1);
    m_input->setText(o["draft"].toString());
}
