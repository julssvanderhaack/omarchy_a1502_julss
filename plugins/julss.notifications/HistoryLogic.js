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
    // Each line comes as "<file name>\t<json>" so a single entry can be deleted.
    var file = ""
    var tab = line.indexOf("\t")
    if (tab > 0 && line.charAt(0) !== "{") {
      file = line.slice(0, tab)
      line = line.slice(tab + 1)
    }
    try {
      var value = JSON.parse(line)
      if (value && typeof value === "object") {
        entries.push({
          file: file,
          app: String(value.app || ""),
          appIcon: String(value.appIcon || ""),
          webApp: webApp(value.body, value.app, value.appIcon),
          webHost: webHost(value.body, value.app, value.appIcon),
          execArgv: String(value.execArgv || ""),
          summary: displaySummary(value.summary, value.body, value.app, value.appIcon),
          body: displayBody(value.body, value.app, value.appIcon),
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

// Chromium web-app notifications (WhatsApp Web and friends) arrive as
// summary = chat title, body = `<a href="https://web.whatsapp.com/">web.whatsapp.com</a>`
// + blank line + the actual message. The panel shows plain text, so the link
// markup leaked through verbatim. Turn that into "WhatsApp: <title>" over the
// message itself. Mirrors displaySummary() in julss.notifications-service.
var WEB_APP_NAMES = {
  whatsapp: "WhatsApp", telegram: "Telegram", discord: "Discord", slack: "Slack",
  google: "Google", youtube: "YouTube", github: "GitHub", gitlab: "GitLab",
  linkedin: "LinkedIn", instagram: "Instagram", facebook: "Facebook",
  messenger: "Messenger", x: "X", twitter: "X", outlook: "Outlook",
  live: "Outlook", office: "Office", teams: "Teams", microsoft: "Microsoft",
  notion: "Notion", spotify: "Spotify", twitch: "Twitch", reddit: "Reddit"
}

var ORIGIN_LINK = /^\s*<a\b[^>]*>\s*(?:https?:\/\/)?((?:[a-z0-9-]+\.)+[a-z]{2,})[^<]*<\/a>\s*/i
var ORIGIN_TEXT = /^\s*(?:https?:\/\/)?((?:[a-z0-9-]+\.)+[a-z]{2,})(?::\d+)?(?:\/\S*)?\s+/i

function isChromiumDerived(app, appIcon) {
  var source = (String(app || "") + "\n" + String(appIcon || "")).toLowerCase()
  return /chrom|brave|vivaldi|microsoft-edge|opera/.test(source)
}

function originMatch(body, app, appIcon) {
  if (!isChromiumDerived(app, appIcon)) return null
  var text = String(body || "")
  return ORIGIN_LINK.exec(text) || ORIGIN_TEXT.exec(text)
}

function webAppName(host) {
  var parts = String(host || "").toLowerCase().split(".")
  var key = parts.length >= 2 ? parts[parts.length - 2] : parts[0]
  if (parts.length >= 3 && /^(co|com|org|net|gob|gov|ac)$/.test(key)) key = parts[parts.length - 3]
  if (!key) return ""
  return WEB_APP_NAMES[key] || (key.charAt(0).toUpperCase() + key.slice(1))
}

// Site host ("web.whatsapp.com") for a Chromium web-app notification, "" otherwise.
function webHost(body, app, appIcon) {
  var m = originMatch(body, app, appIcon)
  return m ? m[1].toLowerCase() : ""
}

// Site name ("WhatsApp") for a Chromium web-app notification, "" otherwise.
function webApp(body, app, appIcon) {
  var m = originMatch(body, app, appIcon)
  return m ? webAppName(m[1]) : ""
}

function displaySummary(summary, body, app, appIcon) {
  var text = String(summary || "")
  var name = webApp(body, app, appIcon)
  if (!name) return text
  if (!text) return name
  if (text.toLowerCase().indexOf(name.toLowerCase()) === 0) return text
  return name + ": " + text
}

// Plain-text body for the panel: origin link dropped, any other markup the
// sender used (<b>, <a>, <br>) flattened, entities decoded, blank lines folded.
function displayBody(body, app, appIcon) {
  var text = String(body || "")
  var m = originMatch(text, app, appIcon)
  if (m) text = text.slice(m[0].length)
  return text
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]*>/g, "")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"")
    .replace(/&#39;|&apos;/g, "'").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&")
    .replace(/[\u200e\u200f]/g, "")
    .replace(/\n{2,}/g, "\n")
    .trim()
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
    displaySummary: displaySummary,
    displayBody: displayBody,
    webApp: webApp,
    timeAgo: timeAgo
  }
}
