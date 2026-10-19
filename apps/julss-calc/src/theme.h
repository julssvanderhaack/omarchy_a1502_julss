// Colours from the active Omarchy theme (colors.toml), shared by every widget.
#pragma once
#include <QColor>
#include <QString>
#include <QVector>

struct Theme {
    QColor bg, bgDark, bgLight, fg, fgDim, fgLight, accent, selection, muted;
    QVector<QColor> plot;     // distinct series colours
    QVector<QColor> ramp;     // height colour map for surfaces
    bool dark = true;
    QString mono, serif;

    static Theme &get();
    void load();
    QString styleSheet() const;
    QColor series(int i) const { return plot.isEmpty() ? accent : plot[((i % plot.size()) + plot.size()) % plot.size()]; }
};
