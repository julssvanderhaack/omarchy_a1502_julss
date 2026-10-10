import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Keyboard popup: backlight slider (smc::kbd_backlight on the MacBook) and
// the keyboard layouts listed in Hyprland's kb_layout.
//
// brightnessctl goes through logind, so no root is needed. The level also
// changes from the keyboard's own keys, so it is re-read while anyone can
// see it: the popup open, or the indicator revealed (its colour follows the
// level). Hidden, nothing polls.
Panel {
  id: root
  moduleName: "julss.kbd-backlight"
  ipcTarget: "julss.kbd-backlight"

  property var anchorItem: null
  // Set by the indicator while it is on screen.
  property bool watched: false

  readonly property string device: "*kbd_backlight*"
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  property int percent: 0
  property int pendingPercent: -1
  property bool available: true

  // [{ code, variant }] from the main keyboard, and which one is active.
  property var layouts: []
  property int activeLayout: -1

  readonly property var layoutNames: ({
    "es": "Español", "us": "Inglés (EE. UU.)", "gb": "Inglés (Reino Unido)",
    "latam": "Español (Latinoamérica)", "fr": "Francés", "de": "Alemán",
    "it": "Italiano", "pt": "Portugués", "br": "Portugués (Brasil)",
    "dk": "Danés", "ch": "Suizo", "be": "Belga", "nl": "Neerlandés",
    "ru": "Ruso", "gr": "Griego", "jp": "Japonés", "eu": "EurKEY"
  })

  function layoutLabel(entry) {
    var name = layoutNames[entry.code] || entry.code.toUpperCase()
    return entry.variant ? name + " · " + entry.variant : name
  }

  function refresh() {
    if (!readProc.running) readProc.running = true
  }

  function refreshLayouts() {
    if (!devicesProc.running) devicesProc.running = true
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

  // All keyboards together, so the internal one and any external follow.
  function setLayout(index) {
    if (index === activeLayout) return
    activeLayout = index
    Quickshell.execDetached(["hyprctl", "switchxkblayout", "all", String(index)])
    layoutRecheck.restart()
  }

  onOpenedChanged: if (opened) { refresh(); refreshLayouts() }
  onWatchedChanged: if (watched) refresh()

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

  // The keyboard Hyprland marks main (fcitx5's virtual one here) carries the
  // seat's kb_layout; fall back to the first one that has a keymap.
  Process {
    id: devicesProc
    command: ["hyprctl", "-j", "devices"]
    stdout: StdioCollector {
      onStreamFinished: {
        var keyboards
        try { keyboards = JSON.parse(text || "{}").keyboards } catch (e) { return }
        if (!Array.isArray(keyboards) || keyboards.length === 0) return
        var kb = null
        for (var i = 0; i < keyboards.length && !kb; i++) if (keyboards[i].main) kb = keyboards[i]
        for (var j = 0; j < keyboards.length && !kb; j++) if (keyboards[j].active_keymap) kb = keyboards[j]
        if (!kb) return
        var codes = String(kb.layout || "").split(",")
        var variants = String(kb.variant || "").split(",")
        var list = []
        for (var k = 0; k < codes.length; k++) {
          var code = codes[k].trim()
          if (code) list.push({ code: code, variant: (variants[k] || "").trim() })
        }
        root.layouts = list
        root.activeLayout = typeof kb.active_layout_index === "number" ? kb.active_layout_index : -1
      }
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.opened || !event || !event.name) return
      var name = String(event.name)
      if (name.indexOf("activelayout") !== -1 || name === "configreloaded") root.refreshLayouts()
    }
  }

  Timer {
    interval: root.opened ? 1000 : 2000
    running: root.opened || root.watched
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: applyDebounce
    interval: 80
    onTriggered: if (root.pendingPercent >= 0) root.apply(root.pendingPercent)
  }

  Timer {
    id: layoutRecheck
    interval: 300
    onTriggered: root.refreshLayouts()
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
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      // ←/→ brightness; ↑/↓ step through the layouts.
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.apply(root.percent + dx * 10)
        else if (dy !== 0 && root.layouts.length > 1)
          root.setLayout((Math.max(0, root.activeLayout) + dy + root.layouts.length) % root.layouts.length)
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

        PanelSeparator {
          foreground: root.fg
        }

        PanelSectionHeader {
          text: "DISPOSICIÓN DEL TECLADO"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        Repeater {
          model: root.layouts

          Button {
            required property var modelData
            required property int index
            width: parent.width
            leftAlign: true
            bordered: true
            selected: index === root.activeLayout
            iconText: index === root.activeLayout ? "󰄬" : ""
            text: root.layoutLabel(modelData)
            tooltipText: modelData.code + (modelData.variant ? " (" + modelData.variant + ")" : "")
            foreground: root.fg
            fontFamily: root.fontFamily
            onClicked: root.setLayout(index)
          }
        }

        Text {
          visible: root.layouts.length <= 1
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Para tener más, añádelas a kb_layout en ~/.config/hypr/input.lua"
          color: Qt.darker(root.fg, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
