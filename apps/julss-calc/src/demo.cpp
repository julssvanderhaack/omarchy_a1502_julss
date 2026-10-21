#include "demo.h"
#include <QLineEdit>
#include <QMainWindow>
#include <QPlainTextEdit>
#include <QComboBox>
#include <QPushButton>
#include <QTabWidget>
#include <QTimer>
#include <functional>

namespace {
QPushButton *button(QWidget *root, const QString &text)
{
    for (auto *b : root->findChildren<QPushButton *>())
        if (b->text() == text && b->isVisible()) return b;
    return nullptr;
}
}

void runDemo(QMainWindow *w, const QString &dir)
{
    auto *tabs = w->findChild<QTabWidget *>();
    auto steps = std::make_shared<std::vector<std::function<void()>>>();
    auto shot = [w, dir](const QString &name) { w->grab().save(dir + "/" + name + ".png"); };
    auto sciInput = [w]() -> QLineEdit * {
        for (auto *e : w->findChildren<QLineEdit *>())
            if (e->placeholderText().startsWith("Escribe")) return e;
        return nullptr;
    };
    for (const char *in : {"2 sen(30°) + √2", "(3+4i)/(1-i)", "f(x) = x^2 + 1", "f(3) + 1/3", "x^2 - 5x + 6 = 0", "∫"})
        steps->push_back([=] {
            QString s = QString::fromUtf8(in);
            if (s == QString::fromUtf8("∫")) { sciInput()->setText("integrate(x^2 sen x, x)"); return; }
            sciInput()->setText(s);
            emit sciInput()->returnPressed();
        });
    steps->push_back([=] { shot("1-cientifica"); });
    steps->push_back([=] {
        tabs->setCurrentIndex(1);
        w->findChild<QPlainTextEdit *>()->setPlainText("x + y <= 6\nx - y >= -2\nx >= 0\ny >= 0");
        button(w, QString::fromUtf8("Resolver"))->click();
    });
    steps->push_back([=] { shot("2-ecuaciones-region"); });
    steps->push_back([=] {
        w->findChild<QPlainTextEdit *>()->setPlainText("x + y + z = 6\n2x - y + z = 3\nx + 2y - z = 2");
        button(w, QString::fromUtf8("Resolver"))->click();
    });
    steps->push_back([=] { shot("3-ecuaciones-sistema"); });
    steps->push_back([=] {
        w->findChild<QPlainTextEdit *>()->setPlainText("(x - 1)/(x + 2) >= 0");
        button(w, QString::fromUtf8("Resolver"))->click();
    });
    steps->push_back([=] { shot("4-inecuacion"); });
    steps->push_back([=] {
        tabs->setCurrentIndex(2);
        for (auto *e : tabs->currentWidget()->findChildren<QLineEdit *>())
            if (e->placeholderText().startsWith("p. ej.")) { e->setText(QString::fromUtf8("x^2·e^x")); break; }
        button(w, QString::fromUtf8("Calcular"))->click();
    });
    steps->push_back([=] { shot("5-calculo-derivada"); });
    steps->push_back([=] {
        auto *combo = tabs->currentWidget()->findChild<QComboBox *>();
        combo->setCurrentIndex(2);
        for (auto *e : tabs->currentWidget()->findChildren<QLineEdit *>())
            if (e->placeholderText().startsWith("p. ej.")) { e->setText(QString::fromUtf8("sen(x)^2")); break; }
        button(w, QString::fromUtf8("Calcular"))->click();
    });
    steps->push_back([=] { shot("6-calculo-integral"); });
    auto calcOp = [=](int op, const char *f, const char *g) {
        tabs->currentWidget()->findChild<QComboBox *>()->setCurrentIndex(op);
        for (auto *e : tabs->currentWidget()->findChildren<QLineEdit *>()) {
            if (e->placeholderText().startsWith("p. ej.")) e->setText(QString::fromUtf8(f));
            else if (e->isVisible() && (e->placeholderText().startsWith("x^2 - x") || e->placeholderText().startsWith("x −")))
                e->setText(QString::fromUtf8(g));
        }
        button(w, QString::fromUtf8("Calcular"))->click();
    };
    steps->push_back([=] { calcOp(8, "x^4 - 3x^2 + 2x - 5", "x^2 - x + 1"); });
    steps->push_back([=] { shot("6b-division-polinomios"); });
    steps->push_back([=] { calcOp(9, "2x^3 - 5x^2 + 4", "x - 2"); });
    steps->push_back([=] { shot("6c-ruffini"); });
    steps->push_back([=] { calcOp(9, "x^4 - x^3 - 7x^2 + x + 6", ""); });
    steps->push_back([=] { shot("6d-ruffini-factorizar"); });
    steps->push_back([=] {
        tabs->setCurrentIndex(3);
        button(w, QString::fromUtf8("Dibujar"))->click();
    });
    steps->push_back([=] { shot("7-graficas-2d"); });
    steps->push_back([=] {
        QList<QLineEdit *> rows;
        for (auto *e : tabs->currentWidget()->findChildren<QLineEdit *>())
            if (e->placeholderText().startsWith("f(x)")) rows << e;
        rows[0]->setText(QString::fromUtf8("x^2 + y^2 + z^2 = 9"));
        rows[1]->clear();
        button(w, QString::fromUtf8("Dibujar"))->click();
    });
    steps->push_back([=] { shot("8-graficas-3d"); });
    steps->push_back([=] {
        QList<QLineEdit *> rows;
        for (auto *e : tabs->currentWidget()->findChildren<QLineEdit *>())
            if (e->placeholderText().startsWith("f(x)")) rows << e;
        rows[0]->clear(); rows[1]->setText(QString::fromUtf8("(sqrt(x^2+y^2) - 3)^2 + z^2 = 1"));
        button(w, QString::fromUtf8("Dibujar"))->click();
    });
    steps->push_back([=] { shot("9-dominio-complejo"); });
    steps->push_back([=] {
        QList<QLineEdit *> rows;
        for (auto *e : tabs->currentWidget()->findChildren<QLineEdit *>())
            if (e->placeholderText().startsWith("f(x)")) rows << e;
        rows[0]->setText(QString::fromUtf8("x^2 + y^2 = 9"));
        rows[1]->setText(QString::fromUtf8("y > x^2 - 2"));
        button(w, QString::fromUtf8("Dibujar"))->click();
    });
    steps->push_back([=] { shot("10-implicita-region"); });
    steps->push_back([=] { w->close(); });

    auto idx = std::make_shared<size_t>(0);
    auto *timer = new QTimer(w);
    QObject::connect(timer, &QTimer::timeout, w, [steps, idx, timer] {
        if (*idx >= steps->size()) { timer->stop(); return; }
        (*steps)[(*idx)++]();
    });
    timer->start(450);
}
