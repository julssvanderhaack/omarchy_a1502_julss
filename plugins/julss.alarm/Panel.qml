// Alarmas, cronómetro y temporizador en la barra. Todo vive aquí (sin
// servicios aparte): un Timer de 1 s comprueba alarmas y temporizador, el
// estado se guarda en ~/.local/state/julss/alarm.json y sobrevive a reinicios
// de la shell. Al saltar: sonido en bucle (pw-play) + notificación crítica
// (clic en ella = detener) + icono rojo en la barra (clic = detener).

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "julss.alarm"
  ipcTarget: "julss.alarm"
  manageIpc: false

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/julss"
  readonly property string stateFile: stateDir + "/alarm.json"
  readonly property string iconFile: String(Qt.resolvedUrl("assets/alarm.png")).replace("file://", "")
  readonly property string soundFile: "/usr/share/sounds/freedesktop/stereo/alarm-clock-elapsed.oga"
  // Una alarma perdida (portátil suspendido) aún suena si han pasado menos.
  readonly property int graceMs: 15 * 60 * 1000
  readonly property int snoozeMinutes: 5
  // Si nadie la para, deja de sonar sola (la notificación se queda).
  readonly property int ringLimitMs: 5 * 60 * 1000

  readonly property var locale: Qt.locale("es_ES")
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property color ringColor: "#EF5350"

  // ---------------------------------------------------------------- estado
  property var alarms: []            // [{id, h, m, label, days:[0-6], enabled}]
  property var snooze: null          // {at, label} o null
  property var timer: ({ total: 0, endAt: 0, remaining: 0, running: false })
  property var stopwatch: ({ startedAt: 0, accumulated: 0, running: false, laps: [] })
  property bool loaded: false

  property double now: Date.now()
  property double lastTick: Date.now()

  // Lo que está sonando: {kind: "alarm"|"timer", title, body, startedAt} o null.
  property var ringing: null

  property string tab: "alarms"

  // Formulario de alarma (nueva o edición).
  property string editingId: ""
  property int formH: 7
  property int formM: 30
  property var formDays: []

  // ---------------------------------------------------------------- derivados
  readonly property double timerRemaining: timer.running ? Math.max(0, timer.endAt - now) : timer.remaining
  readonly property bool timerActive: timer.running || timer.remaining > 0
  readonly property double stopwatchElapsed: stopwatch.running ? stopwatch.accumulated + (now - stopwatch.startedAt) : stopwatch.accumulated
  readonly property bool stopwatchActive: stopwatch.running || stopwatch.accumulated > 0

  readonly property var nextAlarm: {
    var best = null
    for (var i = 0; i < alarms.length; i++) {
      var t = Model.nextFire(alarms[i], now)
      if (t >= 0 && (!best || t < best.at)) best = { at: t, alarm: alarms[i] }
    }
    if (snooze && snooze.at > now && (!best || snooze.at < best.at)) best = { at: snooze.at, alarm: { label: snooze.label } }
    return best
  }

  readonly property string heroStatus: {
    if (ringing) return "¡Sonando!"
    if (timer.running) return "Temporizador en marcha"
    if (stopwatch.running) return "Cronometrando"
    if (nextAlarm) return "Próxima " + Model.inText(nextAlarm.at, now)
    return "Sin alarmas activas"
  }

  readonly property string heroBig: {
    if (timer.running || timer.remaining > 0) return Model.barText(timerRemaining)
    if (nextAlarm) { var d = new Date(nextAlarm.at); return Model.clockText(d.getHours(), d.getMinutes()) }
    return "--:--"
  }

  // Texto de la barra junto al icono: temporizador > cronómetro > nada.
  readonly property string barLabel: {
    if (ringing) return ""
    if (timerActive) return Model.barText(timerRemaining)
    if (stopwatch.running) return Model.barText(stopwatchElapsed)
    return ""
  }

  readonly property string barIcon: {
    if (ringing) return "󰀠"
    if (timerActive) return "󱎫"
    if (stopwatch.running) return "󰔛"
    return nextAlarm ? "󰀠" : "󰀣"
  }

  // ---------------------------------------------------------------- persistencia
  function save() {
    if (!loaded) return
    stateView.setText(JSON.stringify({
      alarms: alarms, snooze: snooze, timer: timer, stopwatch: stopwatch,
      ringing: ringing ? { title: ringing.title } : null
    }, null, 2) + "\n")
  }

  function load(text) {
    try {
      var s = JSON.parse(String(text || "{}"))
      alarms = Array.isArray(s.alarms) ? s.alarms : []
      snooze = s.snooze && s.snooze.at > Date.now() ? s.snooze : null
      if (s.timer) timer = s.timer
      if (s.stopwatch) stopwatch = s.stopwatch
    } catch (e) {
      console.warn("julss.alarm: estado ilegible", e)
    }
    loaded = true
    // Un temporizador que terminó con la shell apagada: suena ya.
    if (timer.running && timer.endAt <= Date.now()) finishTimer()
  }

  FileView {
    id: stateView
    path: root.stateFile
    atomicWrites: true
    printErrors: false
    onLoaded: root.load(text())
    onLoadFailed: root.load("{}")
  }

  Component.onCompleted: Quickshell.execDetached(["mkdir", "-p", root.stateDir])

  // ---------------------------------------------------------------- reloj interno
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.tick()
  }

  // Décimas del cronómetro solo cuando se ven.
  Timer {
    interval: 100
    running: root.opened && root.tab === "stopwatch" && root.stopwatch.running
    repeat: true
    onTriggered: root.now = Date.now()
  }

  function tick() {
    var t = Date.now()
    now = t
    if (!loaded) { lastTick = t; return }
    for (var i = 0; i < alarms.length; i++) {
      var a = alarms[i]
      if (Model.dueBetween(a, lastTick, t, graceMs)) {
        ring("alarm", a.label || "Alarma", Model.clockText(a.h, a.m) + (a.days && a.days.length ? " · " + Model.daysText(a.days) : ""))
        // Las de "una vez" se apagan solas tras sonar.
        if (!a.days || a.days.length === 0) setAlarm(a.id, { enabled: false })
      }
    }
    if (snooze && snooze.at > lastTick && snooze.at <= t) {
      var label = snooze.label
      snooze = null
      save()
      ring("alarm", label || "Alarma", "Fin de la siesta de " + snoozeMinutes + " min")
    }
    if (timer.running && timer.endAt <= t) finishTimer()
    if (ringing && t - ringing.startedAt > ringLimitMs) stopRinging()
    lastTick = t
  }

  // ---------------------------------------------------------------- sonar
  function ring(kind, title, body) {
    ringing = { kind: kind, title: title, body: body, startedAt: Date.now() }
    save()
    soundProc.running = false
    soundProc.running = true
    notifyProc.command = ["notify-send", "-u", "critical", "-a", "Alarmas", "-i", root.iconFile,
                          "--action=default=Detener", "󰀠  " + title, body + "\nClic para detener"]
    notifyProc.running = false
    notifyProc.running = true
  }

  function stopRinging() {
    soundProc.running = false
    notifyProc.running = false
    ringing = null
    save()
  }

  function snoozeRinging() {
    if (!ringing) return
    snooze = { at: Date.now() + snoozeMinutes * 60000, label: ringing.title }
    stopRinging()
    save()
  }

  Process {
    id: soundProc
    // Bucle hasta que se pare; al matar bash se lleva el pw-play en curso.
    command: ["bash", "-c", "trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM INT; " +
              "while :; do pw-play '" + root.soundFile + "' & wait $!; sleep 0.4; done"]
  }

  Process {
    id: notifyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() === "default") root.stopRinging()
    }
  }

  // ---------------------------------------------------------------- alarmas
  function setAlarm(id, changes) {
    var next = []
    for (var i = 0; i < alarms.length; i++) {
      var a = alarms[i]
      if (a.id === id) {
        var c = {}
        for (var k in a) c[k] = a[k]
        for (var k2 in changes) c[k2] = changes[k2]
        a = c
      }
      next.push(a)
    }
    alarms = next
    save()
  }

  function deleteAlarm(id) {
    alarms = alarms.filter(function(a) { return a.id !== id })
    if (editingId === id) resetForm()
    save()
  }

  function sortAlarms(list) {
    return list.slice().sort(function(a, b) { return (a.h * 60 + a.m) - (b.h * 60 + b.m) })
  }

  function resetForm() {
    editingId = ""
    var d = new Date(now + 60 * 60000)
    formH = d.getHours()
    formM = Math.floor(d.getMinutes() / 5) * 5
    formDays = []
    nameField.text = ""
  }

  function editAlarm(a) {
    editingId = a.id
    formH = a.h
    formM = a.m
    formDays = (a.days || []).slice()
    nameField.text = a.label || ""
  }

  function submitForm() {
    var data = { h: formH, m: formM, label: String(nameField.text || "").trim(), days: formDays.slice(), enabled: true }
    if (editingId !== "") setAlarm(editingId, data)
    else {
      data.id = Model.newId()
      alarms = sortAlarms(alarms.concat([data]))
      save()
    }
    resetForm()
  }

  function toggleFormDay(day) {
    var d = formDays.slice()
    var i = d.indexOf(day)
    if (i >= 0) d.splice(i, 1)
    else d.push(day)
    formDays = d
  }

  // ---------------------------------------------------------------- temporizador
  property int timerSetH: 0
  property int timerSetM: 5
  property int timerSetS: 0

  function startTimer(ms) {
    if (ms <= 0) return
    timer = { total: ms, endAt: Date.now() + ms, remaining: ms, running: true }
    save()
  }

  function pauseTimer() {
    if (!timer.running) return
    timer = { total: timer.total, endAt: 0, remaining: Math.max(0, timer.endAt - Date.now()), running: false }
    save()
  }

  function resumeTimer() {
    if (timer.running || timer.remaining <= 0) return
    timer = { total: timer.total, endAt: Date.now() + timer.remaining, remaining: timer.remaining, running: true }
    save()
  }

  function addToTimer(ms) {
    if (timer.running) timer = { total: timer.total + ms, endAt: timer.endAt + ms, remaining: timer.remaining, running: true }
    else if (timer.remaining > 0) timer = { total: timer.total + ms, endAt: 0, remaining: timer.remaining + ms, running: false }
    save()
  }

  function cancelTimer() {
    timer = { total: 0, endAt: 0, remaining: 0, running: false }
    save()
  }

  function finishTimer() {
    var total = timer.total
    timer = { total: 0, endAt: 0, remaining: 0, running: false }
    save()
    ring("timer", "Temporizador terminado", Model.durationText(total, false) + " cumplidos")
  }

  // ---------------------------------------------------------------- cronómetro
  function startStopwatch() {
    stopwatch = { startedAt: Date.now(), accumulated: stopwatch.accumulated, running: true, laps: stopwatch.laps || [] }
    save()
  }

  function pauseStopwatch() {
    stopwatch = { startedAt: 0, accumulated: stopwatchElapsed, running: false, laps: stopwatch.laps || [] }
    save()
  }

  function lapStopwatch() {
    var laps = (stopwatch.laps || []).slice()
    laps.unshift(stopwatchElapsed)
    stopwatch = { startedAt: stopwatch.startedAt, accumulated: stopwatch.accumulated, running: stopwatch.running, laps: laps }
    save()
  }

  function resetStopwatch() {
    stopwatch = { startedAt: 0, accumulated: 0, running: false, laps: [] }
    save()
  }

  // ---------------------------------------------------------------- IPC
  IpcHandler {
    target: "julss.alarm"

    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
    // omarchy-shell julss.alarm timer 300  → temporizador de 5 min
    function timer(seconds: string): void { root.startTimer(Number(seconds) * 1000) }
    function stop(): void { root.stopRinging() }
    function cancel(): void { root.cancelTimer() }
    function test(): void { root.ring("alarm", "Prueba", "Así suena una alarma") }
  }

  onOpenedChanged: if (opened) { now = Date.now(); if (editingId === "" && nameField.text === "") resetForm() }

  // ---------------------------------------------------------------- barra
  // El icono lo pinta el indicador "Alarm" de julss.indicators (oculto entre
  // los iconos del centro salvo si hay algo activo, como la cafeína). Este
  // widget no ocupa sitio: solo aporta la lógica y el panel.
  implicitWidth: 0
  implicitHeight: 0

  WidgetButton {
    id: button
    visible: false
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: barRow.implicitWidth + Style.space(10)
    tooltipText: root.ringing ? "Clic para detener" : (root.nextAlarm ? "Próxima alarma " + Model.whenText(root.nextAlarm.at, root.now, root.locale) : "Alarmas")

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(4)

      Text {
        id: barGlyph
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.barIcon
        color: root.ringing ? root.ringColor : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body

        SequentialAnimation on opacity {
          running: !!root.ringing
          loops: Animation.Infinite
          alwaysRunToEnd: true
          NumberAnimation { from: 1; to: 0.25; duration: 450 }
          NumberAnimation { from: 0.25; to: 1; duration: 450 }
        }
      }

      Text {
        visible: root.barLabel !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.barLabel
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    onPressed: function(mouseButton) {
      if (root.ringing) {
        if (mouseButton === Qt.RightButton) root.snoozeRinging()
        else root.stopRinging()
        return
      }
      root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: true
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nameField.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        if (dx === 0) return
        var tabs = ["alarms", "stopwatch", "timer"]
        var i = (tabs.indexOf(root.tab) + dx + tabs.length) % tabs.length
        root.tab = tabs[i]
      }
      onActivateRequested: if (root.ringing) root.stopRinging()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroBigText.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.barIcon
            color: root.ringing ? root.ringColor : root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroBigText.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Alarmas"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.heroStatus.toUpperCase()
              color: root.ringing ? root.ringColor : Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          Text {
            id: heroBigText
            textFormat: Text.PlainText
            text: root.heroBig
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        // ---------- Sonando ----------
        Rectangle {
          visible: !!root.ringing
          width: parent.width
          implicitHeight: ringColumn.implicitHeight + Style.space(24)
          radius: Style.cornerRadius
          color: Qt.rgba(0.94, 0.33, 0.31, 0.12)
          border.width: 1
          border.color: Qt.rgba(0.94, 0.33, 0.31, 0.55)

          Column {
            id: ringColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            spacing: Style.space(10)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.ringing ? root.ringing.title : ""
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.ringing ? root.ringing.body : ""
              color: Qt.darker(root.fg, 1.3)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(10)

              Button {
                iconText: "󰓛"
                text: "Detener"
                foreground: root.ringColor
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.stopRinging()
              }

              Button {
                iconText: "󰒲"
                text: "Posponer " + root.snoozeMinutes + " min"
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.snoozeRinging()
              }
            }
          }
        }

        // ---------- Pestañas ----------
        ButtonGroup {
          width: parent.width
          options: [
            { value: "alarms", label: "Alarmas", icon: "󰀠" },
            { value: "stopwatch", label: "Cronómetro", icon: "󰔛" },
            { value: "timer", label: "Temporizador", icon: "󱎫" }
          ]
          value: root.tab
          foreground: root.fg
          fontFamily: root.fontFamily
          fontSize: Style.font.bodySmall
          focusable: false
          onChanged: function(v) { root.tab = v }
        }

        // ================= ALARMAS =================
        Column {
          visible: root.tab === "alarms"
          width: parent.width
          spacing: Style.space(10)

          Text {
            visible: root.alarms.length === 0
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: "No hay alarmas. Crea una abajo."
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.alarms

            AlarmRow {
              required property var modelData
              alarm: modelData
              width: parent.width
            }
          }

          PanelSeparator { foreground: root.fg }

          PanelSectionHeader {
            text: root.editingId !== "" ? "EDITAR ALARMA" : "NUEVA ALARMA"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)

            Spinner { value: root.formH; to: 23; onStep: function(v) { root.formH = v } }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: ":"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              font.bold: true
            }

            Spinner { value: root.formM; to: 59; onStep: function(v) { root.formM = v } }
          }

          // Días: L M X J V S D (ninguno = una sola vez).
          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(4)

            Repeater {
              model: Model.DAY_ORDER

              Button {
                required property var modelData
                width: Style.space(38)
                text: Model.DAY_LETTER[modelData]
                fontSize: Style.font.bodySmall
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                active: root.formDays.indexOf(modelData) >= 0
                onClicked: root.toggleFormDay(modelData)
              }
            }
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: Model.daysText(root.formDays)
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: nameField
            width: parent.width
            placeholderText: "Nombre (opcional)"
            foreground: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onAccepted: root.submitForm()
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              width: root.editingId !== "" ? (parent.width - parent.spacing) / 2 : parent.width
              iconText: root.editingId !== "" ? "󰄬" : "󰀤"
              text: root.editingId !== "" ? "Guardar" : "Añadir alarma"
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.submitForm()
            }

            Button {
              visible: root.editingId !== ""
              width: (parent.width - parent.spacing) / 2
              iconText: "󰜺"
              text: "Cancelar"
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.resetForm()
            }
          }
        }

        // ================= CRONÓMETRO =================
        Column {
          visible: root.tab === "stopwatch"
          width: parent.width
          spacing: Style.space(12)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: Model.durationText(root.stopwatchElapsed, true)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge * 1.4
            font.bold: true
          }

          Row {
            width: parent.width
            spacing: Style.space(8)
            readonly property real cell: (width - spacing * 2) / 3

            Button {
              width: parent.cell
              iconText: root.stopwatch.running ? "󰏤" : "󰐊"
              text: root.stopwatch.running ? "Pausar" : (root.stopwatchActive ? "Seguir" : "Iniciar")
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              active: root.stopwatch.running
              onClicked: root.stopwatch.running ? root.pauseStopwatch() : root.startStopwatch()
            }

            Button {
              width: parent.cell
              iconText: "󰐕"
              text: "Vuelta"
              enabled: root.stopwatch.running
              opacity: enabled ? 1 : 0.45
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.lapStopwatch()
            }

            Button {
              width: parent.cell
              iconText: "󰑓"
              text: "Reiniciar"
              enabled: root.stopwatchActive
              opacity: enabled ? 1 : 0.45
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.resetStopwatch()
            }
          }

          Column {
            visible: (root.stopwatch.laps || []).length > 0
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "VUELTAS"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            Repeater {
              model: (root.stopwatch.laps || []).slice(0, 8)

              Item {
                required property var modelData
                required property int index
                readonly property var laps: root.stopwatch.laps || []
                readonly property int number: laps.length - index
                readonly property double split: modelData - (index + 1 < laps.length ? laps[index + 1] : 0)
                width: parent.width
                implicitHeight: lapLabel.implicitHeight

                InfoText { id: lapLabel; text: "Vuelta " + parent.number; opacity: 0.6 }
                InfoText {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "+" + Model.durationText(parent.split, true)
                }
                InfoText { anchors.right: parent.right; text: Model.durationText(modelData, true) }
              }
            }
          }
        }

        // ================= TEMPORIZADOR =================
        Column {
          visible: root.tab === "timer"
          width: parent.width
          spacing: Style.space(12)

          // En marcha o en pausa: cuenta atrás grande + barra.
          Column {
            visible: root.timerActive
            width: parent.width
            spacing: Style.space(10)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: Model.barText(root.timerRemaining)
              color: root.timer.running ? root.fg : Qt.darker(root.fg, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge * 1.4
              font.bold: true
            }

            Item {
              width: parent.width
              implicitHeight: Style.space(8)

              Rectangle {
                id: timerTrack
                anchors.fill: parent
                radius: height / 2
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
              }

              Rectangle {
                height: timerTrack.height
                radius: timerTrack.radius
                width: root.timer.total > 0 ? Math.max(height, timerTrack.width * root.timerRemaining / root.timer.total) : 0
                color: Color.accent
                Behavior on width { NumberAnimation { duration: 900 } }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              readonly property real cell: (width - spacing * 2) / 3

              Button {
                width: parent.cell
                iconText: root.timer.running ? "󰏤" : "󰐊"
                text: root.timer.running ? "Pausar" : "Seguir"
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.timer.running ? root.pauseTimer() : root.resumeTimer()
              }

              Button {
                width: parent.cell
                iconText: "󰐕"
                text: "1 min"
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.addToTimer(60000)
              }

              Button {
                width: parent.cell
                iconText: "󰜺"
                text: "Cancelar"
                foreground: root.fg
                fontFamily: root.fontFamily
                bordered: true
                onClicked: root.cancelTimer()
              }
            }
          }

          // Parado: elegir duración.
          Column {
            visible: !root.timerActive
            width: parent.width
            spacing: Style.space(12)

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)

              Spinner { value: root.timerSetH; to: 23; caption: "h"; onStep: function(v) { root.timerSetH = v } }
              Text { anchors.verticalCenter: parent.verticalCenter; text: ":"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.displayLarge; font.bold: true }
              Spinner { value: root.timerSetM; to: 59; caption: "min"; onStep: function(v) { root.timerSetM = v } }
              Text { anchors.verticalCenter: parent.verticalCenter; text: ":"; color: root.fg; font.family: root.fontFamily; font.pixelSize: Style.font.displayLarge; font.bold: true }
              Spinner { value: root.timerSetS; to: 59; caption: "s"; onStep: function(v) { root.timerSetS = v } }
            }

            // Atajos de un clic.
            Grid {
              id: presetGrid
              width: parent.width
              columns: 4
              spacing: Style.space(6)
              readonly property real cell: (width - spacing * 3) / 4

              Repeater {
                model: [1, 3, 5, 10, 15, 25, 30, 60]

                Button {
                  required property var modelData
                  width: presetGrid.cell
                  text: modelData < 60 ? modelData + " min" : "1 h"
                  fontSize: Style.font.bodySmall
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.startTimer(modelData * 60000)
                }
              }
            }

            Button {
              width: parent.width
              iconText: "󰐊"
              text: "Iniciar " + Model.durationText((root.timerSetH * 3600 + root.timerSetM * 60 + root.timerSetS) * 1000, false)
              enabled: root.timerSetH + root.timerSetM + root.timerSetS > 0
              opacity: enabled ? 1 : 0.45
              foreground: root.fg
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.startTimer((root.timerSetH * 3600 + root.timerSetM * 60 + root.timerSetS) * 1000)
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- componentes

  // Fila de una alarma: hora grande, nombre y días, interruptor, borrar.
  component AlarmRow: Rectangle {
    id: alarmRow
    property var alarm: ({})
    readonly property bool on: !!alarm.enabled
    readonly property bool editing: root.editingId === alarm.id

    implicitHeight: Style.space(54)
    radius: Style.cornerRadius
    color: editing ? Style.selectedFillFor(root.fg, Color.accent)
      : (rowMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent")

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.editAlarm(alarmRow.alarm)
    }

    Text {
      id: alarmTime
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: Model.clockText(alarmRow.alarm.h, alarmRow.alarm.m)
      color: root.fg
      opacity: alarmRow.on ? 1 : 0.4
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
      font.bold: true
    }

    Column {
      anchors.left: alarmTime.right
      anchors.leftMargin: Style.space(14)
      anchors.right: alarmSwitch.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      opacity: alarmRow.on ? 1 : 0.4
      spacing: Style.space(2)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: alarmRow.alarm.label || "Alarma"
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: Model.daysText(alarmRow.alarm.days)
          + (alarmRow.on ? " · " + Model.inText(Model.nextFire(alarmRow.alarm, root.now), root.now) : "")
        color: Qt.darker(root.fg, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    ToggleSwitch {
      id: alarmSwitch
      anchors.right: deleteButton.left
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      checked: alarmRow.on
      cursorRing: false
      foreground: root.fg
      onToggled: root.setAlarm(alarmRow.alarm.id, { enabled: !alarmRow.on })
    }

    PanelActionButton {
      id: deleteButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰆴"
      tooltipText: "Borrar"
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: root.deleteAlarm(alarmRow.alarm.id)
    }
  }

  // Selector numérico grande: flecha arriba, número, flecha abajo; rueda.
  component Spinner: Column {
    id: spinner
    property int value: 0
    property int to: 59
    property string caption: ""
    signal step(int value)

    function bump(d) { spinner.step((spinner.value + d + spinner.to + 1) % (spinner.to + 1)) }

    spacing: 0

    PanelActionButton {
      anchors.horizontalCenter: parent.horizontalCenter
      iconText: "󰅃"
      tooltipText: ""
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: spinner.bump(1)
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      textFormat: Text.PlainText
      text: Model.pad2(spinner.value)
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.displayLarge
      font.bold: true

      WheelHandler {
        onWheel: function(event) { if (event.angleDelta.y !== 0) spinner.bump(event.angleDelta.y > 0 ? 1 : -1) }
      }
    }

    Text {
      visible: spinner.caption !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      text: spinner.caption
      color: Qt.darker(root.fg, 1.6)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    PanelActionButton {
      anchors.horizontalCenter: parent.horizontalCenter
      iconText: "󰅀"
      tooltipText: ""
      foreground: root.fg
      fontFamily: root.fontFamily
      onClicked: spinner.bump(-1)
    }
  }

  component InfoText: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }
}
