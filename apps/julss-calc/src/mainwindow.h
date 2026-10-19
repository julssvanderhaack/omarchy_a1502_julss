#pragma once
#include <QMainWindow>
#include <QJsonObject>

class Cas;
class QLabel;
class QPushButton;
class QTabWidget;
class SciPage;
class EqPage;
class CalcPage;
class GraphPage;

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    MainWindow();

protected:
    void closeEvent(QCloseEvent *e) override;

private:
    void loadState();
    void saveState() const;
    void setDefinition(const QString &name, const QString &src);
    void removeDefinition(const QString &base);

    Cas *m_cas;
    QTabWidget *m_tabs;
    SciPage *m_sci;
    EqPage *m_eq;
    CalcPage *m_calc;
    GraphPage *m_graph;
    QLabel *m_busy;
    QPushButton *m_cancel;
    QStringList m_defNames, m_defSrc;
};
