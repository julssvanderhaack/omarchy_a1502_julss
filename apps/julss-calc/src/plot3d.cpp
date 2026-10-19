#include "plot3d.h"
#include "mathrender.h"
#include "theme.h"
#include <QApplication>
#include <QClipboard>
#include <QContextMenuEvent>
#include <QFileDialog>
#include <QMenu>
#include <QPainter>
#include <QSet>
#include <QWheelEvent>
#include <algorithm>

namespace {
constexpr int kGrid = 60;
}

Plot3D::Plot3D(QWidget *parent) : QWidget(parent)
{
    setMinimumSize(240, 200);
    setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
}

void Plot3D::setSpec(PlotPtr spec)
{
    m_spec = std::move(spec);
    rebuild();
    update();
}

void Plot3D::resetView()
{
    m_yaw = -55, m_pitch = 28, m_zoom = 1;
    update();
}

QColor Plot3D::rampColor(double t) const
{
    const auto &r = Theme::get().ramp;
    t = std::clamp(t, 0.0, 1.0) * (r.size() - 1);
    int i = std::min(int(t), int(r.size()) - 2);
    double f = t - i;
    const QColor &a = r[i], &b = r[i + 1];
    return QColor::fromRgbF(a.redF() + (b.redF() - a.redF()) * f, a.greenF() + (b.greenF() - a.greenF()) * f,
                            a.blueF() + (b.blueF() - a.blueF()) * f);
}

// Samples z = p(x,y). Vertices where the surface is undefined but next to a
// defined one are slid onto the boundary, so shapes like the two halves of a
// sphere meet at the equator instead of leaving a jagged gap.
void Plot3D::sample(Mesh &m, const Program &p, double x0, double x1, double y0, double y1)
{
    const int n = m.n;
    m.x.assign(size_t(n) * n, 0);
    m.y.assign(size_t(n) * n, 0);
    m.z.assign(size_t(n) * n, NAN);
    for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
            size_t k = size_t(j) * n + i;
            m.x[k] = x0 + (x1 - x0) * i / (n - 1);
            m.y[k] = y0 + (y1 - y0) * j / (n - 1);
            m.z[k] = p.eval2(m.x[k], m.y[k]);
        }
    std::vector<double> nx = m.x, ny = m.y, nz = m.z;
    for (int j = 0; j < n; ++j)
        for (int i = 0; i < n; ++i) {
            size_t k = size_t(j) * n + i;
            if (std::isfinite(m.z[k])) continue;
            const int di[4] = {1, -1, 0, 0}, dj[4] = {0, 0, 1, -1};
            for (int d = 0; d < 4; ++d) {
                int a = i + di[d], b = j + dj[d];
                if (a < 0 || b < 0 || a >= n || b >= n) continue;
                size_t q = size_t(b) * n + a;
                if (!std::isfinite(m.z[q])) continue;
                double gx = m.x[q], gy = m.y[q], bx = m.x[k], by = m.y[k];
                for (int it = 0; it < 40; ++it) {
                    double mx = (gx + bx) / 2, my = (gy + by) / 2;
                    if (std::isfinite(p.eval2(mx, my))) gx = mx, gy = my;
                    else bx = mx, by = my;
                }
                nx[k] = gx, ny[k] = gy, nz[k] = p.eval2(gx, gy);
                break;
            }
        }
    m.x = std::move(nx), m.y = std::move(ny), m.z = std::move(nz);
}

