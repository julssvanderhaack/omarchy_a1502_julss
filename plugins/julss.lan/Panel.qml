import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Dispositivos de la red local. El escaneo lo hace scripts/scan.py (ping en
// paralelo + tabla de vecinos + mDNS/DNS/NetBIOS/UPnP para los nombres) y
// guarda un historial para enseñar también lo visto en las últimas 24 h.
Panel {
  id: root
  moduleName: "julss.lan"
  ipcTarget: "julss.lan"

  property var anchorItem: null
  property var hostWidget: null

  property var devices: []
  property var recent: []
  property string network: ""
  property int scannedAt: 0
  property string scanError: ""
  property double nowTick: Date.now()

  // Nombres puestos por nosotros, por MAC: ~/.local/state/julss-lan/aliases.json
  property var aliases: ({})
  property string editingMac: ""

  // Iconos elegidos por nosotros, por MAC: ~/.local/state/julss-lan/icons.json
  // ({ mac: glyph }). El anterior de cada uno va en icons-previous.json para
  // poder deshacer ("" = el icono automático).
  property var customIcons: ({})
  property var previousIcons: ({})
  property string iconPickerMac: ""
  readonly property var iconChoices: [
    { glyph: "󰑩", label: "Router" },
    { glyph: "󰌢", label: "Portátil" },
    { glyph: "󰇄", label: "Ordenador" },
    { glyph: "󰄜", label: "Móvil" },
    { glyph: "󰓶", label: "Tablet" },
    { glyph: "󰔂", label: "Televisión" },
    { glyph: "󰓃", label: "Altavoz" },
    { glyph: "󰊴", label: "Consola" },
    { glyph: "󰐪", label: "Impresora" },
    { glyph: "󰄀", label: "Cámara" },
    { glyph: "󰌵", label: "Bombilla" },
    { glyph: "󰚥", label: "Enchufe" },
    { glyph: "󰖉", label: "Reloj" },
    { glyph: "󰒋", label: "Servidor / NAS" },
    { glyph: "󰖩", label: "Repetidor Wi-Fi" },
    { glyph: "󰋋", label: "Auriculares" },
    { glyph: "󰾰", label: "Otro" }
  ]

  property FileView iconFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/julss-lan/icons.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.customIcons = JSON.parse(text() || "{}") } catch (e) { root.customIcons = {} }
    }
    onLoadFailed: root.customIcons = {}
  }

  property FileView previousIconFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/julss-lan/icons-previous.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.previousIcons = JSON.parse(text() || "{}") } catch (e) { root.previousIcons = {} }
    }
    onLoadFailed: root.previousIcons = {}
  }

  // El icono "por defecto" del selector: el que tenía antes del último cambio.
  function previousIconFor(d) {
    if (!d || !d.mac || !(d.mac in root.previousIcons)) return ""
    return root.previousIcons[d.mac] || ""
  }

  function hasPreviousIcon(d) {
    return !!d && !!d.mac && (d.mac in root.previousIcons)
  }

  function automaticIcon(d) {
    if (d.gateway) return "󰑩"
    if (d.self) return "󰌢"
    var v = String(d.vendor || "").toLowerCase()
    var n = String(root.displayName(d) || "").toLowerCase()
    if (n.indexOf("tv") !== -1 || v.indexOf("samsung") !== -1 && n.indexOf("[tv]") !== -1) return "󰔂"
    if (v.indexOf("amazon") !== -1) return "󰓃"
    if (v.indexOf("aleatoria") !== -1) return "󰄜"
    if (v.indexOf("print") !== -1 || v.indexOf("epson") !== -1 || v.indexOf("brother") !== -1 || v.indexOf("hp ") === 0) return "󰐪"
    return "󰾰"
  }

  function toggleIconPicker(d) {
    if (!d || !d.mac) return
    root.editingMac = ""
    root.iconPickerMac = root.iconPickerMac === d.mac ? "" : d.mac
  }

  function setIcon(mac, glyph) {
    var current = root.customIcons[mac] || ""
    if (current !== (glyph || "")) {
      var prev = JSON.parse(JSON.stringify(root.previousIcons))
      prev[mac] = current
      root.previousIcons = prev
      previousIconFile.setText(JSON.stringify(prev, null, 1) + "\n")
    }
    var next = JSON.parse(JSON.stringify(root.customIcons))
    if (glyph) next[mac] = glyph
    else delete next[mac]
    root.customIcons = next
    iconFile.setText(JSON.stringify(next, null, 1) + "\n")
    root.iconPickerMac = ""
  }
  property string toast: ""

  property FileView aliasFile: FileView {
    path: Quickshell.env("HOME") + "/.local/state/julss-lan/aliases.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try { root.aliases = JSON.parse(text() || "{}") } catch (e) { root.aliases = {} }
    }
    onLoadFailed: root.aliases = {}
  }

  function displayName(d) {
    var alias = d && d.mac ? root.aliases[d.mac] : ""
    return alias || d.name || ""
  }

  function startRename(d) {
    if (!d || !d.mac) return
    root.iconPickerMac = ""
    root.editingMac = d.mac
  }

  function finishRename(mac, value) {
    var next = JSON.parse(JSON.stringify(root.aliases))
    var name = String(value || "").trim()
    if (name) next[mac] = name
    else delete next[mac]
    root.aliases = next
    aliasFile.setText(JSON.stringify(next, null, 1) + "\n")
    root.editingMac = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function cancelRename() {
    root.editingMac = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function showToast(text) {
    root.toast = text
    toastTimer.restart()
  }

  Timer {
    id: toastTimer
    interval: 2000
    onTriggered: root.toast = ""
  }

  readonly property bool scanning: scanProc.running
  readonly property string scanScript: localPath(Qt.resolvedUrl("scripts/scan.py"))

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function open() {
    root.controller.show()
    root.nowTick = Date.now()
  }

  function scan() {
    if (!scanProc.running) scanProc.running = true
  }

  function updateData(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      if (parsed.error) {
        root.scanError = parsed.error
        return
      }
      root.devices = parsed.devices || []
      root.recent = parsed.recent || []
      root.network = parsed.network || ""
      root.scannedAt = parsed.scannedAt || 0
      root.scanError = ""
    } catch (error) {
      root.scanError = "No se pudo leer el resultado del escaneo"
    }
    root.nowTick = Date.now()
  }

  function ago(seconds) {
    var diff = Math.max(0, Math.round(root.nowTick / 1000 - seconds))
    if (diff < 60) return "hace un momento"
    if (diff < 3600) return "hace " + Math.floor(diff / 60) + " min"
    return "hace " + Math.floor(diff / 3600) + " h"
  }

  function deviceIcon(d) {
    if (d.mac && root.customIcons[d.mac]) return root.customIcons[d.mac]
    return root.automaticIcon(d)
  }

  function detailFor(d, offline) {
    var parts = []
    var alias = d && d.mac ? root.aliases[d.mac] : ""
    if (alias && d.name && d.name !== alias) parts.push(d.name)
    if (d.vendor) parts.push(d.vendor)
    if (d.mac) parts.push(String(d.mac).toUpperCase())
    if (offline) parts.push("visto " + root.ago(d.lastSeen || 0))
    return parts.join("  ·  ")
  }

  function copy(value) {
    if (!value) return
    Quickshell.execDetached(["wl-copy", String(value)])
    root.showToast("IP copiada: " + value)
  }

  Process {
    id: scanProc
    command: ["python3", root.scanScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateData(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.scanError === "") root.scanError = "Falló el escaneo"
    }
  }

  // Escanea al arrancar y luego cada hora, esté el panel abierto o no; el
  // botón Escanear (o la tecla R) lo fuerza cuando quieras.
  Timer {
    interval: 60 * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.scan()
  }
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowTick = Date.now()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.scan()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(8)

        RowLayout {
          width: parent.width

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "RED LOCAL"
            foreground: root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Button {
            text: root.scanning ? "Escaneando" : "Escanear"
            iconText: "󰑐"
            iconSpinning: root.scanning
            enabled: !root.scanning
            bordered: true
            foreground: root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.caption
            iconSize: Style.font.caption
            tooltipText: "Volver a buscar dispositivos (R)"
            onClicked: root.scan()
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.toast !== "" ? root.toast
            : root.scanning ? "Escaneando la red…"
            : root.scanError !== "" ? root.scanError
            : root.scannedAt === 0 ? ""
            : root.devices.length + (root.devices.length === 1 ? " dispositivo" : " dispositivos")
              + "  ·  " + root.network + "  ·  " + root.ago(root.scannedAt)
          color: root.scanError !== "" ? (root.bar ? root.bar.urgent : Color.urgent) : Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator {
          foreground: root.barForeground
        }

        PanelSectionHeader {
          text: "CONECTADOS AHORA"
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Text {
          visible: root.devices.length === 0
          textFormat: Text.PlainText
          width: parent.width
          text: root.scanning ? "Buscando dispositivos…" : "No se ha encontrado nada"
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.devices
          delegate: DeviceRow {
            required property var modelData
            device: modelData
            offline: false
          }
        }

        PanelSeparator {
          visible: root.recent.length > 0
          foreground: root.barForeground
        }

        PanelSectionHeader {
          visible: root.recent.length > 0
          text: "VISTOS EN LAS ÚLTIMAS 24 H"
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Repeater {
          model: root.recent
          delegate: DeviceRow {
            required property var modelData
            device: modelData
            offline: true
          }
        }
      }
    }
  }

  component DeviceRow: CursorSurface {
    id: rowRoot
    property var device: ({})
    property bool offline: false
    readonly property bool editing: !!device.mac && root.editingMac === device.mac
    readonly property bool pickingIcon: !!device.mac && root.iconPickerMac === device.mac

    width: parent.width
    height: rowContent.implicitHeight + Style.space(10) + (pickingIcon ? iconPicker.implicitHeight + Style.space(8) : 0)
    foreground: root.barForeground
    hasCursor: mouse.containsMouse
    opacity: offline ? 0.55 : 1.0

    MouseArea {
      id: mouse
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      height: rowContent.implicitHeight + Style.space(10)
      enabled: !rowRoot.editing
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouseEvent) {
        if (mouseEvent.button === Qt.RightButton) root.copy(rowRoot.device.ip)
        else root.startRename(rowRoot.device)
      }
    }

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.top: parent.top
      anchors.topMargin: Style.space(5)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: root.deviceIcon(rowRoot.device)
        color: iconMouse.containsMouse || rowRoot.pickingIcon ? Color.accent : rowRoot.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter

        MouseArea {
          id: iconMouse
          anchors.fill: parent
          anchors.margins: -Style.space(4)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleIconPicker(rowRoot.device)
        }

        PanelToolTip {
          visible: iconMouse.containsMouse && !rowRoot.pickingIcon
          text: "Cambiar icono"
        }
      }

      Column {
        width: parent.width - Style.space(32)
        spacing: Style.space(1)

        RowLayout {
          width: parent.width

          Text {
            visible: !rowRoot.editing
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: (root.displayName(rowRoot.device) || "Sin nombre") + (rowRoot.device.self ? "  (este equipo)" : "")
            color: rowRoot.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: !!root.displayName(rowRoot.device)
            elide: Text.ElideRight
          }

          TextField {
            id: nameField
            visible: rowRoot.editing
            Layout.fillWidth: true
            placeholderText: "Nombre para este dispositivo"
            foreground: rowRoot.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            onVisibleChanged: if (visible) {
              text = root.aliases[rowRoot.device.mac] || rowRoot.device.name || ""
              selectAll()
              Qt.callLater(forceActiveFocus)
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.cancelRename()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.finishRename(rowRoot.device.mac, text)
                event.accepted = true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            text: rowRoot.device.ip || ""
            color: Qt.darker(rowRoot.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.detailFor(rowRoot.device, rowRoot.offline)
          color: Qt.darker(rowRoot.foreground, 1.5)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    // Selector de icono: se despliega bajo la fila al pulsar su icono.
    Flow {
      id: iconPicker
      visible: rowRoot.pickingIcon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.top: rowContent.bottom
      anchors.topMargin: Style.space(6)
      spacing: Style.space(4)

      Repeater {
        model: root.iconChoices

        Rectangle {
          required property var modelData
          readonly property bool chosen: root.customIcons[rowRoot.device.mac] === modelData.glyph
          width: Style.space(30)
          height: Style.space(30)
          radius: Math.min(4, Style.cornerRadius)
          color: pickMouse.containsMouse || chosen ? Style.hoverFillFor(rowRoot.foreground, Color.accent) : "transparent"
          border.width: chosen ? 1 : 0
          border.color: Color.accent

          Text {
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: modelData.glyph
            color: rowRoot.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
          }

          MouseArea {
            id: pickMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setIcon(rowRoot.device.mac, modelData.glyph)
          }

          PanelToolTip {
            visible: pickMouse.containsMouse
            text: modelData.label
          }
        }
      }

      // Por defecto: vuelve al icono que tenía antes del último cambio (o al
      // automático si nunca se cambió).
      Rectangle {
        readonly property string glyph: root.hasPreviousIcon(rowRoot.device)
          ? (root.previousIconFor(rowRoot.device) || root.automaticIcon(rowRoot.device))
          : root.automaticIcon(rowRoot.device)
        width: Style.space(44)
        height: Style.space(30)
        radius: Math.min(4, Style.cornerRadius)
        color: resetMouse.containsMouse ? Style.hoverFillFor(rowRoot.foreground, Color.accent) : "transparent"
        border.width: 1
        border.color: Qt.darker(rowRoot.foreground, 1.8)

        Row {
          anchors.centerIn: parent
          spacing: Style.space(3)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "↺"
            color: Qt.darker(rowRoot.foreground, 1.3)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: parent.parent.glyph
            color: rowRoot.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.title
          }
        }

        MouseArea {
          id: resetMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setIcon(rowRoot.device.mac, root.previousIconFor(rowRoot.device))
        }

        PanelToolTip {
          visible: resetMouse.containsMouse
          text: root.hasPreviousIcon(rowRoot.device) ? "Volver al icono anterior" : "Icono automático"
        }
      }
    }

    PanelToolTip {
      visible: mouse.containsMouse && !rowRoot.editing
      text: "Clic: cambiar nombre  ·  Clic derecho: copiar IP  ·  Clic en el icono: cambiar icono"
    }
  }
}
