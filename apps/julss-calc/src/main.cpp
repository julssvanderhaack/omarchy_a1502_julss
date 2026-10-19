#include "demo.h"
#include "mainwindow.h"
#include "theme.h"
#include <QApplication>
#include <QIcon>
#include <QPalette>
#include <QStyleFactory>
#include <QTimer>

int main(int argc, char **argv)
{
    QApplication app(argc, argv);
    QApplication::setApplicationName("julss-calc");
    QApplication::setApplicationDisplayName("Calculadora");
    QGuiApplication::setDesktopFileName("julss-calc");
    QApplication::setWindowIcon(QIcon::fromTheme("accessories-calculator", QIcon::fromTheme("omacalc")));

    Theme &th = Theme::get();
    th.load();
    app.setStyle(QStyleFactory::create("Fusion"));
    QPalette pal;
    pal.setColor(QPalette::Window, th.bg);
    pal.setColor(QPalette::WindowText, th.fg);
    pal.setColor(QPalette::Base, th.bgDark);
    pal.setColor(QPalette::AlternateBase, th.bgLight);
    pal.setColor(QPalette::Text, th.fg);
    pal.setColor(QPalette::Button, th.bgLight);
    pal.setColor(QPalette::ButtonText, th.fg);
    pal.setColor(QPalette::Highlight, th.selection);
    pal.setColor(QPalette::HighlightedText, th.fg);
    pal.setColor(QPalette::PlaceholderText, th.fgDim);
    pal.setColor(QPalette::ToolTipBase, th.bgLight);
    pal.setColor(QPalette::ToolTipText, th.fg);
    pal.setColor(QPalette::Link, th.accent);
    app.setPalette(pal);
    app.setStyleSheet(th.styleSheet());

    MainWindow w;
    w.show();
    if (qEnvironmentVariableIsSet("JULSS_CALC_QUIT")) QTimer::singleShot(0, &app, &QApplication::quit);
    if (qEnvironmentVariableIsSet("JULSS_CALC_SHOTS")) runDemo(&w, qEnvironmentVariable("JULSS_CALC_SHOTS"));
    return app.exec();
}
