#include "mathrender.h"
#include "theme.h"
#include <QFontMetricsF>
#include <QPainter>
#include <QSet>

namespace MathRender {

namespace {

struct Style {
    double base;        // pixel size at level 0
    int level = 0;      // 0 normal, 1 inside fractions, 2 scripts, 3 script-scripts
    bool inFrac = false;
    double px() const
    {
        static const double f[] = {1.0, 0.86, 0.7, 0.58};
        return base * f[std::min(level, 3)];
    }
    Style script() const { Style s = *this; s.level = std::min(level + 2, 3); return s; }
    Style fracChild() const
    {
        Style s = *this;
        if (level == 0 && !inFrac) s.inFrac = true;
        else s.level = std::min(level + 1, 3);
        return s;
    }
};

QFont font(double px, bool italic = false)
{
    QFont f(Theme::get().serif);
    f.setPixelSize(std::max(6, int(std::lround(px))));
    f.setItalic(italic);
    f.setStyleStrategy(QFont::PreferAntialias);
    return f;
}

double axisOf(double px) { return QFontMetricsF(font(px)).strikeOutPos(); }

BoxP textBox(const QString &s, double px, bool italic)
{
    auto b = std::make_shared<Box>();
    QFont f = font(px, italic);
    QFontMetricsF fm(f);
    QRectF tight = fm.tightBoundingRect(s);
    b->w = fm.horizontalAdvance(s) + (italic ? px * 0.06 : 0);
    b->a = std::max(-tight.top(), fm.xHeight()) + px * 0.04;
    b->d = std::max(tight.bottom(), 0.0) + px * 0.04;
    b->glyphs.push_back({QPointF(0, 0), s, f});
    return b;
}

BoxP spaceBox(double w)
{
    auto b = std::make_shared<Box>();
    b->w = w;
    return b;
}

BoxP build(const MPtr &n, const Style &st);

BoxP rowBox(const std::vector<BoxP> &items)
{
    auto b = std::make_shared<Box>();
    double x = 0;
    for (auto &k : items) {
        if (!k) continue;
        b->kids.push_back({QPointF(x, 0), k});
        x += k->w;
        b->a = std::max(b->a, k->a);
        b->d = std::max(b->d, k->d);
    }
    b->w = x;
    return b;
}

bool isRelation(const QString &op)
{
    static const QSet<QString> rel = {"=", "<", ">", QString::fromUtf8("≤"), QString::fromUtf8("≥"), QString::fromUtf8("≠"),
                                      QString::fromUtf8("≈"), QString::fromUtf8("∈"), QString::fromUtf8("→"),
                                      ":=", QString::fromUtf8("⟹"), QString::fromUtf8("∧"), QString::fromUtf8("∨"), "mod"};
    return rel.contains(op);
}

BoxP opBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    BoxP g = textBox(n.text, px, false);
    if (n.n == 1) {  // unary minus/plus: tight
        g->w += px * 0.04;
        return g;
    }
    double gap = (isRelation(n.text) ? 0.28 : 0.2) * px * (st.level >= 2 ? 0.5 : 1.0);
    if (n.text == QString::fromUtf8("→") && st.level >= 2) gap = px * 0.08;
    return rowBox({spaceBox(gap), g, spaceBox(gap)});
}

BoxP fracBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    Style cs = st.fracChild();
    BoxP num = build(n.c[0], cs), den = build(n.c[1], cs);
    const double t = std::max(1.0, px * 0.055), gap = px * 0.16, axis = axisOf(px), pad = px * 0.12;
    auto b = std::make_shared<Box>();
    b->w = std::max(num->w, den->w) + 2 * pad;
    const double numBase = -axis - t / 2 - gap - num->d;
    const double denBase = -axis + t / 2 + gap + den->a;
    b->kids.push_back({QPointF((b->w - num->w) / 2, numBase), num});
    b->kids.push_back({QPointF((b->w - den->w) / 2, denBase), den});
    QPainterPath bar;
    bar.addRect(QRectF(px * 0.04, -axis - t / 2, b->w - px * 0.08, t));
    b->strokes.push_back({bar, 0, true});
    b->a = -numBase + num->a;
    b->d = denBase + den->d;
    return b;
}

BoxP powBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    BoxP base = build(n.c[0], st), ex = build(n.c[1], st.script());
    double shift = std::max(px * 0.42, base->a - ex->a * 0.45);
    auto b = std::make_shared<Box>();
    b->kids.push_back({QPointF(0, 0), base});
    b->kids.push_back({QPointF(base->w + px * 0.04, -shift), ex});
    b->w = base->w + px * 0.04 + ex->w + px * 0.03;
    b->a = std::max(base->a, shift + ex->a);
    b->d = std::max(base->d, ex->d - shift);
    return b;
}