// Marching tetrahedra over an n³ grid: every cube is split into six
// tetrahedra, each crossing of F = 0 yields one or two triangles.
void Plot3D::marchTetra(Mesh &m, const Program &p, double x0, double x1, double y0, double y1, double z0, double z1, int n)
{
    m.tv.clear();
    m.tn.clear();
    const double hx = (x1 - x0) / n, hy = (y1 - y0) / n, hz = (z1 - z0) / n;
    const int N = n + 1;
    std::vector<double> v(size_t(N) * N * N);
    auto idx = [N](int i, int j, int k) { return (size_t(k) * N + j) * N + i; };
    for (int k = 0; k < N; ++k)
        for (int j = 0; j < N; ++j)
            for (int i = 0; i < N; ++i) {
                double a[3] = {x0 + i * hx, y0 + j * hy, z0 + k * hz};
                v[idx(i, j, k)] = p.eval(a);
            }
    static const int corner[8][3] = {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}};
    static const int tets[6][4] = {{0, 5, 1, 6}, {0, 1, 2, 6}, {0, 2, 3, 6}, {0, 3, 7, 6}, {0, 7, 4, 6}, {0, 4, 5, 6}};
    auto grad = [&](const std::array<double, 3> &c) {
        auto f = [&](double x, double y, double z) { double a[3] = {x, y, z}; return p.eval(a); };
        std::array<double, 3> g = {(f(c[0] + hx * 0.5, c[1], c[2]) - f(c[0] - hx * 0.5, c[1], c[2])) / hx,
                                   (f(c[0], c[1] + hy * 0.5, c[2]) - f(c[0], c[1] - hy * 0.5, c[2])) / hy,
                                   (f(c[0], c[1], c[2] + hz * 0.5) - f(c[0], c[1], c[2] - hz * 0.5)) / hz};
        double l = std::sqrt(g[0] * g[0] + g[1] * g[1] + g[2] * g[2]);
        if (!(l > 0) || !std::isfinite(l)) return std::array<double, 3>{0, 0, 1};
        return std::array<double, 3>{g[0] / l, g[1] / l, g[2] / l};
    };
    auto emitTri = [&](const std::array<double, 3> &a, const std::array<double, 3> &b, const std::array<double, 3> &c) {
        m.tv.push_back(a), m.tv.push_back(b), m.tv.push_back(c);
        m.tn.push_back(grad({(a[0] + b[0] + c[0]) / 3, (a[1] + b[1] + c[1]) / 3, (a[2] + b[2] + c[2]) / 3}));
    };
    for (int k = 0; k < n; ++k)
        for (int j = 0; j < n; ++j)
            for (int i = 0; i < n; ++i) {
                std::array<double, 3> P[8];
                double V[8];
                bool ok = true;
                for (int c = 0; c < 8; ++c) {
                    int a = i + corner[c][0], b = j + corner[c][1], d = k + corner[c][2];
                    P[c] = {x0 + a * hx, y0 + b * hy, z0 + d * hz};
                    V[c] = v[idx(a, b, d)];
                    ok &= std::isfinite(V[c]);
                }
                if (!ok) continue;
                for (auto &t : tets) {
                    int in[4], out[4], ni = 0, no = 0;
                    for (int q = 0; q < 4; ++q) (V[t[q]] < 0 ? in[ni++] : out[no++]) = t[q];
                    if (ni == 0 || ni == 4) continue;
                    auto cut = [&](int a, int b) {
                        double s = V[a] / (V[a] - V[b]);
                        return std::array<double, 3>{P[a][0] + (P[b][0] - P[a][0]) * s, P[a][1] + (P[b][1] - P[a][1]) * s,
                                                     P[a][2] + (P[b][2] - P[a][2]) * s};
                    };
                    if (ni == 1) emitTri(cut(in[0], out[0]), cut(in[0], out[1]), cut(in[0], out[2]));
                    else if (ni == 3) emitTri(cut(out[0], in[0]), cut(out[0], in[1]), cut(out[0], in[2]));
                    else {
                        auto a = cut(in[0], out[0]), b = cut(in[0], out[1]), c = cut(in[1], out[1]), d = cut(in[1], out[0]);
                        emitTri(a, b, c);
                        emitTri(a, c, d);
                    }
                }
            }
}

void Plot3D::computeBox()
{
    const double sx = m_x1 - m_x0, sy = m_y1 - m_y0, sz = m_z1 - m_z0;
    const double mx = std::max({sx, sy, sz}), mn = std::min({sx, sy, sz});
    bool implicit = false;   // closed shapes (spheres, tori...) only make sense at true scale
    for (auto &m : m_meshes) implicit |= !m.tv.empty();
    const bool real = m_aspect == 1 || (m_aspect == 0 && mn > 0 && (implicit || mx / mn <= 3.5));
    if (real) m_bx = sx / mx, m_by = sy / mx, m_bz = sz / mx;
    else m_bx = 1, m_by = 1, m_bz = 0.8;
}

