// Lays out and paints MNode formula trees (fractions, roots, powers,
// integrals, matrices...) with plain QPainter calls.
#pragma once
#include "types.h"
#include <QColor>
#include <QFont>
#include <QPainterPath>
#include <QWidget>

namespace MathRender {

struct Box;
using BoxP = std::shared_ptr<Box>;

struct Box {
    double w = 0, a = 0, d = 0;   // width, ascent, descent (baseline at y = 0)
    struct Glyph { QPointF pos; QString s; QFont f; };
    struct Stroke { QPainterPath path; double width; bool fill; };
    std::vector<Glyph> glyphs;
    std::vector<Stroke> strokes;
    std::vector<std::pair<QPointF, BoxP>> kids;
};

BoxP layout(const MPtr &n, double px);
void paint(QPainter &p, const BoxP &b, QPointF baselineLeft, const QColor &color);
// Convenience: lays out and draws in one go, returns the size used.
QSizeF draw(QPainter &p, const MPtr &n, double px, QPointF topLeft, const QColor &color);

}

class MathWidget : public QWidget {
    Q_OBJECT
public:
    explicit MathWidget(QWidget *parent = nullptr);
    void setFormula(MPtr f);
    MPtr formula() const { return m_formula; }
    void setPixelSize(double px);
    void setAlignment(Qt::Alignment a) { m_align = a; update(); }
    void setColor(const QColor &c) { m_color = c; update(); }
    QSize sizeHint() const override;
    QSize minimumSizeHint() const override { return sizeHint(); }

protected:
    void paintEvent(QPaintEvent *) override;

private:
    void relayout();
    MPtr m_formula;
    MathRender::BoxP m_box;
    double m_px = 22;
    Qt::Alignment m_align = Qt::AlignLeft;
    QColor m_color;
};
