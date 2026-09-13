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

  // Ticks while the panel is open so "hace X min" stays roughly accurate
  // without re-reading the history files just to update a clock.
  property double nowTick: Date.now()

  function open() {
    root.controller.show()
    if (root.hostWidget) root.hostWidget.refresh()
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
            entrySummary: modelData.summary
            entryBody: modelData.body
            entryImage: modelData.image
            entryGlyph: modelData.glyph
            entryTimestamp: modelData.timestamp
            nowTick: root.nowTick
            resolveIcon: root.iconSource
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
    property string entrySummary: ""
    property string entryBody: ""
    property string entryImage: ""
    property string entryGlyph: ""
    property double entryTimestamp: 0
    property double nowTick: Date.now()
    property var resolveIcon: null

    readonly property string foreground: rowRoot.bar ? rowRoot.bar.barForeground : Color.foreground
    readonly property string iconSrc: rowRoot.entryImage.length > 0
      ? rowRoot.entryImage
      : (rowRoot.resolveIcon ? rowRoot.resolveIcon(rowRoot.entryAppIcon) : "")
    readonly property bool hasIcon: rowRoot.iconSrc.length > 0
    readonly property bool hasGlyph: rowRoot.entryGlyph.length > 0

    height: rowContent.implicitHeight + Style.space(10)

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
    }
  }
}
