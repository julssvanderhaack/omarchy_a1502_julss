import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.monitor"
  ipcTarget: "omarchy.monitor"
  manageIpc: false

  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the brightness + state methods below.
  property int brightnessPercent: 0
  property int pendingBrightnessPercent: 0
  property bool brightnessSetQueued: false
  property bool brightnessAvailable: false
  property string internalMonitor: ""
  property string externalMonitor: ""
  property string focusedMonitor: ""
  property bool internalEnabled: false
  property bool mirrorEnabled: false
  property string monitorScale: ""
  property var displays: []
  property int enabledDisplayCount: 0

  // julss: apariencia (tema, fondo, paleta GTK, iconos, cursor) vía
  // ~/.local/bin/julss-appearance, que devuelve opciones y valores en JSON.
  property var appearance: ({})
  property bool appearanceBusy: false

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  // Cursor model shared by keyboard and mouse. Sections:
  //   "brightness" - single slider row, selectedIndex = -1 sentinel
  //                  (mirrors Audio's slider rows). Only present if a
  //                  controllable backlight was detected.
  //   "scale"      - 6 Button scale presets; treated as a single
  //                  horizontal row from j/k's perspective. h/l moves
  //                  between presets, identical to bluetooth's header.
  //   "monitors"   - vertical display row list for enabling/disabling displays;
  //                  j/k walks each row.
  // Mouse hover on a target updates root state via the components' `hovered`
  // signal so keyboard cursor and pointer share one highlight.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.availableScales(scalePresets, display.width, display.height)
    }
    return scalePresets
  }
  property string focusSection: "scale"
  property int selectedIndex: 0
  property bool cursorActive: false

  // Text size slider — curated macOS-style notches (px). The panel snaps to
  // these stops; the CLI (omarchy-display-text-size) accepts any integer in range.
  readonly property var textSizeStops: [9, 10, 11, 12, 14, 16, 20]
  // While a change is in flight, the chosen stop index overrides the live
  // base-size so the knob doesn't snap back during the file round-trip. -1 =
  // no pending change; follow Style.font.baseSize.
  property int textSizePreviewIndex: -1

  // A text-size change reflows the whole panel (both font and spacing scale),
  // which slides rows under a stationary pointer and fires synthetic hover.
  // While true, hover is not allowed to hijack the keyboard focus section —
  // otherwise h/l on the text-size slider can jump focus to another row.
  property bool reflowingText: false
  function markReflowing() {
    root.reflowingText = true
    reflowSettle.restart()
  }

  readonly property var visibleSections: {
    var list = []
    if (brightnessAvailable) list.push("brightness")
    list.push("textsize")
    list.push("scale")
    if (displays.length > 1) list.push("monitors")
    return list
  }

  function sectionCount(section) {
    if (section === "brightness") return 0  // only the slider sentinel at -1
    if (section === "textsize") return 0    // slider sentinel at -1, like brightness
    if (section === "scale") return scaleValues.length
    if (section === "monitors") return displays.length
    return 0
  }

  function sectionIsSingleRow(section) {
    // brightness and text size are lone sliders; scale presets sit horizontally.
    return section === "brightness" || section === "textsize" || section === "scale"
  }

  function sectionFirstIndex(section) {
    if (section === "brightness" || section === "textsize") return -1
    return 0
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections || sections.length === 0) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var inSingleRow = sectionIsSingleRow(focusSection)
    var max = inSingleRow ? 0 : sectionCount(focusSection) - 1

    if (delta > 0) {
      if (!inSingleRow && selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionFirstIndex(focusSection)
      }
    } else {
      if (!inSingleRow && selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        // Coming up from below — land on the last navigable row of the prev
        // section, or its sentinel for single-row sections.
        selectedIndex = sectionIsSingleRow(prev) ? sectionFirstIndex(prev) : sectionCount(prev) - 1
      }
    }
  }

  // h/l: in scale section, walks the preset row; everywhere else, no-op
  // because adjustBrightness handles horizontal motion on the brightness
  // slider.
  function moveCursorH(delta) {
    if (focusSection !== "scale") return
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > scaleValues.length - 1) next = scaleValues.length - 1
    selectedIndex = next
  }

  function adjustBrightness(delta) {
    if (focusSection !== "brightness") return
    if (!brightnessAvailable) return
    setBrightness(root.brightnessPercent + delta)
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
      return
    }
    if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
    // brightness: no separate action; the slider value is the action.
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    var count = sectionCount(focusSection)
    if (sectionIsSingleRow(focusSection)) {
      // brightness/text size use the -1 sentinel; scale clamps into the presets.
      if (focusSection === "brightness" || focusSection === "textsize") selectedIndex = -1
      else if (selectedIndex < 0 || selectedIndex >= count) selectedIndex = 0
      return
    }
    if (count === 0) {
      var sIdx = sections.indexOf(focusSection)
      focusSection = sIdx > 0 ? sections[sIdx - 1] : sections[0]
      selectedIndex = sectionFirstIndex(focusSection)
      return
    }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Keep the keyboard-focused row inside the viewport when the panel grows
  // taller than its allotted height (lots of displays). Mirrors audio's
  // ensureCursorVisible helper.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    var margin = 6
    if (top < viewTop + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > viewBottom - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function brightnessIpc(percent) {
    var value = Number(percent)
    root.setBrightness(value)
    return "got " + root.pendingBrightnessPercent
  }

  function stateIpc() {
    return JSON.stringify({
      brightness: root.brightnessPercent,
      brightnessAvailable: root.brightnessAvailable,
      focusedMonitor: root.focusedMonitor,
      scale: root.monitorScale,
      displays: root.displays
    })
  }

  IpcHandler {
    target: "omarchy.monitor"

    function brightness(percent: string): string { return root.brightnessIpc(percent) }
    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  // Abre el plugin Monitor Layout; la regla de Hyprland en hyprland.lua lo
  // pone flotante y centrado.
  function openMonitorLayout() {
    root.close()
    Quickshell.execDetached(["omarchy-shell", "shell", "summon", "io.github.cjgarcia1229.monitor-layout", "{}"])
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
    refreshAppearance()
  }

  function refreshAppearance() {
    if (!appearanceProc.running) appearanceProc.running = true
  }

  // ---- Barra (julss): posición, transparencia y color de fondo ----
  readonly property var barPositions: [
    { value: "top", label: "Arriba" },
    { value: "bottom", label: "Abajo" },
    { value: "left", label: "Izquierda" },
    { value: "right", label: "Derecha" }
  ]
  // Mientras se arrastra, el valor elegido manda sobre el leído del disco.
  property int barTransparencyPreview: -1

  function barTransparency() {
    return barTransparencyPreview >= 0 ? barTransparencyPreview : (appearance.barTransparency || 0)
  }

  function setBar(key, value) {
    Quickshell.execDetached(["julss-appearance", "set", key, String(value)])
    barRefresh.restart()
  }

  function previewBarTransparency(v) {
    root.barTransparencyPreview = Math.round(v)
    barTransparencyDebounce.restart()
  }

  function openBgDir() {
    root.close()
    Quickshell.execDetached(["julss-appearance", "open-bg-dir"])
  }

  function setAppearance(key, value) {
    if (!value || value === root.appearance[key]) return
    var cmd = ["julss-appearance", "set", key, value]
    if (appearanceSetProc.running) { Quickshell.execDetached(cmd); return }
    root.appearanceBusy = true
    appearanceSetProc.command = cmd
    appearanceSetProc.running = true
  }

  function setBrightness(value) {
    var percent = Model.clampBrightness(value)
    root.brightnessPercent = percent
    root.pendingBrightnessPercent = percent

    if (setBrightnessProc.running) {
      root.brightnessSetQueued = true
      return
    }

    root.brightnessSetQueued = false
    setBrightnessProc.command = ["omarchy-brightness-display", "--no-osd", "--monitor", root.focusedMonitor, percent + "%"]
    setBrightnessProc.running = true
  }

  function previewBrightness(value) {
    root.brightnessPercent = Model.clampBrightness(value)
    brightnessDebounce.restart()
  }

  function showBrightnessOsd(percent) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "brightness",
      value: percent
    }))
  }

  function normalizeScale(scale) {
    return Model.normalizeScale(scale)
  }

  function activeScaleIndex() {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.matchingScaleIndex(scaleValues, monitorScale, display.width, display.height)
    }
    return -1
  }

  function effectiveScale(scale) {
    for (var i = 0; i < displays.length; i++) {
      var display = displays[i]
      if (display && display.focused)
        return Model.cleanScale(scale, display.width, display.height)
    }
    return normalizeScale(scale)
  }

  // Playful mood-name for a given brightness percent. Bands intentionally
  // span ~10–20 points so casual tweaks change the label, while small
  // nudges within one band don't.
  function brightnessName(percent) {
    return Model.brightnessName(percent)
  }

  function updateDisplays(displaysJson) {
    var parsed = Model.parseDisplays(displaysJson)
    root.displays = parsed.displays
    root.enabledDisplayCount = parsed.enabledDisplayCount
  }

  function toggleDisplay(name, enabled) {
    if (!name) return
    if (enabled && root.enabledDisplayCount <= 1) return

    actionProc.command = ["hyprctl", "keyword", "monitor", name + (enabled ? ",disable" : ",preferred,auto,auto")]
    if (!actionProc.running) actionProc.running = true
  }

  function setScale(scale) {
    actionProc.command = ["bash", "-c", "omarchy-hyprland-monitor-scaling " + scale]
    if (!actionProc.running) actionProc.running = true
  }

  // ---- Text size (shell base font + GTK text-scaling, via one CLI) ----
  function nearestTextStop(px) {
    var best = 0
    var bestDist = 1e9
    for (var i = 0; i < textSizeStops.length; i++) {
      var d = Math.abs(textSizeStops[i] - px)
      if (d < bestDist) { bestDist = d; best = i }
    }
    return best
  }

  // Effective stop index: the pending choice while a change is in flight,
  // otherwise whatever Style's live base-size rounds to.
  function currentTextIndex() {
    return textSizePreviewIndex >= 0 ? textSizePreviewIndex : nearestTextStop(Style.font.baseSize)
  }

  // px shown in the header: the pending stop if any, else the true base-size
  // (which may be an off-notch value set from the CLI).
  function displayedTextPx() {
    return textSizePreviewIndex >= 0 ? textSizeStops[textSizePreviewIndex] : Style.font.baseSize
  }

  function setTextSize(px) {
    textScaleProc.command = ["omarchy-display-text-size", String(px)]
    if (!textScaleProc.running) textScaleProc.running = true
  }

  function adjustTextSize(deltaSteps) {
    var idx = currentTextIndex() + deltaSteps
    if (idx < 0) idx = 0
    if (idx > textSizeStops.length - 1) idx = textSizeStops.length - 1
    markReflowing()
    textSizePreviewIndex = idx
    setTextSize(textSizeStops[idx])
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  // KeyboardPanel primes focus at open-time, so SUPER-bound IPC summons land
  // with j/k ready to navigate. Keep a default landing point, but don't paint
  // the cursor until hover or the first navigation key.
  onOpenedChanged: {
    if (opened) {
      refresh()
      if (brightnessAvailable) {
        focusSection = "brightness"
        selectedIndex = -1
      } else {
        focusSection = "scale"
        selectedIndex = 0
      }
      cursorActive = false
    }
  }

  onBrightnessAvailableChanged: clampCursor()
  onDisplaysChanged: clampCursor()
  onScaleValuesChanged: clampCursor()
  onVisibleSectionsChanged: clampCursor()

  // Only poll while the panel is open; the bar glyph tracks monitor count via
  // Quickshell.screens, and open-time refresh + Component.onCompleted cover the
  // rest. External brightness changes are reflected whenever the panel is open.
  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: ["omarchy-monitor-state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var brightness = String(lines[0] || "").trim()
        root.brightnessAvailable = brightness !== "unavailable" && brightness !== ""
        root.brightnessPercent = root.brightnessAvailable ? Math.max(0, Math.min(100, parseInt(brightness, 10))) : 0
        root.internalMonitor = String(lines[1] || "").trim()
        root.externalMonitor = String(lines[2] || "").trim()
        root.internalEnabled = String(lines[3] || "").trim() !== ""
        root.mirrorEnabled = String(lines[4] || "").trim() === root.externalMonitor && root.externalMonitor !== ""
        root.focusedMonitor = String(lines[5] || "").trim()
        root.monitorScale = root.normalizeScale(String(lines[6] || "").trim())
        root.updateDisplays(String(lines[7] || "[]").trim())
      }
    }
  }

  Process {
    id: appearanceProc
    command: ["julss-appearance", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.appearance = JSON.parse(String(text || "{}")) } catch (e) { return }
        // Dropdown rompe su binding de value al elegir; se reasigna a mano.
        themeDropdown.value = root.appearance.theme || ""
        bgDropdown.value = root.appearance.bg || ""
        gtkDropdown.value = root.appearance.gtk || ""
        iconsDropdown.value = root.appearance.icons || ""
        cursorDropdown.value = root.appearance.cursor || ""
      }
    }
  }

  Timer {
    id: barTransparencyDebounce
    interval: 120
    onTriggered: root.setBar("bar-transparency", root.barTransparencyPreview)
  }

  // Relee el estado tras escribir (el cambio en sí ya se ve al momento).
  Timer {
    id: barRefresh
    interval: 400
    onTriggered: {
      root.barTransparencyPreview = -1
      root.refreshAppearance()
    }
  }

  Process {
    id: appearanceSetProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) {
      root.appearanceBusy = false
      root.refreshAppearance()
    }
  }

  Timer {
    id: brightnessDebounce
    interval: 180
    repeat: false
    onTriggered: root.setBrightness(root.brightnessPercent)
  }

  Process {
    id: setBrightnessProc
    stdout: StdioCollector { waitForEnd: true }
    // Do NOT call refresh() after a brightness set completes. The local
    // brightnessPercent we just wrote is authoritative; re-reading via
    // `omarchy-brightness-display` races the hardware/driver and can
    // return an empty string, which the parser then coerces to 0 —
    // visible as a "bounce to zero" after h/l keypresses. External
    // brightness changes are still picked up by the 5s periodic refresh,
    // the open-time refresh, and Component.onCompleted.
    onRunningChanged: {
      if (running) return
      if (root.brightnessSetQueued) {
        root.setBrightness(root.pendingBrightnessPercent)
      }
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // Applies text size via the CLI, which rewrites the shell override file;
  // Style picks the new base-size up through its own file watch, so there's
  // nothing to refresh here.
  Process {
    id: textScaleProc
    stdout: StdioCollector { waitForEnd: true }
  }

  // Clears the hover-suppression flag once the reflow triggered by a text-size
  // change has settled.
  Timer {
    id: reflowSettle
    interval: 300
    repeat: false
    onTriggered: root.reflowingText = false
  }

  // Once Style's base-size catches up to the pending choice, drop the preview
  // so the slider tracks the live value again. The change itself reflows the
  // panel, so suppress hover for a beat while it lands.
  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textSizePreviewIndex >= 0
          && root.nearestTextStop(Style.font.baseSize) === root.textSizePreviewIndex)
        root.textSizePreviewIndex = -1
    }
  }

  BarIconButton {
    // julss: ranura más estrecha que la de Omarchy para juntar los iconos
    // de la derecha (la flecha de la bandeja chocaba con los indicadores).
    slotSize: Style.bar.iconSlot - Style.space(4)
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: function(b) { root.toggle() }
    onWheelMoved: function(delta) {
      if (!root.brightnessAvailable) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightnessPercent + wheel.steps * 5)
      root.showBrightnessOsd(root.brightnessPercent)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(780))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(740))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) {
          if (root.focusSection === "brightness") root.adjustBrightness(dx * 5)
          else if (root.focusSection === "textsize") root.adjustTextSize(dx)
          else if (root.focusSection === "scale") root.moveCursorH(dx)
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: display icon · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: root.displays.length > 1 ? "󰍺" : "󰍹"
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
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Pantalla"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: {
                  if (root.brightnessAvailable) {
                    return root.brightnessName(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent).toUpperCase()
                  }
                  return "BRILLO FIJO"
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
          }

          // julss: dos columnas para que el panel no necesite scroll.
          Row {
            id: columnsRow
            width: parent.width
            spacing: Style.space(24)

            // Pantalla: brillo, texto, escala y barra.
            Column {
              id: leftColumn
              width: (columnsRow.width - columnsRow.spacing) / 2
              spacing: Style.space(14)

                  // ---------- Brightness ----------
                  PanelSeparator {
                    visible: root.brightnessAvailable
                    foreground: root.bar.foreground
                  }

                  Column {
                    visible: root.brightnessAvailable
                    width: parent.width
                    spacing: Style.space(6)

                    Item {
                      width: parent.width
                      implicitHeight: Math.max(brightnessHeader.implicitHeight, brightnessPercent.implicitHeight)

                      PanelSectionHeader {
                        id: brightnessHeader
                        text: "BRILLO"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        id: brightnessPercent
                        textFormat: Text.PlainText
                        text: Math.round(brightnessSlider.dragging ? brightnessSlider.liveValue : root.brightnessPercent) + "%"
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    CursorSurface {
                      id: brightnessRow
                      width: parent.width
                      height: brightnessSlider.implicitHeight + Style.spacing.controlGap
                      hasCursor: root.cursorActive && root.focusSection === "brightness" && root.selectedIndex === -1
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(brightnessRow)
                      foreground: root.bar.foreground
                      outline: true

                      PanelSlider {
                        id: brightnessSlider
                        bar: root.bar
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(6)
                        anchors.rightMargin: Style.space(6)
                        minimum: 1
                        maximum: 100
                        step: 1
                        value: root.brightnessPercent
                        integer: true
                        onMoved: function(v) { root.previewBrightness(v) }
                        onReleased: function(v) {
                          brightnessDebounce.stop()
                          root.setBrightness(v)
                        }
                      }

                      HoverHandler {
                        onHoveredChanged: if (hovered && !root.reflowingText) {
                          root.cursorActive = true
                          root.focusSection = "brightness"
                          root.selectedIndex = -1
                        }
                      }
                    }
                  }

                  // ---------- Text size ----------
                  PanelSeparator {
                    foreground: root.bar.foreground
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(6)

                    Item {
                      width: parent.width
                      implicitHeight: Math.max(textSizeHeader.implicitHeight, textSizePx.implicitHeight)

                      PanelSectionHeader {
                        id: textSizeHeader
                        text: "TAMAÑO DE TEXTO"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        id: textSizePx
                        textFormat: Text.PlainText
                        text: (textSizeSlider.dragging
                               ? root.textSizeStops[Math.round(textSizeSlider.liveValue)]
                               : root.displayedTextPx()) + "px"
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    CursorSurface {
                      id: textSizeRow
                      width: parent.width
                      height: textSizeSlider.implicitHeight + Style.spacing.controlGap
                      hasCursor: root.cursorActive && root.focusSection === "textsize" && root.selectedIndex === -1
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(textSizeRow)
                      foreground: root.bar.foreground
                      outline: true

                      PanelSlider {
                        id: textSizeSlider
                        bar: root.bar
                        anchors.fill: parent
                        anchors.leftMargin: Style.space(6)
                        anchors.rightMargin: Style.space(6)
                        minimum: 0
                        maximum: root.textSizeStops.length - 1
                        step: 1
                        integer: true
                        tickCount: root.textSizeStops.length
                        value: root.currentTextIndex()
                        onReleased: function(v) { root.setTextSize(root.textSizeStops[Math.round(v)]) }
                      }

                      HoverHandler {
                        onHoveredChanged: if (hovered && !root.reflowingText) {
                          root.cursorActive = true
                          root.focusSection = "textsize"
                          root.selectedIndex = -1
                        }
                      }
                    }
                  }

                  // ---------- Scale ----------
                  PanelSeparator {
                    foreground: root.bar.foreground
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(10)

                    Item {
                      width: parent.width
                      implicitHeight: Math.max(scaleHeader.implicitHeight, scaleMonitor.implicitHeight)

                      PanelSectionHeader {
                        id: scaleHeader
                        text: "ESCALA"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      // Name the monitor SCALE targets, since it only applies to the
                      // focused one.
                      Text {
                        id: scaleMonitor
                        textFormat: Text.PlainText
                        text: root.focusedMonitor
                        // Only worth naming when more than one display is in play.
                        visible: root.focusedMonitor !== "" && root.enabledDisplayCount > 1
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    Grid {
                      id: scaleRow
                      width: parent.width
                      columns: root.scaleValues.length
                      spacing: Style.spacing.xs

                      readonly property real cellWidth: root.scaleValues.length > 0
                        ? (width - spacing * (columns - 1)) / columns
                        : 0

                      Repeater {
                        model: root.scaleValues

                        ScalePill {
                          required property string modelData
                          required property int index

                          scaleValue: modelData
                          scaleIndex: index
                          width: scaleRow.cellWidth
                        }
                      }
                    }
                  }

                  // ---------- Barra (julss) ----------
                  PanelSeparator {
                    foreground: root.bar.foreground
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(10)

                    PanelSectionHeader {
                      text: "BARRA"
                      foreground: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                    }

                    Grid {
                      id: barPositionRow
                      width: parent.width
                      columns: root.barPositions.length
                      spacing: Style.spacing.xs
                      readonly property real cellWidth: (width - spacing * (columns - 1)) / columns

                      Repeater {
                        model: root.barPositions

                        Button {
                          required property var modelData
                          width: barPositionRow.cellWidth
                          text: modelData.label
                          fontSize: Style.font.caption
                          foreground: root.bar.foreground
                          fontFamily: root.bar.fontFamily
                          horizontalPadding: Style.spacing.xs
                          verticalPadding: Style.spacing.controlPaddingY
                          bordered: true
                          active: (root.appearance.barPosition || "top") === modelData.value
                          onClicked: root.setBar("bar-position", modelData.value)
                        }
                      }
                    }

                    Item {
                      width: parent.width
                      implicitHeight: barTransparencyLabel.implicitHeight

                      Text {
                        id: barTransparencyLabel
                        textFormat: Text.PlainText
                        text: "Transparencia"
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.left: parent.left
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: Math.round(barTransparencySlider.dragging ? barTransparencySlider.liveValue : root.barTransparency()) + "%"
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                      }
                    }

                    PanelSlider {
                      id: barTransparencySlider
                      bar: root.bar
                      width: parent.width - Style.space(12)
                      x: Style.space(6)
                      minimum: 0
                      maximum: 100
                      step: 5
                      integer: true
                      value: root.barTransparency()
                      onMoved: function(v) { root.previewBarTransparency(v) }
                      onReleased: function(v) {
                        barTransparencyDebounce.stop()
                        root.barTransparencyPreview = Math.round(v)
                        root.setBar("bar-transparency", Math.round(v))
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: "Color de fondo"
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }

                    // Muestras de la paleta del tema; la primera es la del tema
                    // (quita el color propio). Al cambiar de tema vuelve la del tema.
                    Flow {
                      width: parent.width
                      spacing: Style.spacing.xs

                      BarSwatch {
                        swatchColor: root.appearance.themeBarColor || "#000000"
                        isTheme: true
                        selected: !root.appearance.barColor
                      }

                      Repeater {
                        model: root.appearance.barSwatches || []

                        BarSwatch {
                          required property string modelData
                          swatchColor: modelData
                          selected: root.appearance.barColor === modelData
                        }
                      }
                    }

                    Row {
                      width: parent.width
                      spacing: Style.spacing.xs

                      TextField {
                        id: barHexField
                        width: parent.width - barHexApply.width - parent.spacing
                        placeholderText: "#rrggbb"
                        text: root.appearance.barColor || ""
                        foreground: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                        onAccepted: barHexApply.clicked()
                      }

                      Button {
                        id: barHexApply
                        text: "Aplicar"
                        height: barHexField.height
                        fontSize: Style.font.caption
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        bordered: true
                        onClicked: {
                          var hex = String(barHexField.text || "").trim()
                          if (hex.charAt(0) !== "#") hex = "#" + hex
                          if (/^#[0-9a-fA-F]{6}$/.test(hex)) root.setBar("bar-color", hex.toLowerCase())
                        }
                      }
                    }
                  }

            }

            // Apariencia, pantallas y distribución.
            Column {
              id: rightColumn
              width: (columnsRow.width - columnsRow.spacing) / 2
              spacing: Style.space(14)

                  // ---------- Apariencia (julss) ----------
                  PanelSeparator {
                    foreground: root.bar.foreground
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(10)

                    Item {
                      width: parent.width
                      implicitHeight: appearanceHeader.implicitHeight

                      PanelSectionHeader {
                        id: appearanceHeader
                        text: "APARIENCIA"
                        foreground: root.bar.foreground
                        fontFamily: root.bar.fontFamily
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: "APLICANDO…"
                        visible: root.appearanceBusy
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        anchors.right: parent.right
                        anchors.rightMargin: Style.space(6)
                        anchors.verticalCenter: parent.verticalCenter
                      }
                    }

                    AppearanceDropdown { id: themeDropdown; label: "Tema de Omarchy"; key: "theme"; options: root.appearance.themes || [] }
                    // Fondo + botón para abrir ~/.config/omarchy/backgrounds/<tema>,
                    // donde van los fondos extra de ese tema.
                    Column {
                      width: parent.width
                      spacing: Style.spacing.labelGap

                      Text {
                        textFormat: Text.PlainText
                        text: "Fondo de pantalla"
                        color: Qt.darker(root.bar.foreground, 1.4)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }

                      Row {
                        width: parent.width
                        spacing: Style.spacing.xs

                        AppearanceDropdown {
                          id: bgDropdown
                          key: "bg"
                          showLabel: false
                          options: root.appearance.bgs || []
                          width: parent.width - bgFolderButton.width - parent.spacing
                        }

                        Button {
                          id: bgFolderButton
                          width: height
                          height: bgDropdown.height
                          iconText: "󰉋"
                          tooltipText: "Abrir la carpeta de fondos extra de este tema"
                          foreground: root.bar.foreground
                          fontFamily: root.bar.fontFamily
                          bordered: true
                          onClicked: root.openBgDir()
                        }
                      }
                    }

                    AppearanceDropdown { id: gtkDropdown; label: "Tema GTK"; key: "gtk"; options: root.appearance.gtks || [] }
                    AppearanceDropdown { id: iconsDropdown; label: "Iconos"; key: "icons"; options: root.appearance.iconThemes || [] }
                    AppearanceDropdown { id: cursorDropdown; label: "Cursor"; key: "cursor"; options: root.appearance.cursors || [] }
                  }

                  // ---------- Monitors ----------
                  PanelSeparator {
                    visible: root.displays.length > 1
                    foreground: root.bar.foreground
                  }

                  Column {
                    width: parent.width
                    spacing: Style.space(10)
                    visible: root.displays.length > 1

                    PanelSectionHeader {
                      text: "PANTALLAS"
                      foreground: root.bar.foreground
                      fontFamily: root.bar.fontFamily
                    }

                    Repeater {
                      model: root.displays

                      MonitorRow {
                        required property var modelData
                        required property int index

                        width: rightColumn.width
                        display: modelData
                        rowIndex: index
                      }
                    }
                  }

                  // ---------- Monitor Layout (plugin io.github.cjgarcia1229.monitor-layout) ----------
                  PanelSeparator {
                    foreground: root.bar.foreground
                  }

                  Button {
                    width: parent.width
                    iconText: "󰍺"
                    text: "Distribución de pantallas"
                    tooltipText: "Abrir Distribución de pantallas"
                    foreground: root.bar.foreground
                    fontFamily: root.bar.fontFamily
                    bordered: true
                    onClicked: root.openMonitorLayout()
                  }

            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component BarSwatch: Rectangle {
    id: swatch
    property string swatchColor: "#000000"
    property bool isTheme: false
    property bool selected: false

    width: Style.space(26)
    height: Style.space(26)
    radius: Style.cornerRadius
    color: swatchColor
    border.width: selected ? Math.max(2, Style.space(2)) : 1
    border.color: selected ? Color.accent : Qt.rgba(root.bar.foreground.r, root.bar.foreground.g, root.bar.foreground.b, 0.35)

    // La muestra del tema lleva una «T» para distinguirla.
    Text {
      anchors.centerIn: parent
      visible: swatch.isTheme
      text: "T"
      color: Qt.colorEqual(swatch.swatchColor, "transparent") ? root.bar.foreground
        : ((swatch.color.r * 0.299 + swatch.color.g * 0.587 + swatch.color.b * 0.114) > 0.55 ? "#000000" : "#ffffff")
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.setBar("bar-color", swatch.isTheme ? "theme" : swatch.swatchColor)
    }
  }

  component AppearanceDropdown: Dropdown {
    required property string key
    width: rightColumn.width
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    onChanged: function(v) { root.setAppearance(key, v) }
  }

  component ScalePill: Button {
    id: pill
    required property string scaleValue
    required property int scaleIndex

    text: root.effectiveScale(scaleValue) + "x"
    fontSize: Style.font.caption
    foreground: root.bar.foreground
    fontFamily: root.bar.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true

    active: root.activeScaleIndex() === scaleIndex
    hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === scaleIndex

    onClicked: root.setScale(scaleValue)
    onHovered: function(isHovered) {
      if (!isHovered || root.reflowingText) return
      root.cursorActive = true
      root.focusSection = "scale"
      root.selectedIndex = pill.scaleIndex
    }
  }

  component MonitorRow: CursorSurface {
    id: monitorRow
    required property var display
    required property int rowIndex

    readonly property bool isFocused: display && display.focused
    readonly property bool canToggle: display && (!display.enabled || root.enabledDisplayCount > 1)

    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(monitorRow)
    current: isFocused
    foreground: root.bar.foreground
    fill: Style.hoverFillFor(root.bar.foreground, Color.accent)
    currentFill: Style.selectedFillFor(root.bar.foreground, Color.accent)
    implicitHeight: monitorInner.implicitHeight + Style.spacing.xl
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: monitorInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "󰍹"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.name + (monitorRow.display.focused ? " · activa" : "")
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        width: parent.width - Style.space(22) - Style.space(14) - Style.space(16)
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: monitorRow.display.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: monitorRow.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse && !root.reflowingText) {
        root.cursorActive = true
        root.focusSection = "monitors"
        root.selectedIndex = monitorRow.rowIndex
      }
      onClicked: if (monitorRow.canToggle) root.toggleDisplay(monitorRow.display.name, monitorRow.display.enabled)
    }
  }
}
