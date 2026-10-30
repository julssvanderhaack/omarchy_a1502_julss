import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The clock's calendar popup: a month grid with ISO week numbers, built to
// sit beside the weather panel — same hero-over-detail composition, same
// spacing scale, same small-caps labels.
//
// The grid is a read-out rather than a picker: today is the only marked
// day, and the only thing that moves is which month is on screen —
// chevrons, the scroll wheel, and the arrow keys all step it.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "omarchy.clock"
  ipcTarget: "omarchy.clock"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel. Everything the bar identifies a panel by has to be that
  // widget: the popout coordinator (and with it the open-panel dot under the
  // pill) compares against `slot.activeItem`, and switchPanelFrom looks the
  // slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Today. SystemClock keeps this honest across midnight so the
  //      highlight rolls over without the panel being reopened.
  property date today: new Date()
  readonly property string todayKey: Model.keyForDate(today)

  // The month on screen. Stepping moves this and nothing else: the grid is
  // a read-out, not a picker, so there is no per-day cursor to keep in sync.
  property int viewYear: today.getFullYear()
  property int viewMonth: today.getMonth()

  readonly property date viewDate: new Date(viewYear, viewMonth, 1)
  readonly property bool viewingCurrentMonth: viewYear === today.getFullYear() && viewMonth === today.getMonth()

  // Pinned to today, not to the month being browsed — stepping through the
  // calendar does not change how much of the year is gone.
  readonly property real yearDone: Model.yearProgress(today.getFullYear(), today.getMonth(), today.getDate())
  readonly property int yearDonePercent: Model.yearProgressPercent(today.getFullYear(), today.getMonth(), today.getDate())

  // Memento mori, for anyone who goes looking: double-tapping the year bar
  // asks for a birth year and a life expectancy, and a second bar tracks one
  // against the other. A birth year rather than an age, so it keeps counting
  // on its own. Without one the bar stays hidden.
  readonly property int birthYear: Model.parseBirthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int age: Model.ageFromBirthYear(birthYear, today.getFullYear())
  readonly property int lifeExpectancy: Model.parseLifeExpectancy(setting("lifeExpectancy", 0))
  readonly property real lifeDone: Model.lifeProgress(age, lifeExpectancy)

  // ---- julss: embarazo. Fecha probable de parto (FPP); la semana se cuenta
  //      desde la última regla = FPP − 280 días, como en las ecografías
  //      ("18+2" = 18 semanas cumplidas y 2 días).
  readonly property var babyDue: new Date(2027, 2, 16)
  readonly property var babyStart: new Date(babyDue.getFullYear(), babyDue.getMonth(), babyDue.getDate() - 280)
  function babyDaysOn(y, m, d) {
    return Math.round((new Date(y, m, d) - root.babyStart) / 86400000)
  }
  readonly property int babyDays: babyDaysOn(today.getFullYear(), today.getMonth(), today.getDate())
  // Se muestra desde el inicio hasta dos semanas después de la FPP.
  readonly property bool babyActive: babyDays >= 0 && babyDays <= 294
  readonly property real babyDone: Math.max(0, Math.min(1, babyDays / 280))
  readonly property string babyLabel: Math.floor(babyDays / 7) + "+" + (babyDays % 7)
  readonly property int babyDaysLeft: 280 - babyDays
  function babyWeekForRow(row) {
    // Semana de embarazo del último día de la fila (domingo). La última regla
    // cae en martes, así que la semana cambia los martes y el domingo da la
    // semana de la mayoría de los días de la fila (martes a domingo).
    var last = row.days[row.days.length - 1]
    var n = babyDaysOn(last.year, last.month, last.day)
    if (n < 0 || n > 300) return ""
    return String(Math.max(0, Math.floor(n / 7)))
  }
  function isBabyDue(cell) {
    return cell.year === babyDue.getFullYear() && cell.month === babyDue.getMonth() && cell.day === babyDue.getDate()
  }
  readonly property int lifeDonePercent: Model.lifeProgressPercent(age, lifeExpectancy)
  property bool editingLife: false

  // ---- julss: agenda. Los datos los lleva ~/.local/bin/julss-agenda
  //      (caché local + cola offline + sincronización con Google Calendar);
  //      el panel solo lee su events.json y le pasa órdenes.
  readonly property string agendaBin: Quickshell.env("HOME") + "/.local/bin/julss-agenda"
  readonly property string agendaFile: Quickshell.env("HOME") + "/.local/state/julss-agenda/events.json"
  property var agenda: ({ events: [], google: {}, pending: 0 })
  property var eventsByDay: ({})
  property string selectedKey: todayKey
  readonly property var selectedDate: {
    var p = selectedKey.split("-")
    return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
  }
  readonly property var selectedEvents: eventsByDay[selectedKey] || []
  readonly property bool googleConfigured: !!(agenda.google && agenda.google.configured)
  readonly property bool googleConnected: !!(agenda.google && agenda.google.connected)
  property bool agendaBusy: false
  property string agendaMessage: ""
  property var agendaQueue: []

  property bool editingEvent: false
  property string editId: ""
  property bool editAllDay: false

  function loadAgenda(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return }
    var byDay = {}
    var list = data.events || []
    for (var i = 0; i < list.length; i++) {
      var days = list[i].days || []
      for (var j = 0; j < days.length; j++) {
        if (!byDay[days[j]]) byDay[days[j]] = []
        byDay[days[j]].push(list[i])
      }
    }
    root.eventsByDay = byDay
    root.agenda = data
  }

  function runAgenda(args) {
    root.agendaQueue = root.agendaQueue.concat([args])
    pumpAgenda()
  }

  function pumpAgenda() {
    if (agendaProc.running || root.agendaQueue.length === 0) return
    var next = root.agendaQueue[0]
    root.agendaQueue = root.agendaQueue.slice(1)
    root.agendaBusy = true
    agendaProc.command = [root.agendaBin].concat(next)
    agendaProc.running = true
  }

  function syncAgenda() {
    if (root.agendaQueue.length === 0 && !agendaProc.running) runAgenda(["sync"])
  }

  function selectDay(cell) {
    root.selectedKey = cell.key
    if (!cell.inMonth) { root.viewYear = cell.year; root.viewMonth = cell.month }
    if (root.editingEvent && root.editId === "")
      dateField.text = root.labelLocale.toString(new Date(cell.year, cell.month, cell.day), "d/M/yyyy")
  }

  function pad2(n) { return (n < 10 ? "0" : "") + n }

  // "9", "930", "9:30", "9.30", "09h30" → "09:30"; "" si no se entiende.
  function parseTime(text) {
    var t = String(text).trim().replace(/[.h]/g, ":")
    var m = t.match(/^(\d{1,2})(?::?(\d{2}))?$/)
    if (!m) return ""
    var h = Number(m[1]), mi = m[2] ? Number(m[2]) : 0
    if (h > 23 || mi > 59) return ""
    return pad2(h) + ":" + pad2(mi)
  }

  // "5/11", "5/11/2026", "5-11-26", "2026-11-05" → "2026-11-05"; "" si no vale.
  function parseDate(text) {
    var t = String(text).trim()
    var iso = t.match(/^(\d{4})-(\d{1,2})-(\d{1,2})$/)
    var y, mo, d
    if (iso) { y = Number(iso[1]); mo = Number(iso[2]); d = Number(iso[3]) }
    else {
      var m = t.match(/^(\d{1,2})[\/\-.](\d{1,2})(?:[\/\-.](\d{2,4}))?$/)
      if (!m) return ""
      d = Number(m[1]); mo = Number(m[2])
      y = m[3] ? Number(m[3]) : root.selectedDate.getFullYear()
      if (y < 100) y += 2000
    }
    var probe = new Date(y, mo - 1, d)
    if (probe.getMonth() !== mo - 1 || probe.getDate() !== d) return ""
    return y + "-" + pad2(mo) + "-" + pad2(d)
  }

  function startNewEvent() {
    root.editId = ""
    root.editAllDay = false
    root.editingEvent = true
    root.agendaMessage = ""
    Qt.callLater(function() {
      titleField.text = ""
      dateField.text = root.labelLocale.toString(root.selectedDate, "d/M/yyyy")
      startField.text = ""
      endField.text = ""
      placeField.text = ""
      titleField.forceActiveFocus()
    })
  }

  function startEditEvent(ev) {
    if (!ev.writable) return
    root.editId = ev.id
    root.editAllDay = !!ev.allDay
    root.editingEvent = true
    root.agendaMessage = ""
    var p = ev.start.substring(0, 10).split("-")
    Qt.callLater(function() {
      titleField.text = ev.title
      dateField.text = Number(p[2]) + "/" + Number(p[1]) + "/" + p[0]
      startField.text = ev.allDay ? "" : ev.start.substring(11, 16)
      endField.text = ev.allDay ? "" : ev.end.substring(11, 16)
      placeField.text = ev.location || ""
      titleField.forceActiveFocus()
      titleField.selectAll()
    })
  }

  function cancelEditEvent() {
    root.editingEvent = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveEvent() {
    var date = parseDate(dateField.text)
    if (date === "") { root.agendaMessage = "Fecha no válida (d/m/aaaa)"; return }
    var args = root.editId === "" ? ["add"] : ["update", root.editId]
    args.push("--title", titleField.text.trim() || "(sin título)", "--date", date, "--location", placeField.text.trim())
    if (root.editAllDay) {
      args.push("--all-day")
    } else {
      var st = parseTime(startField.text)
      if (st === "") { root.agendaMessage = "Hora de inicio no válida (HH:MM)"; return }
      args.push("--start", st)
      if (endField.text.trim() !== "") {
        var en = parseTime(endField.text)
        if (en === "") { root.agendaMessage = "Hora de fin no válida (HH:MM)"; return }
        args.push("--end", en)
      }
    }
    root.selectedKey = date
    var p = date.split("-")
    root.viewYear = Number(p[0]); root.viewMonth = Number(p[1]) - 1
    root.runAgenda(args)
    root.cancelEditEvent()
  }

  function deleteEvent(id) {
    root.runAgenda(["delete", id])
    if (root.editingEvent && root.editId === id) root.cancelEditEvent()
  }

  function handleEventKey(event, next) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditEvent()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.saveEvent()
      event.accepted = true
    } else if ((event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) && next) {
      next.selectAll()
      next.forceActiveFocus()
      event.accepted = true
    }
  }

  function syncTooltip() {
    if (!root.googleConfigured) return "Solo local: falta ~/.config/julss-agenda/client_secret.json"
    if (!root.googleConnected || String(root.agenda.error || "").indexOf("volver a conectar") >= 0)
      return "Conectar con Google Calendar"
    var t = "Sincronizar con Google"
    if (root.agenda.lastSync)
      t += " · última " + root.labelLocale.toString(new Date(root.agenda.lastSync), "HH:mm")
    if (root.agenda.pending > 0) t += " · " + root.agenda.pending + " sin subir"
    return t
  }

  FileView {
    id: agendaView
    path: root.agendaFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadAgenda(text())
  }

  Process {
    id: agendaProc
    stderr: StdioCollector {
      id: agendaErr
      waitForEnd: true
    }
    onExited: function(code) {
      root.agendaBusy = false
      var err = agendaErr.text.trim()
      if (code !== 0 && err !== "") root.agendaMessage = err.split("\n").pop()
      agendaView.reload()
      root.pumpAgenda()
    }
  }

  // Recordatorios cada minuto; la sincronización periódica (cada 5 min) la
  // decide el propio tick. Con varios monitores hay un panel por barra: el
  // script lleva un lock, así que no se pisan.
  Process { id: tickProc }
  Timer {
    interval: 60000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (!tickProc.running) {
        tickProc.command = [root.agendaBin, "tick"]
        tickProc.running = true
      }
    }
  }

  // Unset falls through to the locale's own first day, so a fresh install
  // starts out matching the rest of the desktop rather than a hardcoded
  // convention. Clicking the grid's "W" heading writes the choice back to
  // shell.json.
  readonly property int weekStart: Model.normalizedWeekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  // The interface is English throughout, so day names are not taken from the
  // system locale. Where the week starts still is: that is a regional
  // convention rather than a translation, and it stays overridable above.
  readonly property var labelLocale: Qt.locale("es_ES")
  readonly property string nextWeekStartLabel: labelLocale.dayName(Model.toggledWeekStart(weekStart), Locale.LongFormat)
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(viewYear, viewMonth, weekStart, todayKey)


  // Guarded so the widget renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellSpacing: Style.space(2)
  readonly property int weekColumnWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  function open() {
    refresh()
    root.controller.show()
    // Set after showing, not before: showing hands the popout coordinator
    // over, which closes whichever panel was open, and that close clears the
    // shared flag. Deferring means the panel taking over always wins, while
    // a handoff to a panel that does not manage the flag still leaves it
    // cleared rather than stuck on.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    // Dismissing the panel mid-edit would otherwise leave the inputs up,
    // waiting behind a closed popup for the next time it opens.
    if (root.editingLife) root.cancelEditingLife()
    if (root.editingEvent) root.cancelEditEvent()
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function refresh() {
    root.today = new Date()
    root.goToToday()
    root.selectedKey = Model.keyForDate(root.today)
    root.syncAgenda()
  }

  function goToToday() {
    root.viewYear = today.getFullYear()
    root.viewMonth = today.getMonth()
    root.selectedKey = Model.keyForDate(today)
  }

  function moveMonth(delta) {
    var next = Model.stepMonth(viewYear, viewMonth, delta)
    root.viewYear = next.year
    root.viewMonth = next.month
  }

  function moveYear(delta) {
    moveMonth(delta * 12)
  }

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing. The host widget builds its own
  // entry when the label format is cycled, so it has to be kept in step or
  // it would write this key straight back out from a stale copy.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setWeekStart(day) {
    var next = Model.normalizedWeekStart(day, root.weekStart)
    if (next === root.weekStart) return
    persistSettings({ weekStartDay: Model.weekStartSettingName(next) })
  }

  function startEditingLife() {
    root.editingLife = true
    Qt.callLater(function() {
      bornField.text = root.birthYear > 0 ? String(root.birthYear) : ""
      expectancyField.text = String(root.lifeExpectancy)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function cancelEditingLife() {
    root.editingLife = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Shared by both fields: Tab hops to the other one, Enter commits the pair,
  // Escape drops the lot.
  function handleLifeKey(event, other) {
    if (event.key === Qt.Key_Escape) {
      root.cancelEditingLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      root.commitLife()
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
      event.accepted = true
    }
  }

  // Double-tapping the life bar puts it away again. The expectancy stays in
  // the config so setting a birth year again brings your own number back
  // rather than the default.
  function clearLife() {
    if (root.birthYear <= 0) return
    persistSettings({ birthYear: 0 })
  }

  function commitLife() {
    var born = Model.parseBirthYear(bornField.text, today.getFullYear())
    var span = Model.parseLifeExpectancy(expectancyField.text)
    if (born !== root.birthYear || span !== root.lifeExpectancy)
      persistSettings({ birthYear: born, lifeExpectancy: span })
    cancelEditingLife()
  }

  function toggleWeekStart() {
    setWeekStart(Model.toggledWeekStart(root.weekStart))
  }

  // Nombres cortos de los días en castellano.
  function weekdayLabel(weekday) {
    return String(labelLocale.dayName(weekday, Locale.ShortFormat)).toUpperCase()
  }

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyForDate(clock.date) === String(root.todayKey)) return
      var followToday = root.viewingCurrentMonth
      root.today = clock.date
      if (followToday) root.goToToday()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    // julss: anclado bajo la fecha/hora en vez de centrado en la barra.
    centerOnBar: false
    focusTarget: keyCatcher
    // Wide enough for the hero too: long months ("30 de septiembre") would
    // otherwise run off the right edge at 560.
    contentWidth: panel.fittedContentWidth(Math.max(Style.space(560), heroRow.width + Style.space(56)))
    contentHeight: panel.fittedContentHeight(calendarColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife || root.editingEvent
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.moveMonth(dx)
        if (dy !== 0) root.moveYear(dy)
      }
      onActivateRequested: root.goToToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "[") root.moveMonth(-1)
        else if (t === "]") root.moveMonth(1)
        else if (t === "{") root.moveYear(-1)
        else if (t === "}") root.moveYear(1)
        else if (t === "t" || t === "T") root.goToToday()
        else if (t === "w" || t === "W") root.toggleWeekStart()
        else if (t === "n" || t === "N" || t === "+") root.startNewEvent()
      }

      Flickable {
        id: calendarScroll
        anchors.fill: parent
        contentWidth: calendarColumn.width
        contentHeight: calendarColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: calendarColumn
          // Never narrower than the grid. The popup width is capped to what
          // the screen allows, and a fixed seven-column grid would otherwise
          // lose its last days off the edge instead of scrolling.
          width: Math.max(calendarScroll.width, gridColumn.width)
          spacing: Style.space(8)

          // ---- Hero: today, centered. Once the view has stepped back
          //      it is also the way home — clicking the date you are
          //      looking for beats hunting for a reset button.
          Item {
            width: parent.width
            height: heroRow.height

            Row {
              id: heroRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              Text {
                // Baseline-aligned, not center-aligned: "July 26" carries a
                // descender, so centering the two boxes leaves the icon
                // sitting visibly low against the digits.
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.*
                // scale. Sized so the glyph reads at the cap height of the
                // date beside it rather than towering over it.
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: root.labelLocale.toString(root.today, "d 'de' MMMM")
                color: heroMouse.containsMouse
                  ? Style.hoverStateColor(root.contentForeground, Color.accent)
                  : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: heroRow.x
              y: heroRow.y
              width: heroRow.width
              height: heroRow.height
              enabled: !root.viewingCurrentMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.goToToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Volver a hoy"
                fontFamily: root.contentFontFamily
              }
            }
          }

          // ---- Year progress, doubling as the rule under the hero:
          //      a plain hairline said nothing, and whole days done
          //      over days in the year says the same thing louder.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(yearLabel.implicitHeight, Style.space(10))

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.startEditingLife()
              }

              Row {
                visible: root.editingLife
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "NACIDO EN"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "año"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, expectancyField) }
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: 0
                  leftPadding: Style.space(6)
                  text: "HASTA LOS"
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                TextField {
                  id: expectancyField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  inputMethodHints: Qt.ImhDigitsOnly

                  Keys.onPressed: function(event) { root.handleLifeKey(event, bornField) }
                }
              }

              Text {
                id: yearLabel
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.today.getFullYear()
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: yearPercent
                textFormat: Text.PlainText
                visible: !root.editingLife
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.yearDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                id: yearTrack
                visible: !root.editingLife
                anchors.left: yearLabel.right
                anchors.right: yearPercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.yearDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }
            }
          }

          // ---- Memento mori. Only here once someone has gone looking and
          //      given an age; the same rail as the year above it, measured
          //      against a nominal lifetime.
          Item {
            visible: root.birthYear > 0
            width: parent.width
            height: visible ? lifeBlock.height : 0

            Item {
              id: lifeBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(lifeLabel.implicitHeight, Style.space(10))

              Text {
                id: lifeLabel
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "VIDA"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: lifePercent
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.lifeDonePercent + "%"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Rectangle {
                anchors.left: lifeLabel.right
                anchors.right: lifePercent.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.lifeDone)
                  height: parent.height
                  radius: parent.radius
                  color: Style.selectedStateColor(root.contentForeground, Color.accent)

                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              TapHandler {
                onDoubleTapped: root.clearLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- julss: semanas de embarazo, mismo carril que el año.
          Item {
            visible: root.babyActive
            width: parent.width
            height: visible ? babyBlock.height : 0

            Item {
              id: babyBlock
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: Math.max(babyLabelText.implicitHeight, Style.space(10))

              Text {
                id: babyLabelText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "BEBÉ"
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
              }

              Text {
                id: babyWeekText
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Semana " + root.babyLabel
                color: Color.accent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              Rectangle {
                anchors.left: babyLabelText.right
                anchors.right: babyWeekText.left
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                height: Style.space(6)
                radius: Style.cornerRadius > 0 ? height / 2 : 0
                color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                Rectangle {
                  width: Math.round(parent.width * root.babyDone)
                  height: parent.height
                  radius: parent.radius
                  color: Color.accent
                  Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                }
              }

              MouseArea {
                id: babyMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: babyMouse.containsMouse
                  text: (root.babyDaysLeft > 0
                    ? "Faltan " + root.babyDaysLeft + " días"
                    : (root.babyDaysLeft === 0 ? "¡Hoy sale de cuentas!" : "Pasado " + (-root.babyDaysLeft) + " días de la fecha"))
                    + " · FPP " + root.labelLocale.toString(root.babyDue, "d 'de' MMMM yyyy")
                  fontFamily: root.contentFontFamily
                }
              }
            }
          }

          // ---- Month grid: week numbers down a gutter on the left, then
          //      the seven day columns. Always six rows, so the popup is
          //      exactly as tall in February as it is in August.
          Item {
            width: parent.width
            height: gridColumn.y + gridColumn.height

            WheelHandler {
              onWheel: function(event) {
                // Horizontal wheels and touchpad side-scrolls report y === 0;
                // without this they would every one read as "next month".
                if (event.angleDelta.y === 0) return
                root.moveMonth(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: gridColumn
              // The meter above is a solid rule; the grid needs room to
              // read as its own block rather than hanging off it.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headerRow
                spacing: root.cellSpacing

                // julss: cabecera de la columna de semanas de embarazo (a la izquierda de S).
                Text {
                  visible: root.babyActive
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                  text: "󰹼"
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                }

                // The week-number heading doubles as the week-start toggle.
                // It is the one control in the panel whose meaning is not
                // self-evident, so it carries a tooltip naming the day the
                // click will switch to.
                Rectangle {
                  width: root.weekColumnWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  Text {
                    anchors.centerIn: parent
                    text: "S"
                    color: weekStartMouse.containsMouse
                      ? Style.hoverStateColor(root.contentForeground, Color.accent)
                      : Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Empezar la semana en " + root.nextWeekStartLabel
                    fontFamily: root.contentFontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Text {
                    textFormat: Text.PlainText
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayLabel(modelData)
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: 1
                    font.bold: true
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  required property var modelData
                  spacing: root.cellSpacing


                  // julss: semana de embarazo de la fila.
                  Text {
                    visible: root.babyActive
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.babyWeekForRow(modelData)
                    color: Color.accent
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekColumnWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: modelData.week
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: modelData.days

                    Rectangle {
                      required property var modelData

                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      // Today is outlined, not filled: a lit-up block shouts
                      // over a grid this quiet.
                      color: root.isBabyDue(modelData)
                        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.25)
                        : (modelData.key === root.selectedKey
                          ? Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
                          : (dayMouse.containsMouse ? Style.hoverFillFor(root.contentForeground, Color.accent) : "transparent"))
                      border.width: modelData.today || root.isBabyDue(modelData) ? Style.spacing.hairline : 0
                      border.color: root.isBabyDue(modelData) ? Color.accent : Style.normalBorderFor(root.contentForeground, Color.accent)

                      // julss: clic = ver/añadir citas de ese día; doble clic = nueva cita.
                      MouseArea {
                        id: dayMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.selectDay(parent.modelData)
                        onDoubleClicked: { root.selectDay(parent.modelData); root.startNewEvent() }
                      }

                      // julss: un punto por cita (máx. 3) con el color de su calendario.
                      Row {
                        readonly property var dayEvents: root.eventsByDay[parent.modelData.key] || []
                        visible: dayEvents.length > 0
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(4)
                        spacing: Style.space(3)

                        Repeater {
                          model: Math.min(3, parent.dayEvents.length)

                          Rectangle {
                            required property int index
                            width: Style.space(5)
                            height: width
                            radius: width / 2
                            color: parent.dayEvents[index].color || Color.accent
                            opacity: parent.parent.modelData.inMonth ? 1 : 0.4
                          }
                        }
                      }

                      Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: modelData.day
                        color: modelData.inMonth
                          ? (modelData.weekend ? Qt.darker(root.contentForeground, 1.45) : root.contentForeground)
                          : Qt.darker(root.contentForeground, 2.2)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.today
                      }
                    }
                  }
                }
              }
            }

            // Hairline down the week-number gutter, drawn only beside the
            // day rows so it does not cut through the header band.
            Rectangle {
              x: gridColumn.x + (root.babyActive ? root.weekColumnWidth + root.cellSpacing : 0)
                + root.weekColumnWidth + root.cellSpacing + Math.round((root.gutterWidth - width) / 2)
              y: gridColumn.y + headerRow.height + gridColumn.spacing
              width: Style.spacing.hairline
              height: gridColumn.height - headerRow.height - gridColumn.spacing
              color: root.contentForeground
              opacity: 0.1
            }
          }

          // ---- Month stepping, spanning the grid it drives. The chevrons
          //      sit on the grid's outer bounds, the same edges the year
          //      rail above uses, so the row reads as the panel's other
          //      full-width rail instead of a cluster floating in space.
          //      The label is centered and fixed-width, so it holds still
          //      from "MAY" to "SEPTEMBER".
          Item {
            width: parent.width
            height: monthNav.height

            Item {
              id: monthNav
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              height: monthLabel.implicitHeight + Style.space(10)

              Text {
                id: monthLabel
                textFormat: Text.PlainText
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                // Fixed width so the chevrons hold still between a
                // "MAY 2026" and a "SEPTEMBER 2026".
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: root.labelLocale.toString(root.viewDate, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              PanelActionButton {
                // Pulled out by the button's own padding so the glyph, not
                // its hit box, lines up with the "2026" on the year rail.
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Mes anterior"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Mes siguiente"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.moveMonth(1)
              }
            }
          }

          // ---- julss: agenda del día seleccionado.
          Item {
            width: parent.width
            height: agendaColumn.height + Style.space(4)

            Column {
              id: agendaColumn
              anchors.horizontalCenter: parent.horizontalCenter
              width: gridColumn.width
              spacing: Style.space(6)

              Rectangle {
                width: parent.width
                height: Style.spacing.hairline
                color: root.contentForeground
                opacity: 0.1
              }

              // Cabecera: día elegido a la izquierda, estado + acciones a la derecha.
              Item {
                width: parent.width
                height: Math.max(agendaTitle.implicitHeight, addButton.height)

                Text {
                  id: agendaTitle
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: "AGENDA · " + (root.selectedKey === root.todayKey
                    ? "HOY"
                    : root.labelLocale.toString(root.selectedDate, "ddd d MMM").toUpperCase())
                  color: Qt.darker(root.contentForeground, 1.5)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.letterSpacing: 1
                }

                Row {
                  anchors.right: parent.right
                  anchors.rightMargin: -Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 0

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    rightPadding: Style.space(4)
                    textFormat: Text.PlainText
                    visible: text !== ""
                    text: root.agendaBusy ? "sincronizando…"
                      : (!root.googleConnected ? "solo local"
                      : (root.agenda.pending > 0 ? root.agenda.pending + " sin subir" : ""))
                    color: Qt.darker(root.contentForeground, 1.9)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  PanelActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: root.googleConnected ? "󰑓" : "󰒍"
                    tooltipText: root.syncTooltip()
                    foreground: root.agenda.error ? Color.urgent : root.contentForeground
                    fontFamily: root.contentFontFamily
                    enabled: !root.agendaBusy
                    onClicked: {
                      // En modo «Prueba» Google caduca el acceso cada 7 días:
                      // entonces el mismo botón vuelve a conectar.
                      if (root.googleConfigured && String(root.agenda.error || "").indexOf("volver a conectar") >= 0)
                        root.runAgenda(["auth"])
                      else if (root.googleConnected) root.syncAgenda()
                      else if (root.googleConfigured) root.runAgenda(["auth"])
                      else root.agendaMessage = "Falta ~/.config/julss-agenda/client_secret.json (ver julss-agenda --help)"
                    }
                  }

                  PanelActionButton {
                    id: addButton
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰐕"
                    tooltipText: "Nueva cita (n)"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.startNewEvent()
                  }
                }
              }

              Text {
                width: parent.width
                visible: text !== ""
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: root.agendaMessage !== "" ? root.agendaMessage : (root.agenda.error || "")
                color: Color.urgent
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              // ---- Formulario: nueva cita o edición.
              Column {
                visible: root.editingEvent
                width: parent.width
                spacing: Style.space(6)

                TextField {
                  id: titleField
                  width: parent.width
                  placeholderText: "Título de la cita"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) { root.handleEventKey(event, dateField) }
                }

                Row {
                  spacing: Style.space(6)

                  TextField {
                    id: dateField
                    width: Style.space(112)
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: "d/m/aaaa"
                    foreground: root.contentForeground
                    font.family: root.contentFontFamily
                    Keys.onPressed: function(event) { root.handleEventKey(event, root.editAllDay ? placeField : startField) }
                  }

                  TextField {
                    id: startField
                    visible: !root.editAllDay
                    width: Style.space(70)
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: "09:00"
                    foreground: root.contentForeground
                    font.family: root.contentFontFamily
                    Keys.onPressed: function(event) { root.handleEventKey(event, endField) }
                  }

                  Text {
                    visible: !root.editAllDay
                    anchors.verticalCenter: parent.verticalCenter
                    text: "–"
                    color: Qt.darker(root.contentForeground, 1.5)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                  }

                  TextField {
                    id: endField
                    visible: !root.editAllDay
                    width: Style.space(70)
                    anchors.verticalCenter: parent.verticalCenter
                    placeholderText: "+1 h"
                    foreground: root.contentForeground
                    font.family: root.contentFontFamily
                    Keys.onPressed: function(event) { root.handleEventKey(event, placeField) }
                  }

                  Item { width: Style.space(4); height: 1 }

                  ToggleSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: root.editAllDay
                    cursorRing: false
                    onToggled: root.editAllDay = !root.editAllDay
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Todo el día"
                    color: Qt.darker(root.contentForeground, 1.3)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                TextField {
                  id: placeField
                  width: parent.width
                  placeholderText: "Lugar (opcional)"
                  foreground: root.contentForeground
                  font.family: root.contentFontFamily
                  Keys.onPressed: function(event) { root.handleEventKey(event, titleField) }
                }

                Row {
                  spacing: Style.space(8)

                  Button {
                    iconText: "󰄬"
                    text: "Guardar"
                    bordered: true
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.saveEvent()
                  }

                  Button {
                    text: "Cancelar"
                    foreground: root.contentForeground
                    fontFamily: root.contentFontFamily
                    onClicked: root.cancelEditEvent()
                  }

                  Button {
                    visible: root.editId !== ""
                    iconText: "󰆴"
                    text: "Borrar"
                    foreground: Color.urgent
                    fontFamily: root.contentFontFamily
                    onClicked: root.deleteEvent(root.editId)
                  }
                }
              }

              Text {
                visible: !root.editingEvent && root.selectedEvents.length === 0
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                topPadding: Style.space(4)
                bottomPadding: Style.space(4)
                text: "Nada en la agenda · doble clic en un día o «n» para añadir"
                color: Qt.darker(root.contentForeground, 1.9)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
              }

              // ---- Citas del día.
              Repeater {
                model: root.selectedEvents

                Rectangle {
                  id: eventRow
                  required property var modelData
                  width: agendaColumn.width
                  height: Math.max(Style.space(34), eventText.implicitHeight + Style.space(10))
                  radius: Style.cornerRadius
                  color: rowHover.hovered && modelData.writable
                    ? Style.hoverFillFor(root.contentForeground, Color.accent)
                    : "transparent"

                  HoverHandler { id: rowHover }

                  MouseArea {
                    id: eventMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: eventRow.modelData.writable ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.startEditEvent(eventRow.modelData)
                  }

                  Rectangle {
                    id: eventBar
                    x: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(3)
                    height: parent.height - Style.space(10)
                    radius: width / 2
                    color: eventRow.modelData.color || Color.accent
                  }

                  Text {
                    id: eventTime
                    anchors.left: eventBar.right
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(104)
                    textFormat: Text.PlainText
                    text: eventRow.modelData.time
                    color: Qt.darker(root.contentForeground, 1.3)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Column {
                    id: eventText
                    anchors.left: eventTime.right
                    anchors.right: eventIcons.left
                    anchors.rightMargin: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      width: parent.width
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: eventRow.modelData.title
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Text {
                      width: parent.width
                      visible: text !== ""
                      elide: Text.ElideRight
                      textFormat: Text.PlainText
                      text: [eventRow.modelData.location || "",
                             root.googleConnected && eventRow.modelData.calName !== "Local" ? eventRow.modelData.calName : ""]
                            .filter(function(s) { return s !== "" }).join(" · ")
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Row {
                    id: eventIcons
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: !!eventRow.modelData.pending
                      rightPadding: Style.space(4)
                      text: "󰔟"
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: !!eventRow.modelData.recurring
                      rightPadding: Style.space(4)
                      text: "󰑖"
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: !eventRow.modelData.writable
                      rightPadding: Style.space(4)
                      text: "󰌾"
                      color: Qt.darker(root.contentForeground, 1.7)
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                    }

                    PanelActionButton {
                      anchors.verticalCenter: parent.verticalCenter
                      visible: eventRow.modelData.writable && rowHover.hovered
                      iconText: "󰆴"
                      tooltipText: eventRow.modelData.recurring ? "Borrar esta vez" : "Borrar"
                      foreground: root.contentForeground
                      fontFamily: root.contentFontFamily
                      onClicked: root.deleteEvent(eventRow.modelData.id)
                    }
                  }

                  PanelToolTip {
                    visible: rowHover.hovered && (eventRow.modelData.notes || !eventRow.modelData.writable || eventRow.modelData.pending)
                    text: [eventRow.modelData.notes || "",
                           eventRow.modelData.pending ? "Pendiente de subir a Google" : "",
                           !eventRow.modelData.writable ? "Calendario de solo lectura" : ""]
                          .filter(function(s) { return s !== "" }).join("\n")
                    fontFamily: root.contentFontFamily
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