void Plot3D::rebuild()
{
    m_meshes.clear();
    m_curves.clear();
    if (!m_spec) return;
    const PlotSpec &s = *m_spec;
    m_x0 = s.xmin, m_x1 = s.xmax;
    m_y0 = std::isfinite(s.ymin) ? s.ymin : s.xmin;
    m_y1 = std::isfinite(s.ymax) ? s.ymax : s.xmax;
    std::vector<double> all;
    double implicitBox[4] = {INFINITY, -INFINITY, INFINITY, -INFINITY};
    int next = 0;
    // A single equation (even with several branches, like a sphere) gets the
    // height colour ramp; several different surfaces get one colour each.
    QSet<int> surfaceColors;
    for (auto &se : s.series)
        if (se.kind == Series::Surface || se.kind == Series::Implicit3) surfaceColors.insert(se.color);
    const int surfaces = surfaceColors.size();
    for (auto &se : s.series) {
        QColor c = Theme::get().series(se.color >= 0 ? se.color : next++);
        if (se.kind == Series::Surface && !se.p.empty() && se.p[0].valid) {
            Mesh m;
            m.n = kGrid;
            m.color = c;
            m.label = se.label;
            m.ramp = surfaces == 1;
            sample(m, se.p[0], m_x0, m_x1, m_y0, m_y1);
            m_meshes.push_back(std::move(m));
            m_meshPrograms.push_back(&se.p[0]);
        } else if (se.kind == Series::Implicit3 && !se.p.empty() && se.p[0].valid) {
            // coarse pass to find where the surface is, fine pass inside that box
            Mesh m;
            m.color = c;
            m.label = se.label;
            m.ramp = surfaces == 1;
            const double r0 = m_x0, r1 = m_x1;
            marchTetra(m, se.p[0], m_x0, m_x1, m_y0, m_y1, r0, r1, 20);
            double b[6] = {INFINITY, -INFINITY, INFINITY, -INFINITY, INFINITY, -INFINITY};
            for (auto &q : m.tv)
                for (int a = 0; a < 3; ++a) b[2 * a] = std::min(b[2 * a], q[a]), b[2 * a + 1] = std::max(b[2 * a + 1], q[a]);
            if (std::isfinite(b[0])) {
                const double pad[3] = {(m_x1 - m_x0) / 20, (m_y1 - m_y0) / 20, (r1 - r0) / 20};
                for (int a = 0; a < 3; ++a) b[2 * a] -= pad[a], b[2 * a + 1] += pad[a];
                b[0] = std::max(b[0], m_x0), b[1] = std::min(b[1], m_x1);
                b[2] = std::max(b[2], m_y0), b[3] = std::min(b[3], m_y1);
                b[4] = std::max(b[4], r0), b[5] = std::min(b[5], r1);
                marchTetra(m, se.p[0], b[0], b[1], b[2], b[3], b[4], b[5], 42);
                implicitBox[0] = std::min(implicitBox[0], b[0]), implicitBox[1] = std::max(implicitBox[1], b[1]);
                implicitBox[2] = std::min(implicitBox[2], b[2]), implicitBox[3] = std::max(implicitBox[3], b[3]);
                for (auto &q : m.tv) all.push_back(q[2]);
            }
            m_meshes.push_back(std::move(m));
        } else if (se.kind == Series::Param3 && se.p.size() == 3) {
            Curve cv;
            cv.color = c;
            cv.label = se.label;
            const int N = 1500;
            double bx0 = INFINITY, bx1 = -INFINITY, by0 = INFINITY, by1 = -INFINITY;
            for (int i = 0; i <= N; ++i) {
                double t = s.tmin + (s.tmax - s.tmin) * i / N;
                std::array<double, 3> p = {se.p[0].eval1(t), se.p[1].eval1(t), se.p[2].eval1(t)};
                cv.pts.push_back(p);
                if (std::isfinite(p[0]) && std::isfinite(p[1]) && std::isfinite(p[2])) {
                    bx0 = std::min(bx0, p[0]), bx1 = std::max(bx1, p[0]);
                    by0 = std::min(by0, p[1]), by1 = std::max(by1, p[1]);
                    all.push_back(p[2]);
                }
            }
            if (m_meshes.empty() && std::isfinite(bx0)) {
                double pad = 0.05 * std::max(bx1 - bx0, by1 - by0) + 1e-9;
                m_x0 = bx0 - pad, m_x1 = bx1 + pad, m_y0 = by0 - pad, m_y1 = by1 + pad;
            }
            m_curves.push_back(std::move(cv));
        }
    }
    // Surfaces defined only on part of the window (a sphere solved for z):
    // zoom the window onto where they exist and sample again.
    if (!m_meshes.empty()) {
        double bx0 = INFINITY, bx1 = -INFINITY, by0 = INFINITY, by1 = -INFINITY;
        if (std::isfinite(implicitBox[0]))
            bx0 = implicitBox[0], bx1 = implicitBox[1], by0 = implicitBox[2], by1 = implicitBox[3];
        for (auto &m : m_meshes)
            for (size_t k = 0; k < m.z.size(); ++k)
                if (std::isfinite(m.z[k])) {
                    bx0 = std::min(bx0, m.x[k]), bx1 = std::max(bx1, m.x[k]);
                    by0 = std::min(by0, m.y[k]), by1 = std::max(by1, m.y[k]);
                }
        if (std::isfinite(bx0) && bx1 > bx0 && by1 > by0 &&
            ((bx1 - bx0) < 0.8 * (m_x1 - m_x0) || (by1 - by0) < 0.8 * (m_y1 - m_y0))) {
            double px = (bx1 - bx0) * 0.04, py = (by1 - by0) * 0.04;
            m_x0 = bx0 - px, m_x1 = bx1 + px, m_y0 = by0 - py, m_y1 = by1 + py;
            for (size_t i = 0, g = 0; i < m_meshes.size(); ++i)
                if (m_meshes[i].tv.empty() && g < m_meshPrograms.size()) sample(m_meshes[i], *m_meshPrograms[g++], m_x0, m_x1, m_y0, m_y1);
        }
        for (auto &m : m_meshes)
            for (double z : m.z)
                if (std::isfinite(z)) all.push_back(z);
    }
    m_meshPrograms.clear();
    if (all.empty()) {
        m_z0 = -1, m_z1 = 1;
        computeBox();
        return;
    }
    std::sort(all.begin(), all.end());
    double lo = all[size_t(all.size() * 0.02)], hi = all[std::min(all.size() - 1, size_t(all.size() * 0.98))];
    // keep the true extremes when they are not outliers
    if (all.front() > lo - (hi - lo) * 0.5) lo = all.front();
    if (all.back() < hi + (hi - lo) * 0.5) hi = all.back();
    if (hi - lo < 1e-9) lo -= 1, hi += 1;
    double pad = (hi - lo) * 0.05;
    m_z0 = lo - pad, m_z1 = hi + pad;
    for (auto &m : m_meshes)
        for (double &z : m.z)
            if (z < m_z0 - (m_z1 - m_z0) * 0.02 || z > m_z1 + (m_z1 - m_z0) * 0.02) z = NAN;
    computeBox();
}