BoxP subBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    BoxP base = build(n.c[0], st), sb = build(n.c[1], st.script());
    double shift = std::max(px * 0.2, base->d + sb->a * 0.3);
    auto b = std::make_shared<Box>();
    b->kids.push_back({QPointF(0, 0), base});
    b->kids.push_back({QPointF(base->w + px * 0.02, shift), sb});
    b->w = base->w + px * 0.02 + sb->w + px * 0.03;
    b->a = std::max(base->a, sb->a - shift);
    b->d = std::max(base->d, shift + sb->d);
    return b;
}

BoxP sqrtBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    BoxP c = build(n.c[0], st);
    const double t = std::max(1.0, px * 0.06), clear = px * 0.14;
    const double top = -(c->a + clear), bottom = c->d + px * 0.02;
    const double H = bottom - top;
    const double sw = px * 0.42 + H * 0.12;
    BoxP idx = n.c.size() > 1 && n.c[1] ? build(n.c[1], Style{st.base, 3}) : nullptr;
    const double off = idx ? std::max(0.0, idx->w - sw * 0.45) : 0;

    auto b = std::make_shared<Box>();
    QPainterPath p;
    const double ymid = bottom - H * 0.42;
    p.moveTo(off + 0, ymid + px * 0.05);
    p.lineTo(off + sw * 0.22, ymid - px * 0.04);
    p.lineTo(off + sw * 0.52, bottom);
    p.lineTo(off + sw, top);
    p.lineTo(off + sw + c->w + px * 0.12, top);
    b->strokes.push_back({p, t, false});
    b->kids.push_back({QPointF(off + sw + px * 0.04, 0), c});
    if (idx) b->kids.push_back({QPointF(0, ymid - px * 0.12 - idx->d), idx});
    b->w = off + sw + c->w + px * 0.18;
    b->a = c->a + clear + t;
    if (idx) b->a = std::max(b->a, -(ymid - px * 0.12 - idx->d) + idx->a);
    b->d = bottom + t;
    return b;
}

void delimPath(QPainterPath &p, QChar ch, double x, double w, double top, double bottom, bool closing)
{
    auto X = [&](double fx) { return closing ? x + w - fx : x + fx; };
    const double mid = (top + bottom) / 2, H = bottom - top;
    switch (ch.unicode()) {
    case '(':
    case ')':
        p.moveTo(X(w * 0.85), top);
        p.quadTo(X(-w * 0.15), mid, X(w * 0.85), bottom);
        break;
    case '[':
    case ']':
        p.moveTo(X(w * 0.85), top);
        p.lineTo(X(w * 0.3), top);
        p.lineTo(X(w * 0.3), bottom);
        p.lineTo(X(w * 0.85), bottom);
        break;
    case '{':
    case '}':
        p.moveTo(X(w * 0.9), top);
        p.quadTo(X(w * 0.45), top, X(w * 0.45), top + H * 0.15);
        p.lineTo(X(w * 0.45), mid - H * 0.12);
        p.quadTo(X(w * 0.45), mid, X(w * 0.05), mid);
        p.quadTo(X(w * 0.45), mid, X(w * 0.45), mid + H * 0.12);
        p.lineTo(X(w * 0.45), bottom - H * 0.15);
        p.quadTo(X(w * 0.45), bottom, X(w * 0.9), bottom);
        break;
    case '|':
        p.moveTo(X(w * 0.5), top);
        p.lineTo(X(w * 0.5), bottom);
        break;
    case 0x230A:  // ⌊
    case 0x230B:
        p.moveTo(X(w * 0.3), top);
        p.lineTo(X(w * 0.3), bottom);
        p.lineTo(X(w * 0.85), bottom);
        break;
    case 0x2308:  // ⌈
    case 0x2309:
        p.moveTo(X(w * 0.85), top);
        p.lineTo(X(w * 0.3), top);
        p.lineTo(X(w * 0.3), bottom);
        break;
    default:
        break;
    }
}

