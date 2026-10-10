import QtQuick
import qs.Ui

// Keyboard: backlight and layout. Never "active": it lives with the hideable
// icons and shows on hover; a click drops a panel with a brightness slider
// and the kb_layout list. The icon goes from dark grey at 0 % to white at
// 100 %, so instead of the stock dimming it is shown at full opacity.
//
// The indicator is instantiated once per block (inactive and active) and
// per bar orientation; only the inactive copy on screen carries the panel.
BarIndicator {
  id: root

  active: false
  inactiveText: "󰌌"
  inactiveTooltipText: kbdPanel ? "Teclado — brillo " + kbdPanel.percent + " %" : "Teclado"

  readonly property real level: kbdPanel ? Math.max(0, Math.min(100, kbdPanel.percent)) / 100 : 1
  foreground: Qt.rgba(0.3 + 0.7 * level, 0.3 + 0.7 * level, 0.3 + 0.7 * level, 1)

  // BarIndicator dims revealed inactive icons to 0.45; the colour already
  // carries the level here.
  function syncIndicatorOpacity() {
    root.opacity = !belongsInBlock ? 0 : (effectiveActive || inactiveRevealed ? 1 : 0)
  }

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
    kbdPanel.watched = Qt.binding(function() { return root.inactiveRevealed })
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
