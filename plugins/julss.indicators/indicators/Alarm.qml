import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// julss: alarmas (plugin julss.alarm). Visible solo si hay alguna alarma
// activa, un temporizador o cronómetro en marcha o algo sonando; si no,
// queda entre los iconos ocultos. Lee el estado que guarda julss.alarm en
// ~/.local/state/julss/alarm.json (vigilado, sin sondear).
BarIndicator {
  id: root

  property var state: ({})
  property double now: Date.now()

  readonly property var timer: state.timer || {}
  readonly property var stopwatch: state.stopwatch || {}
  readonly property bool ringing: !!state.ringing
  readonly property bool timerActive: timer.running === true || (timer.remaining || 0) > 0
  readonly property bool hasAlarms: {
    var list = state.alarms || []
    for (var i = 0; i < list.length; i++) if (list[i].enabled) return true
    return !!state.snooze
  }

  function pad2(n) { return n < 10 ? "0" + n : String(n) }
  function short(ms) {
    var t = Math.max(0, Math.ceil(ms / 1000))
    var h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60
    return h > 0 ? h + ":" + pad2(m) + ":" + pad2(s) : m + ":" + pad2(s)
  }

  readonly property string timeText: {
    if (timerActive) return short(timer.running ? timer.endAt - now : timer.remaining)
    if (stopwatch.running) return short((stopwatch.accumulated || 0) + now - stopwatch.startedAt)
    return ""
  }

  active: ringing || timerActive || stopwatch.running === true || hasAlarms
  activeText: (ringing ? "󰀠" : timerActive ? "󱎫" : stopwatch.running ? "󰔛" : "󰀠")
    + (timeText !== "" && !ringing ? " " + timeText : "")
  inactiveText: "󰀠"
  // Con tiempo a la vista, el hueco se ajusta al texto (los demás indicadores
  // son de un solo icono y tienen ancho fijo).
  fixedWidth: vertical ? -1 : (effectiveActive && timeText !== "" && !ringing ? -1 : Style.bar.statusSlot)
  activeTooltipText: ringing ? "Sonando: clic para detener" : "Alarmas"
  inactiveTooltipText: "Alarmas, cronómetro y temporizador"

  FileView {
    path: Quickshell.env("HOME") + "/.local/state/julss/alarm.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.state = JSON.parse(text()) } catch (e) { root.state = ({}) }
    }
  }

  // Solo hace falta reloj propio para la cuenta atrás / cronómetro visibles.
  Timer {
    interval: 1000
    repeat: true
    running: (root.timer.running === true) || (root.stopwatch.running === true)
    onTriggered: root.now = Date.now()
  }

  onPressed: function() {
    Quickshell.execDetached(["omarchy-shell", "julss.alarm", root.ringing ? "stop" : "toggle"])
  }
}
