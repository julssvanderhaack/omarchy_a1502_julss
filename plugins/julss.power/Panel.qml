import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.power"
  ipcTarget: "omarchy.power"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the togglePercentage method below.
  manageIpc: false
  property var batteryInfo: ({})
  property var systemInfo: ({})
  property var profiles: []
  property string activeProfile: ""
  property int profileIndex: 0
  property bool cursorActive: false
  readonly property bool showPercentage: setting("showPercentage", false) === true
  // With the percentage shown the button paints a text block wider than an
  // icon, so the open-panel mark takes the painted width instead of the
  // icon-sized fraction of the slot the fallback assumes.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0
  readonly property bool batteryPresent: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent)
  }

  function upowerStates() {
    return {
      Charging: UPowerDeviceState.Charging,
      Discharging: UPowerDeviceState.Discharging,
      FullyCharged: UPowerDeviceState.FullyCharged,
      PendingCharge: UPowerDeviceState.PendingCharge
    }
  }

  function selectProfileByDelta(delta) {
    profileIndex = Model.selectProfileIndex(profileIndex, delta, profiles)
  }

  function activateSelectedProfile() {
    if (profileIndex < 0 || profileIndex >= profiles.length) return
    setProfile(profiles[profileIndex])
  }

  function batteryIcon() {
    var device = UPower.displayDevice
    return Model.batteryIcon(device, root.discharging, upowerStates())
  }

  function modeLabel() {
    var device = UPower.displayDevice
    return Model.modeLabel(device, root.discharging, upowerStates())
  }

  function profileIcon(name) {
    return Model.profileIcon(name)
  }

  readonly property bool fullyCharged: {
    var device = UPower.displayDevice
    return device && device.isPresent && device.state === UPowerDeviceState.FullyCharged && !root.chargeThresholdActive
  }
  readonly property bool discharging: {
    var device = UPower.displayDevice
    return !!(device && device.isPresent && UPower.onBattery)
  }
  readonly property bool chargeThresholdActive: {
    var device = UPower.displayDevice
    return Model.chargeThresholdActive(device, root.discharging, upowerStates())
  }
  readonly property bool batteryFull: fullyCharged || (!root.discharging && batteryFraction >= 1)
  readonly property bool batteryFlowIdle: batteryFull || chargeThresholdActive

  // 0..1 charge level, used by the visual progress bar.
  readonly property real batteryFraction: {
    var d = UPower.displayDevice
    return Model.batteryFraction(d)
  }

  readonly property bool charging: {
    var d = UPower.displayDevice
    return d && d.isPresent && !UPower.onBattery && !root.batteryFlowIdle
  }

  // Bar icon by charge: green 66–100 %, yellow 20–65 %, red below 20 %.
  readonly property int batteryPercent: Math.round(root.batteryFraction * 100)
  readonly property color batteryLevelColor: !root.batteryPresent
    ? (root.bar ? root.bar.foreground : Color.foreground)
    : root.batteryPercent >= 66 ? "#7cc77c"
    : root.batteryPercent >= 20 ? "#e5c07b"
    : "#e06c75"

  // julss: por debajo del 10 % el icono va en negativo sobre un cuadrado rojo,
  // como el número del espacio de trabajo activo.
  readonly property color barBackground: root.bar ? root.bar.background : Color.background
  readonly property bool batteryCritical: root.batteryPresent && root.batteryPercent < 10

  readonly property color batteryFillColor: {
    return root.bar ? root.bar.foreground : Color.foreground
  }

  // Cute agent-flavored phrases shown in the hero status line, rotated on a
  // timer so the panel feels alive when current is flowing (either direction).
  readonly property var chargingPhrases: [
    "Merendando electrones",
    "Chupando del enchufe",
    "Recargando el café",
    "Siesta con enchufe",
    "Cogiendo fuerzas",
    "Dándose un atracón",
    "Repostando sin pagar",
    "Bebiendo del enchufe",
    "Haciendo la digestión"
  ]
  readonly property var onBatteryPhrases: [
    "Chupando de la pila",
    "A dieta de vatios",
    "Buscando un enchufe",
    "Tirando de ahorros",
    "Sin cargador y sin miedo",
    "Aguantando como puede",
    "Estirando el último julio",
    "Rezando por un enchufe",
    "Racionando electrones"
  ]
  property int phraseIndex: 0

  // Whichever list is "active" given the current power state.
  readonly property var activePhrases: {
    if (fullyCharged) return []
    if (charging) return chargingPhrases
    if (discharging) return onBatteryPhrases
    return []
  }
  readonly property bool rotatingPhrases: activePhrases.length > 0

  readonly property string heroStatusText: {
    if (fullyCharged) return "Carga completa"
    if (rotatingPhrases) return activePhrases[phraseIndex % activePhrases.length]
    return modeLabel()
  }

  function refresh() {
    if (!batteryPresent) return

    if (!batteryProc.running) batteryProc.running = true
    batteryTempFile.reload()
    if (!profilesProc.running) profilesProc.running = true
    if (!systemProc.running) systemProc.running = true
  }

  function updateKeyValue(raw, targetName) {
    var next = Model.parseKeyValue(raw)
    // Keep last known good data if a refresh briefly returns nothing — happens
    // around AC plug/unplug events. Avoids the section collapsing mid-transition.
    if (Object.keys(next).length === 0) return
    if (targetName === "battery") batteryInfo = next
    else systemInfo = next
  }

  function updateProfiles(raw) {
    var parsed = Model.parseProfiles(raw, profileIndex)
    // Same guard as battery: preserve the last known profile list across
    // transient empty payloads so the buttons don't blink out.
    if (parsed.profiles.length === 0) return
    profiles = parsed.profiles
    activeProfile = parsed.activeProfile
    profileIndex = parsed.profileIndex
    if (opened && !cursorActive) {
      var idx = profiles.indexOf(activeProfile)
      if (idx >= 0) profileIndex = idx
    }
  }

  function setProfile(profile) {
    if (!profile || actionProc.running) return
    actionProc.command = ["omarchy-powerprofiles-set", root.discharging ? "battery" : "ac", profile]
    actionProc.running = true
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  IpcHandler {
    target: "omarchy.power"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePercentage() { root.togglePercentage() }
  }

  // ---- julss: histórico de carga (UPower GetHistory por D-Bus) ----
  // Puntos {t, v, s}: hora (s), % y estado UPower (1 cargando, 2 descargando,
  // 4 cargada). UPower ya guarda el histórico, aunque la shell no corriera.
  readonly property var historyRanges: [3, 6, 12, 24]
  property int historyHours: 6
  property var historyPoints: []

  function refreshHistory() {
    if (historyProc.running) return
    historyProc.command = ["bash", "-c",
      "dev=$(upower -e | grep -m1 /battery_); [ -n \"$dev\" ] && gdbus call --system " +
      "--dest org.freedesktop.UPower --object-path \"$dev\" " +
      "--method org.freedesktop.UPower.Device.GetHistory charge " + (root.historyHours * 3600) + " 150"]
    historyProc.running = true
  }

  function parseHistory(raw) {
    var re = /\((?:uint32 )?(\d+), ([\d.]+), (?:uint32 )?(\d+)\)/g
    var pts = [], m
    while ((m = re.exec(String(raw || ""))) !== null) {
      // Al arrancar UPower apunta a veces un 0 % con estado desconocido (0):
      // no es real y pintaría un pico hasta abajo.
      if (Number(m[3]) === 0 && Number(m[2]) === 0) continue
      pts.push({ t: Number(m[1]), v: Number(m[2]), s: Number(m[3]) })
    }
    pts.sort(function(a, b) { return a.t - b.t })
    // UPower solo apunta cambios: se añade el valor actual para que la línea
    // llegue hasta «ahora».
    if (root.batteryPresent)
      pts.push({ t: Date.now() / 1000, v: root.batteryPercent, s: root.charging ? 1 : 2 })
    root.historyPoints = pts
  }

  Process {
    id: historyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseHistory(text)
    }
  }

  Timer {
    interval: 60000
    running: root.opened
    repeat: true
    onTriggered: root.refreshHistory()
  }

  onHistoryHoursChanged: refreshHistory()

  onOpenedChanged: {
    if (opened) {
      if (!batteryPresent) {
        close()
        return
      }

      refresh()
      refreshHistory()
      var idx = profiles.indexOf(activeProfile)
      profileIndex = idx >= 0 ? idx : 0
      cursorActive = false
    }
  }

  onBatteryPresentChanged: if (!batteryPresent) close()

  visible: batteryPresent
  implicitWidth: batteryPresent ? button.implicitWidth : 0
  implicitHeight: batteryPresent ? button.implicitHeight : 0

  Process {
    id: batteryProc
    // Stock status plus health/full/design from ./battery-health.
    command: ["bash", "-c", "omarchy-battery-status --shell; \"$HOME/.config/omarchy/plugins/julss.power/battery-health\""]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "battery") }
  }

  Process {
    id: profilesProc
    command: ["omarchy-powerprofiles-list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateProfiles(text) }
  }

  Process {
    id: systemProc
    command: ["omarchy-system-stats"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.updateKeyValue(text, "system") }
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  // Rotate the status phrase while the panel is open and we're in a
  // rotating state (charging or on battery). The text swap is wrapped in a
  // fade so the changeover reads as one organism rather than a hard cut.
  Timer {
    id: phraseTimer
    interval: 2800
    running: root.opened && root.rotatingPhrases
    repeat: true
    triggeredOnStart: false
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 0.0; duration: 180; easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: {
        var n = root.activePhrases.length
        if (n > 0) root.phraseIndex = (root.phraseIndex + 1) % n
      }
    }
    PropertyAnimation {
      target: heroStatus; property: "opacity"
      to: 1.0; duration: 260; easing.type: Easing.InQuad
    }
  }

  // If we leave a rotating state mid-swap, halt the animation and snap back
  // to full opacity so "FULLY CHARGED" is legible immediately rather than
  // appearing dimmed.
  Connections {
    target: root
    function onRotatingPhrasesChanged() {
      if (!root.rotatingPhrases) {
        phraseSwap.stop()
        heroStatus.opacity = 1.0
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    foreground: root.batteryLevelColor
    text: root.showPercentage && !vertical
      ? root.batteryIcon() + " " + root.batteryPercent + "%"
      : root.batteryIcon()
    // With the percentage shown, only the icon takes the level colour: the
    // two are drawn as separate texts instead of the single glyph string.
    iconComponent: (root.showPercentage && !vertical) || root.batteryCritical ? percentAndIcon : null
    slotSize: Style.bar.iconSlot * (root.showPercentage && !vertical ? 2 : 1) - Style.space(4)  // julss: más junto
    tooltipText: ""
    onPressed: function(b) {
      if (!root.batteryPresent) return
      if (b === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  Component {
    id: percentAndIcon

    Item {
      Row {
        anchors.centerIn: parent

        // julss: icono primero y el porcentaje a su derecha.
        Item {
          anchors.verticalCenter: parent.verticalCenter
          width: root.batteryCritical ? criticalSquare.width + Style.space(4) : batteryGlyph.implicitWidth
          height: batteryGlyph.implicitHeight

          Rectangle {
            id: criticalSquare
            visible: root.batteryCritical
            anchors.centerIn: parent
            // Mismo tamaño que el cuadrado del espacio activo (julss.workspaces).
            width: Style.space(16)
            height: width
            radius: Style.space(4)
            color: "#e06c75"
          }

          Text {
            id: batteryGlyph
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.batteryCritical
              ? Qt.rgba(root.barBackground.r, root.barBackground.g, root.barBackground.b, 1)
              : root.batteryLevelColor
            font.family: button.fontFamily
            font.pixelSize: button.fontSize
          }
        }

        Text {
          visible: root.showPercentage && !button.vertical
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: " " + root.batteryPercent + "%"
          color: root.bar ? root.bar.foreground : Color.foreground
          font.family: button.fontFamily
          font.pixelSize: button.fontSize
        }
      }
    }
  }

  // julss: temperatura de la batería (décimas de °C en sysfs). Solo se lee
  // con el panel abierto, junto al resto de datos.
  property string batteryTempC: ""

  FileView {
    id: batteryTempFile
    path: "/sys/class/power_supply/BAT0/temp"
    blockLoading: true
    printErrors: false
    onLoaded: {
      var tenths = parseInt(text(), 10)
      root.batteryTempC = isFinite(tenths) ? (tenths / 10).toFixed(1).replace(".", ",") + " °C" : ""
    }
    onLoadFailed: root.batteryTempC = ""
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.batteryPresent
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dx !== 0) root.selectProfileByDelta(dx)
        else if (dy !== 0) root.selectProfileByDelta(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateSelectedProfile()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(14)

        // ---------- Hero: battery icon · title/status · percentage ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroPercent.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: root.batteryIcon()
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
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
              text: "Batería"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              id: heroStatus
              textFormat: Text.PlainText
              text: root.heroStatusText.toUpperCase()
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
            text: root.batteryInfo.percentage || "—"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // ---------- Battery progress bar ----------
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: barTrack
            anchors.fill: parent
            radius: height / 2
            color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
          }

          Rectangle {
            id: barFill
            anchors.left: barTrack.left
            anchors.verticalCenter: barTrack.verticalCenter
            height: barTrack.height
            radius: barTrack.radius
            color: root.batteryFillColor
            width: Math.max(barTrack.height, barTrack.width * root.batteryFraction)

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            // Subtle pulse while charging — visible signal that energy is flowing in.
            SequentialAnimation on opacity {
              running: root.charging && !root.fullyCharged && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // ---------- Stats ----------
        // Visibility is intentionally only gated by "we've ever loaded data" so
        // the section never collapses mid-transition. fullyCharged is *not* part
        // of the condition: UPower briefly reports FullyCharged on plug-in when
        // the battery sits above the charge-control start threshold, and we
        // refuse to flicker the whole panel for that ~1s window.
        Row {
          visible: root.batteryInfo.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair { label: "Capacidad máx."; value: root.batteryInfo.full || root.batteryInfo.size || "" }
            InfoPair { label: "Ciclos de carga"; value: root.batteryInfo.cycles || "—" }
            InfoPair {
              visible: root.batteryTempC !== ""
              label: "Temperatura"
              value: root.batteryTempC
            }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            InfoPair {
              label: root.chargeThresholdActive ? "Límite de carga" : (root.discharging ? "Tiempo restante" : "Hasta cargar")
              value: root.chargeThresholdActive ? (root.batteryInfo.threshold || "-") : (root.batteryFlowIdle ? "-" : (root.batteryInfo.time || "—"))
            }
            InfoPair {
              label: root.chargeThresholdActive ? "Estado" : (root.discharging ? "Descargando" : "Cargando")
              value: root.chargeThresholdActive ? "Mantenida" : (root.batteryFull ? "-" : (root.batteryInfo.rate || ""))
            }
            InfoPair { label: "Salud"; value: root.batteryInfo.health || "—" }
          }
        }

        // ---------- Histórico de carga (julss) ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(8)

          Item {
            width: parent.width
            implicitHeight: Math.max(historyHeader.implicitHeight, rangeRow.implicitHeight)

            PanelSectionHeader {
              id: historyHeader
              text: "HISTÓRICO DE CARGA"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Row {
              id: rangeRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Repeater {
                model: root.historyRanges

                Button {
                  required property var modelData
                  text: modelData + " h"
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.space(6)
                  verticalPadding: Style.space(2)
                  bordered: true
                  active: root.historyHours === modelData
                  onClicked: root.historyHours = modelData
                }
              }
            }
          }

          HistoryChart {
            width: parent.width
            height: Style.space(110)
          }

          // Leyenda.
          Row {
            spacing: Style.space(14)

            Row {
              spacing: Style.space(6)
              Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Style.space(8); height: width; radius: width / 2; color: Color.accent }
              InfoLabel { text: "Cargando" }
            }

            Row {
              spacing: Style.space(6)
              Rectangle { anchors.verticalCenter: parent.verticalCenter; width: Style.space(8); height: width; radius: width / 2; color: root.bar.foreground }
              InfoLabel { text: "Con batería" }
            }
          }
        }

        // ---------- Power profile picker ----------
        PanelSeparator {
          foreground: root.bar.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "PERFIL DE ENERGÍA"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: profileRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: root.profiles.length > 0
              ? (width - spacing * (root.profiles.length - 1)) / root.profiles.length
              : 0

            Repeater {
              model: root.profiles
              Button {
                required property var modelData
                required property int index
                width: profileRow.cellWidth
                iconText: root.profileIcon(String(modelData))
                iconSize: Style.font.title
                text: ({ "power-saver": "Ahorro", "balanced": "Equilibrado", "performance": "Rendimiento" })[String(modelData)]
                  || String(modelData).charAt(0).toUpperCase() + String(modelData).slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeProfile === modelData
                hasCursor: root.cursorActive && root.profileIndex === index
                onClicked: root.setProfile(modelData)
                onHovered: function(h) {
                  if (h) {
                    root.cursorActive = true
                    root.profileIndex = index
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // Gráfica de área del % de batería en el rango elegido: eje X = tiempo
  // (de hace N h a ahora), guías al 0/50/100 %, tramos cargando en acento.
  component HistoryChart: Item {
    id: chart
    readonly property real labelWidth: Style.space(30)
    readonly property real axisHeight: Style.space(14)

    // Guías horizontales y su etiqueta.
    Repeater {
      model: [100, 50, 0]

      Item {
        required property var modelData
        x: 0
        width: chart.width
        y: (chart.height - chart.axisHeight) * (1 - modelData / 100)

        Rectangle {
          x: chart.labelWidth
          width: chart.width - chart.labelWidth
          height: 1
          color: Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.12)
        }

        Text {
          anchors.verticalCenter: parent.top
          textFormat: Text.PlainText
          text: parent.modelData + "%"
          color: root.bar.foreground
          opacity: 0.5
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }

    Canvas {
      id: plot
      x: chart.labelWidth
      width: chart.width - chart.labelWidth
      height: chart.height - chart.axisHeight
      renderStrategy: Canvas.Cooperative

      property var points: root.historyPoints
      property color fg: root.bar.foreground
      property color accent: Color.accent
      onPointsChanged: requestPaint()
      onFgChanged: requestPaint()
      onAccentChanged: requestPaint()
      onWidthChanged: requestPaint()

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var pts = points || []
        if (pts.length < 2) return
        var now = Date.now() / 1000
        var span = root.historyHours * 3600
        var px = function(t) { return Math.max(0, Math.min(width, width * (1 - (now - t) / span))) }
        var py = function(v) { return height * (1 - Math.max(0, Math.min(100, v)) / 100) }
        // Cada intervalo se clasifica por su pendiente: si el % sube, está
        // cargando; si baja, con batería; si es llano, hereda el anterior
        // (el primero llano usa el estado de UPower). Se agrupan los
        // intervalos consecutivos de la misma clase en un tramo.
        var seg = [pts[0]]
        var segCharging = pts[0].s === 1 || pts[0].s === 4
        var flush = function() {
          if (seg.length < 2) return
          var c = segCharging ? accent : fg
          ctx.beginPath()
          ctx.moveTo(px(seg[0].t), height)
          for (var i = 0; i < seg.length; i++) ctx.lineTo(px(seg[i].t), py(seg[i].v))
          ctx.lineTo(px(seg[seg.length - 1].t), height)
          ctx.closePath()
          ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 0.18)
          ctx.fill()
          ctx.beginPath()
          for (var j = 0; j < seg.length; j++) {
            if (j === 0) ctx.moveTo(px(seg[j].t), py(seg[j].v))
            else ctx.lineTo(px(seg[j].t), py(seg[j].v))
          }
          ctx.strokeStyle = c
          ctx.lineWidth = 2
          ctx.lineJoin = "round"
          ctx.stroke()
        }
        for (var k = 1; k < pts.length; k++) {
          var dv = pts[k].v - pts[k - 1].v
          var up = dv > 0 ? true : (dv < 0 ? false : segCharging)
          if (up !== segCharging && seg.length >= 2) {
            flush()
            seg = [pts[k - 1]]
          }
          segCharging = up
          seg.push(pts[k])
        }
        flush()
      }
    }

    // Eje de tiempo: hace N h · mitad · ahora.
    Repeater {
      model: 3

      Text {
        required property int index
        y: chart.height - chart.axisHeight + Style.space(2)
        x: chart.labelWidth + (plot.width - implicitWidth) * index / 2
        textFormat: Text.PlainText
        text: index === 2 ? "ahora" : "-" + (root.historyHours * (2 - index) / 2) + " h"
        color: root.bar.foreground
        opacity: 0.5
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      anchors.centerIn: plot
      visible: root.historyPoints.length < 2
      textFormat: Text.PlainText
      text: "Sin datos de UPower todavía"
      color: root.bar.foreground
      opacity: 0.5
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2); height: 1 }
    InfoValue { text: value }
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
