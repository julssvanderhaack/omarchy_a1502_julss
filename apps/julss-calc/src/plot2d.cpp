#include "plot2d.h"
#include "mathrender.h"
#include "theme.h"
#include <QApplication>
#include <QClipboard>
#include <QContextMenuEvent>
#include <QFileDialog>
#include <QMenu>
#include <QPainter>
#include <QWheelEvent>
#include <algorithm>

namespace {

double niceStep(double span, double pixels, double target = 80)
{
    double raw = span / std::max(1.0, pixels / target);
    double mag = std::pow(10.0, std::floor(std::log10(raw)));
    double f = raw / mag;
    return mag * (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10);
}

QString tickLabel(double v, double step)
{
    if (std::fabs(v) < step * 1e-6) return "0";
    QString s = QString::number(v, 'g', 6);
    if (s.contains('e')) s = QString::number(v, 'g', 3);
    return s.replace('-', QString::fromUtf8("−"));
}

bool relHolds(int rel, double d)
{
    switch (rel) {
    case Series::Lt: return d < 0;
    case Series::Le: return d <= 0;
    case Series::Gt: return d > 0;
    case Series::Ge: return d >= 0;
    default: return d != 0;
    }
}

} // namespace

Plot2D::Plot2D(QWidget *parent) : QWidget(parent)
{
    setMouseTracking(true);
    setMinimumSize(240, 200);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
    m_placeholder = QString::fromUtf8("La gráfica aparecerá aquí");
}

void Plot2D::setSpec(PlotPtr spec, bool reset)
{
    m_spec = std::move(spec);
    if (reset) autoView();
    update();
}

void Plot2D::resizeEvent(QResizeEvent *)
{
    // The first real size decides the y-range of equal-aspect views.
    if (!m_hadSize && width() > 50) {
        m_hadSize = true;
        if (m_spec) autoView();
    }
}

void Plot2D::resetView()
{
    autoView();
    update();
    emit viewChanged(m_x0, m_x1, m_y0, m_y1);
}

void Plot2D::equalAxes()
{
    double cy = (m_y0 + m_y1) / 2;
    double half = (m_x1 - m_x0) * height() / std::max(1, width()) / 2;
    m_y0 = cy - half;
    m_y1 = cy + half;
    update();
    emit viewChanged(m_x0, m_x1, m_y0, m_y1);
}

void Plot2D::autoView()
{
    if (!m_spec) return;
    const PlotSpec &s = *m_spec;
    m_x0 = s.xmin;
    m_x1 = s.xmax;
    if (!(m_x1 > m_x0)) m_x0 = -10, m_x1 = 10;
    const double aspect = double(std::max(1, height())) / std::max(1, width());

    bool onlyPlane = true;   // implicit/region/domain/param: equal aspect is nicer
    std::vector<double> ys;
    double px0 = INFINITY, px1 = -INFINITY;
    for (auto &se : s.series) {
        if (se.kind == Series::Func || se.kind == Series::Fill) {
            onlyPlane = false;
            if (se.p.empty() || !se.p[0].valid) continue;
            for (int i = 0; i <= 400; ++i) {
                double x = m_x0 + (m_x1 - m_x0) * i / 400.0;
                if (se.complexParts) {
                    std::complex<double> z(x, 0);
                    auto v = se.p[0].evalc(&z);
                    if (std::isfinite(v.real())) ys.push_back(v.real());
                    if (std::isfinite(v.imag())) ys.push_back(v.imag());
                } else {
                    double y = se.p[0].eval1(x);
                    if (std::isfinite(y)) ys.push_back(y);
                }
            }
        } else if (se.kind == Series::Points) {
            for (auto &p : se.pts)
                if (std::isfinite(p.y())) ys.push_back(p.y());
        } else if (se.kind == Series::Param2 && se.p.size() == 2) {
            for (int i = 0; i <= 600; ++i) {
                double t = s.tmin + (s.tmax - s.tmin) * i / 600.0;
                double x = se.p[0].eval1(t), y = se.p[1].eval1(t);
                if (std::isfinite(x) && std::isfinite(y)) {
                    px0 = std::min(px0, x), px1 = std::max(px1, x);
                    ys.push_back(y);
                }
            }
        } else if (se.kind == Series::XBand) {
            onlyPlane = false;
        }
    }
    // Parametric-only plots: fit the curve itself.
    bool paramOnly = !s.series.empty() && std::all_of(s.series.begin(), s.series.end(), [](const Series &x) { return x.kind == Series::Param2; });
    if (paramOnly && std::isfinite(px0)) {
        double ymn = *std::min_element(ys.begin(), ys.end()), ymx = *std::max_element(ys.begin(), ys.end());
        double cx = (px0 + px1) / 2, cy = (ymn + ymx) / 2;
        double hw = std::max((px1 - px0) / 2, (ymx - ymn) / 2 / aspect) * 1.15 + 1e-9;
        m_x0 = cx - hw, m_x1 = cx + hw;
        m_y0 = cy - hw * aspect, m_y1 = cy + hw * aspect;
        return;
    }
    if (std::isfinite(s.ymin) && std::isfinite(s.ymax) && s.ymax > s.ymin) {
        m_y0 = s.ymin, m_y1 = s.ymax;
        return;
    }
    if (onlyPlane || s.equalAspect || ys.empty()) {
        double half = (m_x1 - m_x0) * aspect / 2;
        m_y0 = -half, m_y1 = half;
        return;
    }
    std::sort(ys.begin(), ys.end());
    double lo = ys[size_t(ys.size() * 0.03)], hi = ys[std::min(ys.size() - 1, size_t(ys.size() * 0.97))];
    lo = std::min(lo, ys.front() < lo - (hi - lo) * 2 ? lo : ys.front());
    hi = std::max(hi, ys.back() > hi + (hi - lo) * 2 ? hi : ys.back());
    if (lo > 0 && lo < (hi - lo) * 0.5) lo = 0;
    if (hi < 0 && -hi < (hi - lo) * 0.5) hi = 0;
    double span = hi - lo;
    if (span < 1e-9) span = std::max(1.0, std::fabs(lo));
    m_y0 = lo - span * 0.12;
    m_y1 = hi + span * 0.12;
}

