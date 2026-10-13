// Lógica pura del plugin de alarmas (sin QML), para que Panel.qml solo pinte.

// Días en el orden del calendario español: lunes primero. getDay(): 0 = domingo.
var DAY_ORDER = [1, 2, 3, 4, 5, 6, 0]
var DAY_LETTER = { 1: "L", 2: "M", 3: "X", 4: "J", 5: "V", 6: "S", 0: "D" }

function pad2(n) { n = Math.floor(Math.abs(n)); return n < 10 ? "0" + n : String(n) }

function clockText(h, m) { return pad2(h) + ":" + pad2(m) }

// "Una vez", "Todos los días", "Laborables", "Fin de semana" o "L X V".
function daysText(days) {
  if (!days || days.length === 0) return "Una vez"
  var set = {}
  for (var i = 0; i < days.length; i++) set[days[i]] = true
  var n = days.length
  if (n === 7) return "Todos los días"
  if (n === 5 && set[1] && set[2] && set[3] && set[4] && set[5]) return "Laborables"
  if (n === 2 && set[6] && set[0]) return "Fin de semana"
  var out = []
  for (var j = 0; j < DAY_ORDER.length; j++) if (set[DAY_ORDER[j]]) out.push(DAY_LETTER[DAY_ORDER[j]])
  return out.join(" ")
}

// Momento (ms) de la alarma en la fecha de `base` (a medianoche + h:m).
function occurrenceOn(base, alarm) {
  return new Date(base.getFullYear(), base.getMonth(), base.getDate(), alarm.h, alarm.m, 0, 0).getTime()
}

function firesOnDay(alarm, date) {
  if (!alarm.days || alarm.days.length === 0) return true
  return alarm.days.indexOf(date.getDay()) !== -1
}

// ¿Ha llegado su hora entre lastTick (exclusivo) y now (inclusivo)? Mira hoy
// y ayer para cubrir medianoche y suspensiones; no dispara si han pasado más
// de `graceMs` (p. ej. el portátil estuvo suspendido toda la noche).
function dueBetween(alarm, lastTick, now, graceMs) {
  if (!alarm.enabled) return false
  var today = new Date(now)
  var yesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1)
  var days = [today, yesterday]
  for (var i = 0; i < days.length; i++) {
    if (!firesOnDay(alarm, days[i])) continue
    var t = occurrenceOn(days[i], alarm)
    if (t > lastTick && t <= now && now - t <= graceMs) return true
  }
  return false
}

// Próxima vez que sonará (ms) o -1 si está desactivada.
function nextFire(alarm, now) {
  if (!alarm.enabled) return -1
  var base = new Date(now)
  for (var d = 0; d < 8; d++) {
    var day = new Date(base.getFullYear(), base.getMonth(), base.getDate() + d)
    if (!firesOnDay(alarm, day)) continue
    var t = occurrenceOn(day, alarm)
    if (t > now) return t
  }
  return -1
}

// "hoy 07:30", "mañana 07:30", "jueves 07:30".
function whenText(ms, now, locale) {
  if (ms < 0) return ""
  var d = new Date(ms), n = new Date(now)
  var dayDiff = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(n.getFullYear(), n.getMonth(), n.getDate())) / 86400000)
  var hm = clockText(d.getHours(), d.getMinutes())
  if (dayDiff === 0) return "hoy " + hm
  if (dayDiff === 1) return "mañana " + hm
  return locale.dayName(d.getDay(), 0) + " " + hm
}

// "en 7 h 12 min", "en 5 min", "en menos de 1 min".
function inText(ms, now) {
  var mins = Math.ceil((ms - now) / 60000)
  if (mins <= 1) return "en menos de 1 min"
  var h = Math.floor(mins / 60), m = mins % 60
  if (h === 0) return "en " + m + " min"
  if (h >= 24) return "en " + Math.floor(h / 24) + " d " + (h % 24) + " h"
  return "en " + h + " h" + (m > 0 ? " " + m + " min" : "")
}

// Duración: "1:02:03" o "02:03"; con décimas si `tenths`.
function durationText(ms, tenths) {
  ms = Math.max(0, ms)
  var total = Math.floor(ms / 1000)
  var h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60
  var out = (h > 0 ? h + ":" + pad2(m) : pad2(m)) + ":" + pad2(s)
  if (tenths) out += "," + Math.floor((ms % 1000) / 100)
  return out
}

// Texto corto para la barra: "4:59" / "1:02:03".
function barText(ms) {
  ms = Math.max(0, ms)
  var total = Math.ceil(ms / 1000)
  var h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60
  return h > 0 ? h + ":" + pad2(m) + ":" + pad2(s) : m + ":" + pad2(s)
}

function newId() {
  return Date.now().toString(36) + Math.floor(Math.random() * 1e6).toString(36)
}
