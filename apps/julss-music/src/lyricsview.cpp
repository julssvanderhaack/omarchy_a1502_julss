#include "lyricsview.h"
#include "theme.h"
#include <QMouseEvent>
#include <QPainter>
#include <QTextLayout>
#include <QWheelEvent>

static QFont lyricFont(int width)
{
    QFont f;
    f.setPixelSize(std::clamp(width / 26, 15, 22));
    return f;
}

LyricsView::LyricsView(QWidget *parent) : QWidget(parent)
{
    setMouseTracking(true);
    setMinimumHeight(120);
    anim_.setDuration(380);
    anim_.setEasingCurve(QEasingCurve::OutCubic);
    connect(&anim_, &QVariantAnimation::valueChanged, this, [this](const QVariant &v) {
        scroll_ = v.toDouble();
        update();
    });
}

void LyricsView::setLyrics(const Lyrics &l)
{
    lyr_ = l;
    cur_ = -1;
    manual_ = 0;
    manualAt_.invalidate();
    relayout();
    anim_.stop();
    scroll_ = targetScroll();
    setPosition(pos_, dur_);
    update();
}

void LyricsView::setStatus(const QString &s)
{
    status_ = s;
    update();
}

void LyricsView::relayout()
{
    const QFont f = lyricFont(width());
    const QFontMetricsF fm(f);
    const double w = std::max(60, width() - 48);
    top_.resize(lyr_.lines.size());
    height_.resize(lyr_.lines.size());
    double y = 0;
    const double gap = fm.height() * (lyr_.synced ? 0.55 : 0.25);
    for (int i = 0; i < lyr_.lines.size(); ++i) {
        const QString &txt = lyr_.lines[i].text;
        double h = txt.isEmpty() ? fm.height() * (lyr_.synced ? 0.6 : 0.8)
                                 : fm.boundingRect(QRectF(0, 0, w, 1e6), Qt::AlignHCenter | Qt::TextWordWrap, txt).height();
        top_[i] = y;
        height_[i] = h;
        y += h + gap;
    }
    contentH_ = y;
}

void LyricsView::resizeEvent(QResizeEvent *)
{
    relayout();
    anim_.stop();
    scroll_ = targetScroll();
}

double LyricsView::targetScroll() const
{
    const double view = height();
    if (manualAt_.isValid() && manualAt_.elapsed() < 3500) return manual_;
    if (lyr_.synced) {
        if (cur_ < 0) return -view / 2 + (top_.isEmpty() ? 0 : height_[0] / 2) + 40;
        return top_[cur_] + height_[cur_] / 2 - view * 0.45;
    }
    // unsynced: drift through the text in step with the song
    if (contentH_ <= view || dur_ <= 0) return -std::max(0.0, (view - contentH_) / 2);
    const double frac = std::clamp((pos_ - 15) / std::max(1.0, dur_ - 40), 0.0, 1.0);
    return -24 + frac * (contentH_ - view + 48);
}

void LyricsView::glideTo(double y)
{
    if (std::abs(y - scroll_) < 0.5) return;
    anim_.stop();
    anim_.setStartValue(scroll_);
    anim_.setEndValue(y);
    anim_.start();
}

void LyricsView::setPosition(double sec, double duration)
{
    pos_ = sec;
    dur_ = duration;
    if (!isVisible()) return;
    if (lyr_.synced) {
        const double t = sec + offset_ + 0.15;   // a hair early reads naturally
        int c = -1;
        int lo = 0, hi = lyr_.lines.size() - 1;
        while (lo <= hi) {
            int mid = (lo + hi) / 2;
            if (lyr_.lines[mid].t <= t) {
                c = mid;
                lo = mid + 1;
            } else hi = mid - 1;
        }
        if (c != cur_) {
            cur_ = c;
            glideTo(targetScroll());
            update();
        } else if (manualAt_.isValid() && manualAt_.elapsed() >= 3500) {
            manualAt_.invalidate();
            glideTo(targetScroll());
        }
    } else if (!anim_.state() && !lyr_.lines.isEmpty()) {
        const double y = targetScroll();
        if (std::abs(y - scroll_) >= 1) {
            scroll_ = y;
            update();
        }
    }
}

