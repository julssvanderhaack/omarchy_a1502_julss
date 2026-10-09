// Pure logic for the Force Quit widget: turning `hyprctl -j clients` into one
// row per process, the `ps` probe that annotates those rows, and the two
// commands a row can run.
//
// A row is a process, not a window. macOS lists applications in its Force Quit
// dialog for a reason a signal makes literal: the kernel can end a process, it
// cannot end a window. Windows still matter for the polite path, which asks
// Hyprland to close each of the process's windows so the app can put up its own
// save prompt before it goes.

// hyprctl reports pids as numbers and addresses as 0x-prefixed hex, and both
// end up on a command line. Classes and titles never do — they are attacker-
// controlled strings (any window can name itself anything) and stay data.
function isPid(value) {
  var n = Number(value)
  // Never pid 1: `kill -9 1` from a bar widget is not a thing that should be
  // one mis-parse away.
  return isFinite(n) && n > 1 && Math.floor(n) === n
}

function isAddress(value) {
  return /^0x[0-9a-fA-F]+$/.test(String(value || ""))
}

// A window Hyprland reports without a pid cannot be killed and would show a
// row whose only button fails, so those are dropped here rather than rendered.
function parseClients(rawJson) {
  var out = []
  try {
    var list = JSON.parse(rawJson)
    for (var i = 0; i < list.length; i++) {
      var c = list[i] || {}
      if (!isAddress(c.address) || !isPid(c.pid)) continue
      var ws = c.workspace || {}
      out.push({
        address: String(c.address),
        pid: Number(c.pid),
        cls: String(c.class || ""),
        title: String(c.title || ""),
        workspace: workspaceLabel(ws.name, ws.id),
        xwayland: !!c.xwayland,
        // Hyprland orders focus history with the focused window at 0.
        focused: Number(c.focusHistoryID) === 0
      })
    }
  } catch (e) {
    // A truncated or failed hyprctl read yields no rows; the panel says
    // "no open windows" and the next refresh corrects it.
  }
  return out
}

// Special workspaces are named "special:scratchpad"; the prefix is noise in a
// badge that is already only ever a workspace.
function workspaceLabel(name, id) {
  var label = String(name || "")
  if (label.indexOf("special:") === 0) return label.slice(8)
  if (label !== "") return label
  return id === undefined || id === null ? "" : String(id)
}

// Fallback display name, used when no desktop entry matches the window class.
// Classes are either a bare name ("firefox") or reverse-DNS
// ("org.omarchy.agent"), and the last segment is the part a human recognises.
function prettyName(cls, fallbackTitle) {
  var name = String(cls || "").trim()
  if (name === "") name = String(fallbackTitle || "").trim()
  if (name === "") return "Desconocido"

  var parts = name.split(".")
  var last = parts[parts.length - 1]
  if (parts.length > 1 && last.length > 1) name = last

  name = name.replace(/[-_]+/g, " ").trim()
  return name.charAt(0).toUpperCase() + name.slice(1)
}

function titleFor(windows) {
  for (var i = 0; i < windows.length; i++) if (windows[i].focused) return windows[i].title
  return windows.length > 0 ? windows[0].title : ""
}

function uniquePush(list, value) {
  if (value !== "" && list.indexOf(value) === -1) list.push(value)
}

// One row per pid. Two windows of the same application share a process far
// more often than not, and a row that says "Firefox · 3 windows" is both the
// truth about what the kill ends and shorter than three rows saying Firefox.
function groupByProcess(clients) {
  var groups = {}
  var order = []

  for (var i = 0; i < clients.length; i++) {
    var c = clients[i]
    var key = String(c.pid)
    if (!groups[key]) {
      groups[key] = {
        pid: c.pid,
        cls: c.cls,
        name: prettyName(c.cls, c.title),
        windows: [],
        addresses: [],
        workspaces: [],
        focused: false,
        xwayland: false
      }
      order.push(key)
    }
    var g = groups[key]
    g.windows.push(c)
    g.addresses.push(c.address)
    uniquePush(g.workspaces, c.workspace)
    if (c.focused) g.focused = true
    if (c.xwayland) g.xwayland = true
    // A process whose first window carried an empty class can still be named
    // by a later one.
    if (g.cls === "" && c.cls !== "") {
      g.cls = c.cls
      g.name = prettyName(c.cls, c.title)
    }
  }

  var rows = []
  for (var j = 0; j < order.length; j++) {
    var row = groups[order[j]]
    row.title = titleFor(row.windows)
    row.windowCount = row.windows.length
    rows.push(row)
  }
  return rows
}

function annotate(rows, stats) {
  var byPid = stats || {}
  for (var i = 0; i < rows.length; i++) {
    var info = byPid[String(rows[i].pid)] || null
    rows[i].memoryKb = info ? info.memoryKb : 0
    rows[i].state = info ? info.state : ""
    rows[i].stateNote = info ? stateNote(info.state) : ""
  }
  return rows
}

