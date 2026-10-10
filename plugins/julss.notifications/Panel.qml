import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

import "HistoryLogic.js" as HistoryLogic

Panel {
  id: root
  moduleName: "julss.notifications"
  ipcTarget: "julss.notifications"

  property var anchorItem: null
  property var hostWidget: null
  property var entries: []
  property bool dnd: false
  property int durationSeconds: -1
  // Segundos que un aviso se queda en pantalla; 0 = hasta cerrarlo.
  readonly property var durationOptions: [3, 5, 8, 15, 30, 0]

  // Ticks while the panel is open so "hace X min" stays roughly accurate
  // without re-reading the history files just to update a clock.
  property double nowTick: Date.now()

  function open() {
    root.controller.show()
    if (root.hostWidget) root.hostWidget.refresh()
  }

  function toggleDnd() {
    if (root.hostWidget) root.hostWidget.setDnd(!root.dnd)
  }

  function setDuration(seconds) {
    if (root.hostWidget) root.hostWidget.setDuration(seconds)
  }

  // Clic en una notificación: enfocar la ventana de la app o lanzarla.
  function openApp(entry) {
    Quickshell.execDetached(["bash", Qt.resolvedUrl("open-app.sh").toString().replace(/^file:\/\//, ""),
      entry.app || "", entry.appIcon || "", entry.webHost || "", entry.execArgv || ""])
    root.close()
  }

  function removeEntry(file) {
    if (root.hostWidget) root.hostWidget.removeEntry(file)
  }

  function clearAll() {
    if (root.hostWidget) root.hostWidget.clearAll()
  }

  function iconSource(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
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
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        RowLayout {
          width: parent.width

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "NOTIFICACIONES"
            foreground: root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          }

          Button {
            text: "Borrar todas"
            iconText: "󰆴"
            bordered: true
            enabled: root.entries.length > 0
            foreground: root.bar ? root.bar.urgent : Color.urgent
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.caption
            iconSize: Style.font.caption
            onClicked: root.clearAll()
          }
        }

        RowLayout {
          width: parent.width

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.dnd ? "Solo en esta lista" : "También en pantalla"
            color: Qt.darker(root.barForeground, 1.4)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Button {
            text: root.dnd ? "No molestar: sí" : "No molestar: no"
            iconText: root.dnd ? "󰂛" : "󰂚"
            bordered: true
            foreground: root.dnd ? (root.bar ? root.bar.urgent : Color.urgent) : root.barForeground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            fontSize: Style.font.caption
            iconSize: Style.font.caption
            onClicked: root.toggleDnd()
          }
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: root.durationSeconds < 0
            ? "Tiempo en pantalla: por defecto de Omarchy (5–8 s)"
            : (root.durationSeconds === 0 ? "Tiempo en pantalla: hasta cerrarlo" : "Tiempo en pantalla: " + root.durationSeconds + " s")
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Row {
          id: durationRow
          width: parent.width
          spacing: Style.space(6)
          readonly property real cellWidth: (width - spacing * (root.durationOptions.length - 1)) / root.durationOptions.length

          Repeater {
            model: root.durationOptions

            Button {
              required property var modelData
              width: durationRow.cellWidth
              text: modelData === 0 ? "∞" : modelData + " s"
              tooltipText: modelData === 0 ? "Hasta cerrarlo" : "Desaparece a los " + modelData + " s"
              bordered: true
              active: root.durationSeconds === modelData
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              horizontalPadding: Style.spacing.sm
              onClicked: root.setDuration(modelData)
            }
          }
        }

        PanelSeparator {
          foreground: root.barForeground
        }

        Text {
          visible: root.entries.length === 0
          textFormat: Text.PlainText
          width: parent.width
          text: "Sin notificaciones acumuladas"
          color: Qt.darker(root.barForeground, 1.4)
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: root.entries

          delegate: NotificationRow {
            required property var modelData
            width: column.width
            bar: root.bar
            entryApp: modelData.app
            entryAppIcon: modelData.appIcon
            entryWebApp: modelData.webApp
            entrySummary: modelData.summary
            entryBody: modelData.body
            entryImage: modelData.image
            entryGlyph: modelData.glyph
            entryTimestamp: modelData.timestamp
            nowTick: root.nowTick
            resolveIcon: root.iconSource
            onActivated: root.openApp(modelData)
            onRemoveRequested: root.removeEntry(modelData.file)
          }
        }
      }
    }
  }

  component NotificationRow: Item {
    id: rowRoot

    property var bar: null
    property string entryApp: ""
    property string entryAppIcon: ""
    property string entryWebApp: ""
    property string entrySummary: ""
    property string entryBody: ""
    property string entryImage: ""
    property string entryGlyph: ""
    property double entryTimestamp: 0
    property double nowTick: Date.now()
    property var resolveIcon: null

    signal activated()
    signal removeRequested()

    readonly property string foreground: rowRoot.bar ? rowRoot.bar.barForeground : Color.foreground
    readonly property string iconSrc: rowRoot.entryImage.length > 0
      ? rowRoot.entryImage
      : (rowRoot.webAppIcon.length > 0
        ? rowRoot.webAppIcon
        : (rowRoot.resolveIcon ? rowRoot.resolveIcon(rowRoot.entryAppIcon) : ""))
    // Web-app notifications carry the browser's icon; prefer the site's own
    // theme icon (e.g. hicolor "whatsapp") when one is installed.
    readonly property string webAppIcon: rowRoot.entryWebApp.length > 0
      ? Quickshell.iconPath(rowRoot.entryWebApp.toLowerCase(), true)
      : ""
    readonly property bool hasIcon: rowRoot.iconSrc.length > 0
    readonly property bool hasGlyph: rowRoot.entryGlyph.length > 0

    height: rowContent.implicitHeight + Style.space(10)

    Rectangle {
      anchors.fill: parent
      anchors.leftMargin: -Style.space(6)
      anchors.rightMargin: -Style.space(6)
      radius: Style.space(4)
      color: rowRoot.foreground
      opacity: rowMouse.containsMouse ? 0.08 : 0
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: rowRoot.activated()
    }

    Row {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Item {
        width: Style.space(28)
        height: Style.space(28)
        anchors.verticalCenter: parent.verticalCenter

        Image {
          anchors.fill: parent
          visible: rowRoot.hasIcon && !rowRoot.hasGlyph
          source: rowRoot.iconSrc
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          smooth: true
        }

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          visible: rowRoot.hasGlyph
          text: rowRoot.entryGlyph
          color: rowRoot.foreground
          font.family: rowRoot.bar ? rowRoot.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.heading
        }
      }

      Column {
        width: parent.width - Style.space(38) - timeLabel.implicitWidth - Style.space(10)
          - trashButton.width - Style.space(10)
        spacing: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: rowRoot.entrySummary.length > 0 ? rowRoot.entrySummary : rowRoot.entryApp
          color: rowRoot.foreground
          font.family: rowRoot.bar ? rowRoot.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          maximumLineCount: 1
        }

        Text {
          textFormat: Text.PlainText
          visible: rowRoot.entryBody.length > 0
          width: parent.width
          text: rowRoot.entryBody
          color: Qt.darker(rowRoot.foreground, 1.3)
          font.family: rowRoot.bar ? rowRoot.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          wrapMode: Text.WordWrap
          maximumLineCount: 2
        }
      }

      Text {
        id: timeLabel
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        text: HistoryLogic.timeAgo(rowRoot.entryTimestamp, rowRoot.nowTick)
        color: Qt.darker(rowRoot.foreground, 1.5)
        font.family: rowRoot.bar ? rowRoot.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      // Papelera: borra solo esta notificación de la lista. Va encima del
      // MouseArea de la fila, así que el clic no abre la app.
      Item {
        id: trashButton
        width: Style.space(22)
        height: Style.space(22)
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "󰆴"
          color: trashMouse.containsMouse
            ? (rowRoot.bar ? rowRoot.bar.urgent : Color.urgent)
            : Qt.darker(rowRoot.foreground, 1.5)
          font.family: rowRoot.bar ? rowRoot.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
        }

        MouseArea {
          id: trashMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: rowRoot.removeRequested()
        }
      }
    }
  }
}