QPointF Plot2D::toPx(double x, double y) const
{
    return QPointF((x - m_x0) / (m_x1 - m_x0) * width(), (m_y1 - y) / (m_y1 - m_y0) * height());
}

QPointF Plot2D::toData(QPointF p) const
{
    return QPointF(m_x0 + p.x() / width() * (m_x1 - m_x0), m_y1 - p.y() / height() * (m_y1 - m_y0));
}

QColor Plot2D::colorFor(const Series &s, int &next) const
{
    return Theme::get().series(s.color >= 0 ? s.color : next++);
}

void Plot2D::paintEvent(QPaintEvent *)
{
    const Theme &th = Theme::get();
    QPainter p(this);
    p.fillRect(rect(), th.bgDark);
    p.setRenderHint(QPainter::Antialiasing);
    if (!m_spec || m_spec->series.empty()) {
        p.setPen(th.fgDim);
        p.drawText(rect(), Qt::AlignCenter, m_placeholder);
        return;
    }
    // Domain colouring goes under the grid.
    int next = 0;
    for (auto &s : m_spec->series) {
        if (s.kind != Series::Domain || s.p.empty() || !s.p[0].valid) continue;
        const int W = std::max(1, width() / 2), H = std::max(1, height() / 2);
        QImage img(W, H, QImage::Format_RGB32);
        for (int j = 0; j < H; ++j) {
            auto *line = reinterpret_cast<QRgb *>(img.scanLine(j));
            double y = m_y1 - (j + 0.5) / H * (m_y1 - m_y0);
            for (int i = 0; i < W; ++i) {
                std::complex<double> z(m_x0 + (i + 0.5) / W * (m_x1 - m_x0), y);
                auto w = s.p[0].evalc(&z);
                double mag = std::abs(w);
                if (!std::isfinite(mag)) {
                    line[i] = std::isinf(mag) ? qRgb(255, 255, 255) : th.bgDark.rgb();
                    continue;
                }
                double h = std::arg(w) / (2 * M_PI);
                if (h < 0) h += 1;
                double l2 = std::log2(mag + 1e-300);
                double frac = l2 - std::floor(l2);
                double v = 0.62 + 0.38 * frac;
                double sat = 0.85 - 0.5 * std::max(0.0, std::min(1.0, (l2 - 6) / 10));
                line[i] = QColor::fromHsvF(h, std::max(0.2, sat), std::min(1.0, v)).rgb();
            }
        }
        p.drawImage(rect(), img);
        ++next;
    }
    drawGrid(p);
    drawSeries(p);
    drawLegend(p);

    if (m_mouse.x() >= 0) {
        QPointF d = toData(m_mouse);
        double step = niceStep(m_x1 - m_x0, width(), 8);
        int dec = std::max(0, int(-std::floor(std::log10(step))));
        QString s = QString("%1 = %2   %3 = %4").arg(m_spec->xname).arg(d.x(), 0, 'f', dec).arg(m_spec->yname).arg(d.y(), 0, 'f', dec);
        QFont f = font();
        f.setPixelSize(12);
        p.setFont(f);
        QRectF r = p.fontMetrics().boundingRect(s).adjusted(-8, -4, 8, 4);
        r.moveBottomRight(QPointF(width() - 8, height() - 8));
        QColor bg = th.bg;
        bg.setAlpha(220);
        p.setPen(Qt::NoPen);
        p.setBrush(bg);
        p.drawRoundedRect(r, 6, 6);
        p.setPen(th.fg);
        p.drawText(r, Qt::AlignCenter, s);
    }
}