BoxP parenBox(const BoxP &c, const QString &kind, const Style &st)
{
    const double px = st.px();
    QChar open = kind.size() > 0 ? kind[0] : QChar('('), close = kind.size() > 1 ? kind[1] : QChar(')');
    const double axis = axisOf(px);
    QFontMetricsF fm(font(px));
    const bool small = c->a <= fm.ascent() * 1.02 && c->d <= fm.descent() * 1.5 && open != '|';
    auto b = std::make_shared<Box>();
    if (small) {
        BoxP o = textBox(QString(open), px, false), cl = textBox(QString(close), px, false);
        o->a = cl->a = std::max(o->a, c->a);
        auto r = rowBox({o, spaceBox(px * 0.03), c, spaceBox(px * 0.03), cl});
        return r;
    }
    const double half = std::max(c->a - axis, c->d + axis) + px * 0.12;
    const double top = -axis - half, bottom = -axis + half, H = bottom - top;
    const double dw = std::min(px * 0.22 + H * 0.06, px * 0.55);
    const double t = std::max(1.0, px * 0.065);
    QPainterPath p;
    delimPath(p, open, 0, dw, top, bottom, false);
    const double cx = dw + px * 0.06;
    delimPath(p, close, cx + c->w + px * 0.06, dw, top, bottom, true);
    b->strokes.push_back({p, t, false});
    b->kids.push_back({QPointF(cx, 0), c});
    b->w = cx + c->w + px * 0.06 + dw;
    b->a = -top + t;
    b->d = bottom + t;
    return b;
}

BoxP matrixBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    const int cols = std::max(1, n.n);
    const int rows = int((n.c.size() + cols - 1) / cols);
    std::vector<BoxP> cells;
    for (auto &c : n.c) cells.push_back(build(c, st));
    std::vector<double> cw(cols, 0), ra(rows, 0), rd(rows, 0);
    for (int i = 0; i < int(cells.size()); ++i) {
        int r = i / cols, c = i % cols;
        cw[c] = std::max(cw[c], cells[i]->w);
        ra[r] = std::max(ra[r], std::max(cells[i]->a, px * 0.6));
        rd[r] = std::max(rd[r], std::max(cells[i]->d, px * 0.2));
    }
    // "ruffini": synthetic division table (root column, rule above the last
    // row, boxed remainder). "longdiv:r,r…": long division with the divisor
    // and quotient in the last column and a rule above each listed row.
    // Both right align cells like hand-written sums.
    const bool ruffini = n.text == "ruffini";
    const bool longdiv = n.text.startsWith("longdiv");
    const bool right = ruffini || longdiv;
    const double cg = px * (ruffini ? 1.1 : longdiv ? 0.5 : 0.8), rg = px * (right ? 0.55 : 0.25);
    double H = 0;
    for (int r = 0; r < rows; ++r) H += ra[r] + rd[r] + (r ? rg : 0);
    const double axis = axisOf(px);
    double y = -axis - H / 2;
    const double top = y;
    auto b = std::make_shared<Box>();
    std::vector<double> rowTop(rows), rowBottom(rows), colLeft(cols);
    for (int r = 0; r < rows; ++r) {
        if (r) y += rg;
        rowTop[r] = y;
        y += ra[r];
        double x = 0;
        for (int c = 0; c < cols; ++c) {
            colLeft[c] = x;
            int i = r * cols + c;
            if (i < int(cells.size()))
                b->kids.push_back({QPointF(x + (longdiv && c == cols - 1 ? 0 : right ? cw[c] - cells[i]->w : (cw[c] - cells[i]->w) / 2), y), cells[i]});
            x += cw[c] + cg;
        }
        y += rd[r];
        rowBottom[r] = y;
    }
    double w = -cg;
    for (double c : cw) w += c + cg;
    if (ruffini && cols > 2 && rows >= 3) {
        const double t = std::max(1.0, px * 0.055), pad = cg / 2;
        QPainterPath p;
        const double vx = colLeft[1] - pad;
        p.moveTo(vx, top - rg / 3);
        p.lineTo(vx, rowBottom[rows - 2] + rg / 2);
        p.moveTo(vx - cw[0] - pad, rowBottom[rows - 2] + rg / 2);
        p.lineTo(w + pad / 2, rowBottom[rows - 2] + rg / 2);
        const double rx = colLeft[cols - 1] - pad;   // remainder box
        p.moveTo(rx, rowBottom[rows - 2] + rg / 2);
        p.lineTo(rx, rowBottom[rows - 1] + rg / 3);
        p.lineTo(w + pad / 2, rowBottom[rows - 1] + rg / 3);
        b->strokes.push_back({p, t, false});
        w += pad / 2;
    }
    if (longdiv && cols > 1 && rows >= 2) {
        const double t = std::max(1.0, px * 0.055), pad = px * 0.5;
        QPainterPath p;
        const double vx = colLeft[cols - 1] - pad / 2, hy = rowBottom[0] + rg / 2;
        p.moveTo(vx, top - rg / 3);   // the box around the divisor
        p.lineTo(vx, hy);
        p.lineTo(w + pad / 2, hy);
        for (const QString &part : n.text.section(':', 1).split(',', Qt::SkipEmptyParts)) {
            const int r = part.toInt();
            if (r < 1 || r >= rows) continue;
            int c0 = cols, c1 = -1;   // under the terms of the subtraction above
            for (int c = 0; c < cols - 1; ++c)
                if (cells[(r - 1) * cols + c]->w > 0) c0 = std::min(c0, c), c1 = c;
            if (c1 < 0) continue;
            const double ly = rowBottom[r - 1] + rg / 2;
            p.moveTo(colLeft[c0] - cg / 2, ly);
            p.lineTo(colLeft[c1] + cw[c1] + cg / 4, ly);
        }
        b->strokes.push_back({p, t, false});
        w += pad / 2;
    }
    b->w = w;
    b->a = -top;
    b->d = y + (right ? rg / 3 + 1 : 0);
    return b;
}

