.pragma library

// Flatpak cuenta en unidades de 1000 (MB, GB), así que aquí también.
function formatBytes(n) {
  n = Number(n) || 0
  if (n <= 0) return "—"
  var units = ["B", "kB", "MB", "GB", "TB"]
  var i = 0
  while (n >= 1000 && i < units.length - 1) { n /= 1000; i++ }
  var digits = n >= 100 || i === 0 ? 0 : 1
  return n.toFixed(digits).replace(".", ",") + " " + units[i]
}

function plural(n, one, many) {
  return n + " " + (n === 1 ? one : many)
}

function installationLabel(inst) {
  return inst === "user" ? "Solo para mí" : "Para todos"
}

// Permisos de [Context] en lenguaje normal. risk: lo que conviene mirar dos veces.
var LABELS = {
  shared: {
    network: { text: "Internet", icon: 0xF059F },
    ipc: { text: "Memoria compartida con X11", icon: 0xF035B }
  },
  sockets: {
    x11: { text: "Ventanas X11", icon: 0xF0379 },
    "fallback-x11": { text: "X11 si no hay Wayland", icon: 0xF0379 },
    wayland: { text: "Ventanas Wayland", icon: 0xF0379 },
    pulseaudio: { text: "Sonido y micrófono", icon: 0xF057E },
    "session-bus": { text: "Todo el bus de sesión", icon: 0xF0026, risk: true },
    "system-bus": { text: "Todo el bus del sistema", icon: 0xF0026, risk: true },
    "ssh-auth": { text: "Tus claves SSH", icon: 0xF0306, risk: true },
    "gpg-agent": { text: "Tus claves GPG", icon: 0xF0306, risk: true },
    cups: { text: "Impresoras", icon: 0xF042A },
    pcsc: { text: "Tarjetas inteligentes", icon: 0xF0FEF },
    inherit: { text: "Sockets heredados", icon: 0xF0339 }
  },
  devices: {
    dri: { text: "Aceleración gráfica", icon: 0xF08AE },
    all: { text: "Todos los dispositivos (mandos, USB, cámara…)", icon: 0xF0026, risk: true },
    kvm: { text: "Virtualización (KVM)", icon: 0xF0697 },
    input: { text: "Mandos y dispositivos de entrada", icon: 0xF0EB5 },
    usb: { text: "Dispositivos USB", icon: 0xF0553 },
    shm: { text: "Memoria compartida", icon: 0xF035B }
  },
  features: {
    devel: { text: "Herramientas de depuración", icon: 0xF0026, risk: true },
    multiarch: { text: "Programas de 32 bits", icon: 0xF0EE0 },
    bluetooth: { text: "Bluetooth", icon: 0xF00AF },
    canbus: { text: "Bus CAN", icon: 0xF0339 },
    "per-app-dev-shm": { text: "/dev/shm propio", icon: 0xF035B }
  }
}

var PLACES = {
  host: { text: "Todos tus ficheros y los del sistema", risk: true },
  "host-os": { text: "Ficheros del sistema operativo", risk: true },
  "host-etc": { text: "Configuración del sistema (/etc)", risk: true },
  home: { text: "Toda tu carpeta personal", risk: true },
  "xdg-download": { text: "Descargas" },
  "xdg-documents": { text: "Documentos" },
  "xdg-music": { text: "Música" },
  "xdg-pictures": { text: "Imágenes" },
  "xdg-videos": { text: "Vídeos" },
  "xdg-desktop": { text: "Escritorio" },
  "xdg-config": { text: "Tu configuración (~/.config)" },
  "xdg-data": { text: "Tus datos (~/.local/share)" },
  "xdg-cache": { text: "Tu caché" },
  "xdg-run": { text: "Carpeta de ejecución" }
}

function permissionList(perms) {
  var out = []
  if (!perms) return out
  var groups = ["shared", "sockets", "devices", "features"]
  for (var g = 0; g < groups.length; g++) {
    var values = perms[groups[g]] || []
    for (var i = 0; i < values.length; i++) {
      var v = values[i]
      if (v.charAt(0) === "!") continue
      var label = (LABELS[groups[g]] || {})[v]
      out.push(label ? { text: label.text, icon: label.icon, risk: !!label.risk }
                     : { text: groups[g] + ": " + v, icon: 0xF0339, risk: false })
    }
  }
  var fs = perms.filesystems || []
  for (var j = 0; j < fs.length; j++) {
    var raw = fs[j]
    if (raw.charAt(0) === "!") continue
    var ro = /:ro$/.test(raw)
    var create = /:create$/.test(raw)
    var path = raw.replace(/:(ro|rw|create)$/, "")
    var key = path.split("/")[0]
    var place = PLACES[path] || null
    var text
    if (place) text = place.text
    else if (PLACES[key] && path.indexOf("/") > 0) text = PLACES[key].text + " › " + path.substring(key.length + 1)
    else text = path.replace(/^~/, "Tu carpeta")
    if (ro) text += " (solo lectura)"
    out.push({ text: text, icon: 0xF024B, risk: !!(place && place.risk) && !ro })
  }
  return out
}

function riskCount(perms) {
  var list = permissionList(perms)
  var n = 0
  for (var i = 0; i < list.length; i++) if (list[i].risk) n++
  return n
}

function matches(app, filter) {
  if (!filter) return true
  var f = filter.toLowerCase()
  return (app.name || "").toLowerCase().indexOf(f) >= 0
    || (app.id || "").toLowerCase().indexOf(f) >= 0
    || (app.summary || "").toLowerCase().indexOf(f) >= 0
}
