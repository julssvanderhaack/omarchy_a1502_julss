// Bar-widget entry point for the notifications manager. Rather than
// reimplementing storage, this reads the same history files the built-in
// omarchy.notifications service already writes to
// ~/.local/state/omarchy/notifications/history/ (see its Service.qml), and
// clears them through its public "notifications" IPC target (the same one a
// keybinding would call) rather than through bar.shell.firstPartyServiceFor:
// that accessor only proxies a small allowlisted surface (doNotDisturb) to
// third-party plugins and does not expose historyDir/clearHistory directly.
//
// Popup timeout: the service already expires low/normal toasts after 5-8 s,
// but critical-urgency ones (duration 0) stay until clicked. This widget
// sweeps the service's per-popup files and dismisses any toast older than
// popupTimeoutMs through the same IPC, which moves it into history.
//
// Do Not Disturb is the service's own: while on, toasts are not shown and go
// straight to history. Read/set through IPC (isDnd/setDnd) because the
// firstPartyServiceFor proxy is only handed to full bars and Indicators
// clones, not to plain bar widgets like this one.

import QtQuick
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
  readonly property int popupTimeoutMs: 30000

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
  }

  function refresh() {
    if (historyProc.running) return
    historyProc.command = ["bash", "-c",
      "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", root.historyDir]
    historyProc.running = true
  }

  function setDnd(value) {
    if (setDndProc.running) return
    root.dnd = !!value
    setDndProc.command = ["omarchy-shell", "-q", "notifications", "setDnd", root.dnd ? "on" : "off"]
    setDndProc.running = true
  }

  function readDnd() {
    if (dndProc.running || setDndProc.running) return
    dndProc.running = true
  }

  function sweepPopups() {
    if (popupProc.running || dismissProc.running) return
    popupProc.command = ["bash", "-c",
      "awk 1 \"$1\"/*.json 2>/dev/null || true", "--", root.popupDir]
    popupProc.running = true
  }

  function dismissStale(raw) {
    var summaries = HistoryLogic.expiredPopupSummaries(
      HistoryLogic.parseHistoryFile(raw), Date.now(), root.popupTimeoutMs)
    if (summaries.length === 0) return
    dismissProc.command = ["bash", "-c",
      "for s in \"$@\"; do omarchy-shell -q notifications dismiss \"$s\"; done", "--"].concat(summaries)
    dismissProc.running = true
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

  Component.onCompleted: {
    refresh()
    readDnd()
  }

  Timer {
    id: pollTimer
    interval: 4000
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

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: {
      root.sweepPopups()
      root.readDnd()
    }
  }

  Process {
    id: popupProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.dismissStale(text)
    }
  }

  Process {
    id: dndProc
    command: ["omarchy-shell", "notifications", "isDnd"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = text.trim()
        if (state === "on" || state === "off") root.dnd = state === "on"
      }
    }
  }

  Process {
    id: setDndProc
    onExited: root.readDnd()
  }

  Process {
    id: dismissProc
    onExited: root.refresh()
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
    color: root.bar ? root.bar.urgent : Color.urgent
    border.color: root.bar ? root.bar.background : Color.background
    border.width: Math.max(1, Style.space(1))
    anchors.right: button.right
    anchors.top: button.top
    anchors.rightMargin: -Style.space(2)
    anchors.topMargin: -Style.space(2)

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
