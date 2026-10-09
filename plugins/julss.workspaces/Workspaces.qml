import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  // Always 1..5, extended up to the highest existing workspace so an empty
  // one in the middle (e.g. 6 with 7 and 8 in use) still shows, dimmed,
  // instead of leaving a gap in the sequence.
  function workspaceIds() {
    var last = 5
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > last && id <= 10) last = id
    }

    var ids = []
    for (var n = 1; n <= last; n++) ids.push(n)
    return ids
  }

  // The bar background may carry alpha; the number on the filled square
  // must stay readable either way.
  function opaque(c) {
    return Qt.rgba(c.r, c.g, c.b, 1)
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      WidgetButton {
        required property int modelData

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

        bar: root.bar
        text: modelData === 10 ? "0" : String(modelData)
        // Focused workspace: number in negative on a filled rounded square.
        foreground: focused ? root.opaque(root.bar ? root.bar.background : Color.background) : (root.bar ? root.bar.barForeground : Color.foreground)
        opacity: occupied || focused ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize
        onPressed: function() { root.focusWorkspace(modelData) }

        Rectangle {
          z: -1
          visible: parent.focused
          anchors.centerIn: parent
          width: Math.min(parent.width, parent.height) - Style.space(4)
          height: width
          radius: Style.space(4)
          color: root.bar ? root.bar.barForeground : Color.foreground
        }
      }
    }
  }
}
