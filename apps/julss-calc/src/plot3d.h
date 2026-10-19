// Software 3D plotter: surfaces z = f(x,y) and space curves, painted back
// to front with QPainter. Light enough for old integrated GPUs.
#pragma once
#include "types.h"
#include <QWidget>
#include <array>

class Plot3D : public QWidget {
    Q_OBJECT
public:
    explicit Plot3D(QWidget *parent = nullptr);
    void setSpec(PlotPtr spec);
    void resetView();

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
    void mouseDoubleClickEvent(QMouseEvent *) override;
    void wheelEvent(QWheelEvent *) override;
    void contextMenuEvent(QContextMenuEvent *) override;

private:
    struct Mesh {
        int n = 0;
        std::vector<double> x, y, z;   // n*n vertices, z NaN = hole
        QColor color;
        MPtr label;
        bool ramp = false;
        // implicit surfaces: triangles (3 vertices each) and one normal per triangle
        std::vector<std::array<double, 3>> tv, tn;
    };
    struct Curve {
        std::vector<std::array<double, 3>> pts;
        QColor color;
        MPtr label;
    };
    void rebuild();
    void sample(Mesh &m, const Program &p, double x0, double x1, double y0, double y1);
    void computeBox();
    static void marchTetra(Mesh &m, const Program &p, double x0, double x1, double y0, double y1, double z0, double z1, int n);
    QPointF project(double X, double Y, double Z, double *depth = nullptr) const;
    QColor rampColor(double t) const;

    PlotPtr m_spec;
    std::vector<Mesh> m_meshes;
    std::vector<Curve> m_curves;
    std::vector<const Program *> m_meshPrograms;   // only valid inside rebuild()
    double m_x0 = -5, m_x1 = 5, m_y0 = -5, m_y1 = 5, m_z0 = -1, m_z1 = 1;
    double m_yaw = -55, m_pitch = 28, m_zoom = 1;
    double m_bx = 1, m_by = 1, m_bz = 0.8;   // half sizes of the drawn box
    int m_aspect = 0;                       // 0 automatic, 1 true scale, 2 fill the box
    QPoint m_last;
    bool m_dragging = false;
};
