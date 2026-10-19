// Scrolling, karaoke-style lyrics: the current line sits in the middle and
// glides when the next one starts. Click a line to jump there.
#pragma once
#include "lyrics.h"
#include <QElapsedTimer>
#include <QVariantAnimation>
#include <QWidget>

class LyricsView : public QWidget {
    Q_OBJECT
public:
    explicit LyricsView(QWidget *parent = nullptr);
    void setLyrics(const Lyrics &l);
    void setStatus(const QString &s);              // shown when there are no lines
    void setPosition(double sec, double duration);
    void setOffset(double s) { offset_ = s; setPosition(pos_, dur_); }
    double offset() const { return offset_; }
    const Lyrics &lyrics() const { return lyr_; }

signals:
    void seekRequested(double sec);

protected:
    void paintEvent(QPaintEvent *) override;
    void resizeEvent(QResizeEvent *) override;
    void wheelEvent(QWheelEvent *) override;
    void mouseMoveEvent(QMouseEvent *) override;
    void mousePressEvent(QMouseEvent *) override;
    void leaveEvent(QEvent *) override { hoverLine_ = -1; update(); }

private:
    void relayout();
    int lineAt(double y) const;
    double targetScroll() const;
    void glideTo(double y);

    Lyrics lyr_;
    QString status_;
    QVector<double> top_, height_;   // per line, in content coordinates
    double contentH_ = 0;
    int cur_ = -1, hoverLine_ = -1;
    double pos_ = 0, dur_ = 0, offset_ = 0;
    double scroll_ = 0, manual_ = 0;
    QElapsedTimer manualAt_;
    QVariantAnimation anim_;
};
