import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// A Force Quit dialog in the bar: every open window, grouped into the process
// that owns it, with two ways out per row — ask the app to close its windows,
// or end the process outright.
//
// The panel deliberately keeps two separate verbs. "Quit" is a Hyprland close
// request, which the application sees and can answer with a save prompt.
// "Force quit" is SIGKILL, which it cannot see, cannot refuse, and cannot save
// through. Everything about the second one's presentation — the red, the skull,
// the armed confirmation step — exists because that difference is invisible
// once the click has landed.
Panel {
  id: root
  moduleName: "julss.forcequit"
  ipcTarget: "julss.forcequit"
  // manageIpc: false so this panel owns the single IpcHandler the target
  // allows — needed for the list/quit methods keybinds and scripts call.
  manageIpc: false

  readonly property bool requireConfirm: setting("requireConfirm", true) !== false
  readonly property int confirmSeconds: Math.max(2, Math.min(30, Number(setting("confirmSeconds", 5)) || 5))
  readonly property int visibleRows: Math.max(3, Math.min(20, Number(setting("visibleRows", 8)) || 8))

  property var clients: []
  property var stats: ({})
  property string query: ""
  property int cursorIndex: 0
  // pid of the row waiting for its second confirmation, 0 when nothing is armed.
  property int armedPid: 0

  // class -> { name, icon }. Mutated in place, never reassigned: a reassignment
  // would notify the `rows` binding that reads it and re-enter this lookup.
  property var metaCache: ({})

  readonly property var rows: root.decorate(Model.buildRows(root.clients, root.stats, root.query))
  readonly property var totals: Model.totals(root.clients)
  readonly property bool empty: root.rows.length === 0

  readonly property string activeWorkspace: Hyprland.focusedWorkspace
    ? Model.workspaceLabel(Hyprland.focusedWorkspace.name, Hyprland.focusedWorkspace.id)
    : ""

  readonly property int rowHeight: Style.space(46)
  readonly property int rowSpacing: Style.space(4)
  readonly property int maxListHeight: root.visibleRows * root.rowHeight + (root.visibleRows - 1) * root.rowSpacing

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // --- naming and icons ----------------------------------------------------

  // A window class is a developer's identifier ("org.omarchy.agent"); the
  // desktop entry holds the name and icon a user recognises. Look the class up
  // once per class and cache it — heuristicLookup walks every installed entry.
  function metaFor(cls, fallbackTitle) {
    var key = String(cls || "")
    var cached = root.metaCache[key]
    if (cached) return cached

    var entry = null
    try {
      if (key !== "") entry = DesktopEntries.heuristicLookup(key)
    } catch (e) {
      entry = null
    }

    var iconName = entry && entry.icon ? String(entry.icon) : key.toLowerCase()
    var meta = {
      name: entry && entry.name ? String(entry.name) : Model.prettyName(key, fallbackTitle),
      icon: iconName !== "" ? Quickshell.iconPath(iconName, true) : ""
    }
    // Only a hit is cached. The first lookup can run before the desktop-entry
    // index has finished loading, and a cached miss would pin an application to
    // its class name ("Code") for the life of the shell.
    if (entry) root.metaCache[key] = meta
    return meta
  }

  function decorate(list) {
    for (var i = 0; i < list.length; i++) {
      var meta = root.metaFor(list[i].cls, list[i].title)
      list[i].name = meta.name
      list[i].iconSource = meta.icon
    }
    // Named after the desktop entry rather than the class, so sort again.
    list.sort(Model.byName)
    return list
  }

  // --- cursor --------------------------------------------------------------

  function currentRow() {
    return (root.cursorIndex >= 0 && root.cursorIndex < root.rows.length) ? root.rows[root.cursorIndex] : null
  }

  function moveCursor(step) {
    if (root.rows.length === 0) return
    root.disarm()
    root.cursorIndex = Math.max(0, Math.min(root.rows.length - 1, root.cursorIndex + step))
    root.ensureVisible(root.cursorIndex)
  }

  function selectIndex(index) {
    if (index === root.cursorIndex) return
    root.disarm()
    root.cursorIndex = index
  }

  function ensureVisible(index) {
    var top = index * (root.rowHeight + root.rowSpacing)
    var bottom = top + root.rowHeight
    if (top < listFlick.contentY) listFlick.contentY = top
    else if (bottom > listFlick.contentY + listFlick.height) listFlick.contentY = bottom - listFlick.height
  }

  // --- the two ways out ----------------------------------------------------

  function arm(row) {
    root.armedPid = row.pid
    disarmTimer.restart()
  }

  function disarm() {
    root.armedPid = 0
    disarmTimer.stop()
  }

  // First press arms, second kills. The armed row states the consequence in
  // words, which is the only warning there is: SIGKILL has no undo and no
  // save prompt.
  function activate(row) {
    if (!row) return
    if (!root.requireConfirm || root.armedPid === row.pid) root.forceQuit(row)
    else root.arm(row)
  }

  function forceQuit(row) {
    if (!row) return
    var command = Model.forceQuitCommand(row.pid)
    if (!command) return
    root.disarm()
    Quickshell.execDetached(command)
    refreshTimer.restart()
  }

  function quit(row) {
    if (!row) return
    var commands = Model.quitCommands(row.addresses)
    if (commands.length === 0) return
    root.disarm()
    for (var i = 0; i < commands.length; i++) Quickshell.execDetached(commands[i])
    refreshTimer.restart()
  }

  // --- data ----------------------------------------------------------------

  function refresh() {
    if (!clientsProc.running) clientsProc.running = true
  }

  function refreshStats() {
    if (statsProc.running) return
    statsProc.command = ["bash", "-c", Model.statsScript(Model.pidsOf(root.clients))]
    statsProc.running = true
  }

  onRowsChanged: {
    if (root.cursorIndex > root.rows.length - 1) root.cursorIndex = Math.max(0, root.rows.length - 1)
    // The armed row can vanish under the confirmation — it exited on its own,
    // or the filter moved on. Re-arming the row that slid into its place is
    // the one outcome this must never have.
    if (root.armedPid !== 0) {
      var stillThere = false
      for (var i = 0; i < root.rows.length; i++) if (root.rows[i].pid === root.armedPid) stillThere = true
      if (!stillThere) root.disarm()
    }
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.clients = Model.parseClients(text)
        root.refreshStats()
      }
    }
  }

  Process {
    id: statsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.stats = Model.parseStats(text)
    }
  }

  // A kill is asynchronous: the window is gone when Hyprland says so, not when
  // the signal is sent. The event below normally beats this timer; it covers
  // the process that took a moment to die.
  Timer {
    id: refreshTimer
    interval: 350
    onTriggered: root.refresh()
  }

  Timer {
    id: disarmTimer
    interval: root.confirmSeconds * 1000
    onTriggered: root.disarm()
  }

  // Memory is the column that decides which of two runaway processes to end,
  // and it only moves while someone is looking at it.
  Timer {
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  // Windows opening and closing are tracked whether or not the panel is open:
  // the bar tooltip counts them, and a script asking the IPC handler for the
  // list must not be answered from whatever was on screen last time. Titles and
  // focus only matter while someone is reading them.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      var name = event.name
      var structural = name === "openwindow" || name === "closewindow" || name === "movewindow"
      var cosmetic = name === "activewindow" || name === "activewindowv2"
        || name === "windowtitle" || name === "windowtitlev2"
      if (structural || (root.opened && cosmetic)) eventTimer.restart()
    }
  }

  // A window title changes on every browser tab switch, so events are coalesced
  // rather than each one costing a hyprctl round trip.
  Timer {
    id: eventTimer
    interval: 200
    onTriggered: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Text output so a keybind or script can see the same list the panel shows.
    function list(): string {
      var lines = []
      var rows = root.decorate(Model.buildRows(root.clients, root.stats, ""))
      for (var i = 0; i < rows.length; i++) {
        lines.push(rows[i].pid + "\t" + rows[i].name + "\t" + rows[i].windowCount + " ventana(s)")
      }
      return lines.length > 0 ? lines.join("\n") : "no hay ventanas abiertas"
    }

    // The polite counterpart to kill(): closes the process's windows and lets
    // the application decide what to do about unsaved work.
    function quit(pid: string): string {
      var target = Number(pid)
      var rows = root.decorate(Model.buildRows(root.clients, root.stats, ""))
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].pid === target) {
          root.quit(rows[i])
          return "pedido a " + rows[i].name + " que cierre " + rows[i].windowCount + " ventana(s)"
        }
      }
      return "ninguna ventana pertenece al pid " + pid
    }

    // No arming here: a caller that typed a pid has already decided.
    function kill(pid: string): string {
      var target = Number(pid)
      var rows = root.decorate(Model.buildRows(root.clients, root.stats, ""))
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].pid === target) {
          root.forceQuit(rows[i])
          return "forzado el cierre de " + rows[i].name + " (" + target + ")"
        }
      }
      return "ninguna ventana pertenece al pid " + pid
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.query = ""
      search.text = ""
      root.cursorIndex = 0
      root.disarm()
      listFlick.contentY = 0
      root.refresh()
    } else {
      root.disarm()
    }
  }

  Component.onCompleted: root.refresh()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰚌"
    tooltipText: root.totals.windows === 1
      ? "Forzar cierre — 1 ventana abierta"
      : "Forzar cierre — " + root.totals.windows + " ventanas abiertas"
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: search
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The filter field owns the keyboard whenever it has focus, which is
      // from the moment the panel opens; these handlers are the fallback for
      // a panel whose focus went elsewhere.
      blocked: search.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy !== 0 ? dy : dx) }
      onActivateRequested: root.activate(root.currentRow())
      onDeleteRequested: root.activate(root.currentRow())
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        PanelHero {
          width: parent.width
          title: "Forzar cierre"
          meta: (root.totals.processes + (root.totals.processes === 1 ? " APP · " : " APPS · ")
            + root.totals.windows + (root.totals.windows === 1 ? " VENTANA" : " VENTANAS"))
          detail: root.armedPid !== 0 ? "Forzar el cierre no pregunta si guardar" : ""
          foreground: root.armedPid !== 0 ? root.urgent : root.foreground
          fontFamily: root.fontFamily
          iconComponent: Component {
            Text {
              text: "󰚌"
              color: root.armedPid !== 0 ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        TextField {
          id: search
          width: parent.width
          foreground: root.foreground
          placeholderText: "Filtrar por app, título de ventana o pid"
          font.pixelSize: Style.font.bodySmall
          verticalPadding: Style.space(5)
          onTextChanged: {
            root.query = text
            root.cursorIndex = 0
            root.disarm()
            listFlick.contentY = 0
          }
          // Seen before the editor: Up/Down have to drive the list rather than
          // the cursor inside a one-line field, and Enter must never be a
          // keystroke that only sometimes kills something.
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function(event) { root.handleKey(event) }
        }

        Column {
          width: parent.width
          spacing: Style.space(8)

          PanelSectionHeader {
            text: root.query === "" ? "APLICACIONES ABIERTAS" : "COINCIDENCIAS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Flickable {
            id: listFlick
            width: parent.width
            height: Math.min(listColumn.implicitHeight, root.maxListHeight)
            visible: !root.empty
            contentWidth: width
            contentHeight: listColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: listColumn
              width: listFlick.width
              spacing: root.rowSpacing

              Repeater {
                model: root.rows
                AppRow {
                  required property var modelData
                  required property int index
                  row: modelData
                  rowIndex: index
                  width: listColumn.width
                }
              }
            }
          }

          Text {
            visible: root.empty
            width: parent.width
            text: root.query === "" ? "No hay ventanas abiertas." : "Nada coincide con “" + root.query + "”."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
          }
        }

        Text {
          width: parent.width
          text: "↑↓ elegir · Intro forzar cierre · Mayús+Intro salir · Esc cerrar"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // Escape unwinds one layer at a time — the armed confirmation, then the
  // filter, then the panel — so it never closes a panel the user was still
  // reading.
  function handleKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.armedPid !== 0) root.disarm()
      else if (search.text !== "") search.text = ""
      else root.close()
      event.accepted = true
    } else if (event.key === Qt.Key_Down) {
      root.moveCursor(1)
      event.accepted = true
    } else if (event.key === Qt.Key_Up) {
      root.moveCursor(-1)
      event.accepted = true
    } else if (event.key === Qt.Key_PageDown) {
      root.moveCursor(root.visibleRows)
      event.accepted = true
    } else if (event.key === Qt.Key_PageUp) {
      root.moveCursor(-root.visibleRows)
      event.accepted = true
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (event.modifiers & Qt.ShiftModifier) root.quit(root.currentRow())
      else root.activate(root.currentRow())
      event.accepted = true
    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
      event.accepted = true
    }
  }

  component AppRow: CursorSurface {
    id: entry

    property var row: null
    property int rowIndex: 0

    readonly property bool armed: entry.row && root.armedPid === entry.row.pid
    readonly property bool underCursor: root.cursorIndex === entry.rowIndex

    hasCursor: entry.underCursor
    // No `current` state: the row the user came from is called out in words on
    // the summary line instead. Two competing highlights in one list is one
    // more than a list can have.
    foreground: entry.armed ? root.urgent : root.foreground
    implicitHeight: root.rowHeight

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor
      onEntered: root.selectIndex(entry.rowIndex)
      onClicked: function(mouse) {
        root.selectIndex(entry.rowIndex)
        if (mouse.button === Qt.MiddleButton) root.quit(entry.row)
        else root.activate(entry.row)
      }
    }

    Image {
      id: appIcon
      visible: !entry.armed && source !== ""
      width: Style.space(22)
      height: width
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      fillMode: Image.PreserveAspectFit
      // Decode at physical pixels — a logical-size decode leaves PNG icons
      // upscaled and blurry on HiDPI displays.
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      source: entry.row ? entry.row.iconSource : ""
      asynchronous: true
    }

    Text {
      id: fallbackIcon
      visible: !appIcon.visible
      anchors.left: parent.left
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      width: appIcon.width
      horizontalAlignment: Text.AlignHCenter
      text: entry.armed ? "󰀦" : "󰘔"
      color: entry.armed ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.iconLarge
    }

    Column {
      anchors.left: appIcon.right
      anchors.leftMargin: Style.space(10)
      anchors.right: actions.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        width: parent.width
        text: entry.armed
          ? "¿Forzar el cierre de " + entry.row.name + "?"
          : (entry.row ? entry.row.name : "")
        color: entry.armed ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: entry.underCursor || entry.armed
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        text: {
          if (!entry.row) return ""
          if (entry.armed) {
            return (entry.row.windowCount > 1 ? "se cierran " + entry.row.windowCount + " ventanas · " : "")
              + "sin preguntar si guardar · Intro otra vez para confirmar"
          }
          var summary = Model.windowSummary(entry.row, root.activeWorkspace)
          if (summary === "") return entry.row.title
          return entry.row.title === "" ? summary : summary + " · " + entry.row.title
        }
        color: entry.armed ? root.urgent : root.dim
        opacity: entry.armed ? 0.9 : 1.0
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
        textFormat: Text.PlainText
      }
    }

    Row {
      id: actions
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: !entry.armed && text !== ""
        text: entry.row ? Model.formatMemory(entry.row.memoryKb) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        rightPadding: Style.space(4)
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰅖"
        tooltipText: "Salir — pide a la app que cierre sus ventanas"
        foreground: root.foreground
        opacity: entry.underCursor ? 1.0 : 0.5
        fontFamily: root.fontFamily
        onClicked: root.quit(entry.row)
        onHovered: function(isHovered) { if (isHovered) root.selectIndex(entry.rowIndex) }
      }

      PanelActionButton {
        anchors.verticalCenter: parent.verticalCenter
        iconText: "󰚌"
        tooltipText: entry.armed
          ? "Pulsa otra vez para forzar el cierre"
          : "Forzar cierre — mata el proceso, se pierde lo no guardado"
        foreground: entry.armed ? root.urgent : root.foreground
        hoverColor: root.urgent
        bordered: entry.armed
        opacity: entry.underCursor || entry.armed ? 1.0 : 0.5
        fontFamily: root.fontFamily
        onClicked: {
          root.selectIndex(entry.rowIndex)
          root.activate(entry.row)
        }
        onHovered: function(isHovered) { if (isHovered) root.selectIndex(entry.rowIndex) }
      }
    }
  }
}