BoxP bigopBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    const bool integral = n.text == QString::fromUtf8("∫");
    BoxP body = build(n.c[0], st);
    BoxP lo = n.c.size() > 1 && n.c[1] ? build(n.c[1], st.script()) : nullptr;
    BoxP hi = n.c.size() > 2 && n.c[2] ? build(n.c[2], st.script()) : nullptr;
    const double axis = axisOf(px);
    QFont sf = font(px * (integral ? 1.75 : 1.45), false);
    if (integral) sf.setItalic(false);
    QFontMetricsF fm(sf);
    QRectF tr = fm.tightBoundingRect(n.text);
    const double symH = tr.height();
    // centre the symbol on the maths axis
    const double symBase = -axis + symH / 2 - tr.bottom();
    auto b = std::make_shared<Box>();
    const double symTop = symBase + tr.top(), symBottom = symBase + tr.bottom();
    double x = 0, symW = fm.horizontalAdvance(n.text);
    if (integral) {
        b->glyphs.push_back({QPointF(0, symBase), n.text, sf});
        double lx = symW * 0.85;
        double right = symW;
        if (hi) {
            b->kids.push_back({QPointF(lx + px * 0.05, symTop + hi->a * 0.85), hi});
            right = std::max(right, lx + px * 0.05 + hi->w);
        }
        if (lo) {
            b->kids.push_back({QPointF(lx - px * 0.15, symBottom + lo->a * 0.2), lo});
            right = std::max(right, lx - px * 0.15 + lo->w);
        }
        x = right + px * 0.12;
        b->a = std::max(-symTop, hi ? -(symTop + hi->a * 0.85) + hi->a : 0.0);
        b->d = std::max(symBottom, lo ? symBottom + lo->a * 0.2 + lo->d : 0.0);
    } else {
        double colW = std::max({symW, lo ? lo->w : 0.0, hi ? hi->w : 0.0});
        b->glyphs.push_back({QPointF((colW - symW) / 2, symBase), n.text, sf});
        b->a = -symTop;
        b->d = symBottom;
        if (hi) {
            double yb = symTop - px * 0.12 - hi->d;
            b->kids.push_back({QPointF((colW - hi->w) / 2, yb), hi});
            b->a = -yb + hi->a;
        }
        if (lo) {
            double yb = symBottom + px * 0.12 + lo->a;
            b->kids.push_back({QPointF((colW - lo->w) / 2, yb), lo});
            b->d = yb + lo->d;
        }
        x = colW + px * 0.15;
    }
    b->kids.push_back({QPointF(x, 0), body});
    b->w = x + body->w;
    b->a = std::max(b->a, body->a);
    b->d = std::max(b->d, body->d);
    return b;
}

BoxP underBox(const MNode &n, const Style &st)
{
    const double px = st.px();
    BoxP base = build(n.c[0], st), u = build(n.c[1], st.script());
    auto b = std::make_shared<Box>();
    double w = std::max(base->w, u->w);
    b->kids.push_back({QPointF((w - base->w) / 2, 0), base});
    double yb = base->d + px * 0.08 + u->a;
    b->kids.push_back({QPointF((w - u->w) / 2, yb), u});
    b->w = w;
    b->a = base->a;
    b->d = yb + u->d;
    return b;
}

