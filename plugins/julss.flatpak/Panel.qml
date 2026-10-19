import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Flatpak: gestor de aplicaciones Flatpak con el aspecto del resto del shell.
// Pestañas: Instaladas (detalles, permisos, abrir, desinstalar), Actualizaciones,
// Buscar en Flathub e Instalar fichero (cuando se abre un .flatpak,
// .flatpakref o .flatpakrepo desde Archivos). Todo lo que lee lo saca
// scripts/flatpak.py; las operaciones se lanzan con flatpak directamente (el
// grupo wheel no necesita contraseña para instalar en el sistema, ver
// /usr/share/polkit-1/rules.d/org.freedesktop.Flatpak.rules).
//
//   omarchy-shell shell summon julss.flatpak '{}'
//   omarchy-shell shell summon julss.flatpak '{"file": "/ruta/app.flatpak"}'
//   omarchy-shell shell summon julss.flatpak '{"tab": "updates"}'
//   omarchy-shell shell summon julss.flatpak '{"search": "vlc"}'
// ~/.local/bin/julss-flatpak hace eso mismo y es lo que abre Archivos.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string tab: "installed"

  property var apps: []
  property int runtimeCount: 0
  property real runtimeSize: 0
  property bool loadedOnce: false

  property var updates: []
  property bool updatesChecked: false
  property double updatesCheckedAt: 0

  property string searchQuery: ""
  property var searchResults: []
  property bool searched: false

  property var fileInfo: null
  property string filePath: ""
  property string fileInstallation: "system"

  property string selectedKey: ""
  property var details: null
  property string filter: ""
  property string confirmKey: ""
  property bool deleteData: false

  // Operación en curso (solo una a la vez).
  property string opLabel: ""
  property string opLine: ""
  property int opProgress: -1
  property string opResult: ""
  property bool opFailed: false
  property var opAfter: null
  property string opOpenId: ""
  readonly property bool busy: opProc.running

  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string helper: localPath(Qt.resolvedUrl("scripts/flatpak.py"))

  readonly property color fg: Color.popups.text
  readonly property color bg: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.10)
  readonly property color warn: "#E5A445"
  readonly property string fontFamily: Style.font.family

  readonly property var selectedApp: {
    for (var i = 0; i < root.apps.length; i++)
      if (root.appKey(root.apps[i]) === root.selectedKey) return root.apps[i]
    return null
  }
  readonly property var filteredApps: root.apps.filter(function(a) { return Model.matches(a, root.filter) })
  readonly property real appsSize: {
    var t = 0
    for (var i = 0; i < root.apps.length; i++) t += root.apps[i].size || 0
    return t
  }
  readonly property var updateMap: {
    var m = {}
    for (var i = 0; i < root.updates.length; i++) m[root.updates[i].id + "/" + root.updates[i].installation] = root.updates[i]
    return m
  }

  readonly property var tabOptions: {
    var opts = []
    if (root.fileInfo || root.filePath !== "")
      opts.push({ value: "file", label: "Fichero", icon: glyph(0xF0214), tooltip: "Instalar el fichero abierto (0)" })
    opts.push({ value: "installed", label: "Instaladas", icon: glyph(0xF003B), tooltip: "Aplicaciones instaladas (1)" })
    opts.push({ value: "updates", label: root.updates.length > 0 ? "Actualizaciones · " + root.updates.length : "Actualizaciones",
                icon: glyph(0xF06B0), tooltip: "Actualizaciones pendientes (2)" })
    opts.push({ value: "search", label: "Buscar", icon: glyph(0xF0349), tooltip: "Buscar en Flathub (3, /)" })
    return opts
  }

  function glyph(cp) { return String.fromCodePoint(cp) }
  function appKey(a) { return a ? a.id + "/" + a.installation : "" }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function ago(ms) {
    if (!ms) return ""
    var s = Math.max(0, Math.round((Date.now() - ms) / 1000))
    if (s < 60) return "hace un momento"
    if (s < 3600) return "hace " + Math.round(s / 60) + " min"
    return "hace " + Math.round(s / 3600) + " h"
  }

  // ---------- Ciclo de vida ----------
  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}
    root.opened = true
    root.confirmKey = ""
    if (payload.file) {
      root.filePath = String(payload.file)
      root.fileInfo = null
      root.tab = "file"
      if (!root.busy) { root.opResult = ""; root.opFailed = false }
      inspectProc.command = ["python3", root.helper, "inspect", root.filePath]
      inspectProc.running = true
    } else if (payload.search) {
      root.tab = "search"
      root.runSearch(String(payload.search))
    } else if (payload.tab) {
      root.tab = String(payload.tab)
    }
    root.refresh()
    if (!root.updatesChecked || Date.now() - root.updatesCheckedAt > 15 * 60000) root.checkUpdates()
    Qt.callLater(function() {
      if (!root.opened) return
      if (root.tab === "search" && !payload.search) searchField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    root.confirmKey = ""
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "julss.flatpak")
    else close()
  }

  function setTab(t) {
    root.tab = t
    root.confirmKey = ""
    if (t === "search") Qt.callLater(function() { searchField.forceActiveFocus() })
    else keyCatcher.forceActiveFocus()
  }

  function refresh() {
    if (!listProc.running) listProc.running = true
  }

  function checkUpdates() {
    if (!updProc.running) updProc.running = true
  }

  function runSearch(q) {
    q = String(q || "").trim()
    root.searchQuery = q
    if (searchField.text !== q) searchField.text = q
    if (q.length < 2) { root.searchResults = []; root.searched = false; return }
    searchProc.running = false
    searchProc.command = ["python3", root.helper, "search", q]
    searchProc.running = true
  }

  function select(app) {
    root.selectedKey = root.appKey(app)
    root.confirmKey = ""
    root.deleteData = false
    root.details = null
    if (!app) return
    detailsProc.running = false
    detailsProc.command = ["python3", root.helper, "details", app.id, app.installation]
    detailsProc.running = true
  }

  // ---------- Operaciones ----------
  function runOp(label, cmd, after, openId) {
    if (root.busy) return
    root.opLabel = label
    root.opLine = ""
    root.opProgress = -1
    root.opResult = ""
    root.opFailed = false
    root.opAfter = after || null
    root.opOpenId = openId || ""
    root.confirmKey = ""
    opProc.command = ["python3", root.helper, "run", "--"].concat(cmd)
    opProc.running = true
  }

  function installRemote(item) {
    var ref = item.id + (item.branch ? "//" + item.branch : "")
    root.runOp("Instalando " + item.name,
      ["flatpak", "install", "--system", "-y", "--noninteractive", item.remote || "flathub", ref],
      "installed:" + item.name, item.id)
  }

  function uninstall(app) {
    var cmd = ["flatpak", "uninstall", "--" + app.installation, "-y", "--noninteractive"]
    if (root.deleteData) cmd.push("--delete-data")
    cmd.push(app.id)
    root.runOp("Desinstalando " + app.name, cmd, "uninstalled:" + app.name)
  }

  function updateOne(u) {
    root.runOp("Actualizando " + u.name,
      ["flatpak", "update", "--" + u.installation, "-y", "--noninteractive", u.ref || u.id],
      "updated:" + u.name)
  }

  function updateAll() {
    root.runOp("Actualizando todo",
      ["bash", "-c", "flatpak update --system -y --noninteractive; s=$?; flatpak update --user -y --noninteractive || s=$?; exit $s"],
      "updated:todo")
  }

  function cleanUnused() {
    root.runOp("Quitando runtimes que ya no usa nadie",
      ["bash", "-c", "flatpak uninstall --system --unused -y --noninteractive; flatpak uninstall --user --unused -y --noninteractive"],
      "cleaned:")
  }

  function installFile() {
    var f = root.fileInfo
    if (!f) return
    var inst = "--" + root.fileInstallation
    var cmd
    if (f.kind === "repo") {
      cmd = ["flatpak", "remote-add", inst, "--if-not-exists", f.id, "--from", f.file]
      root.runOp("Añadiendo el repositorio " + f.name, cmd, "repo:" + f.name)
      return
    }
    cmd = ["flatpak", "install", inst, "-y", "--noninteractive"]
    if (root.installedIn(root.fileInstallation)) cmd.push("--reinstall")
    cmd = cmd.concat(f.kind === "bundle" ? ["--bundle", f.file] : ["--from", f.file])
    root.runOp((root.installedIn(root.fileInstallation) ? "Reinstalando " : "Instalando ") + f.name, cmd,
      "installed:" + f.name, f.isRuntime ? "" : f.id)
  }

  function installedIn(inst) {
    var list = (root.fileInfo && root.fileInfo.installed) || []
    for (var i = 0; i < list.length; i++) if (list[i].installation === inst) return list[i]
    return null
  }

  function launch(id) {
    Quickshell.execDetached(["uwsm-app", "--", "flatpak", "run", id])
    root.dismiss()
  }

  function opFinished(code) {
    var after = String(root.opAfter || "")
    var kind = after.split(":")[0], name = after.substring(kind.length + 1)
    root.opFailed = code !== 0
    root.opProgress = -1
    if (code !== 0) {
      root.opResult = "Ha fallado: " + (root.opLine || ("código " + code))
    } else if (kind === "installed") {
      root.opResult = name + " instalada"
    } else if (kind === "uninstalled") {
      root.opResult = name + " desinstalada"
      root.selectedKey = ""
      root.details = null
    } else if (kind === "updated") {
      root.opResult = name === "todo" ? "Todo al día" : name + " actualizada"
    } else if (kind === "cleaned") {
      root.opResult = "Limpieza hecha"
    } else if (kind === "repo") {
      root.opResult = "Repositorio " + name + " añadido"
    } else {
      root.opResult = "Hecho"
    }
    if (!root.opened)
      Quickshell.execDetached(["notify-send", "-a", "Flatpak", "-i", "package-x-generic",
        root.opFailed ? "Flatpak: algo ha fallado" : "Flatpak", root.opResult])
    root.refresh()
    root.checkUpdates()
    if (root.filePath !== "" && root.fileInfo) {
      inspectProc.command = ["python3", root.helper, "inspect", root.filePath]
      inspectProc.running = true
    }
    if (root.searched) root.runSearch(root.searchQuery)
  }

  // ---------- Procesos ----------
  Process {
    id: listProc
    command: ["python3", root.helper, "installed"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var d = JSON.parse(text || "{}")
          root.apps = d.apps || []
          root.runtimeCount = d.runtimeCount || 0
          root.runtimeSize = d.runtimeSize || 0
          root.loadedOnce = true
          if (root.selectedKey === "" && root.apps.length > 0) root.select(root.apps[0])
          else if (root.selectedKey !== "" && !root.selectedApp) root.select(root.apps.length > 0 ? root.apps[0] : null)
        } catch (e) {}
      }
    }
  }

  Process {
    id: updProc
    command: ["python3", root.helper, "updates"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.updates = JSON.parse(text || "{}").updates || [] } catch (e) { root.updates = [] }
        root.updatesChecked = true
        root.updatesCheckedAt = Date.now()
      }
    }
  }

  Process {
    id: searchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.searchResults = JSON.parse(text || "{}").results || [] } catch (e) { root.searchResults = [] }
        root.searched = true
      }
    }
  }

  Process {
    id: detailsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.details = JSON.parse(text || "null") } catch (e) { root.details = null }
      }
    }
  }

  Process {
    id: inspectProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var info = null
        try { info = JSON.parse(text || "null") } catch (e) {}
        root.fileInfo = info || { error: "No se ha podido leer el fichero", fileName: root.filePath.split("/").pop(), installed: [] }
      }
    }
  }

  Process {
    id: opProc
    stdout: SplitParser {
      onRead: function(line) {
        var l = String(line).trim()
        if (l === "") return
        var m = l.match(/(\d{1,3})\s*%/)
        if (m) { root.opProgress = Math.min(100, parseInt(m[1])); indet.x = 0 }
        root.opLine = l.replace(/[▀-▟]+/g, "").replace(/\s{2,}/g, " ").trim()
      }
    }
    onExited: function(exitCode) { root.opFinished(exitCode) }
  }

  // ---------- Piezas ----------
  component AppIcon: Item {
    id: appIcon
    property string path: ""
    property real size: Style.space(36)
    property int fallback: 0xF03D6
    implicitWidth: size
    implicitHeight: size

    Image {
      id: img
      anchors.fill: parent
      source: appIcon.path !== "" ? "file://" + appIcon.path : ""
      sourceSize.width: appIcon.size * 2
      sourceSize.height: appIcon.size * 2
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      smooth: true
      mipmap: true
    }

    Rectangle {
      anchors.fill: parent
      visible: img.status !== Image.Ready
      radius: Style.cornerRadius
      color: root.faint
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.glyph(appIcon.fallback)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: appIcon.size * 0.55
      }
    }
  }

  component Label: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: 1.2
    elide: Text.ElideRight
  }

  component Chip: Rectangle {
    property string text: ""
    property bool risk: false
    property int icon: 0
    implicitHeight: chipRow.implicitHeight + Style.space(6)
    implicitWidth: chipRow.implicitWidth + Style.space(14)
    radius: height / 2
    color: risk ? Qt.rgba(root.warn.r, root.warn.g, root.warn.b, 0.16) : root.faint

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(5)
      Text {
        visible: parent.parent.icon > 0
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: parent.parent.icon > 0 ? root.glyph(parent.parent.icon) : ""
        color: parent.parent.risk ? root.warn : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: parent.parent.text
        color: parent.parent.risk ? root.warn : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // Botón de acción con color (instalar / desinstalar).
  component ActionButton: Button {
    property bool danger: false
    property bool primary: false
    bordered: true
    foreground: danger ? Color.urgent : (primary ? Color.accent : root.fg)
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    iconSize: Style.font.bodySmall
    opacity: enabled ? 1 : 0.4
  }

  component Permissions: Flow {
    property var perms: null
    spacing: Style.space(6)
    Repeater {
      model: Model.permissionList(parent.perms)
      Chip {
        required property var modelData
        text: modelData.text
        icon: modelData.icon
        risk: modelData.risk
      }
    }
  }

  component EmptyText: Text {
    textFormat: Text.PlainText
    horizontalAlignment: Text.AlignHCenter
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  // ---------- Ventana ----------
  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "julss-flatpak"
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
        else if (event.text === "0" && root.filePath !== "") root.setTab("file")
        else if (event.text === "1") root.setTab("installed")
        else if (event.text === "2") root.setTab("updates")
        else if (event.text === "3" || event.text === "/") root.setTab("search")
        else if (event.text === "r" || event.text === "R") { root.refresh(); root.checkUpdates() }
        else if (root.tab === "installed" && (event.key === Qt.Key_Down || event.text === "j")) moveSelection(1)
        else if (root.tab === "installed" && (event.key === Qt.Key_Up || event.text === "k")) moveSelection(-1)
        else if (root.tab === "installed" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.selectedApp) root.launch(root.selectedApp.id)
        else if (root.tab === "installed" && event.text.length === 1 && /[\w]/.test(event.text)) {
          filterField.text = event.text
          filterField.forceActiveFocus()
        }
        else return
        event.accepted = true
      }

      function moveSelection(delta) {
        var list = root.filteredApps
        if (list.length === 0) return
        var idx = -1
        for (var i = 0; i < list.length; i++) if (root.appKey(list[i]) === root.selectedKey) idx = i
        idx = Math.max(0, Math.min(list.length - 1, idx + delta))
        root.select(list[idx])
        appList.positionViewAtIndex(idx, ListView.Contain)
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(48), Style.space(1060))
        height: Math.min(parent.height - Style.space(48), Style.space(700))
        radius: Style.cornerRadius
        color: root.bg
        border.width: 1
        border.color: root.borderColor

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onClicked: keyCatcher.forceActiveFocus() }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(20)
          spacing: Style.space(14)

          // ---------- Cabecera ----------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(14)

            Text {
              textFormat: Text.PlainText
              text: root.glyph(0xF03D6)
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }

            ColumnLayout {
              Layout.fillWidth: true
              spacing: Style.space(2)

              Label {
                Layout.fillWidth: true
                text: "Flatpak"
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Caption {
                Layout.fillWidth: true
                text: !root.loadedOnce ? "APLICACIONES EN CAJITAS"
                  : (Model.plural(root.apps.length, "APP", "APPS") + " · " + Model.formatBytes(root.appsSize)
                     + "  ·  " + Model.plural(root.runtimeCount, "RUNTIME", "RUNTIMES") + " · " + Model.formatBytes(root.runtimeSize))
              }
            }

            ButtonGroup {
              options: root.tabOptions
              value: root.tab
              focusable: false
              foreground: root.fg
              background: root.bg
              fontFamily: root.fontFamily
              fontSize: Style.font.bodySmall
              onChanged: function(v) { root.setTab(v) }
            }

            Button {
              iconText: root.glyph(0xF0450)
              iconSpinning: listProc.running || updProc.running
              foreground: root.fg
              fontFamily: root.fontFamily
              tooltipText: "Recargar y buscar actualizaciones (R)"
              onClicked: { root.refresh(); root.checkUpdates() }
            }

            Button {
              iconText: root.glyph(0xF0156)
              foreground: root.fg
              fontFamily: root.fontFamily
              tooltipText: "Cerrar (Esc)"
              onClicked: root.dismiss()
            }
          }

          // ---------- Contenido ----------
          Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ===== Instaladas =====
            RowLayout {
              anchors.fill: parent
              visible: root.tab === "installed"
              spacing: Style.space(18)

              ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 5
                spacing: Style.space(10)

                TextField {
                  id: filterField
                  Layout.fillWidth: true
                  placeholderText: "Filtrar instaladas…"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  foreground: root.fg
                  onTextChanged: root.filter = text
                  Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
                  Keys.onDownPressed: { keyCatcher.moveSelection(1); keyCatcher.forceActiveFocus() }
                  onAccepted: { if (root.filteredApps.length > 0) root.select(root.filteredApps[0]); keyCatcher.forceActiveFocus() }
                }

                ListView {
                  id: appList
                  Layout.fillWidth: true
                  Layout.fillHeight: true
                  clip: true
                  spacing: Style.space(2)
                  model: root.filteredApps
                  boundsBehavior: Flickable.StopAtBounds
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  delegate: Rectangle {
                    required property var modelData
                    readonly property bool sel: root.appKey(modelData) === root.selectedKey
                    readonly property var upd: root.updateMap[root.appKey(modelData)]
                    width: ListView.view.width - Style.space(10)
                    height: rowLay.implicitHeight + Style.space(12)
                    radius: Math.min(6, Style.cornerRadius)
                    color: sel ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
                      : rowMouse.containsMouse ? root.faint : "transparent"

                    MouseArea {
                      id: rowMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: { root.select(modelData); keyCatcher.forceActiveFocus() }
                      onDoubleClicked: root.launch(modelData.id)
                    }

                    RowLayout {
                      id: rowLay
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(12)

                      AppIcon { path: modelData.icon; size: Style.space(34) }

                      ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Label { Layout.fillWidth: true; text: modelData.name; font.bold: true }
                        Label {
                          Layout.fillWidth: true
                          text: modelData.summary || modelData.id
                          color: root.dim
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      Chip {
                        visible: !!upd
                        text: "Nueva " + (upd ? upd.version || "versión" : "")
                        icon: 0xF06B0
                        risk: true
                      }

                      ColumnLayout {
                        spacing: 0
                        Label {
                          Layout.alignment: Qt.AlignRight
                          text: Model.formatBytes(modelData.size)
                          font.pixelSize: Style.font.bodySmall
                        }
                        Label {
                          Layout.alignment: Qt.AlignRight
                          text: modelData.version || modelData.branch
                          color: root.dim
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }

                  EmptyText {
                    anchors.centerIn: parent
                    width: parent.width
                    visible: appList.count === 0
                    text: !root.loadedOnce ? "Mirando qué hay instalado…"
                      : root.apps.length === 0 ? "No hay ninguna app Flatpak instalada.\nBusca una en la pestaña Buscar."
                      : "Nada coincide con «" + root.filter + "»"
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(8)
                  Caption {
                    Layout.fillWidth: true
                    text: "RUNTIMES: " + Model.formatBytes(root.runtimeSize) + " COMPARTIDOS ENTRE APPS"
                  }
                  ActionButton {
                    text: "Limpiar sin uso"
                    iconText: root.glyph(0xF00E2)
                    enabled: !root.busy
                    tooltipText: "Quitar runtimes y extensiones que ya no usa ninguna app"
                    onClicked: root.cleanUnused()
                  }
                }
              }

              Rectangle {
                Layout.fillHeight: true
                implicitWidth: 1
                color: root.faint
              }

              // Detalles de la app elegida.
              Flickable {
                id: detailFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 4
                clip: true
                contentHeight: detailCol.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                EmptyText {
                  anchors.centerIn: parent
                  width: parent.width
                  visible: !root.selectedApp
                  text: "Elige una app de la lista"
                }

                ColumnLayout {
                  id: detailCol
                  width: detailFlick.width - Style.space(12)
                  visible: !!root.selectedApp
                  spacing: Style.space(12)

                  readonly property var app: root.selectedApp || ({})
                  readonly property var d: root.details && root.details.id === app.id ? root.details : ({})
                  readonly property var upd: root.updateMap[root.appKey(root.selectedApp)]

                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(14)
                    AppIcon { path: detailCol.app.icon || ""; size: Style.space(64) }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(2)
                      Label {
                        Layout.fillWidth: true
                        text: detailCol.d.name || detailCol.app.name || ""
                        font.pixelSize: Style.font.title
                        font.bold: true
                      }
                      Label {
                        Layout.fillWidth: true
                        text: detailCol.d.developer ? "de " + detailCol.d.developer : (detailCol.app.id || "")
                        color: root.dim
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                  }

                  Flow {
                    Layout.fillWidth: true
                    spacing: Style.space(8)
                    ActionButton {
                      text: "Abrir"
                      iconText: root.glyph(0xF040A)
                      primary: true
                      onClicked: root.launch(detailCol.app.id)
                    }
                    ActionButton {
                      visible: !!detailCol.upd
                      text: "Actualizar"
                      iconText: root.glyph(0xF06B0)
                      primary: true
                      enabled: !root.busy
                      onClicked: root.updateOne(detailCol.upd)
                    }
                    ActionButton {
                      text: root.confirmKey === "rm:" + root.selectedKey ? "¿Seguro? Desinstalar" : "Desinstalar"
                      iconText: root.glyph(0xF01B4)
                      danger: true
                      enabled: !root.busy
                      onClicked: {
                        if (root.confirmKey === "rm:" + root.selectedKey) root.uninstall(detailCol.app)
                        else root.confirmKey = "rm:" + root.selectedKey
                      }
                    }
                    ActionButton {
                      visible: !!detailCol.d.dataDir
                      text: "Sus datos"
                      iconText: root.glyph(0xF024B)
                      tooltipText: detailCol.d.dataDir || ""
                      onClicked: Quickshell.execDetached(["nautilus", detailCol.d.dataDir])
                    }
                  }

                  RowLayout {
                    visible: root.confirmKey === "rm:" + root.selectedKey && !!detailCol.d.dataDir
                    spacing: Style.space(8)
                    ToggleSwitch {
                      checked: root.deleteData
                      onToggled: root.deleteData = !root.deleteData
                    }
                    Label {
                      text: "Borrar también sus datos (" + Model.formatBytes(detailCol.d.dataSize) + ")"
                      font.pixelSize: Style.font.bodySmall
                      MouseArea { anchors.fill: parent; onClicked: root.deleteData = !root.deleteData }
                    }
                  }

                  Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: detailCol.d.summary || detailCol.app.summary || ""
                    wrapMode: Text.WordWrap
                    elide: Text.ElideNone
                  }

                  Label {
                    Layout.fillWidth: true
                    visible: text !== ""
                    text: detailCol.d.description || ""
                    color: root.dim
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                    elide: Text.ElideRight
                    maximumLineCount: 8
                  }

                  GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: Style.space(14)
                    rowSpacing: Style.space(4)

                    Repeater {
                      model: [
                        ["Versión", (detailCol.app.version || "—") + (detailCol.app.branch ? "  (" + detailCol.app.branch + ")" : "")],
                        ["Instalada", Model.installationLabel(detailCol.app.installation) + " · " + Model.formatBytes(detailCol.app.size)],
                        ["Datos", detailCol.d.dataDir ? Model.formatBytes(detailCol.d.dataSize) + " en ~/.var/app" : "—"],
                        ["Origen", detailCol.app.origin || "—"],
                        ["Runtime", detailCol.d.runtime || "…"],
                        ["Licencia", detailCol.d.license || "—"],
                        ["ID", detailCol.app.id || ""]
                      ]
                      delegate: Item {
                        required property var modelData
                        required property int index
                        Layout.columnSpan: 2
                        Layout.fillWidth: true
                        implicitHeight: infoRow.implicitHeight
                        RowLayout {
                          id: infoRow
                          anchors.fill: parent
                          spacing: Style.space(14)
                          Label {
                            Layout.preferredWidth: Style.space(78)
                            text: modelData[0]
                            color: root.dim
                            font.pixelSize: Style.font.bodySmall
                          }
                          Label {
                            Layout.fillWidth: true
                            text: modelData[1]
                            font.pixelSize: Style.font.bodySmall
                            elide: Text.ElideMiddle
                          }
                        }
                      }
                    }
                  }

                  Label {
                    visible: !!detailCol.d.homepage
                    text: root.glyph(0xF059F) + "  " + (detailCol.d.homepage || "")
                    color: homeMouse.containsMouse ? Color.accent : root.dim
                    font.pixelSize: Style.font.bodySmall
                    Layout.fillWidth: true
                    MouseArea {
                      id: homeMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: { Quickshell.execDetached(["xdg-open", detailCol.d.homepage]); root.dismiss() }
                    }
                  }

                  Caption {
                    text: "PERMISOS"
                    visible: Model.permissionList(detailCol.d.permissions).length > 0
                  }
                  Permissions {
                    Layout.fillWidth: true
                    perms: detailCol.d.permissions || null
                  }
                }
              }
            }

            // ===== Actualizaciones =====
            ColumnLayout {
              anchors.fill: parent
              visible: root.tab === "updates"
              spacing: Style.space(10)

              RowLayout {
                Layout.fillWidth: true
                Caption {
                  Layout.fillWidth: true
                  text: updProc.running ? "BUSCANDO ACTUALIZACIONES…"
                    : root.updates.length === 0 ? "TODO AL DÍA · COMPROBADO " + root.ago(root.updatesCheckedAt).toUpperCase()
                    : Model.plural(root.updates.length, "ACTUALIZACIÓN PENDIENTE", "ACTUALIZACIONES PENDIENTES")
                }
                ActionButton {
                  text: "Actualizar todo"
                  iconText: root.glyph(0xF06B0)
                  primary: true
                  visible: root.updates.length > 0
                  enabled: !root.busy
                  onClicked: root.updateAll()
                }
              }

              ListView {
                id: updList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Style.space(2)
                model: root.updates
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                  required property var modelData
                  width: ListView.view.width - Style.space(10)
                  height: updRow.implicitHeight + Style.space(12)
                  radius: Math.min(6, Style.cornerRadius)
                  color: updMouse.containsMouse ? root.faint : "transparent"
                  MouseArea { id: updMouse; anchors.fill: parent; hoverEnabled: true }

                  RowLayout {
                    id: updRow
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(12)
                    AppIcon { path: modelData.icon; size: Style.space(34); fallback: modelData.runtime ? 0xF035B : 0xF03D6 }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0
                      Label { Layout.fillWidth: true; text: modelData.name; font.bold: true }
                      Label {
                        Layout.fillWidth: true
                        text: (modelData.runtime ? "Runtime · " : "")
                          + (modelData.oldVersion && modelData.version && modelData.oldVersion !== modelData.version
                             ? modelData.oldVersion + " → " + modelData.version
                             : (modelData.version || modelData.branch))
                          + " · " + Model.installationLabel(modelData.installation)
                        color: root.dim
                        font.pixelSize: Style.font.bodySmall
                      }
                    }
                    Label {
                      text: modelData.download > 0 ? Model.formatBytes(modelData.download) : ""
                      color: root.dim
                      font.pixelSize: Style.font.bodySmall
                    }
                    ActionButton {
                      text: "Actualizar"
                      iconText: root.glyph(0xF01DA)
                      enabled: !root.busy
                      onClicked: root.updateOne(modelData)
                    }
                  }
                }

                EmptyText {
                  anchors.centerIn: parent
                  width: parent.width
                  visible: updList.count === 0
                  text: updProc.running ? "Preguntando a Flathub…" : root.glyph(0xF012C) + "  Todo al día"
                }
              }
            }

            // ===== Buscar =====
            ColumnLayout {
              anchors.fill: parent
              visible: root.tab === "search"
              spacing: Style.space(10)

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)
                TextField {
                  id: searchField
                  Layout.fillWidth: true
                  placeholderText: "Buscar en Flathub (nombre o para qué sirve) y pulsa Intro…"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  foreground: root.fg
                  onAccepted: root.runSearch(text)
                  Keys.onEscapePressed: {
                    if (text !== "") text = ""
                    else keyCatcher.forceActiveFocus()
                  }
                }
                ActionButton {
                  text: searchProc.running ? "Buscando" : "Buscar"
                  iconText: root.glyph(0xF0349)
                  iconSpinning: searchProc.running
                  onClicked: root.runSearch(searchField.text)
                }
              }

              ListView {
                id: resultList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                spacing: Style.space(2)
                model: root.searchResults
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: Rectangle {
                  required property var modelData
                  width: ListView.view.width - Style.space(10)
                  height: resRow.implicitHeight + Style.space(12)
                  radius: Math.min(6, Style.cornerRadius)
                  color: resMouse.containsMouse ? root.faint : "transparent"
                  MouseArea { id: resMouse; anchors.fill: parent; hoverEnabled: true }

                  RowLayout {
                    id: resRow
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(12)
                    AppIcon { path: modelData.icon; size: Style.space(38) }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0
                      Label { Layout.fillWidth: true; text: modelData.name; font.bold: true }
                      Label {
                        Layout.fillWidth: true
                        text: modelData.summary
                        color: root.dim
                        font.pixelSize: Style.font.bodySmall
                      }
                      Label {
                        Layout.fillWidth: true
                        text: modelData.id + (modelData.version ? " · " + modelData.version : "")
                        color: root.dim
                        font.pixelSize: Style.font.caption
                      }
                    }
                    ActionButton {
                      visible: modelData.installed
                      text: "Abrir"
                      iconText: root.glyph(0xF040A)
                      onClicked: root.launch(modelData.id)
                    }
                    ActionButton {
                      visible: !modelData.installed
                      text: "Instalar"
                      iconText: root.glyph(0xF01DA)
                      primary: true
                      enabled: !root.busy
                      onClicked: root.installRemote(modelData)
                    }
                  }
                }

                EmptyText {
                  anchors.centerIn: parent
                  width: parent.width
                  visible: resultList.count === 0
                  text: searchProc.running ? "Buscando…"
                    : root.searched ? "Nada en Flathub para «" + root.searchQuery + "»"
                    : "Escribe qué buscas: «vlc», «editor de fotos», «obs»…"
                }
              }
            }

            // ===== Fichero =====
            Flickable {
              id: fileFlick
              anchors.fill: parent
              visible: root.tab === "file"
              clip: true
              contentHeight: fileCol.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              EmptyText {
                anchors.centerIn: parent
                width: parent.width
                visible: !root.fileInfo
                text: "Leyendo " + root.filePath.split("/").pop() + "…"
              }

              ColumnLayout {
                id: fileCol
                width: Math.min(fileFlick.width - Style.space(12), Style.space(760))
                x: (fileFlick.width - width) / 2
                visible: !!root.fileInfo
                spacing: Style.space(14)

                readonly property var f: root.fileInfo || ({})
                readonly property var here: root.installedIn(root.fileInstallation)
                readonly property var anywhere: (f.installed || []).length > 0 ? f.installed[0] : null

                Item { implicitHeight: Style.space(4) }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(18)
                  AppIcon {
                    path: fileCol.f.icon || ""
                    size: Style.space(88)
                    fallback: fileCol.f.kind === "repo" ? 0xF0B9F : (fileCol.f.isRuntime ? 0xF035B : 0xF03D6)
                  }
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(3)
                    Caption {
                      text: fileCol.f.kind === "repo" ? "REPOSITORIO FLATPAK"
                        : fileCol.f.kind === "ref" ? "APP DE " + String(fileCol.f.remote || fileCol.f.suggestedRemote || "UN REPOSITORIO").toUpperCase()
                        : fileCol.f.isRuntime ? "RUNTIME EN UN FICHERO" : "APP EN UN FICHERO"
                    }
                    Label {
                      Layout.fillWidth: true
                      text: fileCol.f.name || fileCol.f.fileName || ""
                      font.pixelSize: Style.font.display
                      font.bold: true
                    }
                    Label {
                      Layout.fillWidth: true
                      visible: text !== ""
                      text: [fileCol.f.version ? "Versión " + fileCol.f.version : "", fileCol.f.developer ? "de " + fileCol.f.developer : ""]
                        .filter(function(s) { return s !== "" }).join(" · ")
                      color: root.dim
                    }
                    Label {
                      Layout.fillWidth: true
                      text: fileCol.f.id || ""
                      color: root.dim
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Label {
                  Layout.fillWidth: true
                  visible: !!fileCol.f.error
                  text: fileCol.f.error || ""
                  color: Color.urgent
                  wrapMode: Text.WordWrap
                }

                Label {
                  Layout.fillWidth: true
                  visible: text !== ""
                  text: fileCol.f.summary || ""
                  wrapMode: Text.WordWrap
                  elide: Text.ElideNone
                }

                Label {
                  Layout.fillWidth: true
                  visible: text !== ""
                  text: fileCol.f.description || ""
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  maximumLineCount: 7
                }

                // Estado: ya instalada, runtime que hará falta, avisos.
                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)

                  Label {
                    Layout.fillWidth: true
                    visible: !!fileCol.anywhere
                    text: root.glyph(0xF012C) + "  Ya instalada (" + (fileCol.anywhere ? Model.installationLabel(fileCol.anywhere.installation).toLowerCase()
                      + (fileCol.anywhere.version ? ", versión " + fileCol.anywhere.version : "") : "") + ")"
                      + (fileCol.anywhere && fileCol.f.version && fileCol.anywhere.version && fileCol.anywhere.version !== fileCol.f.version
                         ? " — el fichero trae la " + fileCol.f.version : "")
                    color: Color.accent
                    wrapMode: Text.WordWrap
                  }
                  Label {
                    Layout.fillWidth: true
                    visible: fileCol.f.kind !== "repo" && !!fileCol.f.runtime && fileCol.f.runtimeInstalled === false
                    text: root.glyph(0xF0162) + "  Necesita " + (fileCol.f.runtime || "").split("/")[0] + " " + (fileCol.f.runtime || "").split("/").pop()
                      + ", que se descargará" + (fileCol.f.runtimeRepo && fileCol.f.runtimeRepo.indexOf("flathub") >= 0 ? " de Flathub" : "")
                    color: root.dim
                    wrapMode: Text.WordWrap
                  }
                  Label {
                    Layout.fillWidth: true
                    visible: fileCol.f.kind === "repo" && !!fileCol.f.existingRemote
                    text: root.glyph(0xF012C) + "  Ya lo tienes como «" + (fileCol.f.existingRemote || "") + "»"
                    color: Color.accent
                  }
                  Label {
                    Layout.fillWidth: true
                    visible: !!fileCol.f.warning
                    text: root.glyph(0xF0026) + "  " + (fileCol.f.warning || "")
                    color: root.warn
                    wrapMode: Text.WordWrap
                  }
                  Label {
                    Layout.fillWidth: true
                    visible: fileCol.f.kind === "bundle"
                    text: root.glyph(0xF0026) + "  Viene en un fichero suelto, no de Flathub: no se actualizará sola. Instálala solo si te fías de dónde la has sacado."
                    color: root.dim
                    font.pixelSize: Style.font.bodySmall
                    wrapMode: Text.WordWrap
                  }
                }

                GridLayout {
                  Layout.fillWidth: true
                  columns: 2
                  columnSpacing: Style.space(14)
                  rowSpacing: Style.space(4)
                  Repeater {
                    model: [
                      ["Fichero", (fileCol.f.fileName || "") + " · " + Model.formatBytes(fileCol.f.fileSize)],
                      ["Descarga", fileCol.f.download > 0 ? Model.formatBytes(fileCol.f.download) + (fileCol.f.installedSizeEstimate > 0 ? " (ocupa " + Model.formatBytes(fileCol.f.installedSizeEstimate) + ")" : "") : ""],
                      ["Rama", fileCol.f.branch || ""],
                      ["Runtime", fileCol.f.runtime || ""],
                      ["Licencia", fileCol.f.license || ""],
                      ["Dirección", fileCol.f.url || ""],
                      ["Web", fileCol.f.homepage || ""]
                    ].filter(function(r) { return r[1] !== "" })
                    delegate: Item {
                      required property var modelData
                      Layout.columnSpan: 2
                      Layout.fillWidth: true
                      implicitHeight: fRow.implicitHeight
                      RowLayout {
                        id: fRow
                        anchors.fill: parent
                        spacing: Style.space(14)
                        Label { Layout.preferredWidth: Style.space(78); text: modelData[0]; color: root.dim; font.pixelSize: Style.font.bodySmall }
                        Label { Layout.fillWidth: true; text: modelData[1]; font.pixelSize: Style.font.bodySmall; elide: Text.ElideMiddle }
                      }
                    }
                  }
                }

                Caption {
                  text: "PODRÁ USAR"
                  visible: Model.permissionList(fileCol.f.permissions).length > 0
                }
                Permissions {
                  Layout.fillWidth: true
                  perms: fileCol.f.permissions || null
                }

                Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: root.faint; visible: !fileCol.f.error }

                RowLayout {
                  Layout.fillWidth: true
                  visible: !fileCol.f.error
                  spacing: Style.space(10)

                  ButtonGroup {
                    options: [
                      { value: "system", label: "Para todos", icon: root.glyph(0xF000E), tooltip: "Instalación del sistema (como Flathub)" },
                      { value: "user", label: "Solo para mí", icon: root.glyph(0xF0004), tooltip: "En ~/.local/share/flatpak" }
                    ]
                    value: root.fileInstallation
                    focusable: false
                    foreground: root.fg
                    background: root.bg
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    onChanged: function(v) { root.fileInstallation = v }
                  }

                  Item { Layout.fillWidth: true }

                  ActionButton {
                    visible: !!fileCol.anywhere && !fileCol.f.isRuntime && fileCol.f.kind !== "repo"
                    text: "Abrir"
                    iconText: root.glyph(0xF040A)
                    onClicked: root.launch(fileCol.f.id)
                  }

                  ActionButton {
                    text: fileCol.f.kind === "repo" ? (fileCol.f.existingRemote ? "Ya añadido" : "Añadir repositorio")
                      : fileCol.here ? "Reinstalar" : "Instalar"
                    iconText: root.glyph(fileCol.f.kind === "repo" ? 0xF0B9F : 0xF01DA)
                    primary: true
                    enabled: !root.busy && !(fileCol.f.kind === "repo" && fileCol.f.existingRemote)
                    onClicked: root.installFile()
                  }
                }

                Item { implicitHeight: Style.space(4) }
              }
            }
          }

          // ---------- Estado de la operación ----------
          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            visible: root.busy || root.opResult !== ""

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)
              Text {
                textFormat: Text.PlainText
                text: root.busy ? root.glyph(0xF0450) : root.glyph(root.opFailed ? 0xF0026 : 0xF012C)
                color: root.opFailed ? Color.urgent : Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                RotationAnimation on rotation {
                  running: root.busy
                  from: 0; to: 360; duration: 1000; loops: Animation.Infinite
                  onRunningChanged: if (!running) parent.rotation = 0
                }
              }
              Label {
                text: root.busy ? root.opLabel : root.opResult
                font.bold: true
                color: root.opFailed ? Color.urgent : root.fg
                Layout.maximumWidth: parent.width * 0.6
                elide: Text.ElideRight
              }
              Label {
                Layout.fillWidth: true
                visible: root.busy
                text: root.opLine
                color: root.dim
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideLeft
              }
              Item { Layout.fillWidth: true; visible: !root.busy }
              ActionButton {
                visible: !root.busy && !root.opFailed && root.opOpenId !== ""
                text: "Abrir"
                iconText: root.glyph(0xF040A)
                primary: true
                onClicked: root.launch(root.opOpenId)
              }
            }

            Item {
              Layout.fillWidth: true
              implicitHeight: Style.space(5)
              visible: root.busy
              Rectangle { anchors.fill: parent; radius: height / 2; color: root.faint }
              Rectangle {
                id: indet
                height: parent.height
                radius: height / 2
                color: Color.accent
                width: root.opProgress >= 0 ? Math.max(height, parent.width * root.opProgress / 100) : parent.width * 0.25
                Behavior on width { enabled: root.opProgress >= 0; NumberAnimation { duration: 250 } }
                SequentialAnimation on x {
                  running: root.busy && root.opProgress < 0
                  loops: Animation.Infinite
                  NumberAnimation { from: 0; to: indet.parent.width * 0.75; duration: 900; easing.type: Easing.InOutQuad }
                  NumberAnimation { from: indet.parent.width * 0.75; to: 0; duration: 900; easing.type: Easing.InOutQuad }
                }
                onVisibleChanged: x = 0
              }
            }
          }

          // ---------- Pie ----------
          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            visible: !root.busy && root.opResult === ""
            text: root.tab === "installed" ? "Doble clic o Intro: abrir · ↑↓: moverse · escribe para filtrar · 1-3: pestañas · Esc: cerrar"
              : root.tab === "search" ? "Se instala para todos desde Flathub · Intro: buscar · Esc: salir del cuadro"
              : root.tab === "file" ? "También puedes abrir .flatpak, .flatpakref y .flatpakrepo desde Archivos"
              : "R: volver a comprobar · Esc: cerrar"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
