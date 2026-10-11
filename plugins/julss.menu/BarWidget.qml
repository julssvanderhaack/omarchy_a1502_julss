import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.menu"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // julss: logotipo de texto de Omarchy (logo.svg teñido del verde #9ECE6A
  // del logo) en lugar del icono.
  readonly property real logoHeight: Style.space(17)
  readonly property real logoWidth: Math.round(logoHeight * 1215 / 285)

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    hasVisualContent: true
    fixedWidth: root.logoWidth + Style.space(13)
    horizontalMargin: 7.5

    Image {
      // Pegado a la izquierda (margen pequeño) en vez de centrado.
      anchors.left: parent.left
      anchors.leftMargin: Style.space(3)
      anchors.verticalCenter: parent.verticalCenter
      width: root.logoWidth
      height: root.logoHeight
      source: Qt.resolvedUrl("assets/omarchy-logo.svg")
      sourceSize.width: Math.round(root.logoWidth * Screen.devicePixelRatio)
      sourceSize.height: Math.round(root.logoHeight * Screen.devicePixelRatio)
      fillMode: Image.PreserveAspectFit
      smooth: true
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
