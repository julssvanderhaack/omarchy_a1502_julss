import QtQuick
import qs.Ui

// Keyboard backlight. Never "active": it lives with the hideable icons and
// shows on hover; a click drops a small panel with a brightness slider.
//
// The indicator is instantiated once per block (inactive and active) and
// per bar orientation; only the inactive copy on screen carries the panel.
BarIndicator {
  id: root

  active: false
  inactiveText: "󰌌"
  inactiveTooltipText: "Brillo del teclado"

  readonly property var kbdPanel: panelLoader.item
  property bool holdingReveal: false

  function syncRevealHold() {
    var want = !!kbdPanel && kbdPanel.opened === true
    if (want === holdingReveal || !indicatorHost || !indicatorHost.holdReveal) return
    indicatorHost.holdReveal(want)
    holdingReveal = want
  }

  function injectPanel() {
    if (!kbdPanel) return
    kbdPanel.bar = root.bar
    kbdPanel.anchorItem = root
  }

  onPressed: function() { if (kbdPanel) kbdPanel.toggle() }
  onBarChanged: injectPanel()
  onIndicatorHostChanged: injectPanel()
  Component.onDestruction: if (holdingReveal && indicatorHost) indicatorHost.holdReveal(false)

  Connections {
    target: root.kbdPanel
    ignoreUnknownSignals: true
    function onOpenedChanged() { root.syncRevealHold() }
  }

  Loader {
    id: panelLoader
    // Only the inactive copy in the layout on screen (the indicators exist
    // once for a horizontal bar and once for a vertical one).
    active: root.indicatorBlock === "inactive" && root.visible
    source: Qt.resolvedUrl("KeyboardBacklightPanel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
}
