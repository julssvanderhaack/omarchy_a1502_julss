import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.menu"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // julss: logotipo de Omarchy con los colores del logo de la pantalla de
  // carga del tema actual. ~/.local/bin/julss-bar-logo lo genera en
  // ~/.local/state/julss/bar-logo.png desde el unlock.png del tema (hook
  // theme-set.d/julss-bar-logo); si aún no existe, el SVG de assets.
  readonly property string generatedLogo: Quickshell.env("HOME") + "/.local/state/julss/bar-logo.png"
  property int logoRevision: 0
  property bool generatedExists: false
  readonly property real logoHeight: Style.space(17)
  readonly property real logoRatio: logo.status === Image.Ready && logo.implicitHeight > 0
    ? logo.implicitWidth / logo.implicitHeight : 1215 / 285
  readonly property real logoWidth: Math.round(logoHeight * logoRatio)

  // Recarga la imagen cuando el hook la reescribe al cambiar de tema.
  FileView {
    path: root.generatedLogo
    watchChanges: true
    printErrors: false
    onLoaded: { root.generatedExists = true; root.logoRevision++ }
    onLoadFailed: root.generatedExists = false
    onFileChanged: reload()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: root.logoWidth + Style.space(13)
    horizontalMargin: 7.5

    Image {
      id: logo
      // Pegado a la izquierda (margen pequeño) en vez de centrado.
      anchors.left: parent.left
      anchors.leftMargin: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
      width: root.logoWidth
      height: root.logoHeight
      source: root.generatedExists
        ? "file://" + root.generatedLogo + "?v=" + root.logoRevision
        : Qt.resolvedUrl("assets/omarchy-logo.svg")
      cache: false
      sourceSize.height: Math.round(root.logoHeight * Screen.devicePixelRatio)
      fillMode: Image.PreserveAspectFit
      smooth: true
      mipmap: true
    }

    onPressed: function(button) {
      if (!root.bar) return
      // Clic derecho: fastfetch en la ventana "About" de Omarchy (btop ya se
      // abre desde el monitor julss.sysmon).
      if (button === Qt.RightButton) root.bar.run("omarchy-launch-about")
      else root.bar.run("omarchy-shell shell toggle omarchy.menu '{\"menu\":\"root\"}'")
    }
  }
}
