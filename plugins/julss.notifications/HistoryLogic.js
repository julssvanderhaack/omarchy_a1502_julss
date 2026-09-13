// Parsing/formatting helpers for the notifications-manager plugin. Kept
// separate from the built-in omarchy.notifications plugin's own JS: we only
// ever read the JSON files it writes under its historyDir, never its private
// code, so this plugin keeps working even if that internal file changes shape
// in a future Omarchy release (unknown fields are just ignored below).

function parseHistoryFile(raw) {
  var lines = String(raw || "").split("\n")
  var entries = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      var value = JSON.parse(line)
      if (value && typeof value === "object") {
        entries.push({
          app: String(value.app || ""),
          appIcon: String(value.appIcon || ""),
          summary: String(value.summary || ""),
          body: String(value.body || ""),
          image: String(value.image || ""),
          glyph: String(value.glyph || ""),
          urgency: typeof value.urgency === "number" ? value.urgency : 1,
          timestamp: Number(value.timestamp || 0)
        })
      }
    } catch (e) {
      // Torn write from a crash mid-save - skip the line, keep the rest.
    }
  }
  entries.sort(function(a, b) { return (b.timestamp || 0) - (a.timestamp || 0) })
  return entries
}

function timeAgo(timestamp, now) {
  var ts = Number(timestamp || 0)
  var current = now === undefined ? Date.now() : now
  var diffMs = current - ts
  if (!isFinite(diffMs) || diffMs < 0) diffMs = 0

  var minutes = Math.floor(diffMs / 60000)
  if (minutes < 1) return "Ahora"
  if (minutes < 60) return minutes + " min"

  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + " h"

  var days = Math.floor(hours / 24)
  return days + " d"
}

if (typeof module !== "undefined") {
  module.exports = {
    parseHistoryFile: parseHistoryFile,
    timeAgo: timeAgo
  }
}