void Plot2D::drawGrid(QPainter &p)
{
    const Theme &th = Theme::get();
    QFont f = font();
    f.setPixelSize(11);
    p.setFont(f);
    QColor grid = th.muted;
    grid.setAlpha(110);
    QColor minor = th.muted;
    minor.setAlpha(45);
    const double sx = niceStep(m_x1 - m_x0, width()), sy = niceStep(m_y1 - m_y0, height());
    // minor lines
    p.setPen(QPen(minor, 1));
    for (double x = std::ceil(m_x0 / (sx / 5)) * (sx / 5); x <= m_x1; x += sx / 5)
        p.drawLine(QPointF(toPx(x, 0).x(), 0), QPointF(toPx(x, 0).x(), height()));
    for (double y = std::ceil(m_y0 / (sy / 5)) * (sy / 5); y <= m_y1; y += sy / 5)
        p.drawLine(QPointF(0, toPx(0, y).y()), QPointF(width(), toPx(0, y).y()));
    p.setPen(QPen(grid, 1));
    for (double x = std::ceil(m_x0 / sx) * sx; x <= m_x1; x += sx)
        p.drawLine(QPointF(toPx(x, 0).x(), 0), QPointF(toPx(x, 0).x(), height()));
    for (double y = std::ceil(m_y0 / sy) * sy; y <= m_y1; y += sy)
        p.drawLine(QPointF(0, toPx(0, y).y()), QPointF(width(), toPx(0, y).y()));

    // axes
    QPointF o = toPx(0, 0);
    double ax = std::clamp(o.y(), 0.0, double(height())), ay = std::clamp(o.x(), 0.0, double(width()));
    QColor axis = th.fg;
    axis.setAlpha(170);
    p.setPen(QPen(axis, 1.3));
    if (o.y() >= 0 && o.y() <= height()) p.drawLine(QPointF(0, o.y()), QPointF(width(), o.y()));
    if (o.x() >= 0 && o.x() <= width()) p.drawLine(QPointF(o.x(), 0), QPointF(o.x(), height()));

    // tick labels, kept inside the view when the axis is off-screen
    p.setPen(th.fgDim);
    const double lx = std::clamp(ax + 4, 4.0, double(height()) - 16);
    for (double x = std::ceil(m_x0 / sx) * sx; x <= m_x1; x += sx) {
        if (std::fabs(x) < sx * 1e-6) continue;
        QPointF q = toPx(x, 0);
        p.drawText(QRectF(q.x() - 40, lx, 80, 14), Qt::AlignHCenter | Qt::AlignTop, tickLabel(x, sx));
    }
    const double ly = std::clamp(ay - 4, 40.0, double(width()) - 4);
    for (double y = std::ceil(m_y0 / sy) * sy; y <= m_y1; y += sy) {
        if (std::fabs(y) < sy * 1e-6) continue;
        QPointF q = toPx(0, y);
        p.drawText(QRectF(ly - 80, q.y() - 7, 80 - 2, 14), Qt::AlignRight | Qt::AlignVCenter, tickLabel(y, sy));
    }
    if (m_spec) {
        f.setItalic(true);
        f.setPixelSize(13);
        p.setFont(f);
        p.setPen(th.fg);
        p.drawText(QRectF(width() - 40, lx - 20, 34, 16), Qt::AlignRight, m_spec->xname);
        p.drawText(QRectF(ly + 6, 4, 40, 16), Qt::AlignLeft, m_spec->yname);
    }
}

