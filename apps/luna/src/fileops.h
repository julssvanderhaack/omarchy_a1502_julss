// Copy/move/delete jobs on worker threads, the freedesktop trash and a
// clipboard format compatible with Nautilus.
#pragma once
#include <QObject>
#include <QStringList>
#include <QThread>
#include <atomic>

class Job : public QObject {
    Q_OBJECT
public:
    enum Kind { Copy, Move, Link, Delete, EmptyTrash, Restore };
    enum Answer { Replace, Skip, KeepBoth, Cancel };
    Job(Kind k, QStringList srcs, QString dest);
    Kind kind() const { return m_kind; }
    QString title() const;
    QStringList createdPaths() const { return m_created; }
    void start();
    void cancel() { m_cancel = true; }

signals:
    void progress(qint64 doneBytes, qint64 totalBytes, int doneFiles, int totalFiles, const QString &current);
    void finished(const QStringList &errors);
    void conflict(const QString &src, const QString &dst, int *answer, bool *applyAll);

private:
    void run();
    void scan(const QString &path);
    bool copyTree(const QString &src, const QString &dst, bool move);
    bool copyFile(const QString &src, const QString &dst);
    bool removeTree(const QString &path);
    QString resolve(const QString &src, const QString &dst, bool &skip);

    Kind m_kind;
    QStringList m_srcs, m_errors, m_created;
    QString m_dest;
    std::atomic<bool> m_cancel{false};
    qint64 m_totalBytes = 0, m_doneBytes = 0;
    int m_totalFiles = 0, m_doneFiles = 0;
    int m_sticky = -1;     // "apply to all" answer
    QThread *m_thread = nullptr;
};

class FileOps : public QObject {
    Q_OBJECT
public:
    static FileOps &get();
    Job *copy(const QStringList &srcs, const QString &dest);
    Job *move(const QStringList &srcs, const QString &dest);
    Job *link(const QStringList &srcs, const QString &dest);
    Job *deleteForever(const QStringList &paths);
    Job *emptyTrash();
    Job *restore(const QStringList &trashedPaths);
    QStringList trash(const QStringList &paths);   // returns error messages

    static QString trashFiles();
    static QString trashInfo();
    static QString originalPath(const QString &trashed);
    static QString uniqueName(const QString &dir, const QString &name);
    static void toClipboard(const QStringList &paths, bool cut);
    static QStringList fromClipboard(bool *cut);
    static bool sameDevice(const QString &a, const QString &b);

signals:
    void jobStarted(Job *job);

private:
    Job *startJob(Job *j);
};