QPointF Plot3D::project(double X, double Y, double Z, double *depth) const
{
    // normalised cube [-1,1]^2 x [-0.8,0.8]
    const double yaw = m_yaw * M_PI / 180, pitch = m_pitch * M_PI / 180;
    double x1 = X * std::cos(yaw) - Y * std::sin(yaw);
    double y1 = X * std::sin(yaw) + Y * std::cos(yaw);
    double sx = x1;
    double sy = Z * std::cos(pitch) + y1 * std::sin(pitch);
    if (depth) *depth = y1 * std::cos(pitch) - Z * std::sin(pitch);
    const double scale = std::min(width(), height()) * 0.34 * m_zoom;
    return QPointF(width() / 2.0 + sx * scale, height() / 2.0 - 6 - sy * scale);
}

void Plot3D::paintEvent(QPaintEvent *)
{
    const Theme &th = Theme::get();
    QPainter p(this);
    p.fillRect(rect(), th.bgDark);
    if (m_meshes.empty() && m_curves.empty()) {
        p.setPen(th.fgDim);
        p.drawText(rect(), Qt::AlignCenter, QString::fromUtf8("La gráfica 3D aparecerá aquí"));
        return;
    }
    p.setRenderHint(QPainter::Antialiasing, !m_dragging);
    auto nx = [&](double x) { return ((x - m_x0) / (m_x1 - m_x0) * 2 - 1) * m_bx; };
    auto ny = [&](double y) { return ((y - m_y0) / (m_y1 - m_y0) * 2 - 1) * m_by; };
    auto nz = [&](double z) { return ((z - m_z0) / (m_z1 - m_z0) * 2 - 1) * m_bz; };

    // ---- box: back edges first
    struct Edge { std::array<double, 3> a, b; };
    const double Bx = m_bx, By = m_by, Zb = m_bz;
    std::vector<Edge> edges;
    for (double u : {-1.0, 1.0})
        for (double v : {-1.0, 1.0}) {
            edges.push_back({{-Bx, u * By, v * Zb}, {Bx, u * By, v * Zb}});
            edges.push_back({{u * Bx, -By, v * Zb}, {u * Bx, By, v * Zb}});
            edges.push_back({{u * Bx, v * By, -Zb}, {u * Bx, v * By, Zb}});
        }
    QColor boxC = th.muted;
    p.setPen(QPen(boxC, 1));
    double dc;
    project(0, 0, 0, &dc);
    std::vector<Edge> front;
    for (auto &e : edges) {
        double d1, d2;
        QPointF a = project(e.a[0], e.a[1], e.a[2], &d1), b = project(e.b[0], e.b[1], e.b[2], &d2);
        if ((d1 + d2) / 2 >= dc - 1e-9) p.drawLine(a, b);
        else front.push_back(e);
    }
    // floor grid
    QColor gridC = th.muted;
    gridC.setAlpha(70);
    p.setPen(QPen(gridC, 1));
    for (int i = 1; i < 10; ++i) {
        double t = -1 + 2.0 * i / 10;
        p.drawLine(project(t * Bx, -By, -Zb), project(t * Bx, By, -Zb));
        p.drawLine(project(-Bx, t * By, -Zb), project(Bx, t * By, -Zb));
    }

    // ---- surfaces
    struct Quad { QPointF pt[4]; double d[4]; QRgb fill; bool tri = false; };
    std::vector<Quad> quads;
    // fixed light from above and slightly to one side
    double L[3] = {-0.35, -0.45, 0.82};
    double ll = std::sqrt(L[0] * L[0] + L[1] * L[1] + L[2] * L[2]);
    for (double &v : L) v /= ll;
    const double yawR = m_yaw * M_PI / 180, pitchR = m_pitch * M_PI / 180;
    const double V[3] = {-std::sin(yawR) * std::cos(pitchR), -std::cos(yawR) * std::cos(pitchR), std::sin(pitchR)};
    auto shadeOf = [&](const QColor &base, double nxv, double nyv, double nzv) {
        // turn the normal towards the viewer, then headlight + key light
        double nv = nxv * V[0] + nyv * V[1] + nzv * V[2];
        if (nv < 0) nxv = -nxv, nyv = -nyv, nzv = -nzv, nv = -nv;
        double key = std::max(0.0, nxv * L[0] + nyv * L[1] + nzv * L[2]);
        double shade = 0.2 + 0.32 * nv + 0.58 * key;
        return QColor::fromRgbF(std::min(1.0, base.redF() * shade), std::min(1.0, base.greenF() * shade),
                                std::min(1.0, base.blueF() * shade)).rgb();
    };
    for (auto &m : m_meshes) {
        for (size_t t = 0; t + 2 < m.tv.size(); t += 3) {
            Quad q;
            q.tri = true;
            double zs = 0;
            for (int k = 0; k < 3; ++k) {
                const auto &v = m.tv[t + k];
                q.pt[k] = project(nx(v[0]), ny(v[1]), nz(v[2]), &q.d[k]);
                zs += v[2];
            }
            // gradient lives in data space; bring it to the drawn box
            const auto &g = m.tn[t / 3];
            double gx = g[0] * (m_x1 - m_x0) / (2 * m_bx), gy = g[1] * (m_y1 - m_y0) / (2 * m_by), gz = g[2] * (m_z1 - m_z0) / (2 * m_bz);
            double gl = std::sqrt(gx * gx + gy * gy + gz * gz) + 1e-12;
            QColor base = m.ramp ? rampColor((zs / 3 - m_z0) / (m_z1 - m_z0)) : m.color;
            q.fill = shadeOf(base, gx / gl, gy / gl, gz / gl);
            quads.push_back(q);
        }
        const int n = m.n;
        if (!m.tv.empty() || m.z.empty()) continue;
        for (int j = 0; j < n - 1; ++j) {
            for (int i = 0; i < n - 1; ++i) {
                double z[4] = {m.z[size_t(j) * n + i], m.z[size_t(j) * n + i + 1], m.z[size_t(j + 1) * n + i + 1], m.z[size_t(j + 1) * n + i]};
                if (!std::isfinite(z[0]) || !std::isfinite(z[1]) || !std::isfinite(z[2]) || !std::isfinite(z[3])) continue;
                const size_t c[4] = {size_t(j) * n + i, size_t(j) * n + i + 1, size_t(j + 1) * n + i + 1, size_t(j + 1) * n + i};
                double X[4], Y[4];
                for (int k = 0; k < 4; ++k) X[k] = nx(m.x[c[k]]), Y[k] = ny(m.y[c[k]]);
                Quad q;
                double zs = 0;
                for (int k = 0; k < 4; ++k) {
                    q.pt[k] = project(X[k], Y[k], nz(z[k]), &q.d[k]);
                    zs += z[k];
                }
                // normal from the diagonals
                double ax = X[2] - X[0], ay = Y[2] - Y[0], az = nz(z[2]) - nz(z[0]);
                double bx = X[3] - X[1], by = Y[3] - Y[1], bz = nz(z[3]) - nz(z[1]);
                double N[3] = {ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx};
                double nl = std::sqrt(N[0] * N[0] + N[1] * N[1] + N[2] * N[2]) + 1e-12;
                QColor base = m.ramp ? rampColor((zs / 4 - m_z0) / (m_z1 - m_z0)) : m.color;
                q.fill = shadeOf(base, N[0] / nl, N[1] / nl, N[2] / nl);
                quads.push_back(q);
            }
        }
    }
    // Z-buffer rasteriser: exact visibility where surfaces cross or meet,
    // which painter's sorting gets wrong. Rendered at device resolution
    // (half while dragging, to stay smooth on slow CPUs).
    {
        const double dpr = m_dragging ? 1.0 : devicePixelRatioF();
        const int W = std::max(1, int(width() * dpr)), H = std::max(1, int(height() * dpr));
        QImage img(W, H, QImage::Format_ARGB32_Premultiplied);
        img.fill(Qt::transparent);
        std::vector<float> zbuf(size_t(W) * H, INFINITY);
        const QColor ec = th.bgDark;
        double edgeW = m_dragging ? 0 : 0.6 * dpr;   // mesh line width in pixels
        auto raster = [&](const Quad &q, int a, int b, int c, bool edgeAB, bool edgeBC) {
            const double x0 = q.pt[a].x() * dpr, y0 = q.pt[a].y() * dpr, x1 = q.pt[b].x() * dpr, y1 = q.pt[b].y() * dpr,
                         x2 = q.pt[c].x() * dpr, y2 = q.pt[c].y() * dpr;
            const double area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
            if (std::fabs(area) < 1e-9) return;
            const int minx = std::max(0, int(std::floor(std::min({x0, x1, x2})))), maxx = std::min(W - 1, int(std::ceil(std::max({x0, x1, x2}))));
            const int miny = std::max(0, int(std::floor(std::min({y0, y1, y2})))), maxy = std::min(H - 1, int(std::ceil(std::max({y0, y1, y2}))));
            const double lab = std::hypot(x1 - x0, y1 - y0) + 1e-12, lbc = std::hypot(x2 - x1, y2 - y1) + 1e-12;
            const QRgb fill = q.fill;
            const int er = qRed(fill) * 0.55 + ec.red() * 0.45, eg = qGreen(fill) * 0.55 + ec.green() * 0.45, eb = qBlue(fill) * 0.55 + ec.blue() * 0.45;
            const QRgb edge = qRgb(er, eg, eb);
            for (int py = miny; py <= maxy; ++py) {
                QRgb *line = reinterpret_cast<QRgb *>(img.scanLine(py));
                float *zl = &zbuf[size_t(py) * W];
                const double cy = py + 0.5;
                for (int px = minx; px <= maxx; ++px) {
                    const double cx = px + 0.5;
                    double w0 = ((x1 - cx) * (y2 - cy) - (x2 - cx) * (y1 - cy)) / area;
                    double w1 = ((x2 - cx) * (y0 - cy) - (x0 - cx) * (y2 - cy)) / area;
                    double w2 = 1 - w0 - w1;
                    if (w0 < -1e-9 || w1 < -1e-9 || w2 < -1e-9) continue;
                    const float d = float(w0 * q.d[a] + w1 * q.d[b] + w2 * q.d[c]);
                    if (d >= zl[px]) continue;
                    zl[px] = d;
                    bool onEdge = false;
                    if (edgeW > 0) {
                        if (edgeAB && w2 * std::fabs(area) / lab < edgeW) onEdge = true;   // distance to edge a-b
                        if (edgeBC && w0 * std::fabs(area) / lbc < edgeW) onEdge = true;   // distance to edge b-c
                    }
                    line[px] = onEdge ? edge : fill;
                }
            }
        };
        const double meshW = edgeW;
        for (auto &q : quads) {
            if (q.tri) {
                edgeW = 0;   // marching triangles: smooth look, no wireframe
                raster(q, 0, 1, 2, false, false);
                edgeW = meshW;
                continue;
            }
            raster(q, 0, 1, 2, true, true);
            raster(q, 2, 3, 0, true, true);
        }
        img.setDevicePixelRatio(dpr);
        p.drawImage(QRectF(0, 0, width(), height()), img);
    }

    // ---- curves
    for (auto &c : m_curves) {
        QPainterPath path;
        bool open = false;
        for (auto &pt : c.pts) {
            if (!std::isfinite(pt[0]) || !std::isfinite(pt[1]) || !std::isfinite(pt[2])) { open = false; continue; }
            QPointF q = project(nx(pt[0]), ny(pt[1]), nz(pt[2]));
            if (!open) path.moveTo(q);
            else path.lineTo(q);
            open = true;
        }
        p.strokePath(path, QPen(c.color, 2.4, Qt::SolidLine, Qt::RoundCap, Qt::RoundJoin));
    }

    // ---- front box edges + labels
    p.setPen(QPen(boxC, 1));
    // front edges of the box are left out so they never cut across the plot

    QFont f = font();
    f.setPixelSize(11);
    p.setFont(f);
    p.setPen(th.fgDim);
    auto lbl = [&](double X, double Y, double Z, const QString &s) {
        QPointF q = project(X, Y, Z);
        p.drawText(QRectF(q.x() - 40, q.y() - 8, 80, 16), Qt::AlignCenter, s);
    };
    auto num = [this](double v) {
        if (std::fabs(v) < 1e-6 * std::max({m_x1 - m_x0, m_y1 - m_y0, m_z1 - m_z0})) v = 0;
        return QString::number(v, 'g', 3).replace('-', QString::fromUtf8("−"));
    };
    // x/y numbers go on the bottom edges lowest on screen (nearest the
    // viewer), z numbers on the vertical edge furthest to the left.
    const double sy = (project(0, By, -Zb).y() > project(0, -By, -Zb).y() ? 1 : -1) * By;
    const double sx = (project(Bx, 0, -Zb).y() > project(-Bx, 0, -Zb).y() ? 1 : -1) * Bx;
    double zx = -1, zy = -1, best = 1e18;
    for (double cx : {-1.0, 1.0})
        for (double cy : {-1.0, 1.0}) {
            double px = project(cx * Bx, cy * By, 0).x();
            if (px < best) best = px, zx = cx, zy = cy;
        }
    for (int k = 0; k <= 4; ++k) {
        double t = -1 + 0.5 * k;
        lbl(t * Bx, sy + 0.2 * (sy > 0 ? 1 : -1), -Zb, num(m_x0 + (m_x1 - m_x0) * (t + 1) / 2));
        lbl(sx + 0.2 * (sx > 0 ? 1 : -1), t * By, -Zb, num(m_y0 + (m_y1 - m_y0) * (t + 1) / 2));
        lbl(zx * (Bx + 0.12), zy * (By + 0.12), t * Zb, num(m_z0 + (m_z1 - m_z0) * (t + 1) / 2));
    }
    f.setItalic(true);
    f.setPixelSize(14);
    p.setFont(f);
    p.setPen(th.fg);
    if (m_spec) {
        lbl(0, sy + 0.45 * (sy > 0 ? 1 : -1), -Zb, m_spec->xname);
        lbl(sx + 0.45 * (sx > 0 ? 1 : -1), 0, -Zb, m_spec->yname);
        lbl(zx * (Bx + 0.12), zy * (By + 0.12), Zb + 0.2, m_spec->zname);
    }

    // ---- legend
    std::vector<std::pair<MPtr, QColor>> leg;
    for (auto &m : m_meshes)
        if (m.label) leg.push_back({m.label, m.ramp ? th.accent : m.color});
    for (auto &c : m_curves)
        if (c.label) leg.push_back({c.label, c.color});
    double y = 12;
    for (auto &e : leg) {
        auto b = MathRender::layout(e.first, 15);
        QRectF r(10, y - 2, std::min(b->w + 44, width() * 0.7), b->a + b->d + 6);
        QColor bg = th.bg;
        bg.setAlpha(210);
        p.setPen(Qt::NoPen);
        p.setBrush(bg);
        p.drawRoundedRect(r, 6, 6);
        p.setBrush(e.second);
        p.drawRoundedRect(QRectF(18, y + (b->a + b->d) / 2 - 5, 16, 10), 3, 3);
        MathRender::paint(p, b, QPointF(42, y + 1 + b->a), th.fg);
        y += r.height() + 4;
    }
    p.setPen(th.fgDim);
    f.setItalic(false);
    f.setPixelSize(11);
    p.setFont(f);
    p.drawText(rect().adjusted(8, 8, -8, -8), Qt::AlignBottom | Qt::AlignRight,
               QString::fromUtf8("Arrastra para girar · rueda para acercar · doble clic para restablecer"));
}

