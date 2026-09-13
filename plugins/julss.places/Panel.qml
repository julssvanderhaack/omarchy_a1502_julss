import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "julss.places"

  property var anchorItem: null
  property var hostWidget: null

  property var bookmarks: []
  property var homePlace: ({ label: "Inicio", path: "" })
  property var media: []
  property bool loading: true
  property string loadError: ""
  property string ejectingParent: ""

  readonly property string listScript: localPath(Qt.resolvedUrl("scripts/list.py"))
  readonly property string ejectScript: localPath(Qt.resolvedUrl("scripts/eject.sh"))

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function open() {
    root.controller.show()
    refresh()
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function updateData(raw) {
    try {
      var parsed = JSON.parse(String(raw || "{}"))
      root.homePlace = parsed.home || { label: "Inicio", path: "" }
      root.bookmarks = Array.isArray(parsed.bookmarks) ? parsed.bookmarks : []
      root.media = Array.isArray(parsed.media) ? parsed.media : []
      root.loadError = ""
    } catch (error) {
      root.loadError = "No se pudieron leer los lugares"
    }
    root.loading = false
  }

  function openPath(path) {
    if (!path) return
    Quickshell.execDetached(["gio", "open", path])
    root.close()
  }

  function eject(parentDevice) {
    if (!parentDevice || ejectProc.running) return
    root.ejectingParent = parentDevice
    ejectProc.command = [root.ejectScript, parentDevice]
    ejectProc.running = true
  }

  Process {
    id: listProc
    command: [root.listScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateData(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loading) {
        root.loadError = "No se pudieron leer los lugares"
        root.loading = false
      }
    }
  }

  Process {
    id: ejectProc
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: {
      root.ejectingParent = ""
      root.refresh()
    }
  }

  // Keep the connected-media list current while the panel is open, so a
  // pendrive plugged in or pulled out shows up without reopening the panel.
  Timer {
    interval: 3000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        PanelSectionHeader {
          text: "LUGARES"
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        PlaceRow {
          label: root.homePlace.label || "Inicio"
          detail: ""
          iconText: ""
          bar: root.bar
          onActivated: root.openPath(root.homePlace.path)
        }

        Repeater {
          model: root.bookmarks

          delegate: PlaceRow {
            required property var modelData
            label: modelData.label
            detail: ""
            iconText: ""
            bar: root.bar
            onActivated: root.openPath(modelData.path)
          }
        }

        Text {
          visible: root.bookmarks.length === 0 && !root.loading
          textFormat: Text.PlainText
          width: parent.width
          text: "Sin marcadores en Nautilus"
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator {
          foreground: root.barForeground
        }

        PanelSectionHeader {
          text: "DISPOSITIVOS"
          foreground: root.barForeground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Text {
          visible: root.media.length === 0
          textFormat: Text.PlainText
          width: parent.width
          text: root.loading ? "Buscando dispositivos…" : "No hay medios conectados"
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.media

          delegate: MediaRow {
            required property var modelData
            label: modelData.label
            detail: (modelData.fstype || "") + (modelData.size ? "  ·  " + modelData.size : "")
            bar: root.bar
            busy: root.ejectingParent === modelData.parent
            onActivated: root.openPath(modelData.mountpoint)
            onEjectRequested: root.eject(modelData.parent)
          }
        }

        Text {
          visible: root.loadError !== ""
          textFormat: Text.PlainText
          width: parent.width
          text: root.loadError
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  component PlaceRow: CursorSurface {
    id: rowRoot
    property string label: ""
    property string detail: ""
    property string iconText: ""
    property var bar: null
    signal activated()

    width: parent.width
    height: Style.space(30)
    foreground: rowRoot.bar ? rowRoot.bar.barForeground : Color.foreground
    hasCursor: mouse.containsMouse

    Row {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: rowRoot.iconText
        color: rowRoot.foreground
        font.family: rowRoot.bar ? rowRoot.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: rowRoot.label
        color: rowRoot.foreground
        font.family: rowRoot.bar ? rowRoot.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(28)
      }
    }

    MouseArea {
      id: mouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rowRoot.activated()
    }
  }

  component MediaRow: CursorSurface {
    id: mediaRowRoot
    property string label: ""
    property string detail: ""
    property var bar: null
    property bool busy: false
    signal activated()
    signal ejectRequested()

    width: parent.width
    height: Style.space(38)
    foreground: mediaRowRoot.bar ? mediaRowRoot.bar.barForeground : Color.foreground
    hasCursor: rowMouse.containsMouse

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: mediaRowRoot.activated()
    }

    Item {
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(deviceIcon.implicitHeight, info.implicitHeight, ejectButton.implicitHeight)

      Text {
        id: deviceIcon
        textFormat: Text.PlainText
        text: ""
        color: mediaRowRoot.foreground
        font.family: mediaRowRoot.bar ? mediaRowRoot.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.heading
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: deviceIcon.right
        anchors.leftMargin: Style.space(10)
        anchors.right: ejectButton.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          text: mediaRowRoot.label
          color: mediaRowRoot.foreground
          font.family: mediaRowRoot.bar ? mediaRowRoot.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: parent.width
        }
        Text {
          textFormat: Text.PlainText
          visible: mediaRowRoot.detail !== ""
          text: mediaRowRoot.busy ? "Expulsando…" : mediaRowRoot.detail
          color: Qt.darker(mediaRowRoot.foreground, 1.4)
          font.family: mediaRowRoot.bar ? mediaRowRoot.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      PanelActionButton {
        id: ejectButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: ""
        tooltipText: "Expulsar de forma segura"
        foreground: mediaRowRoot.foreground
        fontFamily: mediaRowRoot.bar ? mediaRowRoot.bar.fontFamily : Style.font.family
        enabled: !mediaRowRoot.busy
        onClicked: mediaRowRoot.ejectRequested()
      }
    }
  }
}
