#pragma once
#include "engine.h"
#include "lyrics.h"
#include <QHash>
#include <QMainWindow>
#include <QPointer>
#include <QSet>

class QLabel;
class QLineEdit;
class QSortFilterProxyModel;
class QSplitter;
class QStackedWidget;
class QTabBar;
class QTableView;
class QToolButton;
class Bar;
class CoverView;
class EqPanel;
class GlyphButton;
class LyricsView;
class Playlist;
struct Item;

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    enum Repeat { RepeatOff, RepeatAll, RepeatOne };

    MainWindow();
    ~MainWindow() override;

    // used by command line / IPC / MPRIS
    void addPaths(const QStringList &paths, bool playNow);
    void play();
    void pause();
    void playPause();
    void stop();
    void next();
    void prev();
    void seekTo(double sec);
    void seekBy(double sec) { seekTo(engine_->position() + sec); }
    void setVolume(double v);
    double volume() const { return engine_->volume(); }
    void setShuffle(bool on);
    bool shuffle() const { return shuffle_; }
    void setRepeat(Repeat r);
    Repeat repeat() const { return repeat_; }
    Engine *engine() const { return engine_; }
    QVariantMap mprisMetadata() const;
    bool hasCurrent() const;
    void raiseWindow();

signals:
    void metadataChanged();
    void optionsChanged();     // shuffle / repeat / volume
    void seeked(double sec);

protected:
    void closeEvent(QCloseEvent *) override;
    void keyPressEvent(QKeyEvent *) override;
    void resizeEvent(QResizeEvent *) override;
    bool eventFilter(QObject *o, QEvent *e) override;

private:
    QWidget *buildPlaylistPane();
    QWidget *buildNowPane();
    QWidget *buildTransport();

    Playlist *currentList() const;
    Playlist *addList(Playlist *pl, bool select);
    void closeList(int idx);
    void renameList(int idx);
    void playItem(Playlist *pl, quint64 uid, double start = 0, bool paused = false);
    void planNext();
    quint64 pickNext(Playlist *pl, quint64 from, bool manual);
    void onTrackStarted(quint64 token);
    void onFailed(quint64 token, const QString &path, const QString &msg);
    void showTrack(const Item *it);
    void updatePlayButton();
    void updateVolumeIcon();
    void updateStatus();
    void showContextMenu(const QPoint &pos);
    void openFilesDialog(bool folder);
    void loadState();
    void saveState();
    void scheduleSave();
    void reloadTheme();

    Engine *engine_;
    LyricsFetcher *fetcher_;

    // widgets
    QTabBar *tabs_ = nullptr;
    QTableView *table_ = nullptr;
    QSortFilterProxyModel *proxy_ = nullptr;
    QLineEdit *search_;
    QLabel *status_;
    QSplitter *split_;
    CoverView *cover_ = nullptr;
    QLabel *title_, *artist_, *album_, *format_;
    QStackedWidget *pages_;
    QToolButton *lyricsTab_, *eqTab_;
    LyricsView *lyrics_;
    QLabel *lyricsSource_;
    EqPanel *eq_;
    GlyphButton *playBtn_, *prevBtn_, *nextBtn_, *shuffleBtn_, *repeatBtn_, *volBtn_;
    Bar *seek_, *vol_;
    QLabel *elapsed_, *total_;
    QWidget *nowPane_ = nullptr;
    QWidget *listPane_ = nullptr;

    // playlists & playback
    QVector<Playlist *> lists_;
    QPointer<Playlist> playingList_;
    quint64 playingUid_ = 0;
    QHash<quint64, QPair<QPointer<Playlist>, quint64>> tokens_;   // engine token → (list, uid)
    quint64 nextToken_ = 1;
    quint64 lastStartToken_ = 0;
    int failStreak_ = 0;
    bool shuffle_ = false;
    Repeat repeat_ = RepeatOff;
    QVector<quint64> history_;            // for "previous" in shuffle mode
    QSet<quint64> shufflePlayed_;
    double resumePos_ = -1;
    float preMute_ = 0.8f;
    QString artFile_;
    quint64 lyricsToken_ = 0;
    QTimer *saveTimer_;
    bool loading_ = false;
};
