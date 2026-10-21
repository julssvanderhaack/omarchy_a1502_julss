// The four tabs of the calculator.
#pragma once
#include "types.h"
#include <QJsonObject>
#include <QSet>
#include <QWidget>

class Cas;
class FormulaView;
class PlotStack;
class QComboBox;
class QFormLayout;
class QLabel;
class QLineEdit;
class QPlainTextEdit;
class QPushButton;
class QScrollArea;
class QSpinBox;
class QTimer;
class QToolButton;
class QVBoxLayout;
class ResultList;

class Page : public QWidget {
    Q_OBJECT
public:
    Page(Cas *cas, QWidget *parent = nullptr);
    virtual void save(QJsonObject &) const {}
    virtual void load(const QJsonObject &) {}

protected:
    // Submits a request and remembers it as ours; replies go to onResponse().
    int submit(Request r);
    virtual void onResponse(const Response &) {}
    Cas *m_cas;

private:
    QSet<int> m_mine;
};

// ------------------------------------------------------------- Científica
class SciPage : public Page {
    Q_OBJECT
public:
    explicit SciPage(Cas *cas, QWidget *parent = nullptr);
    void save(QJsonObject &o) const override;
    void load(const QJsonObject &o) override;
    void setDefinitionNames(const QStringList &names) { m_defNames = names; }
    void focusInput();

signals:
    void defined(const QString &name, const QString &src);
    void undefineRequested(const QString &name);   // empty = everything

protected:
    void onResponse(const Response &r) override;
    bool eventFilter(QObject *o, QEvent *e) override;

private:
    struct Entry {
        QString input;
        std::vector<ResultItem> items;
        QString error;
    };
    void evaluate();
    void insert(const QString &s);
    void addEntryWidget(const Entry &e, int index);
    void requestPreview();
    QWidget *buildKeypad();
    void scrollToBottom();

    QScrollArea *m_scroll;
    QWidget *m_histBody;
    QVBoxLayout *m_histLayout;
    FormulaView *m_preview;
    QLineEdit *m_input;
    QPushButton *m_angle;
    QSpinBox *m_digits;
    QToolButton *m_memory;
    QTimer *m_previewTimer;
    std::vector<Entry> m_history;
    std::map<int, QWidget *> m_pendingCards;
    std::map<int, QString> m_pendingInput;
    QStringList m_defNames;
    int m_previewId = 0;
    int m_recall = -1;
    QString m_draft;
};

// ------------------------------------------------------------- Ecuaciones
class EqPage : public Page {
    Q_OBJECT
public:
    explicit EqPage(Cas *cas, QWidget *parent = nullptr);
    void save(QJsonObject &o) const override;
    void load(const QJsonObject &o) override;

protected:
    void onResponse(const Response &r) override;
    bool eventFilter(QObject *o, QEvent *e) override;

private:
    void solve();
    QPlainTextEdit *m_text;
    QLineEdit *m_vars;
    QComboBox *m_domain;
    ResultList *m_results;
    PlotStack *m_plot;
    int m_last = 0;
};

// ---------------------------------------------------------------- Cálculo
class CalcPage : public Page {
    Q_OBJECT
public:
    explicit CalcPage(Cas *cas, QWidget *parent = nullptr);
    void save(QJsonObject &o) const override;
    void load(const QJsonObject &o) override;

protected:
    void onResponse(const Response &r) override;

private:
    void compute();
    void updateFields();
    QLineEdit *m_f;
    FormulaView *m_preview;
    QComboBox *m_op;
    QFormLayout *m_form;
    QLineEdit *m_g, *m_var, *m_a, *m_b, *m_var2, *m_c, *m_d, *m_point;
    QSpinBox *m_order;
    QComboBox *m_dir;
    ResultList *m_results;
    PlotStack *m_plot;
    QTimer *m_previewTimer;
    int m_last = 0, m_previewId = 0;
};

// --------------------------------------------------------------- Gráficas
class GraphPage : public Page {
    Q_OBJECT
public:
    explicit GraphPage(Cas *cas, QWidget *parent = nullptr);
    void save(QJsonObject &o) const override;
    void load(const QJsonObject &o) override;

protected:
    void onResponse(const Response &r) override;

private:
    struct Row {
        QWidget *box;
        QLabel *swatch;
        QLineEdit *edit;
        QLabel *error;
    };
    void addRow(const QString &text = QString());
    void removeRow(QWidget *box);
    void recolor();
    void draw();
    QVBoxLayout *m_rowsLayout;
    std::vector<Row> m_rows;
    QLineEdit *m_xmin, *m_xmax, *m_ymin, *m_ymax, *m_tmin, *m_tmax;
    PlotStack *m_plot;
    int m_last = 0;
    bool m_syncing = false;
};