function matches(row, token) {
  if (token === "") return true
  if (String(row.name).toLowerCase().indexOf(token) !== -1) return true
  if (String(row.cls).toLowerCase().indexOf(token) !== -1) return true
  if (String(row.pid).indexOf(token) === 0) return true
  for (var i = 0; i < row.windows.length; i++) {
    if (String(row.windows[i].title).toLowerCase().indexOf(token) !== -1) return true
  }
  return false
}

// Every whitespace-separated token must match something, so "fire dev" narrows
// rather than widens.
function filterRows(rows, query) {
  var tokens = String(query || "").toLowerCase().trim().split(/\s+/).filter(function(t) { return t !== "" })
  if (tokens.length === 0) return rows

  var out = []
  for (var i = 0; i < rows.length; i++) {
    var ok = true
    for (var t = 0; t < tokens.length; t++) {
      if (!matches(rows[i], tokens[t])) { ok = false; break }
    }
    if (ok) out.push(rows[i])
  }
  return out
}

// Alphabetical, like the macOS dialog. Focus order would put the row you are
// about to kill under a cursor that moved since you last looked; a stable
// alphabetical list is the one you can aim at.
function byName(a, b) {
  var an = String(a.name).toLowerCase()
  var bn = String(b.name).toLowerCase()
  if (an < bn) return -1
  if (an > bn) return 1
  return a.pid - b.pid
}

function buildRows(clients, stats, query) {
  var rows = annotate(groupByProcess(clients || []), stats)
  rows.sort(byName)
  return filterRows(rows, query)
}

function totals(clients) {
  var pids = []
  for (var i = 0; i < (clients || []).length; i++) uniquePush(pids, String(clients[i].pid))
  return { processes: pids.length, windows: (clients || []).length }
}

function pidsOf(rows) {
  var pids = []
  for (var i = 0; i < (rows || []).length; i++) if (isPid(rows[i].pid)) pids.push(String(rows[i].pid))
  return pids
}

// `stat` rather than `state` for portability across procps builds; the first
// character is the state letter either way, the rest are flags this ignores.
function statsScript(pids) {
  var safe = []
  for (var i = 0; i < (pids || []).length; i++) if (isPid(pids[i])) safe.push(String(pids[i]))
  if (safe.length === 0) return "true"
  return "ps -o pid=,rss=,stat= -p " + safe.join(",") + " 2>/dev/null || true"
}

function parseStats(raw) {
  var out = {}
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/)
    if (parts.length < 3) continue
    if (!isPid(parts[0])) continue
    out[String(Number(parts[0]))] = {
      memoryKb: Number(parts[1]) || 0,
      state: String(parts[2]).charAt(0)
    }
  }
  return out
}

// Only the states worth acting on. A normal S/R process gets no note, because
// a note on every row is a note on none.
function stateNote(state) {
  if (state === "Z") return "zombi"
  if (state === "T" || state === "t") return "detenido"
  if (state === "D") return "atascado en E/S"
  return ""
}

function formatMemory(kb) {
  var n = Number(kb) || 0
  if (n <= 0) return ""
  if (n >= 1024 * 1024) return (n / (1024 * 1024)).toFixed(1) + " GB"
  if (n >= 1024) return Math.round(n / 1024) + " MB"
  return n + " kB"
}

// The workspace is only worth a word when it is not the one being looked at:
// on a single-workspace session every row would otherwise repeat the same
// badge, and the row that is somewhere else — the reason to open this list at
// all — would not stand out.
function windowSummary(row, activeWorkspace) {
  var parts = []
  if (row.focused) parts.push("activa")
  if (row.windowCount > 1) parts.push(row.windowCount + " ventanas")
  if (row.workspaces.length > 1) parts.push("en " + row.workspaces.length + " escritorios")
  else if (row.workspaces.length === 1 && row.workspaces[0] !== ""
           && row.workspaces[0] !== String(activeWorkspace || "")) parts.push("escritorio " + row.workspaces[0])
  if (row.xwayland) parts.push("xwayland")
  if (row.stateNote !== "") parts.push(row.stateNote)
  return parts.join(" · ")
}

// SIGKILL, deliberately. SIGTERM is what the polite button already does one
// layer up through Hyprland, and a process that ignored that is exactly the
// case this widget exists for.
function forceQuitCommand(pid) {
  if (!isPid(pid)) return null
  return ["kill", "-9", String(pid)]
}

// Closing every window of the process is the closest thing to "Quit" an app
// with no D-Bus quit method has: each window's close request reaches the app
// itself, which is what makes a save prompt possible.
//
// One argv per window rather than a single `hyprctl --batch`. Omarchy parses
// dispatch arguments as Lua, where the familiar `closewindow address:0x...`
// line is a syntax error ("')' expected near 'address'") — the Lua call below
// is the form Omarchy's own close-all script uses, and it carries braces and
// quotes that a batch string would have to survive being split on.
function quitCommands(addresses) {
  var commands = []
  for (var i = 0; i < (addresses || []).length; i++) {
    if (!isAddress(addresses[i])) continue
    commands.push(["hyprctl", "dispatch", 'hl.dsp.window.close({ window = "address:' + addresses[i] + '" })'])
  }
  return commands
}