// Marching squares over the visible area; discards sign changes caused by
// poles (where the function blows up instead of crossing zero).
void Plot2D::contour(QPainter &p, const Program &prog, const QPen &pen, int cell)
{
    const int nx = width() / cell + 1, ny = height() / cell + 1;
    std::vector<double> v(size_t(nx + 1) * (ny + 1));
    auto X = [&](int i) { return m_x0 + double(i) * cell / width() * (m_x1 - m_x0); };
    auto Y = [&](int j) { return m_y1 - double(j) * cell / height() * (m_y1 - m_y0); };
    for (int j = 0; j <= ny; ++j)
        for (int i = 0; i <= nx; ++i) v[size_t(j) * (nx + 1) + i] = prog.eval2(X(i), Y(j));
    auto at = [&](int i, int j) { return v[size_t(j) * (nx + 1) + i]; };

    QVector<QLineF> segs;
    auto crossing = [&](int i1, int j1, int i2, int j2, QPointF &out) {
        double a = at(i1, j1), b = at(i2, j2);
        if (!std::isfinite(a) || !std::isfinite(b) || (a > 0) == (b > 0)) return false;
        double t = a / (a - b);
        double px = (i1 + (i2 - i1) * t) * cell, py = (j1 + (j2 - j1) * t) * cell;
        QPointF d = toData(QPointF(px, py));
        double fm = prog.eval2(d.x(), d.y());
        if (!(std::fabs(fm) <= std::max(std::fabs(a), std::fabs(b)))) return false;
        out = QPointF(px, py);
        return true;
    };
    for (int j = 0; j < ny; ++j) {
        for (int i = 0; i < nx; ++i) {
            QPointF pts[4];
            int n = 0;
            QPointF q;
            if (crossing(i, j, i + 1, j, q)) pts[n++] = q;
            if (crossing(i + 1, j, i + 1, j + 1, q)) pts[n++] = q;
            if (crossing(i, j + 1, i + 1, j + 1, q)) pts[n++] = q;
            if (crossing(i, j, i, j + 1, q)) pts[n++] = q;
            if (n >= 2) segs << QLineF(pts[0], pts[1]);
            if (n == 4) segs << QLineF(pts[2], pts[3]);
        }
    }
    p.setPen(pen);
    p.drawLines(segs);
}

