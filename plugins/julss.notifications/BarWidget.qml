// Bar-widget entry point for the notifications manager. Rather than
// reimplementing storage, this reads the same history files the built-in
// omarchy.notifications service already writes to
// ~/.local/state/omarchy/notifications/history/ (see its Service.qml), and
// clears them through its public "notifications" IPC target (the same one a
// keybinding would call) rather than through bar.shell.firstPartyServiceFor:
// that accessor only proxies a small allowlisted surface (doNotDisturb) to
// third-party plugins and does not expose historyDir/clearHistory directly.
//
// Popup duration: chosen in the panel and written (in seconds, 0 = until
// closed) to ~/.local/state/omarchy/notifications-duration. The cloned
// service julss.notifications-service watches that file and uses it for every
// toast; without the file it keeps Omarchy's stock 5/8 s.
//
// Do Not Disturb is the service's own: while on, toasts are not shown and go
// straight to history. Set through IPC (setDnd); read by watching the
// service's own ~/.local/state/omarchy/notifications.json ("dnd" key).
//
// Consumo: nada se sondea. Antes se lanzaba `omarchy-shell notifications
// isDnd` cada 2 s (~46 ms de CPU por llamada, ~2,3 % de un núcleo) y un awk
// del historial cada 4 s. Ahora un FileView vigila notifications.json y un
// FolderListModel (inotify) vigila history/; solo se relee al cambiar algo,
// con un repaso de seguridad cada 2 min.

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

import "HistoryLogic.js" as HistoryLogic

BarWidget {
  id: root
  moduleName: "julss.notifications"

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string popupDir: root.home + "/.local/state/omarchy/notifications/"
  readonly property string historyDir: root.popupDir + "history/"
  readonly property string durationPath: root.home + "/.local/state/omarchy/notifications-duration"
  property int durationSeconds: -1

  property bool dnd: false

  property var entries: []
  readonly property int count: entries.length

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    target.bar = root.bar
    target.settings = root.settings
    target.anchorItem = button
    target.hostWidget = root
    target.entries = root.entries
    target.dnd = root.dnd
    target.durationSeconds = root.durationSeconds
  }

  function refresh() {
    if (historyProc.running) return
    historyProc.command = ["bash", "-c",
      "awk '{ n = FILENAME; sub(/.*\\//, \"\", n); print n \"\\t\" $0 }' \"$1\"/*.json 2>/dev/null || true", "--", root.historyDir]
    historyProc.running = true
  }

  function setDnd(value) {
    if (setDndProc.running) return
    root.dnd = !!value
    setDndProc.command = ["omarchy-shell", "-q", "notifications", "setDnd", root.dnd ? "on" : "off"]
    setDndProc.running = true
  }

  function parseDnd(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      if (parsed && typeof parsed.dnd === "boolean") root.dnd = parsed.dnd
    } catch (e) {
      // Fichero a medio escribir: el siguiente cambio lo corrige.
    }
  }

  function setDuration(seconds) {
    root.durationSeconds = seconds
    durationFile.setText(String(seconds) + "\n")
  }

  function parseDuration(raw) {
    var n = parseInt(String(raw || "").trim(), 10)
    root.durationSeconds = isFinite(n) && n >= 0 ? n : -1
  }

  // Borra una sola entrada: su fichero en history/ y las imágenes copiadas
  // con el mismo nombre base (así lo hace también el propio servicio).
  function removeEntry(file) {
    var name = String(file || "")
    if (!/^[0-9A-Za-z._-]+\.json$/.test(name)) return
    root.entries = root.entries.filter(function(e) { return e.file !== name })
    Quickshell.execDetached(["bash", "-c",
      "rm -f -- \"$1/$3\" \"$2/${3%.json}\"-*", "--",
      root.historyDir, root.popupDir + "images", name])
  }

  function clearAll() {
    if (clearProc.running) return
    clearProc.running = true
    // The IPC call is fire-and-forget from here; reflect it immediately in
    // the UI rather than waiting on the poll, then confirm shortly after.
    root.entries = []
    injectPanel()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  onEntriesChanged: injectPanel()
  onDndChanged: injectPanel()
  onDurationSecondsChanged: injectPanel()

  FileView {
    id: durationFile
    path: root.durationPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.parseDuration(text())
    onLoadFailed: root.durationSeconds = -1
    onFileChanged: reload()
  }

  Component.onCompleted: refresh()

  // "No molestar": el servicio lo guarda (con un pequeño retardo) aquí.
  FileView {
    id: dndFile
    path: root.home + "/.local/state/omarchy/notifications.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.parseDnd(text())
    onFileChanged: reload()
  }

  // Historial: inotify sobre history/; cualquier alta o baja relee (agrupado).
  FolderListModel {
    id: historyWatch
    folder: "file://" + root.historyDir
    nameFilters: ["*.json"]
    showDirs: false
    onCountChanged: refreshDebounce.restart()
  }

  Connections {
    target: historyWatch
    function onRowsInserted() { refreshDebounce.restart() }
    function onRowsRemoved() { refreshDebounce.restart() }
    function onDataChanged() { refreshDebounce.restart() }
  }

  Timer {
    id: refreshDebounce
    interval: 250
    onTriggered: root.refresh()
  }

  // Repaso de seguridad por si se perdiera algún evento.
  Timer {
    id: pollTimer
    interval: 120000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.entries = HistoryLogic.parseHistoryFile(text)
    }
  }

  Process {
    id: setDndProc
  }

  Process {
    id: clearProc
    command: ["omarchy-shell", "-q", "notifications", "clear"]
    onExited: root.refresh()
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.dnd ? "󰂛" : "󰂚"
    tooltipText: root.dnd ? "Notificaciones (no molestar)" : "Notificaciones"
    onPressed: root.toggle()
  }

  Rectangle {
    visible: root.count > 0
    width: Style.space(15)
    height: Style.space(15)
    radius: width / 2
    // Rojo oscuro, y dentro de los límites del botón: antes asomaba 2 px por
    // arriba y por la derecha (borde de la pantalla) y el círculo se cortaba.
    color: "#B02A2A"
    border.color: root.bar ? root.bar.background : Color.background
    border.width: Math.max(1, Style.space(1))
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: Style.space(1)
    anchors.topMargin: Style.space(1)

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      text: root.count > 9 ? "9+" : String(root.count)
      color: "white"
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }
}