bool italicName(const QString &s)
{
    static const QSet<QString> upright = {QString::fromUtf8("∞"), QString::fromUtf8("ℝ"), QString::fromUtf8("ℂ"), QString::fromUtf8("ℤ")};
    if (upright.contains(s)) return false;
    for (QChar c : s)
        if (!c.isLetter()) return false;
    return true;
}

BoxP build(const MPtr &n, const Style &st)
{
    if (!n) return spaceBox(0);
    const double px = st.px();
    switch (n->kind) {
    case MNode::Row: {
        std::vector<BoxP> items;
        for (auto &c : n->c) items.push_back(build(c, st));
        auto b = rowBox(items);
        if (b->a == 0 && b->d == 0) b->a = px * 0.5;
        return b;
    }
    case MNode::Num: return textBox(n->text, px, false);
    case MNode::Var: return textBox(n->text, px, italicName(n->text));
    case MNode::Text: return textBox(n->text, px, false);
    case MNode::Op: return opBox(*n, st);
    case MNode::Frac: return fracBox(*n, st);
    case MNode::Pow: return powBox(*n, st);
    case MNode::Sub: return subBox(*n, st);
    case MNode::Sqrt: return sqrtBox(*n, st);
    case MNode::Paren: return parenBox(build(n->c[0], st), n->text, st);
    case MNode::Conj: {
        BoxP c = build(n->c[0], st);
        auto b = std::make_shared<Box>();
        const double t = std::max(1.0, px * 0.055), y = -(c->a + px * 0.1);
        QPainterPath p;
        p.moveTo(px * 0.04, y);
        p.lineTo(c->w - px * 0.02, y);
        b->strokes.push_back({p, t, false});
        b->kids.push_back({QPointF(0, 0), c});
        b->w = c->w;
        b->a = c->a + px * 0.1 + t * 2;
        b->d = c->d;
        return b;
    }
    case MNode::Matrix: return matrixBox(*n, st);
    case MNode::BigOp: return bigopBox(*n, st);
    case MNode::Under: return underBox(*n, st);
    case MNode::Space: return spaceBox(px * n->n / 18.0);
    }
    return spaceBox(0);
}

} // namespace

BoxP layout(const MPtr &n, double px) { return build(n, Style{px}); }

void paint(QPainter &p, const BoxP &b, QPointF o, const QColor &color)
{
    if (!b) return;
    for (auto &g : b->glyphs) {
        p.setFont(g.f);
        p.setPen(color);
        p.drawText(o + g.pos, g.s);
    }
    for (auto &s : b->strokes) {
        QPainterPath path = s.path.translated(o);
        if (s.fill) {
            p.fillPath(path, color);
        } else {
            QPen pen(color, s.width, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
            p.strokePath(path, pen);
        }
    }
    for (auto &k : b->kids) paint(p, k.second, o + k.first, color);
}

QSizeF draw(QPainter &p, const MPtr &n, double px, QPointF topLeft, const QColor &color)
{
    BoxP b = layout(n, px);
    paint(p, b, topLeft + QPointF(0, b->a), color);
    return {b->w, b->a + b->d};
}

} // namespace MathRender

// ------------------------------------------------------------- MathWidget
MathWidget::MathWidget(QWidget *parent) : QWidget(parent)
{
    setSizePolicy(QSizePolicy::Preferred, QSizePolicy::Fixed);
}

void MathWidget::setFormula(MPtr f)
{
    m_formula = std::move(f);
    relayout();
}

void MathWidget::setPixelSize(double px)
{
    m_px = px;
    relayout();
}

void MathWidget::relayout()
{
    m_box = m_formula ? MathRender::layout(m_formula, m_px) : nullptr;
    updateGeometry();
    update();
}

QSize MathWidget::sizeHint() const
{
    if (!m_box) return {0, 0};
    const int pad = int(m_px * 0.2);
    return QSize(int(std::ceil(m_box->w)) + 2 * pad, int(std::ceil(m_box->a + m_box->d)) + 2 * pad);
}

void MathWidget::paintEvent(QPaintEvent *)
{
    if (!m_box) return;
    QPainter p(this);
    p.setRenderHint(QPainter::Antialiasing);
    p.setRenderHint(QPainter::TextAntialiasing);
    const double pad = m_px * 0.2;
    double x = pad;
    if (m_align & Qt::AlignRight) x = width() - pad - m_box->w;
    else if (m_align & Qt::AlignHCenter) x = (width() - m_box->w) / 2;
    const double y = (height() - (m_box->a + m_box->d)) / 2 + m_box->a;
    MathRender::paint(p, m_box, QPointF(x, y), m_color.isValid() ? m_color : palette().color(QPalette::WindowText));
}
