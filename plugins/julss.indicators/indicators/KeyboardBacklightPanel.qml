import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Slider for the keyboard backlight (smc::kbd_backlight on the MacBook).
// brightnessctl goes through logind, so no root is needed. The level also
// changes from the keyboard's own keys, so it is re-read while open.
Panel {
  id: root
  moduleName: "julss.kbd-backlight"
  ipcTarget: "julss.kbd-backlight"

  property var anchorItem: null

  readonly property string device: "*kbd_backlight*"
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  property int percent: 0
  property int pendingPercent: -1
  property bool available: true

  function refresh() {
    if (!readProc.running) readProc.running = true
  }

  function preview(value) {
    pendingPercent = Math.round(value)
    percent = pendingPercent
    applyDebounce.restart()
  }

  function apply(value) {
    applyDebounce.stop()
    pendingPercent = -1
    percent = Math.max(0, Math.min(100, Math.round(value)))
    Quickshell.execDetached(["brightnessctl", "-q", "-d", root.device, "set", percent + "%"])
  }

  onOpenedChanged: if (opened) refresh()

  // -m: "smc::kbd_backlight,leds,105,41%,255"
  Process {
    id: readProc
    command: ["brightnessctl", "-m", "-d", root.device, "info"]
    stdout: StdioCollector {
      onStreamFinished: {
        var fields = text.trim().split(",")
        root.available = fields.length >= 5
        if (root.available && root.pendingPercent < 0 && !slider.dragging)
          root.percent = parseInt(fields[3]) || 0
      }
    }
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: applyDebounce
    interval: 80
    onTriggered: if (root.pendingPercent >= 0) root.apply(root.pendingPercent)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    // Not the indicators widget: KeyboardPanel closes through owner.close(),
    // which that widget lacks, and the panel would hide while still "opened".
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(280))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        var delta = dx !== 0 ? dx : -dy
        if (delta !== 0) root.apply(root.percent + delta * 10)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(8)

        Item {
          width: parent.width
          height: header.implicitHeight

          PanelSectionHeader {
            id: header
            anchors.left: parent.left
            text: "BRILLO DEL TECLADO"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: header.verticalCenter
            textFormat: Text.PlainText
            text: root.available ? root.percent + " %" : "—"
            color: Qt.darker(root.fg, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(10)
          visible: root.available

          Text {
            id: lowIcon
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "󰌌"
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Item {
            width: parent.width - lowIcon.width - parent.spacing
            height: Math.max(Style.space(28), slider.implicitHeight)

            PanelSlider {
              id: slider
              bar: root.bar
              anchors.fill: parent
              minimum: 0
              maximum: 100
              step: 1
              integer: true
              value: root.percent
              onMoved: function(v) { root.preview(v) }
              onReleased: function(v) { root.apply(v) }
            }
          }
        }

        Text {
          visible: !root.available
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "No se encuentra la retroiluminación del teclado"
          color: Qt.darker(root.fg, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
