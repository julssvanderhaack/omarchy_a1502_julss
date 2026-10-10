import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// FaceTime HD webcam. "Activada" means the facetimehd driver is loaded (it
// is blacklisted, so it boots unloaded, and the suspend hook unloads it);
// unloading it, rather than just leaving the camera unused, lets the CPU
// reach its deep C-states again. The on/off scripts also flip ASPM on the
// camera's PCIe link, so they need root.
//
//   desactivada  driver unloaded             inactive: hidden until hover, dimmed
//   activada     driver loaded, camera idle  active: plain icon
//   encendida    an app has /dev/video* open active: green icon
BarIndicator {
  id: root

  readonly property string onScript: "/usr/local/bin/facetimehd-camera-on.sh"
  readonly property string offScript: "/usr/local/bin/facetimehd-camera-off.sh"

  // "off" | "enabled" | "live"
  property string camState: "off"

  active: camState !== "off"
  useActiveColor: camState === "live"
  activeColor: "#7cc77c"
  activeText: "󰖠"
  inactiveText: "󱜷"
  activeTooltipText: switchProc.running ? "Cambiando…"
    : camState === "live" ? "Webcam encendida (en uso) — clic para desactivar el driver"
    : "Webcam activada — clic para desactivar el driver"
  inactiveTooltipText: switchProc.running ? "Cambiando…" : "Webcam desactivada — clic para activar el driver"

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  function toggle() {
    if (switchProc.running) return
    switchProc.command = ["pkexec", root.camState === "off" ? root.onScript : root.offScript]
    switchProc.running = true
  }

  onPressed: function() { root.toggle() }

  // Module first; fuser only while it is loaded, since without the driver
  // there is no /dev/video* to hold open. fuser only sees this user's
  // processes, which is where browsers and PipeWire live.
  Process {
    id: stateProc
    command: ["bash", "-c",
      "if grep -q '^facetimehd ' /proc/modules; then " +
      "  if fuser -s /dev/video* 2>/dev/null; then echo live; else echo enabled; fi; " +
      "else echo off; fi"]
    stdout: StdioCollector {
      onStreamFinished: {
        var s = text.trim()
        if (s === "off" || s === "enabled" || s === "live") root.camState = s
      }
    }
  }

  Process {
    id: switchProc
    onExited: function(code) {
      if (code !== 0 && code !== 126)  // 126: polkit prompt dismissed
        Quickshell.execDetached(["notify-send", "-u", "critical", "Webcam",
          "No se ha podido cambiar el estado de la webcam"])
      root.refresh()
    }
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
