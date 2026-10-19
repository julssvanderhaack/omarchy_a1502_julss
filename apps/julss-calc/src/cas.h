// Giac-backed computer algebra, run on its own thread so the window never
// blocks. Requests are queued; results come back through finished() on the
// GUI thread. cancel() interrupts whatever Giac is doing right now.
#pragma once
#include "types.h"
#include <QObject>
#include <QThread>
#include <QMutex>
#include <QWaitCondition>
#include <deque>
#include <atomic>

class CasEngine;

class Cas : public QObject {
    Q_OBJECT
public:
    explicit Cas(QObject *parent = nullptr);
    ~Cas() override;

    // Replays saved definitions before anything else runs.
    void setDefinitions(const QStringList &defs);
    int submit(Request r);
    void cancel();
    bool busy() const { return m_pending > 0; }

signals:
    void finished(const Response &r);
    void busyChanged(bool busy);

private:
    class Worker;
    void deliver(Response r);

    Worker *m_thread = nullptr;
    QMutex m_mutex;
    QWaitCondition m_cond;
    std::deque<Request> m_queue;
    bool m_quit = false;
    int m_nextId = 1;
    int m_pending = 0;   // non-preview jobs queued or running
    QStringList m_defs;
};

Q_DECLARE_METATYPE(Response)
