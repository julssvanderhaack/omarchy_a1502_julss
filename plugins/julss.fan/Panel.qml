import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Ventilador: configura mbpfan (/etc/mbpfan.conf) y enseña a qué temperatura
// salta cada velocidad. La gráfica y la tabla usan el mismo cálculo que
// mbpfan (Model.js), así que lo que se ve es lo que hará el ventilador.
//
// Guardar llama a /usr/local/bin/julss-fan-apply con sudo sin contraseña
// (regla en /etc/sudoers.d/julss-fan); los dos los instala
// ~/src/mbpfan-hwmon/install.sh junto con mbpfan parcheado para el driver
// applesmc nuevo (kernel 7.2.8+).
//
// Se abre desde el panel de julss.sysmon (clic en VENTILADOR) o con
//   omarchy-shell shell summon julss.fan '{}'
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false

  // Estado en vivo (scripts/status.sh).
  property string serviceState: ""
  property int temp: -1
  property int rpm: -1
  property int hwMin: -1
  property int hwMax: -1
  property int mode: -1
  property bool helperInstalled: true

  // Configuración guardada y la que se está editando.
  property var saved: null
  property var draft: null
  property string confText: ""

  property bool applying: applyProc.running
  property string message: ""
  property bool messageIsError: false
  property int hoverTemp: -1

  readonly property bool active: root.serviceState === "active"
  readonly property bool dirty: root.draft && root.saved && !Model.same(root.draft, root.saved)
  readonly property string invalid: root.draft ? Model.validate(root.draft) : ""
  readonly property var rising: root.draft ? Model.risingSteps(root.draft) : []
  readonly property var falling: root.draft ? Model.fallingSteps(root.draft) : []
  readonly property int rpmCap: root.hwMax > 0 ? root.hwMax : Model.LIMITS.rpmMax

  readonly property string statusScript: localPath(Qt.resolvedUrl("scripts/status.sh"))
  readonly property string helper: "/usr/local/bin/julss-fan-apply"
  readonly property string installHint: "sudo ~/src/mbpfan-hwmon/install.sh"

  readonly property color fg: Color.popups.text
  readonly property color bg: Color.popups.background
  readonly property color borderColor: Color.popups.border
  readonly property color dim: Qt.rgba(fg.r, fg.g, fg.b, 0.6)
  readonly property color faint: Qt.rgba(fg.r, fg.g, fg.b, 0.12)
  readonly property color accent: Color.accent
  readonly property color coolColor: "#4FC3F7"
  readonly property color hotColor: "#FF8A50"
  readonly property color warnColor: "#EF5350"
  readonly property string fontFamily: Style.font.family

  readonly property var presets: [
    { label: "Silencioso", tooltip: "Aguanta más calor antes de acelerar",
      cfg: { low: 70, high: 80, max: 90, minRpm: 2000 } },
    { label: "Equilibrado", tooltip: "Lo de siempre: empieza a subir a 75 °C",
      cfg: { low: 65, high: 75, max: 85, minRpm: 2500 } },
    { label: "Fresco", tooltip: "Acelera pronto para que no pase de 80 °C",
      cfg: { low: 55, high: 62, max: 80, minRpm: 2500 } }
  ]

  function glyph(cp) { return String.fromCodePoint(cp) }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  // ---------- Ciclo de vida ----------
  function open(payloadJson) {
    root.opened = true
    root.message = ""
    root.hoverTemp = -1
    confFile.reload()
    refresh()
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "julss.fan")
    else close()
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function loadConf(text) {
    root.confText = text
    var cfg = Model.parseConf(text, root.hwMin, root.hwMax)
    var keepDraft = root.dirty
    root.saved = cfg
    if (!keepDraft) root.draft = Model.copy(cfg)
  }

  // ---------- Edición ----------
  function setField(key, value) {
    var d = Model.copy(root.draft)
    d[key] = value
    root.draft = d
    root.message = ""
  }

  function step(key, delta) {
    var d = root.draft
    var v = d[key] + delta
    var lo, hi
    if (key === "low") { lo = Model.LIMITS.tempMin; hi = d.high - 1 }
    else if (key === "high") { lo = d.low + 1; hi = d.max - 1 }
    else if (key === "max") { lo = d.high + 1; hi = Model.LIMITS.tempMax }
    else if (key === "minRpm") { lo = Model.LIMITS.rpmMin; hi = d.maxRpm - 100 }
    else if (key === "maxRpm") { lo = d.minRpm + 100; hi = root.rpmCap }
    else { lo = Model.LIMITS.intervalMin; hi = Model.LIMITS.intervalMax }
    // Las rpm se mueven de 100 en 100 sobre valores redondos.
    if (key === "minRpm" || key === "maxRpm") v = Math.round(v / 100) * 100
    v = Math.max(lo, Math.min(hi, v))
    if (v !== d[key]) setField(key, v)
  }

  function applyPreset(p) {
    var d = Model.copy(root.draft)
    d.low = p.cfg.low; d.high = p.cfg.high; d.max = p.cfg.max
    d.minRpm = p.cfg.minRpm
    d.maxRpm = root.rpmCap
    root.draft = d
    root.message = ""
  }

  function presetActive(p) {
    var d = root.draft
    return d && d.low === p.cfg.low && d.high === p.cfg.high && d.max === p.cfg.max && d.minRpm === p.cfg.minRpm
  }

  function revert() {
    if (root.saved) root.draft = Model.copy(root.saved)
    root.message = ""
  }

  function save() {
    if (!root.dirty && root.active) return
    if (root.invalid !== "" || root.applying) return
    var d = root.draft
    runHelper([String(d.low), String(d.high), String(d.max), String(d.minRpm), String(d.maxRpm), String(d.interval)],
              "Guardado: mbpfan ya usa la curva nueva")
  }

  function startService() {
    runHelper(["restart"], "mbpfan arrancado")
  }

  function runHelper(args, okText) {
    if (root.applying) return
    root.message = "Aplicando…"
    root.messageIsError = false
    applyProc.okText = okText
    applyProc.command = ["sudo", "-n", root.helper].concat(args)
    applyProc.running = true
  }

  // ---------- Procesos ----------
  Process {
    id: statusProc
    command: ["bash", root.statusScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var hadHw = root.hwMax > 0
        text.split("\n").forEach(function(line) {
          var sp = line.indexOf(" ")
          if (sp < 0) return
          var key = line.slice(0, sp), value = line.slice(sp + 1).trim()
          if (key === "active") root.serviceState = value
          else if (key === "temp") root.temp = parseInt(value, 10)
          else if (key === "rpm") root.rpm = parseInt(value, 10)
          else if (key === "hwmin") root.hwMin = parseInt(value, 10)
          else if (key === "hwmax") root.hwMax = parseInt(value, 10)
          else if (key === "mode") root.mode = parseInt(value, 10)
          else if (key === "helper") root.helperInstalled = value === "1"
        })
        // Sin max_fan1_speed en el fichero, mbpfan usa el máximo del SMC.
        if (!hadHw && root.hwMax > 0 && root.confText !== "") root.loadConf(root.confText)
      }
    }
  }

  Timer {
    interval: 2000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  FileView {
    id: confFile
    path: "/etc/mbpfan.conf"
    blockLoading: true
    printErrors: false
    onLoaded: root.loadConf(text())
    onLoadFailed: root.loadConf("")
  }

  Process {
    id: applyProc
    property string okText: ""
    property string errText: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: applyProc.errText = text.trim()
    }
    onExited: function(exitCode) {
      Qt.callLater(function() {
        if (exitCode === 0) {
          root.message = applyProc.okText
          root.messageIsError = false
          root.saved = null
          confFile.reload()
        } else {
          var err = applyProc.errText
          if (err.indexOf("password") >= 0 || err.indexOf("contraseña") >= 0 || err.indexOf("not found") >= 0
              || err.indexOf("no se") >= 0 || !root.helperInstalled)
            err = "Falta instalar el permiso: ejecuta " + root.installHint
          root.message = err !== "" ? err : "No se pudo aplicar (código " + exitCode + ")"
          root.messageIsError = true
        }
        root.refresh()
      })
    }
  }

  // ---------- Ventana ----------
  PanelWindow {
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "julss-fan"
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
        else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) root.save()
        else return
        event.accepted = true
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(parent.width - Style.space(48), Style.space(1000))
        height: Math.min(parent.height - Style.space(48), body.implicitHeight + Style.space(40))
        radius: Style.cornerRadius
        color: root.bg
        border.width: 1
        border.color: root.borderColor

        MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

        Flickable {
          anchors.fill: parent
          anchors.margins: Style.space(20)
          contentHeight: body.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ColumnLayout {
            id: body
            width: parent.width
            spacing: Style.space(14)

            // ---------- Cabecera ----------
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(14)

              Text {
                textFormat: Text.PlainText
                text: root.glyph(0xF0210)
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                RotationAnimator on rotation {
                  from: 0; to: 360
                  duration: root.rpm > 0 ? Math.max(600, 3600000 / root.rpm) : 4000
                  loops: Animation.Infinite
                  running: root.opened && root.rpm > 0
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: "Ventilador"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  text: (root.active ? "MBPFAN ACTIVO" : root.serviceState === "" ? "…" : "MBPFAN PARADO · LO LLEVA EL FIRMWARE")
                    + (root.temp >= 0 ? "  ·  " + root.temp + " °C" : "")
                  color: root.active ? root.dim : root.warnColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: 1
                  elide: Text.ElideRight
                }
              }

              Text {
                textFormat: Text.PlainText
                text: root.rpm >= 0 ? Model.formatRpm(root.rpm) : "—"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                font.bold: true
              }

              Text {
                Layout.alignment: Qt.AlignBottom
                Layout.bottomMargin: Style.space(6)
                textFormat: Text.PlainText
                text: "rpm"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            // ---------- Aviso si mbpfan no está en marcha ----------
            Rectangle {
              Layout.fillWidth: true
              visible: root.serviceState !== "" && !root.active
              implicitHeight: warnRow.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.12)
              border.width: 1
              border.color: Qt.rgba(root.warnColor.r, root.warnColor.g, root.warnColor.b, 0.5)

              RowLayout {
                id: warnRow
                anchors.fill: parent
                anchors.margins: Style.space(8)
                anchors.leftMargin: Style.space(12)
                spacing: Style.space(12)

                Text {
                  Layout.fillWidth: true
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  text: root.helperInstalled
                    ? "mbpfan no está en marcha, así que esta curva no se aplica: el ventilador va en automático del Mac."
                    : "mbpfan no funciona con el kernel nuevo. Instala la versión parcheada y el permiso con:  " + root.installHint
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Button {
                  visible: root.helperInstalled
                  text: "Arrancar"
                  iconText: root.glyph(0xF040A)
                  bordered: true
                  foreground: root.fg
                  onClicked: root.startService()
                }
              }
            }

            // ---------- Cuerpo: gráfica + escalones | controles ----------
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(24)

              // Columna izquierda
              ColumnLayout {
                Layout.fillWidth: true
                // Ocupa lo que deje la columna de controles, sin depender de su contenido.
                Layout.preferredWidth: 0
                Layout.minimumWidth: 0
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(12)

                SectionLabel {
                  text: "CURVA"
                  detail: root.hoverTemp >= 0 && root.draft
                    ? root.hoverTemp + " °C  ·  calentando " + Model.formatRpm(Model.risingRpm(root.draft, root.hoverTemp))
                      + "  ·  enfriando " + Model.formatRpm(Model.fallingRpm(root.draft, root.hoverTemp)) + " rpm"
                    : "pasa el ratón por la gráfica"
                }

                CurveChart {
                  Layout.fillWidth: true
                  Layout.preferredHeight: Style.space(230)
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(16)
                  Legend { swatch: root.hotColor; text: "Al calentarse" }
                  Legend { swatch: root.coolColor; text: "Al enfriarse" }
                  Legend { swatch: root.fg; text: "Ahora"; dot: true }
                  Item { Layout.fillWidth: true }
                }

                SectionLabel {
                  Layout.topMargin: Style.space(4)
                  text: "AL CALENTARSE"
                  detail: root.draft ? "mínimo hasta " + root.draft.high + " °C" : ""
                }
                StepFlow { steps: root.rising; tint: root.hotColor }

                SectionLabel {
                  text: "AL ENFRIARSE"
                  detail: root.draft ? "baja desde " + root.draft.max + " °C" : ""
                }
                StepFlow { steps: root.falling; tint: root.coolColor }
              }

              // Columna derecha: controles
              ColumnLayout {
                Layout.preferredWidth: Style.space(300)
                Layout.maximumWidth: Style.space(300)
                Layout.alignment: Qt.AlignTop
                spacing: Style.space(10)

                SectionLabel { text: "TEMPERATURAS" }
                Stepper {
                  label: "Mínimo hasta"
                  hint: "Por debajo de esta temperatura el ventilador va a la velocidad mínima (y al enfriarse vuelve a ella aquí)"
                  key: "low"; unit: "°C"; amount: 1; swatch: root.coolColor
                }
                Stepper {
                  label: "Empieza a subir"
                  hint: "Por encima de esta temperatura el ventilador acelera a escalones cada vez mayores"
                  key: "high"; unit: "°C"; amount: 1; swatch: root.hotColor
                }
                Stepper {
                  label: "Máximo desde"
                  hint: "A esta temperatura o más, velocidad máxima"
                  key: "max"; unit: "°C"; amount: 1; swatch: root.warnColor
                }

                SectionLabel { Layout.topMargin: Style.space(6); text: "VELOCIDADES" }
                Stepper {
                  label: "Mínima"
                  hint: "Velocidad en reposo (el SMC no baja de " + (root.hwMin > 0 ? root.hwMin : 1300) + " rpm)"
                  key: "minRpm"; unit: "rpm"; amount: 100
                }
                Stepper {
                  label: "Máxima"
                  hint: "Tope del ventilador (el SMC admite hasta " + root.rpmCap + " rpm)"
                  key: "maxRpm"; unit: "rpm"; amount: 100
                }
                Stepper {
                  label: "Mirar cada"
                  hint: "Cada cuántos segundos mbpfan lee la temperatura"
                  key: "interval"; unit: "s"; amount: 1
                }

                SectionLabel { Layout.topMargin: Style.space(6); text: "PREAJUSTES" }
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(6)
                  Repeater {
                    model: root.presets
                    Button {
                      required property var modelData
                      Layout.fillWidth: true
                      text: modelData.label
                      tooltipText: modelData.tooltip + " (" + modelData.cfg.high + "→" + modelData.cfg.max + " °C)"
                      bordered: true
                      selected: root.presetActive(modelData)
                      foreground: root.fg
                      fontSize: Style.font.bodySmall
                      onClicked: root.applyPreset(modelData)
                    }
                  }
                }
              }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.fg }

            // ---------- Pie ----------
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(10)

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: root.invalid !== "" ? root.invalid
                  : root.message !== "" ? root.message
                  : root.dirty ? "Cambios sin guardar"
                  : "Así está /etc/mbpfan.conf"
                color: root.invalid !== "" || root.messageIsError ? root.warnColor
                  : root.dirty ? root.fg : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                visible: root.dirty
                text: "Deshacer"
                iconText: root.glyph(0xF054C)
                bordered: true
                foreground: root.fg
                onClicked: root.revert()
              }

              Button {
                text: root.applying ? "Aplicando…" : "Guardar y aplicar"
                iconText: root.glyph(0xF0193)
                tooltipText: "Escribe /etc/mbpfan.conf y reinicia mbpfan (Intro)"
                bordered: true
                active: root.dirty && root.invalid === ""
                enabled: root.dirty && root.invalid === "" && !root.applying
                opacity: enabled ? 1 : 0.45
                foreground: root.fg
                onClicked: root.save()
              }
            }
          }
        }
      }
    }
  }

  // ---------- Componentes ----------
  component SectionLabel: RowLayout {
    property string text: ""
    property string detail: ""
    Layout.fillWidth: true
    spacing: Style.space(10)

    Text {
      id: labelTitle
      textFormat: Text.PlainText
      text: parent.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }
    // El detalle cambia al pasar el ratón: ancho y alto fijos, para que ni
    // su largo ni los glifos de otra fuente (·, espacio fino de las rpm, con
    // la línea más alta) redimensionen la columna, la gráfica o el panel.
    Text {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      Layout.minimumWidth: 0
      Layout.preferredHeight: labelTitle.implicitHeight
      verticalAlignment: Text.AlignVCenter
      horizontalAlignment: Text.AlignRight
      elide: Text.ElideLeft
      textFormat: Text.PlainText
      text: parent.detail
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component Legend: Row {
    property color swatch: root.fg
    property string text: ""
    property bool dot: false
    spacing: Style.space(6)

    Rectangle {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.dot ? Style.space(8) : Style.space(16)
      height: parent.dot ? Style.space(8) : Style.space(3)
      radius: height / 2
      color: parent.swatch
    }
    Text {
      textFormat: Text.PlainText
      text: parent.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Escalones como fichas "76 °C  2 567": la del grado actual, resaltada.
  component StepFlow: Flow {
    property var steps: []
    property color tint: root.accent
    Layout.fillWidth: true
    spacing: Style.space(4)

    Repeater {
      model: parent.steps
      Rectangle {
        id: chip
        required property var modelData
        readonly property bool current: modelData.temp === root.temp
        readonly property bool hovered: modelData.temp === root.hoverTemp
        width: Style.space(78)
        height: chipCol.implicitHeight + Style.space(8)
        radius: Style.space(4)
        color: current ? Qt.rgba(tint.r, tint.g, tint.b, 0.35)
          : hovered ? Qt.rgba(tint.r, tint.g, tint.b, 0.2) : root.faint
        border.width: current ? 1 : 0
        border.color: tint
        property color tint: parent.tint

        Column {
          id: chipCol
          anchors.centerIn: parent
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: chip.modelData.temp + " °C"
            color: chip.tint
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: Model.formatRpm(chip.modelData.rpm)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onContainsMouseChanged: root.hoverTemp = containsMouse ? chip.modelData.temp : -1
        }
      }
    }
  }

  // Fila "etiqueta  [−] valor [+]"; la rueda también cambia el valor.
  component Stepper: Item {
    id: stepper
    property string label: ""
    property string hint: ""
    property string key: ""
    property string unit: ""
    property int amount: 1
    property color swatch: "transparent"
    readonly property int value: root.draft ? root.draft[key] : 0
    readonly property bool changed: root.saved && root.draft && root.saved[key] !== root.draft[key]

    Layout.fillWidth: true
    implicitHeight: Style.space(34)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      onWheel: function(wheel) {
        root.step(stepper.key, (wheel.angleDelta.y > 0 ? 1 : -1) * stepper.amount)
      }
    }

    PanelToolTip {
      visible: rowMouse.containsMouse && stepper.hint !== ""
      text: stepper.hint
    }

    Rectangle {
      id: swatchBar
      visible: stepper.swatch.a > 0
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(3)
      height: Style.space(16)
      radius: width / 2
      color: stepper.swatch
    }

    Text {
      anchors.left: swatchBar.visible ? swatchBar.right : parent.left
      anchors.leftMargin: swatchBar.visible ? Style.space(8) : 0
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: stepper.label
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Row {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      StepButton { glyphText: "−"; onTriggered: root.step(stepper.key, -stepper.amount) }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(84)
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: (stepper.unit === "rpm" ? Model.formatRpm(stepper.value) : stepper.value) + " " + stepper.unit
        color: stepper.changed ? root.accent : root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      StepButton { glyphText: "+"; onTriggered: root.step(stepper.key, stepper.amount) }
    }
  }

  // Botón cuadrado que repite mientras se mantiene pulsado.
  component StepButton: Rectangle {
    id: sb
    property string glyphText: ""
    signal triggered()
    width: Style.space(28)
    height: Style.space(28)
    radius: Style.space(4)
    color: sbMouse.pressed ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.25)
      : sbMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.16) : root.faint

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: sb.glyphText
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
    }

    MouseArea {
      id: sbMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPressed: { sb.triggered(); repeatTimer.interval = 400; repeatTimer.start() }
      onReleased: repeatTimer.stop()
      onCanceled: repeatTimer.stop()
    }

    Timer {
      id: repeatTimer
      repeat: true
      onTriggered: { interval = 70; sb.triggered() }
    }
  }

  // Gráfica temperatura → rpm, en escalones de un grado como mbpfan.
  component CurveChart: Item {
    id: chart
    readonly property var cfg: root.draft
    readonly property real padL: Style.space(40)
    readonly property real padB: Style.space(22)
    readonly property real padT: Style.space(18)
    readonly property real padR: Style.space(8)
    readonly property int tMin: cfg ? Math.max(25, Math.min(cfg.low - 8, root.temp >= 0 ? root.temp - 3 : 999)) : 40
    readonly property int tMax: cfg ? Math.min(105, Math.max(cfg.max + 5, root.temp + 3)) : 95
    readonly property int yMax: Math.ceil(Math.max(cfg ? cfg.maxRpm : 0, root.rpmCap, root.rpm) / 1000) * 1000

    function px(t) { return padL + (t - tMin) / (tMax - tMin) * (width - padL - padR) }
    function py(r) { return height - padB - r / yMax * (height - padB - padT) }

    onCfgChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    Connections {
      target: root
      function onTempChanged() { canvas.requestPaint() }
      function onRpmChanged() { canvas.requestPaint() }
      function onHoverTempChanged() { canvas.requestPaint() }
    }

    Canvas {
      id: canvas
      anchors.fill: parent

      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var c = chart.cfg
        if (!c || chart.width <= 0) return
        var w = chart.width, h = chart.height
        var fg = root.fg
        function rgba(col, a) { return Qt.rgba(col.r, col.g, col.b, a) }
        ctx.font = Math.round(Style.font.caption) + "px '" + root.fontFamily + "'"

        // Zona en la que acelera (entre "empieza a subir" y "máximo").
        ctx.fillStyle = rgba(root.hotColor, 0.07)
        ctx.fillRect(chart.px(c.high), chart.padT, chart.px(c.max) - chart.px(c.high), h - chart.padB - chart.padT)

        // Rejilla de rpm.
        ctx.lineWidth = 1
        ctx.textAlign = "right"
        ctx.textBaseline = "middle"
        for (var r = 0; r <= chart.yMax; r += 1000) {
          var y = Math.round(chart.py(r)) + 0.5
          ctx.strokeStyle = rgba(fg, r === 0 ? 0.3 : 0.08)
          ctx.beginPath(); ctx.moveTo(chart.padL, y); ctx.lineTo(w - chart.padR, y); ctx.stroke()
          ctx.fillStyle = rgba(fg, 0.5)
          ctx.fillText(r === 0 ? "0" : (r / 1000) + "k", chart.padL - Style.space(6), y)
        }

        // Eje de temperaturas cada 5 °C.
        ctx.textAlign = "center"
        ctx.textBaseline = "top"
        for (var t = Math.ceil(chart.tMin / 5) * 5; t <= chart.tMax; t += 5) {
          ctx.fillStyle = rgba(fg, 0.5)
          ctx.fillText(t + "°", chart.px(t), h - chart.padB + Style.space(5))
        }

        // Umbrales.
        function marker(t, col, label) {
          var x = Math.round(chart.px(t)) + 0.5
          ctx.strokeStyle = rgba(col, 0.6)
          ctx.setLineDash([3, 3])
          ctx.beginPath(); ctx.moveTo(x, chart.padT); ctx.lineTo(x, h - chart.padB); ctx.stroke()
          ctx.setLineDash([])
          ctx.fillStyle = col
          ctx.textBaseline = "bottom"
          ctx.fillText(label, x, chart.padT - Style.space(2))
        }
        marker(c.low, root.coolColor, c.low + "°")
        marker(c.high, root.hotColor, c.high + "°")
        marker(c.max, root.warnColor, c.max + "°")

        // Escalones: cada grado t ocupa [t - ½, t + ½].
        function stairs(fn, col) {
          ctx.strokeStyle = col
          ctx.lineWidth = Math.max(2, Style.space(2))
          ctx.lineJoin = "round"
          ctx.beginPath()
          for (var t = chart.tMin; t <= chart.tMax; t++) {
            var x0 = chart.px(Math.max(chart.tMin, t - 0.5)), x1 = chart.px(Math.min(chart.tMax, t + 0.5))
            var y = chart.py(fn(c, t))
            if (t === chart.tMin) ctx.moveTo(x0, y); else ctx.lineTo(x0, y)
            ctx.lineTo(x1, y)
          }
          ctx.stroke()
        }
        stairs(Model.fallingRpm, rgba(root.coolColor, 0.9))
        stairs(Model.risingRpm, root.hotColor)

        // Grado bajo el ratón.
        if (root.hoverTemp >= chart.tMin && root.hoverTemp <= chart.tMax) {
          ctx.fillStyle = rgba(fg, 0.08)
          var hx0 = chart.px(root.hoverTemp - 0.5), hx1 = chart.px(root.hoverTemp + 0.5)
          ctx.fillRect(hx0, chart.padT, hx1 - hx0, h - chart.padB - chart.padT)
        }

        // Ahora: temperatura y velocidad reales.
        if (root.temp >= chart.tMin && root.temp <= chart.tMax && root.rpm >= 0) {
          var nx = chart.px(root.temp), ny = chart.py(root.rpm)
          ctx.fillStyle = root.bg
          ctx.beginPath(); ctx.arc(nx, ny, Style.space(6), 0, Math.PI * 2); ctx.fill()
          ctx.fillStyle = fg
          ctx.beginPath(); ctx.arc(nx, ny, Style.space(4), 0, Math.PI * 2); ctx.fill()
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onPositionChanged: function(mouse) {
        var t = chart.tMin + (mouse.x - chart.padL) / (chart.width - chart.padL - chart.padR) * (chart.tMax - chart.tMin)
        root.hoverTemp = mouse.x < chart.padL ? -1 : Math.round(Math.max(chart.tMin, Math.min(chart.tMax, t)))
      }
      onExited: root.hoverTemp = -1
    }
  }
}
