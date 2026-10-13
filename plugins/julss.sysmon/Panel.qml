// Monitor ligero de CPU y RAM. Lee /proc/stat y /proc/meminfo con FileView
// cada 3 s (1,5 s con el panel abierto): sin lanzar procesos (los monitores
// de egoist ejecutan un script de bash cada segundo). Clic: panel con el
// detalle (CPU y núcleos, memoria, swap, ventilador, disco); clic derecho: btop.

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "julss.sysmon"
  ipcTarget: "julss.sysmon"

  // A partir de aquí el número se pone rojo.
  readonly property int alertPercent: 90

  property int cpuPercent: -1
  property int ramPercent: -1
  property real ramUsedGiB: 0
  property real ramTotalGiB: 0
  property int cpuTempC: -1
  // Ruta de la temperatura del paquete (coretemp/k10temp…). hwmonN cambia
  // entre arranques, así que se busca una vez al cargar.
  property string tempPath: ""
  // Ventilador (applesmc en este MacBook): rpm actual y máximo.
  property string fanPath: ""
  property int fanRpm: -1
  property int fanMaxRpm: -1

  readonly property color normalColor: root.bar ? root.bar.barForeground : Color.foreground
  readonly property color alertColor: "#EF5350"

  // /proc/stat: línea "cpu" (total) y "cpuN" (núcleos). Uso = 1 - ocioso
  // (idle + iowait) entre dos lecturas.
  property var lastCpu: ({})
  property var corePercents: []

  function parseCpu(raw) {
    var lines = String(raw || "").split("\n")
    var prev = root.lastCpu, next = {}, cores = []
    for (var i = 0; i < lines.length; i++) {
      var m = /^(cpu\d*)\s+(.*)$/.exec(lines[i])
      if (!m) continue
      var f = m[2].trim().split(/\s+/).map(Number)
      var idle = f[3] + (f[4] || 0)
      var total = 0
      for (var j = 0; j < f.length; j++) total += f[j] || 0
      next[m[1]] = { total: total, idle: idle }
      var pct = -1
      if (prev[m[1]]) {
        var dTotal = total - prev[m[1]].total
        var dIdle = idle - prev[m[1]].idle
        if (dTotal > 0) pct = Math.round(100 * (dTotal - dIdle) / dTotal)
      }
      if (m[1] === "cpu") { if (pct >= 0) root.cpuPercent = pct }
      else cores.push(pct)
    }
    root.lastCpu = next
    root.corePercents = cores
  }

  // /proc/meminfo, en KiB.
  property var mem: ({})

  function parseMem(raw) {
    var v = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = /^(\w+):\s+(\d+)/.exec(lines[i])
      if (m) v[m[1]] = Number(m[2])
    }
    var total = v.MemTotal || 0
    if (total <= 0) return
    var avail = v.MemAvailable || 0
    root.ramPercent = Math.round(100 * (total - avail) / total)
    root.ramUsedGiB = (total - avail) / 1048576
    root.ramTotalGiB = total / 1048576
    root.mem = v
  }

  function gib(kib) {
    return (Number(kib || 0) / 1048576).toFixed(1).replace(".", ",")
  }

  // Disco: df del sistema de ficheros raíz, una vez por minuto.
  property real diskUsedGiB: -1
  property real diskTotalGiB: -1

  Process {
    id: diskProc
    command: ["df", "-B1", "--output=used,size", "/"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var nums = text.trim().split("\n").pop().trim().split(/\s+/).map(Number)
        if (nums.length === 2 && nums[1] > 0) {
          root.diskUsedGiB = nums[0] / 1073741824
          root.diskTotalGiB = nums[1] / 1073741824
        }
      }
    }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!diskProc.running) diskProc.running = true
  }

  FileView {
    id: statFile
    path: "/proc/stat"
    blockLoading: true
    printErrors: false
    onLoaded: root.parseCpu(text())
  }

  // Busca una vez al cargar las rutas del sensor de temperatura y del
  // ventilador (los números hwmonN cambian entre arranques).
  Process {
    id: findSensors
    running: true
    command: ["bash", "-c",
      "for n in /sys/class/hwmon/hwmon*/name; do " +
      "case $(cat \"$n\" 2>/dev/null) in coretemp|k10temp|zenpower|cpu_thermal) " +
      "d=${n%/name}; t=; for l in \"$d\"/temp*_label; do " +
      "case $(cat \"$l\" 2>/dev/null) in 'Package id 0'|Tctl|Tdie) t=${l%_label}_input; break;; esac; done; " +
      "[ -z \"$t\" ] && [ -r \"$d/temp1_input\" ] && t=$d/temp1_input; " +
      "[ -n \"$t\" ] && echo \"temp=$t\" && break;; esac; done; " +
      "for f in /sys/class/hwmon/hwmon*/fan1_input /sys/class/hwmon/hwmon*/device/fan1_input; do " +
      "[ -r \"$f\" ] && echo \"fan=$f\" && echo \"fanmax=$(cat \"${f%_input}_max\" 2>/dev/null)\" && break; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var eq = lines[i].indexOf("=")
          if (eq < 0) continue
          var key = lines[i].slice(0, eq), value = lines[i].slice(eq + 1).trim()
          if (key === "temp") root.tempPath = value
          else if (key === "fan") root.fanPath = value
          else if (key === "fanmax") root.fanMaxRpm = parseInt(value, 10) || -1
        }
      }
    }
  }

  FileView {
    id: fanFile
    path: root.fanPath
    blockLoading: true
    printErrors: false
    onLoaded: {
      var rpm = parseInt(text(), 10)
      if (isFinite(rpm)) root.fanRpm = rpm
    }
  }

  FileView {
    id: tempFile
    path: root.tempPath
    blockLoading: true
    printErrors: false
    onLoaded: {
      var milli = parseInt(text(), 10)
      if (isFinite(milli)) root.cpuTempC = Math.round(milli / 1000)
    }
  }

  FileView {
    id: memFile
    path: "/proc/meminfo"
    blockLoading: true
    printErrors: false
    onLoaded: root.parseMem(text())
  }

  Timer {
    interval: root.opened ? 1500 : 3000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      statFile.reload()
      memFile.reload()
      if (root.tempPath !== "") tempFile.reload()
      if (root.fanPath !== "") fanFile.reload()
    }
  }


  function openBtop() {
    root.close()
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
  }

  function pctText(n) { return n < 0 ? "--" : n + " %" }
  function usageColor(pct) { return pct >= root.alertPercent ? root.alertColor : Color.accent }
  function memPct(kib) { return root.mem.MemTotal > 0 ? Math.round(100 * (kib || 0) / root.mem.MemTotal) : 0 }

  readonly property real usedKiB: (root.mem.MemTotal || 0) - (root.mem.MemAvailable || 0)
  readonly property real cacheKiB: (root.mem.Cached || 0) + (root.mem.Buffers || 0) + (root.mem.SReclaimable || 0)
  readonly property real swapUsedKiB: (root.mem.SwapTotal || 0) - (root.mem.SwapFree || 0)
  readonly property int swapPercent: root.mem.SwapTotal > 0 ? Math.round(100 * root.swapUsedKiB / root.mem.SwapTotal) : 0
  readonly property int fanPercent: root.fanMaxRpm > 0 && root.fanRpm >= 0 ? Math.round(100 * root.fanRpm / root.fanMaxRpm) : -1
  readonly property int diskPercent: root.diskTotalGiB > 0 ? Math.round(100 * root.diskUsedGiB / root.diskTotalGiB) : -1

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: row.implicitWidth + Style.space(10)

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

    // Clic: panel con el detalle; clic derecho: btop.
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.openBtop()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onActivateRequested: root.openBtop()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: icono · título/estado · CPU % ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: "󰍛"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroPercent.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Sistema"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: {
                var parts = ["Uso de CPU"]
                if (root.cpuTempC >= 0) parts.push(root.cpuTempC + " °C")
                parts.push("RAM " + root.ramPercent + " %")
                return parts.join(" · ")
              }
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: heroPercent
            textFormat: Text.PlainText
            text: root.cpuPercent < 0 ? "—" : root.cpuPercent + "%"
            color: root.cpuPercent >= root.alertPercent ? root.alertColor : root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Procesador ----------
        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(8)

          SectionTitle {
            title: "PROCESADOR"
            detail: root.cpuTempC >= 0 ? root.cpuTempC + " °C" : ""
          }

          UsageBar { percent: root.cpuPercent; fillColor: root.usageColor(root.cpuPercent) }

          // Núcleos, dos por fila.
          Grid {
            id: coreGrid
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.space(6)

            Repeater {
              model: root.corePercents

              Row {
                required property var modelData
                required property int index
                width: (coreGrid.width - coreGrid.columnSpacing) / 2
                spacing: Style.space(8)

                InfoLabel {
                  id: coreLabel
                  anchors.verticalCenter: parent.verticalCenter
                  text: "cpu" + index
                  width: Style.space(34)
                }

                UsageBar {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - coreLabel.width - corePct.width - parent.spacing * 2
                  barHeight: Style.space(5)
                  percent: modelData
                  fillColor: root.usageColor(modelData)
                }

                InfoValue {
                  id: corePct
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.pctText(modelData)
                  width: Style.space(38)
                  horizontalAlignment: Text.AlignRight
                }
              }
            }
          }
        }

        // ---------- Memoria ----------
        PanelSeparator { foreground: root.bar.foreground }

        Column {
          width: parent.width
          spacing: Style.space(8)

          SectionTitle {
            title: "MEMORIA"
            detail: root.gib(root.usedKiB) + " / " + root.gib(root.mem.MemTotal) + " GiB · " + root.ramPercent + " %"
          }

          // En uso (color) + caché (tenue) sobre el total.
          Item {
            width: parent.width
            implicitHeight: Style.space(8)

            Rectangle {
              id: memTrack
              anchors.fill: parent
              radius: height / 2
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
            }

            Rectangle {
              x: memUsed.width - radius * 2
              height: memTrack.height
              radius: memTrack.radius
              width: Math.min(memTrack.width - x, memTrack.width * root.memPct(root.cacheKiB) / 100 + radius * 2)
              color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.3)
              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }

            Rectangle {
              id: memUsed
              height: memTrack.height
              radius: memTrack.radius
              width: Math.max(memTrack.height, memTrack.width * root.ramPercent / 100)
              color: root.usageColor(root.ramPercent)
              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(20)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair { label: "En uso"; value: root.gib(root.usedKiB) + " GiB"; swatch: root.usageColor(root.ramPercent) }
              InfoPair { label: "Caché"; value: root.gib(root.cacheKiB) + " GiB"; swatch: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.3) }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap
              InfoPair { label: "Libre"; value: root.gib(root.mem.MemFree) + " GiB" }
              InfoPair { label: "Disponible"; value: root.gib(root.mem.MemAvailable) + " GiB" }
            }
          }

          Column {
            visible: (root.mem.SwapTotal || 0) > 0
            width: parent.width
            spacing: Style.space(6)

            Item { width: 1; height: Style.space(2) }

            SectionTitle {
              title: "SWAP"
              detail: root.gib(root.swapUsedKiB) + " / " + root.gib(root.mem.SwapTotal) + " GiB · " + root.swapPercent + " %"
            }

            UsageBar { percent: root.swapPercent; fillColor: root.usageColor(root.swapPercent) }
          }
        }

        // ---------- Ventilador y disco ----------
        PanelSeparator {
          visible: root.fanPercent >= 0 || root.diskPercent >= 0
          foreground: root.bar.foreground
        }

        Row {
          visible: root.fanPercent >= 0 || root.diskPercent >= 0
          width: parent.width
          spacing: Style.space(20)

          Column {
            visible: root.fanPercent >= 0
            width: (parent.width - parent.spacing) / 2
            spacing: Style.space(8)

            SectionTitle { title: "VENTILADOR"; detail: root.fanRpm + " rpm" }
            UsageBar { percent: root.fanPercent; fillColor: Color.accent }
          }

          Column {
            visible: root.diskPercent >= 0
            width: (parent.width - parent.spacing) / 2
            spacing: Style.space(8)

            SectionTitle {
              title: "DISCO"
              detail: Math.round(root.diskUsedGiB) + " / " + Math.round(root.diskTotalGiB) + " GiB"
            }
            UsageBar { percent: root.diskPercent; fillColor: root.usageColor(root.diskPercent) }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Button {
          width: parent.width
          iconText: "󰄪"
          text: "Abrir btop"
          tooltipText: "Monitor de procesos (también con clic derecho en la barra)"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          bordered: true
          onClicked: root.openBtop()
        }
      }
    }
  }

  // Cabecera de sección con un dato a la derecha.
  component SectionTitle: Item {
    property string title: ""
    property string detail: ""
    width: parent ? parent.width : 0
    implicitHeight: Math.max(sectionHeader.implicitHeight, sectionDetail.implicitHeight)

    PanelSectionHeader {
      id: sectionHeader
      text: parent.title
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: sectionDetail
      textFormat: Text.PlainText
      text: parent.detail
      color: Qt.darker(root.bar.foreground, 1.4)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // Barra de progreso redondeada, como la de la batería.
  component UsageBar: Item {
    id: usage
    property int percent: 0
    property color fillColor: Color.accent
    property real barHeight: Style.space(8)
    width: parent ? parent.width : 0
    implicitHeight: barHeight

    Rectangle {
      id: usageTrack
      anchors.fill: parent
      radius: height / 2
      color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
    }

    Rectangle {
      height: usageTrack.height
      radius: usageTrack.radius
      width: Math.max(usageTrack.height, usageTrack.width * Math.max(0, Math.min(100, usage.percent)) / 100)
      color: usage.fillColor
      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 220 } }
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property color swatch: "transparent"

    width: parent.width
    spacing: Style.space(8)

    Row {
      spacing: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      Rectangle {
        visible: parent.parent.swatch.a > 0
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(8); height: width; radius: width / 2
        color: parent.parent.swatch
      }
      InfoLabel { text: parent.parent.label }
    }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: parent.value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    opacity: 0.6
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