void Plot3D::mousePressEvent(QMouseEvent *e)
{
    if (e->button() != Qt::LeftButton) return;
    m_dragging = true;
    m_last = e->pos();
}

void Plot3D::mouseMoveEvent(QMouseEvent *e)
{
    if (!m_dragging) return;
    QPoint d = e->pos() - m_last;
    m_last = e->pos();
    m_yaw -= d.x() * 0.5;
    m_pitch = std::clamp(m_pitch + d.y() * 0.4, -89.0, 89.0);
    update();
}

void Plot3D::mouseReleaseEvent(QMouseEvent *)
{
    m_dragging = false;
    update();
}

void Plot3D::mouseDoubleClickEvent(QMouseEvent *) { resetView(); }

void Plot3D::wheelEvent(QWheelEvent *e)
{
    m_zoom = std::clamp(m_zoom * std::pow(1.0015, e->angleDelta().y()), 0.3, 6.0);
    update();
}

void Plot3D::contextMenuEvent(QContextMenuEvent *e)
{
    QMenu m(this);
    m.addAction(QString::fromUtf8("Restablecer vista"), this, &Plot3D::resetView);
    m.addAction(QString::fromUtf8("Vista desde arriba"), this, [this] { m_pitch = 89; m_yaw = 0; update(); });
    m.addSeparator();
    const char *modes[] = {"Proporciones automáticas", "Escala real (ejes iguales)", "Ajustar a la caja"};
    for (int i = 0; i < 3; ++i) {
        QAction *a = m.addAction(QString::fromUtf8(modes[i]), this, [this, i] { m_aspect = i; computeBox(); update(); });
        a->setCheckable(true);
        a->setChecked(m_aspect == i);
    }
    m.addSeparator();
    m.addAction(QString::fromUtf8("Copiar imagen"), this, [this] { QApplication::clipboard()->setImage(grab().toImage()); });
    m.addAction(QString::fromUtf8("Guardar imagen…"), this, [this] {
        QString f = QFileDialog::getSaveFileName(this, QString::fromUtf8("Guardar gráfica"), "grafica3d.png", "PNG (*.png)");
        if (!f.isEmpty()) grab().save(f);
    });
    m.exec(e->globalPos());
}
