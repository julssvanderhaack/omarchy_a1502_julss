// sonata: local music player for Omarchy.
//
// Single instance: launching it again (e.g. clicking another file in the file
// manager) hands the files to the running window over a unix socket instead
// of opening a second player.
#include "mainwindow.h"
#include "mpris.h"
#include "theme.h"
#include <QApplication>
#include <QFile>
#include <QStandardPaths>
#include <QDirIterator>
#include <QDir>
#include <QFileInfo>
#include <QIcon>
#include <QLocalServer>
#include <QLocalSocket>
#include <QStyleFactory>
#include <QTimer>
#include <QUrl>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
extern "C" {
#include <libavutil/log.h>
}

static QByteArray socketPath()
{
    QByteArray dir = qgetenv("XDG_RUNTIME_DIR");
    if (dir.isEmpty()) dir = "/tmp";
    return dir + "/sonata.sock";
}

// Plain POSIX so a second launch exits in a few ms without starting Qt GUI.
static bool sendToRunning(const QByteArray &msg)
{
    const QByteArray path = socketPath();
    int fd = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::strncpy(addr.sun_path, path.constData(), sizeof addr.sun_path - 1);
    if (::connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0) {
        ::close(fd);
        return false;
    }
    const char *p = msg.constData();
    qsizetype left = msg.size();
    while (left > 0) {
        ssize_t n = ::write(fd, p, size_t(left));
        if (n <= 0) break;
        p += n;
        left -= n;
    }
    ::close(fd);
    return true;
}

static void handleMessage(MainWindow *w, const QByteArray &msg)
{
    QStringList files;
    bool playNow = false, show = true;
    for (const QByteArray &line : msg.split('\n')) {
        const QString l = QString::fromUtf8(line);
        if (l.isEmpty()) continue;
        if (l == "--play") playNow = true;
        else if (l == "--toggle") { w->playPause(); show = false; }
        else if (l == "--next") { w->next(); show = false; }
        else if (l == "--prev") { w->prev(); show = false; }
        else if (l == "--stop") { w->stop(); show = false; }
        else files << l;
    }
    if (!files.isEmpty()) w->addPaths(files, playNow);
    else if (show) w->raiseWindow();
}

// The player used to be called "julss-music": on the first run as Sonata,
// copy its playlists, state, lyrics and cover cache (copy, not move, in case
// the old version is still running and writes its state on exit).
static void migrateFromJulssMusic()
{
    for (auto loc : {QStandardPaths::GenericDataLocation, QStandardPaths::GenericStateLocation, QStandardPaths::GenericCacheLocation}) {
        const QString base = QStandardPaths::writableLocation(loc);
        const QString from = base + "/julss-music", to = base + "/sonata";
        if (!QFileInfo(from).isDir() || QFileInfo::exists(to)) continue;
        QDirIterator it(from, QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden, QDirIterator::Subdirectories);
        QDir().mkpath(to);
        while (it.hasNext()) {
            it.next();
            const QString dest = to + it.filePath().mid(from.size());
            if (it.fileInfo().isDir()) QDir().mkpath(dest);
            else QFile::copy(it.filePath(), dest);
        }
    }
}

int main(int argc, char **argv)
{
    // Build the message first: absolute paths, so the running instance can
    // resolve them whatever its working directory is.
    QByteArray msg;
    for (int i = 1; i < argc; ++i) {
        QString a = QString::fromLocal8Bit(argv[i]);
        if (a.startsWith("--")) {
            if (a == "--help" || a == "-h") {
                puts("sonata [--play] [--toggle|--next|--prev|--stop] [archivos o carpetas…]");
                return 0;
            }
            msg += a.toUtf8() + '\n';
            continue;
        }
        if (a.startsWith("file://")) a = QUrl(a).toLocalFile();
        msg += QFileInfo(a).absoluteFilePath().toUtf8() + '\n';
    }
    if (sendToRunning(msg.isEmpty() ? QByteArray("\n") : msg)) return 0;

    av_log_set_level(AV_LOG_ERROR);
    QApplication app(argc, argv);
    QApplication::setApplicationName("sonata");
    QApplication::setApplicationDisplayName("Sonata");
    QGuiApplication::setDesktopFileName("sonata");
    QApplication::setWindowIcon(QIcon::fromTheme("sonata", QIcon(":/sonata.svg")));
    app.setStyle(QStyleFactory::create("Fusion"));
    Theme::get().load();
    Theme::get().apply();

    migrateFromJulssMusic();
    MainWindow w;
    registerMpris(&w);

    QLocalServer server;
    ::unlink(socketPath().constData());
    server.setSocketOptions(QLocalServer::UserAccessOption);
    server.listen(QString::fromLocal8Bit(socketPath()));
    QObject::connect(&server, &QLocalServer::newConnection, &w, [&] {
        while (QLocalSocket *s = server.nextPendingConnection()) {
            auto *buf = new QByteArray;
            QObject::connect(s, &QLocalSocket::readyRead, s, [s, buf] { *buf += s->readAll(); });
            QObject::connect(s, &QLocalSocket::disconnected, &w, [s, buf, &w] {
                *buf += s->readAll();
                handleMessage(&w, *buf);
                delete buf;
                s->deleteLater();
            });
        }
    });

    w.show();
    if (const QString shot = qEnvironmentVariable("SONATA_SHOT"); !shot.isEmpty()) {   // tests
        const int delay = qEnvironmentVariableIntValue("SONATA_SHOT_DELAY");
        if (const QStringList sz = qEnvironmentVariable("SONATA_SHOT_SIZE").split('x'); sz.size() == 2)
            w.resize(sz[0].toInt(), sz[1].toInt());
        QTimer::singleShot(delay ? delay : 3000, &w, [&w, shot] {
            w.grab().save(shot);
            if (qEnvironmentVariableIsSet("SONATA_QUIT")) w.close();
        });
    }
    // command-line commands (--toggle etc.) make no sense for a fresh window
    QStringList files;
    bool playNow = false;
    for (const QByteArray &line : msg.split('\n')) {
        if (line == "--play") playNow = true;
        else if (!line.isEmpty() && !line.startsWith("--")) files << QString::fromUtf8(line);
    }
    if (!files.isEmpty()) w.addPaths(files, playNow);
    if (qEnvironmentVariableIsSet("SONATA_SEEK"))   // tests
        QTimer::singleShot(1500, &w, [&w] { w.seekTo(qEnvironmentVariable("SONATA_SEEK").toDouble()); });
    const int rc = app.exec();
    server.close();
    ::unlink(socketPath().constData());
    return rc;
}