void Plot2D::drawSeries(QPainter &p)
{
    const Theme &th = Theme::get();
    const PlotSpec &s = *m_spec;
    int next = 0;
    const double clampY = height() * 20.0;
    for (auto &se : s.series) {
        if (se.kind == Series::Domain) { ++next; continue; }
        QColor c = colorFor(se, next);
        QPen pen(c, 2.2, se.dashed ? Qt::DashLine : Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin);
        switch (se.kind) {
        case Series::Func:
        case Series::Fill: {
            if (se.p.empty() || !se.p[0].valid) break;
            const int N = std::max(200, width() * 2);
            auto curve = [&](auto valueAt, const QPen &pn) {
                QPainterPath path;
                bool open = false;
                double prevY = NAN;
                for (int i = 0; i <= N; ++i) {
                    double x = m_x0 + (m_x1 - m_x0) * i / N;
                    double y = valueAt(x);
                    if (!std::isfinite(y)) { open = false; prevY = NAN; continue; }
                    QPointF q = toPx(x, y);
                    q.setY(std::clamp(q.y(), -clampY, clampY));
                    if (open && std::isfinite(prevY) && std::fabs(q.y() - prevY) > height() * 1.5 &&
                        (q.y() < 0 || q.y() > height() || prevY < 0 || prevY > height()))
                        open = false;   // pole: don't join across it
                    if (!open) path.moveTo(q);
                    else path.lineTo(q);
                    open = true;
                    prevY = q.y();
                }
                p.strokePath(path, pn);
            };
            if (se.kind == Series::Fill) {
                QPainterPath area;
                const int M = 300;
                area.moveTo(toPx(se.a, 0));
                for (int i = 0; i <= M; ++i) {
                    double x = se.a + (se.b - se.a) * i / M, y = se.p[0].eval1(x);
                    if (!std::isfinite(y)) y = 0;
                    QPointF q = toPx(x, y);
                    q.setY(std::clamp(q.y(), -clampY, clampY));
                    area.lineTo(q);
                }
                area.lineTo(toPx(se.b, 0));
                area.closeSubpath();
                QColor fc = se.color >= 0 ? c : th.series(0);
                fc.setAlpha(70);
                p.fillPath(area, fc);
                break;
            }
            if (se.complexParts) {
                curve([&](double x) { std::complex<double> z(x, 0); return se.p[0].evalc(&z).real(); }, pen);
                QPen ip = pen;
                ip.setStyle(Qt::DashLine);
                curve([&](double x) { std::complex<double> z(x, 0); return se.p[0].evalc(&z).imag(); }, ip);
            } else {
                curve([&](double x) { return se.p[0].eval1(x); }, pen);
            }
            break;
        }
        case Series::Implicit:
            if (!se.p.empty() && se.p[0].valid) contour(p, se.p[0], pen, 3);
            break;
        case Series::Region: {
            const int cell = 3;
            const int W = width() / cell + 1, H = height() / cell + 1;
            QImage img(W, H, QImage::Format_ARGB32_Premultiplied);
            img.fill(Qt::transparent);
            QColor fc = c;
            fc.setAlpha(80);
            const QRgb rgb = qPremultiply(fc.rgba());
            for (int j = 0; j < H; ++j) {
                auto *line = reinterpret_cast<QRgb *>(img.scanLine(j));
                for (int i = 0; i < W; ++i) {
                    QPointF d = toData(QPointF((i + 0.5) * cell, (j + 0.5) * cell));
                    bool ok = true;
                    for (size_t k = 0; k < se.p.size() && ok; ++k) {
                        double v = se.p[k].eval2(d.x(), d.y());
                        ok = std::isfinite(v) && relHolds(se.rel[k], v);
                    }
                    if (ok) line[i] = rgb;
                }
            }
            p.drawImage(QRectF(0, 0, W * cell, H * cell), img);
            for (size_t k = 0; k < se.p.size(); ++k) {
                bool strict = se.rel[k] == Series::Lt || se.rel[k] == Series::Gt || se.rel[k] == Series::Ne;
                QPen bp(c, 1.8, strict ? Qt::DashLine : Qt::SolidLine);
                contour(p, se.p[k], bp, 3);
            }
            break;
        }
        case Series::Param2: {
            if (se.p.size() != 2) break;
            const int N = 3000;
            QPainterPath path;
            bool open = false;
            QPointF prev;
            for (int i = 0; i <= N; ++i) {
                double t = s.tmin + (s.tmax - s.tmin) * i / N;
                double x = se.p[0].eval1(t), y = se.p[1].eval1(t);
                if (!std::isfinite(x) || !std::isfinite(y)) { open = false; continue; }
                QPointF q = toPx(x, y);
                q = QPointF(std::clamp(q.x(), -clampY, clampY), std::clamp(q.y(), -clampY, clampY));
                if (open && QLineF(prev, q).length() > std::max(width(), height())) open = false;
                if (!open) path.moveTo(q);
                else path.lineTo(q);
                open = true;
                prev = q;
            }
            p.strokePath(path, pen);
            break;
        }
        case Series::XBand: {
            QColor fc = c;
            fc.setAlpha(45);
            QPointF o = toPx(0, 0);
            double ay = std::clamp(o.y(), 0.0, double(height()));
            for (auto &iv : se.intervals) {
                double a = std::isfinite(iv.first) ? toPx(iv.first, 0).x() : -10;
                double b = std::isfinite(iv.second) ? toPx(iv.second, 0).x() : width() + 10;
                a = std::clamp(a, -10.0, width() + 10.0);
                b = std::clamp(b, -10.0, width() + 10.0);
                p.fillRect(QRectF(a, 0, b - a, height()), fc);
                p.setPen(QPen(c, 5, Qt::SolidLine, Qt::FlatCap));
                p.drawLine(QPointF(a, ay), QPointF(b, ay));
            }
            p.setPen(Qt::NoPen);
            p.setBrush(c);
            for (auto &pt : se.pts) p.drawEllipse(toPx(pt.x(), 0), 5, 5);
            break;
        }
        case Series::Points: {
            QFont f = font();
            f.setPixelSize(11);
            p.setFont(f);
            for (auto &pt : se.pts) {
                QPointF q = toPx(pt.x(), pt.y());
                p.setPen(QPen(th.bgDark, 2));
                p.setBrush(th.fg);
                p.drawEllipse(q, 4.5, 4.5);
                p.setPen(th.fg);
                QString lbl = QString("(%1, %2)").arg(QString::number(pt.x(), 'g', 4), QString::number(pt.y(), 'g', 4));
                p.drawText(q + QPointF(8, -8), lbl);
            }
            break;
        }
        default:
            break;
        }
    }
}

