.pragma library

// Curva del ventilador tal y como la calcula mbpfan 2.4 (src/mbpfan.c):
//   - temperatura = la más alta de los sensores de coretemp, en °C enteros
//   - <= low            -> velocidad mínima
//   - >= max            -> velocidad máxima
//   - subiendo, > high  -> min + T(t - high) · stepUp      (redondeo hacia arriba)
//   - bajando,  > low   -> max - T(max - t) · stepDown     (redondeo hacia abajo)
// donde T(n) = n·(n+1)/2 y los escalones se guardan en un int (se truncan).

var DEFAULTS = { low: 63, high: 66, max: 86, minRpm: 2000, maxRpm: 6200, interval: 1 }

var LIMITS = {
  tempMin: 30, tempMax: 95,
  rpmMin: 1000, rpmMax: 6500,
  intervalMin: 1, intervalMax: 10
}

function tri(n) { return n * (n + 1) / 2 }

function parseConf(text, hwMin, hwMax) {
  var cfg = {
    low: DEFAULTS.low, high: DEFAULTS.high, max: DEFAULTS.max,
    minRpm: hwMin > 0 ? hwMin : DEFAULTS.minRpm,
    maxRpm: hwMax > 0 ? hwMax : DEFAULTS.maxRpm,
    interval: DEFAULTS.interval
  }
  var keys = {
    low_temp: "low", high_temp: "high", max_temp: "max",
    min_fan1_speed: "minRpm", max_fan1_speed: "maxRpm", polling_interval: "interval"
  }
  String(text || "").split("\n").forEach(function(line) {
    var clean = line.replace(/#.*/, "").trim()
    var m = clean.match(/^([a-z0-9_]+)\s*=\s*(-?\d+)/)
    if (m && keys[m[1]] !== undefined) cfg[keys[m[1]]] = parseInt(m[2], 10)
  })
  return cfg
}

function validate(cfg) {
  if (cfg.low < LIMITS.tempMin || cfg.max > LIMITS.tempMax)
    return "Las temperaturas tienen que estar entre " + LIMITS.tempMin + " y " + LIMITS.tempMax + " °C"
  if (!(cfg.low < cfg.high && cfg.high < cfg.max))
    return "Tiene que ser: mínimo hasta < empieza a subir < máximo desde"
  if (cfg.minRpm < LIMITS.rpmMin || cfg.maxRpm > LIMITS.rpmMax)
    return "Las velocidades tienen que estar entre " + LIMITS.rpmMin + " y " + LIMITS.rpmMax + " rpm"
  if (cfg.minRpm >= cfg.maxRpm)
    return "La velocidad mínima tiene que ser menor que la máxima"
  if (cfg.interval < LIMITS.intervalMin || cfg.interval > LIMITS.intervalMax)
    return "El intervalo tiene que estar entre 1 y 10 s"
  return ""
}

function stepUp(cfg) { return Math.trunc((cfg.maxRpm - cfg.minRpm) / tri(cfg.max - cfg.high)) }
function stepDown(cfg) { return Math.trunc((cfg.maxRpm - cfg.minRpm) / tri(cfg.max - cfg.low)) }

// Velocidad al calentarse, partiendo del mínimo.
function risingRpm(cfg, t) {
  if (t >= cfg.max) return cfg.maxRpm
  if (t <= cfg.high) return cfg.minRpm
  return Math.min(cfg.maxRpm, Math.ceil(cfg.minRpm + tri(t - cfg.high) * stepUp(cfg)))
}

// Velocidad al enfriarse, partiendo del máximo.
function fallingRpm(cfg, t) {
  if (t >= cfg.max) return cfg.maxRpm
  if (t <= cfg.low) return cfg.minRpm
  return Math.max(cfg.minRpm, Math.floor(cfg.maxRpm - tri(cfg.max - t) * stepDown(cfg)))
}

// Escalones: [{ temp, rpm }] desde el primer grado en que cambia hasta el
// máximo (calentando) o hasta el mínimo (enfriando).
function risingSteps(cfg) {
  var out = []
  for (var t = cfg.high + 1; t <= cfg.max; t++) out.push({ temp: t, rpm: risingRpm(cfg, t) })
  return out
}

function fallingSteps(cfg) {
  var out = []
  for (var t = cfg.max - 1; t >= cfg.low; t--) out.push({ temp: t, rpm: fallingRpm(cfg, t) })
  return out
}

function same(a, b) {
  if (!a || !b) return false
  return a.low === b.low && a.high === b.high && a.max === b.max
    && a.minRpm === b.minRpm && a.maxRpm === b.maxRpm && a.interval === b.interval
}

function copy(cfg) {
  return { low: cfg.low, high: cfg.high, max: cfg.max, minRpm: cfg.minRpm, maxRpm: cfg.maxRpm, interval: cfg.interval }
}

function formatRpm(rpm) {
  var s = String(Math.round(rpm))
  return s.length > 3 ? s.slice(0, s.length - 3) + " " + s.slice(s.length - 3) : s
}
