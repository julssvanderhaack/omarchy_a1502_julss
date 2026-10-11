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

  // El tooltip de la barra es texto plano centrado en la fuente monoespaciada
  // de la barra: se maquetan columnas con espacios y todas las líneas se
  // rellenan al mismo ancho para que queden alineadas a la izquierda.
  function padEnd(text, width) {
    text = String(text)
    while (text.length < width) text += " "
    return text
  }

  function padStart(text, width) {
    text = String(text)
    while (text.length < width) text = " " + text
    return text
  }

  // Tabla con líneas de caja (SF Mono las tiene, así que todo cuadra al
  // carácter): filas [concepto, valor, %] en secciones separadas por ├─┼─┤.
  // Concepto y valor van alineados a la izquierda; el % a la derecha.
  function table(sections, footer) {
    var w = [0, 0, 0]
    for (var i = 0; i < sections.length; i++)
      for (var j = 0; j < sections[i].length; j++)
        for (var c = 0; c < 3; c++) w[c] = Math.max(w[c], sections[i][j][c].length)
    var bar = function(n) { var t = ""; for (var k = 0; k < n + 2; k++) t += "─"; return t }
    var rule = function(l, m, r) { return l + bar(w[0]) + m + bar(w[1]) + m + bar(w[2]) + r }
    var out = [rule("┌", "┬", "┐")]
    for (var a = 0; a < sections.length; a++) {
      if (a > 0) out.push(rule("├", "┼", "┤"))
      for (var b = 0; b < sections[a].length; b++) {
        var row = sections[a][b]
        out.push("│ " + root.padEnd(row[0], w[0]) + " │ " + root.padEnd(row[1], w[1]) + " │ " + root.padStart(row[2], w[2]) + " │")
      }
    }
    out.push(rule("└", "┴", "┘"))
    out.push(root.padEnd(" " + footer, out[0].length))
    return out.join("\n")
  }

  readonly property string tooltip: {
    if (root.ramTotalGiB <= 0) return "Monitor"
    var pct = function(n) { return n < 0 ? "-- %" : n + " %" }
    var gb = function(kib) { return root.gib(kib) + " GiB" }

    var cpu = [["CPU", root.cpuTempC >= 0 ? root.cpuTempC + " °C" : "", pct(root.cpuPercent)]]
    for (var i = 0; i < root.corePercents.length; i++)
      cpu.push(["  cpu" + i, "", pct(root.corePercents[i])])

    var v = root.mem
    var mem = [
      ["Memoria", gb((v.MemTotal || 0) - (v.MemAvailable || 0)) + " / " + root.gib(v.MemTotal) + " GiB", root.ramPercent + " %"],
      ["  Caché", gb((v.Cached || 0) + (v.Buffers || 0) + (v.SReclaimable || 0)), ""],
      ["  Libre", gb(v.MemFree), ""],
      ["  Disponible", gb(v.MemAvailable), ""]
    ]
    if ((v.SwapTotal || 0) > 0)
      mem.push(["Paginada", gb(v.SwapTotal - v.SwapFree) + " / " + root.gib(v.SwapTotal) + " GiB",
        Math.round(100 * (v.SwapTotal - v.SwapFree) / v.SwapTotal) + " %"])

    var other = []
    if (root.fanRpm >= 0)
      other.push(["Ventilador", root.fanRpm + " rpm",
        root.fanMaxRpm > 0 ? Math.round(100 * root.fanRpm / root.fanMaxRpm) + " %" : ""])
    if (root.diskTotalGiB > 0)
      other.push(["Disco", Math.round(root.diskUsedGiB) + " / " + Math.round(root.diskTotalGiB) + " GiB",
        Math.round(100 * root.diskUsedGiB / root.diskTotalGiB) + " %"])

    var sections = [cpu, mem]
    if (other.length) sections.push(other)
    return root.table(sections, "Clic: btop")
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
    interval: 3000
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: row.implicitWidth + Style.space(10)
    tooltipText: root.tooltip

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
