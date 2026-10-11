// Monitor ligero de CPU y RAM. Lee /proc/stat y /proc/meminfo con FileView
// cada 3 s: sin lanzar procesos (los monitores de egoist ejecutan un script
// de bash cada segundo, ~8 ms de CPU cada uno). Clic: btop.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "julss.sysmon"

  // A partir de aquí el número se pone rojo.
  readonly property int alertPercent: 90

  property int cpuPercent: -1
  property int ramPercent: -1
  property real ramUsedGiB: 0
  property real ramTotalGiB: 0
  property var lastCpu: null

  readonly property color normalColor: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color alertColor: "#EF5350"

  function parseCpu(raw) {
    var line = String(raw || "").split("\n")[0]
    var f = line.trim().split(/\s+/).slice(1).map(Number)
    if (f.length < 4) return
    // idle + iowait cuentan como ocioso.
    var idle = f[3] + (f[4] || 0)
    var total = 0
    for (var i = 0; i < f.length; i++) total += f[i] || 0
    if (root.lastCpu) {
      var dTotal = total - root.lastCpu.total
      var dIdle = idle - root.lastCpu.idle
      if (dTotal > 0) root.cpuPercent = Math.round(100 * (dTotal - dIdle) / dTotal)
    }
    root.lastCpu = { total: total, idle: idle }
  }

  function parseMem(raw) {
    var total = 0, avail = 0
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = /^(MemTotal|MemAvailable):\s+(\d+)/.exec(lines[i])
      if (!m) continue
      if (m[1] === "MemTotal") total = Number(m[2])
      else avail = Number(m[2])
    }
    if (total <= 0) return
    root.ramPercent = Math.round(100 * (total - avail) / total)
    root.ramUsedGiB = (total - avail) / 1048576
    root.ramTotalGiB = total / 1048576
  }

  FileView {
    id: statFile
    path: "/proc/stat"
    blockLoading: true
    printErrors: false
    onLoaded: root.parseCpu(text())
  }

  FileView {
    id: memFile
    path: "/proc/meminfo"
    blockLoading: true
    printErrors: false
    onLoaded: root.parseMem(text())
  }

  Timer {
    interval: 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      statFile.reload()
      memFile.reload()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: row.implicitWidth + Style.space(14)
    tooltipText: root.ramTotalGiB > 0
      ? "CPU " + root.cpuPercent + " %  ·  RAM " + root.ramUsedGiB.toFixed(1) + " / " + root.ramTotalGiB.toFixed(1) + " GiB\nClic: btop"
      : "Monitor"

    Row {
      id: row
      anchors.centerIn: parent
      spacing: Style.space(8)

      // CPU: icono + porcentaje.
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)
        readonly property color tint: root.cpuPercent >= root.alertPercent ? root.alertColor : root.normalColor

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "󰍛"
          color: parent.tint
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          // Ancho fijo de 3 cifras para que la barra no baile.
          text: root.cpuPercent < 0 ? "--%" : root.cpuPercent + "%"
          width: pctMetrics.width
          horizontalAlignment: Text.AlignRight
          color: parent.tint
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      // RAM: icono + usada sobre total (GiB), en dos filas pequeñas.
      Row {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(7)
        readonly property color tint: root.ramPercent >= root.alertPercent ? root.alertColor : root.normalColor

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "󰘚"
          color: parent.tint
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: -Style.space(2)

          Text {
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: root.ramTotalGiB > 0 ? root.ramUsedGiB.toFixed(1) + "G" : "--"
            color: parent.parent.tint
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.right: parent.right
            textFormat: Text.PlainText
            text: root.ramTotalGiB > 0 ? root.ramTotalGiB.toFixed(1) + "G" : "--"
            color: Qt.darker(parent.parent.tint, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    TextMetrics {
      id: pctMetrics
      text: "100%"
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.body
    }

    onPressed: function(mouseButton) {
      if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
    }
  }
}