int LyricsView::lineAt(double y) const
{
    const double cy = y + scroll_;
    for (int i = 0; i < top_.size(); ++i)
        if (cy >= top_[i] - 4 && cy <= top_[i] + height_[i] + 4) return i;
    return -1;
}

void LyricsView::wheelEvent(QWheelEvent *e)
{
    if (lyr_.lines.isEmpty()) return;
    anim_.stop();
    manual_ = (manualAt_.isValid() ? manual_ : scroll_) - e->angleDelta().y() * 0.6;
    manual_ = std::clamp(manual_, -height() / 2.0, std::max(0.0, contentH_ - height() / 2.0));
    manualAt_.start();
    scroll_ = manual_;
    update();
}

void LyricsView::mouseMoveEvent(QMouseEvent *e)
{
    const int l = lyr_.synced ? lineAt(e->position().y()) : -1;
    if (l != hoverLine_) {
        hoverLine_ = l;
        setCursor(l >= 0 ? Qt::PointingHandCursor : Qt::ArrowCursor);
        update();
    }
}

void LyricsView::mousePressEvent(QMouseEvent *e)
{
    if (!lyr_.synced || e->button() != Qt::LeftButton) return;
    const int l = lineAt(e->position().y());
    if (l >= 0) {
        manualAt_.invalidate();
        emit seekRequested(std::max(0.0, lyr_.lines[l].t - offset_));
    }
}

void LyricsView::paintEvent(QPaintEvent *)
{
    const Theme &t = Theme::get();
    QPainter p(this);
    p.setRenderHint(QPainter::TextAntialiasing);
    QFont f = lyricFont(width());
    if (lyr_.lines.isEmpty()) {
        QFont sf = f;
        sf.setPixelSize(std::max(13, f.pixelSize() - 3));
        p.setFont(sf);
        p.setPen(t.fgDim);
        p.drawText(rect().adjusted(20, 0, -20, 0), Qt::AlignCenter | Qt::TextWordWrap,
                   lyr_.instrumental ? QString("♪  Instrumental  ♪") : status_);
        return;
    }
    QFont bold = f;
    bold.setBold(true);
    const double w = std::max(60, width() - 48);
    const int view = height();
    for (int i = 0; i < lyr_.lines.size(); ++i) {
        const double y = top_[i] - scroll_;
        if (y + height_[i] < 0 || y > view) continue;
        const QString &txt = lyr_.lines[i].text;
        if (txt.isEmpty()) {
            if (i == cur_) {   // instrumental break: three dots
                p.setPen(Qt::NoPen);
                p.setBrush(t.accent);
                for (int k = -1; k <= 1; ++k) p.drawEllipse(QPointF(width() / 2.0 + k * 12, y + height_[i] / 2), 2.5, 2.5);
            }
            continue;
        }
        QColor c;
        if (!lyr_.synced) c = t.fg;
        else if (i == cur_) c = t.accent;
        else if (i == hoverLine_) c = t.fg;
        else {
            // fade with distance from the current line
            const int d = std::abs(i - (cur_ < 0 ? 0 : cur_));
            c = i < cur_ ? t.fgDim : t.fg;
            c.setAlphaF(std::clamp(1.0 - d * 0.12, 0.35, i < cur_ ? 0.8 : 0.85));
        }
        // soft fade at the top and bottom edges
        const double edge = std::min(y + height_[i] / 2, view - (y + height_[i] / 2));
        if (edge < 60) c.setAlphaF(c.alphaF() * std::clamp(edge / 60.0, 0.0, 1.0));
        p.setFont(i == cur_ && lyr_.synced ? bold : f);
        p.setPen(c);
        p.drawText(QRectF((width() - w) / 2, y, w, height_[i] + 4), Qt::AlignHCenter | Qt::AlignTop | Qt::TextWordWrap, txt);
    }
}
