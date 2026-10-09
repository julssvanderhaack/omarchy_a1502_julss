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
    // Evita reescanear si el último escaneo es de hace menos de un minuto.
    if (Date.now() / 1000 - root.scannedAt > 60) scan()
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
    if (d.gateway) return "󰑩"
    if (d.self) return "󰌢"
    var v = String(d.vendor || "").toLowerCase()
    var n = String(d.name || "").toLowerCase()
    if (n.indexOf("tv") !== -1 || v.indexOf("samsung") !== -1 && n.indexOf("[tv]") !== -1) return "󰔂"
    if (v.indexOf("amazon") !== -1) return "󰓃"
    if (v.indexOf("aleatoria") !== -1) return "󰄜"
    if (v.indexOf("print") !== -1 || v.indexOf("epson") !== -1 || v.indexOf("brother") !== -1 || v.indexOf("hp ") === 0) return "󰐪"
    return "󰾰"
  }

  function detailFor(d, offline) {
    var parts = []
    if (d.vendor) parts.push(d.vendor)
    if (d.mac) parts.push(String(d.mac).toUpperCase())
    if (offline) parts.push("visto " + root.ago(d.lastSeen || 0))
    return parts.join("  ·  ")
  }

  function copy(value) {
    if (!value) return
    Quickshell.execDetached(["wl-copy", String(value)])
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

  // Refresca "hace X min" y reescanea cada 2 minutos mientras está abierto.
  Timer {
    interval: 120000
    running: root.opened
    repeat: true
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

          Column {
            Layout.fillWidth: true
            spacing: Style.space(2)

            PanelSectionHeader {
              text: "RED LOCAL"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            }

            Text {
              textFormat: Text.PlainText
              text: root.scanning ? "Escaneando la red…"
                : root.scanError !== "" ? root.scanError
                : root.scannedAt === 0 ? ""
                : root.devices.length + (root.devices.length === 1 ? " dispositivo" : " dispositivos")
                  + "  ·  " + root.network + "  ·  " + root.ago(root.scannedAt)
              color: root.scanError !== "" ? (root.bar ? root.bar.urgent : Color.urgent) : Qt.darker(root.barForeground, 1.4)
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.caption
            }
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

    width: parent.width
    height: rowContent.implicitHeight + Style.space(10)
    foreground: root.barForeground
    hasCursor: mouse.containsMouse
    opacity: offline ? 0.55 : 1.0

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: root.deviceIcon(rowRoot.device)
        color: rowRoot.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.title
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        width: parent.width - Style.space(32)
        spacing: Style.space(1)

        RowLayout {
          width: parent.width

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: (rowRoot.device.name || "Sin nombre") + (rowRoot.device.self ? "  (este equipo)" : "")
            color: rowRoot.foreground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.body
            font.bold: !!rowRoot.device.name
            elide: Text.ElideRight
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

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.copy(rowRoot.device.ip)
    }

    PanelToolTip {
      visible: mouse.containsMouse
      text: "Clic para copiar la IP"
    }
  }
}
