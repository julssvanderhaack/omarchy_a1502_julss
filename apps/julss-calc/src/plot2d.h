// 2D plotter. Series carry compiled programs, so panning and zooming
// re-sample instantly without going back to the CAS.
#pragma once
#include "types.h"
#include <QWidget>

class Plot2D : public QWidget {
    Q_OBJECT
public:
    explicit Plot2D(QWidget *parent = nullptr);
    void setSpec(PlotPtr spec, bool resetView = true);
    PlotPtr spec() const { return m_spec; }
    void setPlaceholder(const QString &s) { m_placeholder = s; update(); }
    void resetView();
    void equalAxes();
    void view(double &x0, double &x1, double &y0, double &y1) const { x0 = m_x0, x1 = m_x1, y0 = m_y0, y1 = m_y1; }

signals:
    void viewChanged(double x0, double x1, double y0, double y1);

protected:
    void paintEvent(QPaintEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mouseReleaseEvent(QMouseEvent *) override;
    void mouseDoubleClickEvent(QMouseEvent *) override;
    void wheelEvent(QWheelEvent *) override;
    void leaveEvent(QEvent *) override;
    void contextMenuEvent(QContextMenuEvent *) override;
    void resizeEvent(QResizeEvent *) override;

private:
    QPointF toPx(double x, double y) const;
    QPointF toData(QPointF px) const;
    void drawGrid(QPainter &p);
    void drawSeries(QPainter &p);
    void drawLegend(QPainter &p);
    void autoView();
    void contour(QPainter &p, const Program &prog, const QPen &pen, int cell);
    QColor colorFor(const Series &s, int &next) const;

    PlotPtr m_spec;
    double m_x0 = -10, m_x1 = 10, m_y0 = -6, m_y1 = 6;
    QPoint m_dragStart;
    double m_dx0 = 0, m_dx1 = 0, m_dy0 = 0, m_dy1 = 0;
    bool m_dragging = false;
    QPointF m_mouse{-1, -1};
    QString m_placeholder;
    bool m_hadSize = false;
};
