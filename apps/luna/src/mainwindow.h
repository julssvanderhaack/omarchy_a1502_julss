#pragma once
#include <QMainWindow>

class Pane;
class PathBar;
class Sidebar;
class QLabel;
class QSplitter;
class QStackedWidget;
class QTabBar;
class QToolButton;
class QVBoxLayout;
class Job;

// One tab: one or two panes side by side.
class TabPage : public QWidget {
    Q_OBJECT
public:
    explicit TabPage(const QString &path, QWidget *parent = nullptr);
    Pane *active() const { return m_active; }
    Pane *other() const;
    Pane *first() const { return m_a; }
    bool isSplit() const { return m_b != nullptr; }
    void setSplit(bool on);
    void setActive(Pane *p);

signals:
    void paneCreated(Pane *p);
    void activeChanged(Pane *p);

private:
    QSplitter *m_split;
    Pane *m_a, *m_b = nullptr, *m_active;
};

class MainWindow : public QMainWindow {
    Q_OBJECT
public:
    explicit MainWindow(const QStringList &paths = {});
    Pane *pane() const;
    TabPage *page() const;
    int newTab(const QString &path, bool activate = true);

protected:
    void closeEvent(QCloseEvent *e) override;

private:
    void wirePane(Pane *p);
    void closeTab(int index);
    void syncHeader();
    void layoutSidebar();
    void applySettings();
    void trackJob(Job *job);
    void addShortcuts();
    void showShortcuts();
    void showAbout();
    void connectServer(const QString &uri);
    void syncViewButton();
    QToolButton *toolButton(const QString &glyph, const QString &tip);

    QTabBar *m_tabBar;
    QStackedWidget *m_pages;
    Sidebar *m_sidebar;
    QSplitter *m_main;
    QToolButton *m_back, *m_forward, *m_up, *m_split, *m_sideBtn, *m_viewBtn;
    QList<QAction *> m_viewActions;
    PathBar *m_pathbar;
    QLabel *m_status;
    QWidget *m_jobs;
    QVBoxLayout *m_jobsLayout;
};
