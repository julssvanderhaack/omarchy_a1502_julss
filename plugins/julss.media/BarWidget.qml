import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "omarchy.media"

  readonly property var mediaService: bar?.shell?.firstPartyServiceFor("omarchy.media")
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null
  readonly property var sourcePlayers: mediaService ? mediaService.sourcePlayers : []

  readonly property bool hasMedia: activePlayer !== null && activePlayer.isPlaying && (activePlayer.trackTitle || activePlayer.trackArtist)
  // Icono de la app que suena (Audacious, Spotify…): el Icon= de su .desktop
  // resuelto en el tema de iconos; si no, el nombre tal cual.
  readonly property string appIconSource: {
    if (!activePlayer) return ""
    var names = [activePlayer.desktopEntry, activePlayer.identity]
    for (var i = 0; i < names.length; i++) {
      var id = String(names[i] || "").replace(/\.desktop$/i, "")
      if (!id) continue
      var entry = DesktopEntries.heuristicLookup(id)
      var candidates = entry && entry.icon ? [entry.icon, id, id.toLowerCase()] : [id, id.toLowerCase()]
      for (var j = 0; j < candidates.length; j++) {
        var icon = String(candidates[j])
        if (icon.charAt(0) === "/") return "file://" + icon
        var path = Quickshell.iconPath(icon, true)
        if (path) return path
      }
    }
    return ""
  }
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""

  property bool popupOpen: false

  function close() { popupOpen = false }
  // Último espacio visible en julss.workspaces (siempre 1–5, más hasta el
  // mayor que exista, como mucho 10).
  readonly property int lastWorkspace: {
    var last = 5
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > last && id <= 10) last = id
    }
    return last
  }

  // Ancho máximo del texto; si no cabe, se desplaza en bucle. Cada número de
  // espacio extra (6–10) ocupa Style.space(20) + 1 de separación, así que se
  // le resta para no montarse sobre los indicadores ocultos del centro.
  property real maxLabelWidth: Style.space(260) - (lastWorkspace - 5) * Style.space(21)

  function focusPlayingApplication() {
    if (!activePlayer) return
    var names = [activePlayer.desktopEntry, activePlayer.identity, activePlayer.dbusName]
    var keys = []
    for (var i = 0; i < names.length; i++) {
      var key = String(names[i] || "").toLowerCase()
      key = key.replace(/^org\.mpris\.mediaplayer2\./, "").replace(/\.instance[0-9]+$/, "").replace(/\.desktop$/, "")
      key = key.replace(/[^a-z0-9]/g, "")
      if (key && keys.indexOf(key) < 0) keys.push(key)
    }
    var windows = ToplevelManager.toplevels.values
    for (var j = 0; j < windows.length; j++) {
      var appId = String(windows[j].appId || "").toLowerCase().replace(/[^a-z0-9]/g, "")
      for (var k = 0; k < keys.length; k++) {
        if (appId && (appId === keys[k] || appId.indexOf(keys[k]) !== -1 || keys[k].indexOf(appId) !== -1)) {
          windows[j].activate()
          return
        }
      }
    }
    var fallback = String(activePlayer.desktopEntry || activePlayer.identity || activePlayer.dbusName || "")
      .replace(/^org\.mpris\.MediaPlayer2\./i, "").replace(/\.instance[0-9]+$/i, "")
    var escapedName = fallback.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    if (root.bar && escapedName)
      root.bar.run("hyprctl dispatch focuswindow " + Util.shellQuote("class:(?i).*" + escapedName + ".*"))
  }

  visible: hasMedia
  implicitWidth: hasMedia ? row.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  Row {
    id: row
    anchors.centerIn: parent
    spacing: Style.space(6)

    Image {
      id: appIcon
      width: Style.space(16)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      source: root.appIconSource
      sourceSize.width: width * Screen.devicePixelRatio
      sourceSize.height: height * Screen.devicePixelRatio
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      visible: status === Image.Ready
    }

    Text {
      id: fallbackIcon
      textFormat: Text.PlainText
      anchors.verticalCenter: parent.verticalCenter
      text: "󰝚"
      visible: !appIcon.visible
      color: activePlayer && activePlayer.isPlaying ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    Item {
      id: scrollClip
      readonly property string label: root.title + (root.artist ? "  ·  " + root.artist : "")
      readonly property real gap: Style.space(40)
      readonly property bool needsScroll: measure.implicitWidth > root.maxLabelWidth

      width: Math.min(root.maxLabelWidth, measure.implicitWidth)
      height: measure.implicitHeight
      clip: true
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.bar.vertical && root.title !== ""

      // Solo para medir el texto completo.
      Text {
        id: measure
        visible: false
        textFormat: Text.PlainText
        text: scrollClip.label
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
      }

      // Marquesina sin saltos: dos copias seguidas que avanzan un "texto + hueco"
      // y vuelven a empezar. Si cabe, queda quieto en x = 0.
      Row {
        id: marquee
        spacing: scrollClip.gap
        anchors.verticalCenter: parent.verticalCenter
        x: 0

        Repeater {
          model: scrollClip.needsScroll ? 2 : 1
          Text {
            textFormat: Text.PlainText
            text: scrollClip.label
            color: root.bar.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        NumberAnimation on x {
          id: scrollAnim
          running: scrollClip.needsScroll && scrollClip.visible && !root.popupOpen
          loops: Animation.Infinite
          from: 0
          to: -(measure.implicitWidth + scrollClip.gap)
          // ~40 px por segundo.
          duration: Math.max(4000, (measure.implicitWidth + scrollClip.gap) * 25)
          easing.type: Easing.Linear
          onRunningChanged: if (!running) marquee.x = 0
        }
      }

      // Reiniciar al cambiar de canción para que empiece por el principio.
      onLabelChanged: {
        marquee.x = 0
        if (scrollAnim.running) scrollAnim.restart()
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.activePlayer ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (!root.activePlayer) return
      if (mouse.button === Qt.MiddleButton) {
        if (root.mediaService) root.mediaService.runAction("next", false)
      } else if (mouse.button === Qt.RightButton) {
        root.popupOpen = !root.popupOpen
      } else {
        root.focusPlayingApplication()
      }
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0 && root.mediaService) root.mediaService.runAction("previous", false)
      else if (wheel.angleDelta.y < 0 && root.mediaService) root.mediaService.runAction("next", false)
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? (root.title + (root.artist ? " — " + root.artist : "")) : "")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(320))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        spacing: Style.space(10)
        width: parent.width

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.activePlayer && root.activePlayer.trackArtUrl ? root.activePlayer.trackArtUrl : ""
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: !root.activePlayer || !root.activePlayer.trackArtUrl
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          spacing: Style.space(4)
          width: parent.width - Style.space(74)

          Text {
            textFormat: Text.PlainText
            text: root.title || "Nothing playing"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            elide: Text.ElideRight
            width: parent.width
          }

          Text {
            textFormat: Text.PlainText
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }

          Text {
            textFormat: Text.PlainText
            text: root.activePlayer && root.activePlayer.trackAlbum ? root.activePlayer.trackAlbum : ""
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width
            visible: text !== ""
          }
        }
      }

      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Button {
          iconText: "󰒮"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoPrevious
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("previous", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: root.activePlayer && root.activePlayer.isPlaying ? "󰏤" : "󰐊"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.panelGap
          verticalPadding: Style.spacing.controlPaddingY
          iconSize: Style.font.iconLarge
          enabled: root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause)
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("playPause", false, root.mediaService.playerKey(root.activePlayer))
        }

        Button {
          iconText: "󰒭"
          foreground: root.bar.foreground
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          enabled: root.activePlayer && root.activePlayer.canGoNext
          opacity: enabled ? 1.0 : 0.4
          onClicked: if (root.mediaService) root.mediaService.runAction("next", false, root.mediaService.playerKey(root.activePlayer))
        }
      }

      PanelSeparator {
        visible: root.sourcePlayers.length > 1
        foreground: root.bar.foreground
      }

      Column {
        id: sourceList
        visible: root.sourcePlayers.length > 1
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.sourcePlayers

          BorderSurface {
            id: sourceRow
            required property var modelData

            readonly property var player: modelData
            readonly property bool selected: root.activePlayer && player
              && root.mediaService.playerKey(root.activePlayer) === root.mediaService.playerKey(player)
            readonly property string sourceTitle: player ? (player.trackTitle || player.identity || player.desktopEntry || "Media source") : "Media source"
            readonly property string sourceDetail: player && player.trackArtist ? player.trackArtist : (player && player.identity ? player.identity : "")

            width: sourceList.width
            height: sourceInner.implicitHeight + Style.space(10)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.bar.foreground, Color.accent) : "transparent"
            borderSpec: selected ? Border.controlSpec("normal", root.bar.foreground, Color.accent) : Border.none()

            Row {
              id: sourceInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: sourceRow.borderLeft + Style.space(8)
              anchors.rightMargin: sourceRow.borderRight + Style.space(8)
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: sourceRow.player && sourceRow.player.isPlaying ? "󰏤" : "󰐊"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(26)
                spacing: Style.space(1)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  textFormat: Text.PlainText
                  text: sourceRow.sourceTitle
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: sourceRow.selected
                  elide: Text.ElideRight
                  width: parent.width
                }

                Text {
                  textFormat: Text.PlainText
                  text: sourceRow.sourceDetail
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width
                  visible: text !== ""
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.mediaService) root.mediaService.selectPlayer(root.mediaService.playerKey(sourceRow.player))
            }
          }
        }
      }
    }
  }
}
