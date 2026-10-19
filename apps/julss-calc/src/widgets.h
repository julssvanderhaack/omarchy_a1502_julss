// Small shared widgets: scrollable formula, result list, plot stack.
#pragma once
#include "types.h"
#include <QLabel>
#include <QScrollArea>
#include <QStackedWidget>
#include <QVBoxLayout>

class MathWidget;
class Plot2D;
class Plot3D;

// A formula that scrolls sideways when it does not fit.
class FormulaView : public QScrollArea {
    Q_OBJECT
public:
    explicit FormulaView(QWidget *parent = nullptr);
    void setFormula(MPtr f, double px = 22);
    void setAlignment(Qt::Alignment a);
    MathWidget *math() const { return m_math; }
    QSize sizeHint() const override;
    QSize minimumSizeHint() const override;

private:
    MathWidget *m_math;
};

class ResultList : public QScrollArea {
    Q_OBJECT
public:
    explicit ResultList(QWidget *parent = nullptr);
    void clear();
    void setItems(const std::vector<ResultItem> &items);
    void setError(const QString &msg);
    void setMessage(const QString &msg);

private:
    QWidget *m_body;
    QVBoxLayout *m_layout;
};

// 2D or 3D plot, whichever the spec needs.
class PlotStack : public QStackedWidget {
    Q_OBJECT
public:
    explicit PlotStack(QWidget *parent = nullptr);
    void setSpec(PlotPtr spec, bool resetView = true);
    void clear();
    Plot2D *plot2d() const { return m_2d; }

private:
    Plot2D *m_2d;
    Plot3D *m_3d;
};

QWidget *copyButtons(const ResultItem &it, QWidget *parent);