void Plot2D::drawLegend(QPainter &p)
{
    const Theme &th = Theme::get();
    struct Entry { MPtr f; QColor c; bool dashed; };
    std::vector<Entry> entries;
    int next = 0;
    for (auto &se : m_spec->series) {
        QColor c = colorFor(se, next);
        if (!se.label) continue;
        if (se.kind == Series::Points || se.kind == Series::XBand || se.kind == Series::Fill) continue;
        entries.push_back({se.label, c, se.dashed});
    }
    if (entries.empty()) return;
    const double px = 15;
    std::vector<MathRender::BoxP> boxes;
    double w = 0, h = 0;
    for (auto &e : entries) {
        boxes.push_back(MathRender::layout(e.f, px));
        w = std::max(w, boxes.back()->w);
        h += boxes.back()->a + boxes.back()->d + 6;
    }
    w = std::min(w + 40, width() * 0.7);
    QRectF r(10, 10, w + 12, h + 8);
    QColor bg = th.bg;
    bg.setAlpha(215);
    p.setPen(Qt::NoPen);
    p.setBrush(bg);
    p.drawRoundedRect(r, 8, 8);
    p.save();
    p.setClipRect(r);
    double y = r.top() + 6;
    for (size_t i = 0; i < entries.size(); ++i) {
        auto &b = boxes[i];
        double mid = y + (b->a + b->d) / 2;
        p.setPen(QPen(entries[i].c, 3, entries[i].dashed ? Qt::DashLine : Qt::SolidLine, Qt::RoundCap));
        p.drawLine(QPointF(r.left() + 10, mid), QPointF(r.left() + 30, mid));
        MathRender::paint(p, b, QPointF(r.left() + 40, y + b->a), th.fg);
        y += b->a + b->d + 6;
    }
    p.restore();
}

void Plot2D::mousePressEvent(QMouseEvent *e)
{
    if (e->button() != Qt::LeftButton) return;
    m_dragging = true;
    m_dragStart = e->pos();
    m_dx0 = m_x0, m_dx1 = m_x1, m_dy0 = m_y0, m_dy1 = m_y1;
    setCursor(Qt::ClosedHandCursor);
}

void Plot2D::mouseMoveEvent(QMouseEvent *e)
{
    m_mouse = e->position();
    if (m_dragging) {
        QPoint d = e->pos() - m_dragStart;
        double ddx = -d.x() * (m_dx1 - m_dx0) / width(), ddy = d.y() * (m_dy1 - m_dy0) / height();
        m_x0 = m_dx0 + ddx, m_x1 = m_dx1 + ddx, m_y0 = m_dy0 + ddy, m_y1 = m_dy1 + ddy;
    }
    update();
}

void Plot2D::mouseReleaseEvent(QMouseEvent *)
{
    if (!m_dragging) return;
    m_dragging = false;
    unsetCursor();
    emit viewChanged(m_x0, m_x1, m_y0, m_y1);
}

void Plot2D::mouseDoubleClickEvent(QMouseEvent *) { resetView(); }

void Plot2D::wheelEvent(QWheelEvent *e)
{
    double f = std::pow(1.0015, -e->angleDelta().y());
    QPointF c = toData(e->position());
    const bool onlyX = e->modifiers() & Qt::ShiftModifier, onlyY = e->modifiers() & Qt::ControlModifier;
    if (!onlyY) m_x0 = c.x() + (m_x0 - c.x()) * f, m_x1 = c.x() + (m_x1 - c.x()) * f;
    if (!onlyX) m_y0 = c.y() + (m_y0 - c.y()) * f, m_y1 = c.y() + (m_y1 - c.y()) * f;
    update();
    emit viewChanged(m_x0, m_x1, m_y0, m_y1);
}

void Plot2D::leaveEvent(QEvent *)
{
    m_mouse = QPointF(-1, -1);
    update();
}

void Plot2D::contextMenuEvent(QContextMenuEvent *e)
{
    QMenu m(this);
    m.addAction(QString::fromUtf8("Restablecer vista"), this, &Plot2D::resetView);
    m.addAction(QString::fromUtf8("Ejes a la misma escala (1:1)"), this, &Plot2D::equalAxes);
    m.addSeparator();
    m.addAction(QString::fromUtf8("Copiar imagen"), this, [this] { QApplication::clipboard()->setImage(grab().toImage()); });
    m.addAction(QString::fromUtf8("Guardar imagen…"), this, [this] {
        QString f = QFileDialog::getSaveFileName(this, QString::fromUtf8("Guardar gráfica"), "grafica.png", "PNG (*.png)");
        if (!f.isEmpty()) grab().save(f);
    });
    m.exec(e->globalPos());
}
