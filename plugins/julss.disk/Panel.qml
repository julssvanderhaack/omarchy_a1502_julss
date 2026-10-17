import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Almacenamiento: cómo está repartido el disco, en queso, anillos, mapa de
// rectángulos o árbol (botones arriba a la derecha o teclas 1-4), navegando
// por las carpetas. El recorrido lo hace scripts/scan.py y se guarda en
// ~/.cache/julss-disk/ para que abrir el panel sea instantáneo; si el escaneo
// tiene más de media hora se repite en segundo plano. Las carpetas pequeñas
// no se guardan enteras: se escanean al entrar en ellas.
//
// Se abre desde el panel de julss.sysmon (clic en DISCO) o con
//   omarchy-shell shell summon julss.disk '{}'
// El payload puede elegir la vista: {"view": "pie|sunburst|treemap|tree"}.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false
  property string rootPath: "/"
  property var data: null
  property var tree: null
  // Se incrementa cada vez que el árbol cambia por dentro (carpeta escaneada
  // al entrar): los bindings que leen el árbol dependen de él.
  property int version: 0
  property var pathStack: []
  property string view: "pie"
  property var mounts: []
  property string errorText: ""
  property double nowTick: Date.now()
  property var expanded: ({})

  // Las carpetas desplegadas del árbol son relativas al nivel actual.
  onPathStackChanged: root.expanded = ({})

  property int hoverIndex: -1
  property var hoverInfo: null

  property var loadingStack: null
  property string loadingAction: ""
  readonly property bool scanning: scanProc.running
  readonly property bool loadingDir: subProc.running

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string scanScript: localPath(Qt.resolvedUrl("scripts/scan.py"))
  readonly property string cachePath: homeDir + "/.cache/julss-disk/"
    + (root.rootPath === "/" ? "root" : root.rootPath.replace(/\//g, "_")) + ".json"

  // Colores del tema (los de los paneles emergentes).
  readonly property color fg: Color.popups.text
  readonly property color bg: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property string fontFamily: Style.font.family
  readonly property color onColor: "#15171a"

  readonly property var viewOptions: [
    { value: "pie", label: "Queso", icon: glyph(0xF012B), tooltip: "Gráfico de queso de esta carpeta (1)" },
    { value: "sunburst", label: "Anillos", icon: glyph(0xF0126), tooltip: "Anillos: tres niveles de carpetas a la vez (2)" },
    { value: "treemap", label: "Mapa", icon: glyph(0xF056E), tooltip: "Mapa de rectángulos: el área es el tamaño (3)" },
    { value: "tree", label: "Árbol", icon: glyph(0xF0645), tooltip: "Árbol desplegable de carpetas y ficheros (4)" }
  ]

  function glyph(cp) { return String.fromCodePoint(cp) }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function cssColor(c) {
    return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) + "," + Math.round(c.b * 255) + "," + c.a + ")"
  }

  // Paleta: tonos repartidos con la razón áurea a partir del acento del tema.
  readonly property real baseHue: Color.accent.hslHue < 0 ? 0.55 : Color.accent.hslHue
  function paletteColor(i) {
    return Qt.hsla((root.baseHue + i * 0.618034) % 1, 0.55, 0.62, 1)
  }

  function kindIcon(kind, open) {
    if (kind === "dir") return glyph(open ? 0xF0770 : 0xF024B)
    if (kind === "link") return glyph(0xF0337)
    if (kind === "others") return glyph(0xF01D8)
    if (kind === "system") return glyph(0xF033E)
    return glyph(0xF0214)
  }

  // ---------- Ciclo de vida ----------
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    if (payload.view) root.view = String(payload.view)
    if (payload.path) root.goTo(String(payload.path))
    root.opened = true
    root.nowTick = Date.now()
    root.hoverIndex = -1
    root.hoverInfo = null
    if (!mountsProc.running) mountsProc.running = true
    if (root.data) root.maybeRescan()
    else cacheFile.reload()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.hoverIndex = -1
    root.hoverInfo = null
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "julss.disk")
    else close()
  }

  function rescan() {
    if (scanProc.running) return
    root.errorText = ""
    scanProc.command = ["python3", root.scanScript, "--path", root.rootPath, "--out", root.cachePath]
    scanProc.running = true
  }

  function maybeRescan() {
    if (!root.data || Date.now() / 1000 - (root.data.scannedAt || 0) > 1800) root.rescan()
  }

  function applyData(raw) {
    var parsed
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { return }
    if (!parsed || !parsed.tree) return
    root.data = parsed
    root.tree = parsed.tree
    root.pathStack = Model.validPrefix(root.tree, root.pathStack)
    root.version++
    root.nowTick = Date.now()
    if (root.pendingGoTo !== "") root.goTo(root.pendingGoTo)
    if (root.opened) root.maybeRescan()
  }

  function switchRoot(path) {
    if (path === root.rootPath) return
    root.rootPath = path
    root.data = null
    root.tree = null
    root.pathStack = []
    root.expanded = ({})
    root.version++
  }

  function setView(v) {
    root.view = v
    root.hoverIndex = -1
    root.hoverInfo = null
    viewFile.setText(v + "\n")
  }

  // ---------- Navegación ----------
  function enterPath(stack) {
    var node = Model.nodeAt(root.tree, stack)
    if (!node || !node.d) return
    root.hoverIndex = -1
    root.hoverInfo = null
    if (node.p) loadDir(stack, "enter")
    else root.pathStack = stack
  }

  // Abre una ruta absoluta (desde el payload: {"path": "/home/julss"}).
  function goTo(path) {
    var base = root.rootPath.replace(/\/+$/, "")
    if (path.indexOf(base + "/") !== 0) return
    var names = path.substring(base.length + 1).split("/").filter(function(n) { return n !== "" })
    if (!root.tree) { root.pendingGoTo = path; return }
    // Baja paso a paso: las carpetas que no estén guardadas se escanean.
    var stack = []
    for (var i = 0; i < names.length; i++) {
      var node = Model.nodeAt(root.tree, stack.concat([names[i]]))
      if (!node || !node.d) break
      stack.push(names[i])
      if (node.p) { root.pendingGoTo = i < names.length - 1 ? path : ""; loadDir(stack, "enter"); return }
    }
    root.pendingGoTo = ""
    root.pathStack = stack
  }
  property string pendingGoTo: ""

  function goUp() {
    if (root.pathStack.length > 0) enterPath(root.pathStack.slice(0, -1))
  }

  function toggleExpand(row) {
    if (!row.expandable) return
    var next = Object.assign({}, root.expanded)
    if (next[row.key]) { delete next[row.key]; root.expanded = next; return }
    var full = root.pathStack.concat(row.path)
    var node = Model.nodeAt(root.tree, full)
    if (node && node.p) { loadDir(full, "expand:" + row.key); return }
    next[row.key] = true
    root.expanded = next
  }

  function loadDir(stack, action) {
    if (subProc.running) return
    root.loadingStack = stack
    root.loadingAction = action
    subProc.command = ["python3", root.scanScript, "--path", Model.joinPath(root.rootPath, stack)]
    subProc.running = true
  }

  function applySub(raw) {
    var parsed
    try { parsed = JSON.parse(String(raw || "")) } catch (e) { return }
    var node = Model.nodeAt(root.tree, root.loadingStack || [])
    if (!parsed || !parsed.tree || !node) return
    node.c = parsed.tree.c || []
    node.k = parsed.tree.k || 0
    if (parsed.tree.e) node.e = 1
    delete node.p
    root.version++
    if (root.loadingAction === "enter") {
      root.pathStack = root.loadingStack
      if (root.pendingGoTo !== "") Qt.callLater(function() { root.goTo(root.pendingGoTo) })
    } else if (root.loadingAction.indexOf("expand:") === 0) {
      var next = Object.assign({}, root.expanded)
      next[root.loadingAction.substring(7)] = true
      root.expanded = next
    }
  }

  function openInFiles(stack, isDir) {
    var path = Model.joinPath(root.rootPath, stack)
    root.dismiss()
    if (isDir) Quickshell.execDetached(["nautilus", "--new-window", path])
    else Quickshell.execDetached(["nautilus", "--select", path])
  }

  function ago(seconds) {
    var diff = Math.max(0, Math.round(root.nowTick / 1000 - seconds))
    if (diff < 60) return "hace un momento"
    if (diff < 3600) return "hace " + Math.floor(diff / 60) + " min"
    if (diff < 86400) return "hace " + Math.floor(diff / 3600) + " h"
    return "hace " + Math.floor(diff / 86400) + " d"
  }

  // ---------- Datos del nivel actual ----------
  readonly property var current: {
    root.version
    return root.tree ? Model.nodeAt(root.tree, root.pathStack) : null
  }
  readonly property string currentPath: Model.joinPath(root.rootPath, root.pathStack)
  readonly property string currentName: root.pathStack.length > 0 ? root.pathStack[root.pathStack.length - 1]
    : (root.rootPath === "/" ? "Disco entero" : root.rootPath)

  // Lo que ocupa el sistema de ficheros y no se ha podido sumar (carpetas de
  // root, metadatos…). Solo en la raíz de un punto de montaje.
  readonly property real hiddenBytes: {
    root.version
    if (!root.data || !root.tree || root.pathStack.length > 0 || !root.data.fsUsed) return 0
    var gap = root.data.fsUsed - root.tree.s
    return gap > root.data.fsUsed * 0.01 ? gap : 0
  }

  // Hijos del nivel actual, ordenados y con color: { name, label, size, pct,
  // kind, node, color, textColor, colorIndex, path }.
  readonly property var items: {
    root.version
    var node = root.current
    if (!node || !node.c) return []
    var list = []
    for (var i = 0; i < node.c.length; i++) {
      var c = node.c[i]
      if (c.s <= 0) continue
      list.push({ name: c.o ? "" : c.n, label: Model.labelOf(c), size: c.s, kind: Model.kindOf(c), node: c })
    }
    if (root.hiddenBytes > 0)
      list.push({ name: "", label: "Sin acceso / sistema", size: root.hiddenBytes, kind: "system", node: null })
    list.sort(function(a, b) { return b.size - a.size })
    var total = 0
    for (i = 0; i < list.length; i++) total += list[i].size
    var colorIdx = 0
    for (i = 0; i < list.length; i++) {
      var it = list[i]
      it.pct = total > 0 ? it.size / total : 0
      it.path = it.kind === "others" || it.kind === "system" ? root.pathStack : root.pathStack.concat([it.name])
      if (it.kind === "system") {
        it.color = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.16); it.textColor = root.fg; it.colorIndex = -1
      } else if (it.kind !== "others" && colorIdx < 12 && it.pct >= 0.005) {
        it.color = root.paletteColor(colorIdx); it.textColor = root.onColor; it.colorIndex = colorIdx++
      } else {
        it.color = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.32); it.textColor = root.fg; it.colorIndex = -1
      }
    }
    return list
  }
  readonly property real itemsTotal: {
    var t = 0
    for (var i = 0; i < root.items.length; i++) t += root.items[i].size
    return t
  }

  // Lo que se enseña en el centro del queso / anillos.
  readonly property var focusInfo: {
    if (root.hoverInfo) return root.hoverInfo
    if (root.hoverIndex >= 0 && root.hoverIndex < root.items.length) {
      var it = root.items[root.hoverIndex]
      return { label: it.label, size: it.size, pct: it.pct, kind: it.kind }
    }
    return { label: root.currentName, size: root.itemsTotal, pct: -1, kind: "dir" }
  }

  // ---------- Procesos y ficheros ----------
  Process {
    id: scanProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.errorText = "Falló el escaneo del disco"
      cacheFile.reload()
    }
  }

  Process {
    id: subProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySub(text)
    }
  }

  Process {
    id: mountsProc
    command: ["python3", root.scanScript, "--mounts"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.mounts = JSON.parse(text || "[]") } catch (e) { root.mounts = [] }
      }
    }
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyData(text())
    onLoadFailed: if (root.opened) root.rescan()
  }

  FileView {
    id: viewFile
    path: root.homeDir + "/.local/state/julss-disk/view"
    printErrors: false
    onLoaded: {
      var v = text().trim()
      if (["pie", "sunburst", "treemap", "tree"].indexOf(v) >= 0) root.view = v
    }
  }

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowTick = Date.now()
  }

  // ---------- Ventana ----------
  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "julss-disk"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.5)
      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onClicked: root.dismiss()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) root.dismiss()
        else if (event.key === Qt.Key_Backspace || event.key === Qt.Key_Left || event.text === "h") root.goUp()
        else if (event.text === "1") root.setView("pie")
        else if (event.text === "2") root.setView("sunburst")
        else if (event.text === "3") root.setView("treemap")
        else if (event.text === "4") root.setView("tree")
        else if (event.text === "r" || event.text === "R") root.rescan()
        else return
        event.accepted = true
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(48), Style.space(1100))
        height: Math.min(parent.height - Style.space(48), Style.space(720))
        radius: Style.cornerRadius
        color: root.bg
        border.width: 1
        border.color: root.borderColor

        // Que los clics dentro de la tarjeta no la cierren.
        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(20)
          spacing: Style.space(12)

          // ---------- Cabecera ----------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(14)

            Text {
              textFormat: Text.PlainText
              text: root.glyph(0xF02CA)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: "Almacenamiento"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
              }

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: root.data && root.data.fsSize
                  ? (Model.formatBytes(root.data.fsUsed) + " USADOS DE " + Model.formatBytes(root.data.fsSize)
                     + "  ·  " + Model.formatBytes(root.data.fsFree) + " LIBRES")
                  : "REPARTO DEL ESPACIO EN DISCO"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
              }
            }

            ButtonGroup {
              options: root.viewOptions
              value: root.view
              focusable: false
              foreground: root.fg
              background: root.bg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onChanged: function(v) { root.setView(v) }
            }

            Button {
              text: root.scanning ? "Escaneando" : "Reescanear"
              iconText: root.glyph(0xF0450)
              iconSpinning: root.scanning
              enabled: !root.scanning
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.bodySmall
              tooltipText: "Volver a recorrer el disco (R)"
              onClicked: root.rescan()
            }

            Button {
              iconText: root.glyph(0xF0156)
              foreground: root.fg
              fontFamily: root.fontFamily
              tooltipText: "Cerrar (Esc)"
              onClicked: root.dismiss()
            }
          }

          // Uso del sistema de ficheros.
          Item {
            Layout.fillWidth: true
            implicitHeight: Style.space(8)
            visible: !!(root.data && root.data.fsSize)

            Rectangle {
              id: fsTrack
              anchors.fill: parent
              radius: height / 2
              color: root.faint
            }
            Rectangle {
              height: parent.height
              radius: height / 2
              width: root.data && root.data.fsSize ? Math.max(height, parent.width * root.data.fsUsed / root.data.fsSize) : 0
              color: root.data && root.data.fsSize && root.data.fsUsed / root.data.fsSize >= 0.9 ? "#EF5350" : Color.accent
              Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            }
          }

          // Discos montados (solo si hay más de uno: USB, otra partición…).
          ButtonGroup {
            visible: root.mounts.length > 1
            options: root.mounts.map(function(m) {
              return { value: m.path, label: m.path === "/" ? "Sistema" : m.path.split("/").pop(),
                       icon: root.glyph(m.path === "/" ? 0xF02CA : 0xF0553),
                       tooltip: m.source + " · " + Model.formatBytes(m.used) + " de " + Model.formatBytes(m.size) }
            })
            value: root.rootPath
            focusable: false
            foreground: root.fg
            background: root.bg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            onChanged: function(v) { root.switchRoot(v); cacheFile.reload() }
          }

          // ---------- Ruta ----------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            Button {
              iconText: root.glyph(0xF005D)
              enabled: root.pathStack.length > 0
              opacity: enabled ? 1 : 0.35
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              tooltipText: "Subir un nivel (Retroceso)"
              onClicked: root.goUp()
            }

            Flickable {
              id: crumbFlick
              Layout.fillWidth: true
              implicitHeight: crumbRow.implicitHeight
              contentWidth: crumbRow.implicitWidth
              contentX: Math.max(0, contentWidth - width)
              clip: true
              interactive: contentWidth > width
              boundsBehavior: Flickable.StopAtBounds

              Row {
                id: crumbRow
                spacing: Style.space(4)

                Repeater {
                  model: [root.rootPath === "/" ? "/" : root.rootPath].concat(root.pathStack)

                  Row {
                    required property var modelData
                    required property int index
                    readonly property bool last: index === root.pathStack.length
                    spacing: Style.space(4)

                    Text {
                      visible: index > 0
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "›"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: modelData
                      color: parent.last ? root.fg : (crumbMouse.containsMouse ? Color.accent : root.dim)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: parent.last

                      MouseArea {
                        id: crumbMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: parent.parent.last ? Qt.ArrowCursor : Qt.PointingHandCursor
                        onClicked: if (!parent.parent.last) root.enterPath(root.pathStack.slice(0, index))
                      }
                    }
                  }
                }
              }
            }

            Button {
              text: "Abrir en Archivos"
              iconText: root.glyph(0xF0770)
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              iconSize: Style.font.bodySmall
              tooltipText: root.currentPath
              onClicked: root.openInFiles(root.pathStack, true)
            }
          }

          // ---------- Contenido ----------
          Item {
            id: body
            Layout.fillWidth: true
            Layout.fillHeight: true

            Text {
              anchors.centerIn: parent
              visible: !root.tree || root.items.length === 0 || root.loadingDir
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: root.loadingDir ? "Mirando dentro de " + Model.joinPath(root.rootPath, root.loadingStack || []) + "…"
                : !root.tree ? (root.scanning ? "Recorriendo el disco por primera vez… (unos 20 s)" : "Sin datos todavía")
                : root.current && root.current.e ? "No hay permiso para ver esta carpeta"
                : "Carpeta vacía"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            RowLayout {
              anchors.fill: parent
              spacing: Style.space(18)
              visible: !!root.tree && root.items.length > 0 && !root.loadingDir

              // Gráfico (queso, anillos o mapa) o árbol a todo lo ancho.
              Item {
                id: chartArea
                Layout.fillWidth: true
                Layout.fillHeight: true

                // ----- Queso y anillos -----
                Item {
                  id: radial
                  anchors.fill: parent
                  visible: root.view === "pie" || root.view === "sunburst"
                  readonly property real radius: Math.max(10, Math.min(width, height) / 2 - Style.space(6))
                  readonly property real cx: width / 2
                  readonly property real cy: height / 2
                  readonly property real innerRadius: root.view === "pie" ? radius * 0.56 : radius * 0.3
                  readonly property int depths: 3
                  readonly property real ringWidth: (radius - innerRadius) / depths

                  readonly property var slices: {
                    if (root.view !== "pie") return []
                    var out = [], a = 0, restSize = 0, total = root.itemsTotal
                    if (total <= 0) return out
                    for (var i = 0; i < root.items.length; i++) {
                      var it = root.items[i]
                      if (it.colorIndex < 0 && it.kind !== "system") { restSize += it.size; continue }
                      var span = it.size / total * 2 * Math.PI
                      out.push({ a0: a, a1: a + span, color: it.color, index: i })
                      a += span
                    }
                    if (restSize > 0) out.push({ a0: a, a1: 2 * Math.PI, index: -2,
                      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.32), size: restSize })
                    return out
                  }
                  readonly property real restSize: {
                    for (var i = 0; i < slices.length; i++) if (slices[i].index === -2) return slices[i].size
                    return 0
                  }
                  readonly property var arcs: root.view === "sunburst" ? Model.sunburst(root.items, root.itemsTotal, depths) : []
                  property int hoverArc: -1
                  property bool hoverRest: false

                  function angleAt(x, y) {
                    var a = Math.atan2(y - cy, x - cx) + Math.PI / 2
                    return a < 0 ? a + 2 * Math.PI : a
                  }

                  function hitTest(x, y) {
                    var r = Math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy))
                    var a = angleAt(x, y)
                    if (root.view === "pie") {
                      if (r < innerRadius || r > radius + Style.space(6)) return { center: r < innerRadius }
                      for (var i = 0; i < slices.length; i++)
                        if (a >= slices[i].a0 && a < slices[i].a1) return { slice: slices[i] }
                      return {}
                    }
                    if (r < innerRadius) return { center: true }
                    var depth = Math.ceil((r - innerRadius) / ringWidth)
                    if (depth < 1 || depth > depths) return {}
                    for (var j = 0; j < arcs.length; j++)
                      if (arcs[j].depth === depth && a >= arcs[j].a0 && a < arcs[j].a1) return { arc: j }
                    return {}
                  }

                  function updateHover(x, y) {
                    var hit = hitTest(x, y)
                    hoverArc = hit.arc !== undefined ? hit.arc : -1
                    hoverRest = !!(hit.slice && hit.slice.index === -2)
                    if (hit.slice && hit.slice.index >= 0) {
                      root.hoverIndex = hit.slice.index
                      root.hoverInfo = null
                    } else if (hoverRest) {
                      root.hoverIndex = -1
                      root.hoverInfo = { label: "Resto (pequeños)", size: restSize, pct: restSize / root.itemsTotal, kind: "others" }
                    } else if (hoverArc >= 0) {
                      var arc = arcs[hoverArc]
                      root.hoverIndex = -1
                      root.hoverInfo = { label: arc.name, size: arc.size, pct: arc.size / root.itemsTotal, kind: arc.kind, path: arc.path }
                    } else {
                      root.hoverIndex = -1
                      root.hoverInfo = null
                    }
                  }

                  function clickAt(x, y, button) {
                    var hit = hitTest(x, y)
                    if (hit.center) { if (button === Qt.LeftButton) root.goUp(); return }
                    // Rutas completas (desde la raíz del escaneo).
                    var path = null, kind = ""
                    if (hit.slice && hit.slice.index >= 0) { path = root.items[hit.slice.index].path; kind = root.items[hit.slice.index].kind }
                    else if (hit.arc !== undefined) { path = root.pathStack.concat(arcs[hit.arc].path); kind = arcs[hit.arc].kind }
                    if (!path) return
                    if (button === Qt.RightButton) {
                      if (kind === "dir" || kind === "file" || kind === "link") root.openInFiles(path, kind === "dir")
                    } else if (kind === "dir") {
                      root.enterPath(path)
                    }
                  }

                  Canvas {
                    id: radialCanvas
                    anchors.fill: parent
                    renderStrategy: Canvas.Cooperative
                    property var deps: [root.items, radial.slices, radial.arcs, root.hoverIndex, radial.hoverArc, radial.hoverRest, width, height, root.bg]
                    onDepsChanged: requestPaint()

                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      var cx = radial.cx, cy = radial.cy, R = radial.radius, r0 = radial.innerRadius
                      var gap = root.cssColor(root.bg)
                      ctx.lineWidth = 1.5
                      ctx.strokeStyle = gap
                      function sector(a0, a1, rIn, rOut) {
                        ctx.beginPath()
                        ctx.arc(cx, cy, rOut, a0 - Math.PI / 2, a1 - Math.PI / 2, false)
                        ctx.arc(cx, cy, rIn, a1 - Math.PI / 2, a0 - Math.PI / 2, true)
                        ctx.closePath()
                        ctx.fill()
                        ctx.stroke()
                      }
                      if (root.view === "pie") {
                        for (var i = 0; i < radial.slices.length; i++) {
                          var s = radial.slices[i]
                          var hot = (s.index >= 0 && s.index === root.hoverIndex) || (s.index === -2 && radial.hoverRest)
                          ctx.fillStyle = root.cssColor(hot ? Qt.lighter(s.color, 1.15) : s.color)
                          sector(s.a0, s.a1, r0, hot ? R + Style.space(6) : R)
                        }
                      } else {
                        for (var j = 0; j < radial.arcs.length; j++) {
                          var arc = radial.arcs[j]
                          var rIn = r0 + (arc.depth - 1) * radial.ringWidth
                          var c = arc.color
                          if (arc.depth > 1) c = Qt.lighter(c, 1 + 0.16 * (arc.depth - 1))
                          if (arc.kind === "file" || arc.kind === "link" || arc.kind === "others")
                            c = Qt.rgba(c.r, c.g, c.b, 0.55)
                          var lit = j === radial.hoverArc || (arc.depth === 1 && root.hoverIndex >= 0
                            && root.items[root.hoverIndex] && arc.path[0] === root.items[root.hoverIndex].name && root.items[root.hoverIndex].name !== "")
                          ctx.fillStyle = root.cssColor(lit ? Qt.lighter(c, 1.2) : c)
                          sector(arc.a0, arc.a1, rIn, rIn + radial.ringWidth)
                        }
                        // Círculo central: la carpeta actual (clic: subir).
                        ctx.beginPath()
                        ctx.arc(cx, cy, r0 - 2, 0, 2 * Math.PI)
                        ctx.fillStyle = root.cssColor(root.faint)
                        ctx.fill()
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onPositionChanged: function(mouse) { radial.updateHover(mouse.x, mouse.y) }
                    onExited: { radial.hoverArc = -1; radial.hoverRest = false; root.hoverIndex = -1; root.hoverInfo = null }
                    onClicked: function(mouse) { radial.clickAt(mouse.x, mouse.y, mouse.button) }
                    cursorShape: {
                      if (root.hoverIndex >= 0 && root.items[root.hoverIndex]) return root.items[root.hoverIndex].kind === "dir" ? Qt.PointingHandCursor : Qt.ArrowCursor
                      if (radial.hoverArc >= 0 && radial.arcs[radial.hoverArc]) return radial.arcs[radial.hoverArc].kind === "dir" ? Qt.PointingHandCursor : Qt.ArrowCursor
                      return Qt.ArrowCursor
                    }
                  }

                  // Texto del centro: lo que hay bajo el ratón o la carpeta actual.
                  Column {
                    anchors.centerIn: parent
                    width: radial.innerRadius * 1.6
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      textFormat: Text.PlainText
                      text: root.kindIcon(root.focusInfo.kind, false)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                    }
                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      textFormat: Text.PlainText
                      text: root.focusInfo.label
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideMiddle
                    }
                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      textFormat: Text.PlainText
                      text: Model.formatBytes(root.focusInfo.size)
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: root.view === "pie" ? Style.font.display : Style.font.title
                      font.bold: true
                    }
                    Text {
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      textFormat: Text.PlainText
                      text: root.focusInfo.pct >= 0 ? Model.formatPct(root.focusInfo.pct) + " de " + root.currentName
                        : (root.pathStack.length > 0 && root.view === "sunburst" ? "clic aquí para subir" : "")
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideMiddle
                    }
                  }
                }

                // ----- Mapa de rectángulos -----
                Item {
                  id: treemap
                  anchors.fill: parent
                  visible: root.view === "treemap"
                  clip: true

                  readonly property real headerH: Style.font.caption + Style.space(8)
                  readonly property var rects: {
                    if (root.view !== "treemap" || width <= 0 || height <= 0) return []
                    var top = Model.squarify(root.items.map(function(it, i) { return { value: it.size, it: it, i: i } }),
                                             0, 0, width, height)
                    var out = []
                    for (var t = 0; t < top.length; t++) {
                      var r = top[t], it = r.item.it
                      out.push({ x: r.x, y: r.y, w: r.w, h: r.h, depth: 1, index: r.item.i, label: it.label,
                                 size: it.size, kind: it.kind, path: it.path, color: it.color, textColor: it.textColor })
                      var node = it.node
                      if (it.kind !== "dir" || !node || !node.c || r.w < 60 || r.h < headerH + 24) continue
                      var kids = []
                      for (var k = 0; k < node.c.length; k++) if (node.c[k].s > 0) kids.push({ value: node.c[k].s, n: node.c[k] })
                      var inner = Model.squarify(kids, r.x + 3, r.y + headerH, r.w - 6, r.h - headerH - 3)
                      for (var q = 0; q < inner.length; q++) {
                        var s = inner[q], c = s.item.n
                        if (s.w < 3 || s.h < 3) continue
                        out.push({ x: s.x, y: s.y, w: s.w, h: s.h, depth: 2, index: r.item.i, label: Model.labelOf(c),
                                   size: c.s, kind: Model.kindOf(c), path: c.o ? it.path : it.path.concat([c.n]),
                                   color: it.color, textColor: it.textColor })
                      }
                    }
                    return out
                  }

                  Repeater {
                    model: treemap.rects

                    Rectangle {
                      required property var modelData
                      readonly property bool hot: tmMouse.containsMouse
                      readonly property bool groupHot: modelData.depth === 1 && root.hoverIndex === modelData.index
                      x: modelData.x + 1
                      y: modelData.y + 1
                      width: Math.max(1, modelData.w - 2)
                      height: Math.max(1, modelData.h - 2)
                      radius: Math.min(4, Style.cornerRadius)
                      color: {
                        var c = modelData.color
                        if (modelData.depth === 2) c = Qt.lighter(c, modelData.kind === "dir" ? 1.12 : 1.25)
                        if (hot || groupHot) c = Qt.lighter(c, 1.15)
                        return c
                      }
                      border.width: modelData.depth === 2 ? 1 : 0
                      border.color: Qt.darker(modelData.color, 1.25)

                      Text {
                        visible: parent.width > 46 && parent.height > Style.font.caption + 6
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Style.space(4)
                        anchors.topMargin: modelData.depth === 1 ? Style.space(3) : Style.space(3)
                        textFormat: Text.PlainText
                        text: modelData.label + (parent.width > 140 ? "  " + Model.formatBytes(modelData.size) : "")
                        color: modelData.textColor
                        opacity: modelData.depth === 2 ? 0.8 : 1
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: modelData.depth === 1
                        elide: Text.ElideRight
                      }

                      MouseArea {
                        id: tmMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: modelData.kind === "dir" ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onEntered: {
                          root.hoverIndex = modelData.index
                          root.hoverInfo = { label: modelData.label, size: modelData.size,
                                             pct: modelData.size / root.itemsTotal, kind: modelData.kind }
                        }
                        onExited: if (root.hoverInfo && root.hoverInfo.label === modelData.label) { root.hoverIndex = -1; root.hoverInfo = null }
                        onClicked: function(mouse) {
                          if (mouse.button === Qt.RightButton) {
                            if (modelData.kind !== "others" && modelData.kind !== "system")
                              root.openInFiles(modelData.path, modelData.kind === "dir")
                          } else if (modelData.kind === "dir") {
                            root.enterPath(modelData.path)
                          }
                        }
                      }
                    }
                  }

                  // Etiqueta flotante con lo que hay bajo el ratón.
                  Rectangle {
                    visible: root.view === "treemap" && !!root.hoverInfo
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: Style.space(8)
                    width: tipText.implicitWidth + Style.space(16)
                    height: tipText.implicitHeight + Style.space(10)
                    radius: Math.min(6, Style.cornerRadius)
                    color: Color.tooltip.background
                    border.width: 1
                    border.color: Color.tooltip.border

                    Text {
                      id: tipText
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: root.hoverInfo ? root.hoverInfo.label + "  ·  " + Model.formatBytes(root.hoverInfo.size)
                        + "  ·  " + Model.formatPct(root.hoverInfo.pct) : ""
                      color: Color.tooltip.text
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                  }
                }

                // ----- Árbol -----
                ListView {
                  id: treeList
                  anchors.fill: parent
                  visible: root.view === "tree"
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.view === "tree" ? Model.treeRows(root.items, [], root.expanded, root.itemsTotal) : []
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  delegate: Rectangle {
                    id: treeRow
                    required property var modelData
                    width: treeList.width - Style.space(10)
                    height: Style.font.body + Style.space(12)
                    radius: Math.min(4, Style.cornerRadius)
                    color: rowMouse.containsMouse ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                    MouseArea {
                      id: rowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      acceptedButtons: Qt.LeftButton | Qt.RightButton
                      cursorShape: modelData.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: function(mouse) {
                        if (mouse.button === Qt.RightButton) {
                          if (modelData.kind !== "others" && modelData.kind !== "system")
                            root.openInFiles(root.pathStack.concat(modelData.path), modelData.kind === "dir")
                        } else {
                          root.toggleExpand(modelData)
                        }
                      }
                      onDoubleClicked: if (modelData.kind === "dir") root.enterPath(root.pathStack.concat(modelData.path))
                    }

                    RowLayout {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(6) + modelData.depth * Style.space(18)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(8)

                      Text {
                        Layout.preferredWidth: Style.space(12)
                        textFormat: Text.PlainText
                        text: modelData.expandable ? root.glyph(modelData.expanded ? 0xF0140 : 0xF0142) : ""
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: root.kindIcon(modelData.kind, modelData.expanded)
                        color: modelData.kind === "dir" ? modelData.color : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: modelData.label + (modelData.denied ? "  " + root.glyph(0xF033E) : "")
                        color: modelData.kind === "others" || modelData.kind === "system" ? root.dim : root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: modelData.depth === 0
                        elide: Text.ElideMiddle
                      }

                      Item {
                        Layout.preferredWidth: Style.space(160)
                        implicitHeight: Style.space(6)
                        Rectangle { anchors.fill: parent; radius: height / 2; color: root.faint }
                        Rectangle {
                          height: parent.height
                          radius: height / 2
                          width: Math.max(modelData.pct > 0 ? height : 0, parent.width * modelData.pct)
                          color: modelData.color
                        }
                      }

                      Text {
                        Layout.preferredWidth: Style.space(72)
                        horizontalAlignment: Text.AlignRight
                        textFormat: Text.PlainText
                        text: Model.formatBytes(modelData.size)
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        Layout.preferredWidth: Style.space(52)
                        horizontalAlignment: Text.AlignRight
                        textFormat: Text.PlainText
                        text: Model.formatPct(modelData.pct)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }

              // ----- Leyenda / lista del nivel actual -----
              ListView {
                id: legend
                Layout.preferredWidth: Style.space(340)
                Layout.fillHeight: true
                visible: root.view !== "tree"
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.items
                spacing: Style.space(1)
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                  required property var modelData
                  required property int index
                  readonly property bool hot: legendMouse.containsMouse || root.hoverIndex === index
                    || !!(root.hoverInfo && root.hoverInfo.path && root.hoverInfo.path[0] === modelData.name && modelData.name !== "")
                  width: legend.width - Style.space(10)
                  height: legendCol.implicitHeight + Style.space(10)
                  radius: Math.min(4, Style.cornerRadius)
                  color: hot ? Style.hoverFillFor(root.fg, Color.accent) : "transparent"

                  MouseArea {
                    id: legendMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    cursorShape: modelData.kind === "dir" ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onEntered: { root.hoverIndex = index; root.hoverInfo = null }
                    onExited: if (root.hoverIndex === index) root.hoverIndex = -1
                    onClicked: function(mouse) {
                      if (mouse.button === Qt.RightButton) {
                        if (modelData.kind !== "others" && modelData.kind !== "system")
                          root.openInFiles(modelData.path, modelData.kind === "dir")
                      } else if (modelData.kind === "dir") {
                        root.enterPath(modelData.path)
                      }
                    }
                  }

                  PanelToolTip {
                    visible: legendMouse.containsMouse && (modelData.kind === "others" || modelData.kind === "system")
                    text: modelData.kind === "others" ? "Ficheros y carpetas pequeños agrupados"
                      : modelData.kind === "system" ? "Lo que ocupa el disco y no se puede sumar sin ser root: carpetas protegidas, metadatos, instantáneas…"
                      : "Clic: entrar  ·  Clic derecho: abrir en Archivos"
                  }

                  Column {
                    id: legendCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    spacing: Style.space(4)

                    RowLayout {
                      width: parent.width
                      spacing: Style.space(8)

                      Rectangle {
                        Layout.preferredWidth: Style.space(10)
                        Layout.preferredHeight: Style.space(10)
                        radius: Style.space(3)
                        color: modelData.color
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: root.kindIcon(modelData.kind, false)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: modelData.label + (modelData.node && modelData.node.e && modelData.kind === "dir" ? "  " + root.glyph(0xF033E) : "")
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: modelData.kind === "dir"
                        elide: Text.ElideMiddle
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: Model.formatBytes(modelData.size)
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                      }

                      Text {
                        Layout.preferredWidth: Style.space(46)
                        horizontalAlignment: Text.AlignRight
                        textFormat: Text.PlainText
                        text: Model.formatPct(modelData.pct)
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    Item {
                      width: parent.width
                      height: Style.space(3)
                      Rectangle { anchors.fill: parent; radius: height / 2; color: root.faint }
                      Rectangle {
                        height: parent.height
                        radius: height / 2
                        width: Math.max(height, parent.width * modelData.pct)
                        color: modelData.color
                      }
                    }
                  }
                }
              }
            }
          }

          // ---------- Pie ----------
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: {
              if (root.errorText !== "") return root.errorText
              var parts = []
              if (root.scanning) parts.push("Actualizando…")
              if (root.data) {
                parts.push("Escaneado " + root.ago(root.data.scannedAt))
                if (root.current) parts.push(Model.formatCount(root.current.k || 0) + " elementos aquí")
                if (root.pathStack.length === 0 && root.data.fsUsed && root.tree && root.tree.s > root.data.fsUsed * 1.02)
                  parts.push("suman " + Model.formatBytes(root.tree.s) + "; la compresión de btrfs los deja en " + Model.formatBytes(root.data.fsUsed))
                if (root.data.errors > 0) parts.push(root.data.errors + " carpetas sin permiso " + root.glyph(0xF033E))
              }
              parts.push(root.view === "tree"
                ? "Clic: desplegar · Doble clic: entrar · Clic derecho: abrir en Archivos"
                : "Clic: entrar · Clic derecho: abrir en Archivos · Retroceso: subir")
              return parts.join("  ·  ")
            }
            color: root.errorText !== "" ? Color.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
