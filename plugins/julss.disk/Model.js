.pragma library

// Utilidades sin estado del panel de almacenamiento: tamaños en español,
// búsqueda en el árbol de scan.py y las geometrías del mapa (squarified)
// y de los anillos.

function formatBytes(bytes) {
  var b = Number(bytes || 0)
  var units = ["B", "KiB", "MiB", "GiB", "TiB"]
  var i = 0
  while (b >= 1024 && i < units.length - 1) { b /= 1024; i++ }
  var text = i === 0 ? String(Math.round(b))
    : b >= 100 ? String(Math.round(b))
    : b.toFixed(1).replace(".", ",")
  return text + " " + units[i]
}

function formatPct(fraction) {
  var p = Number(fraction || 0) * 100
  if (p <= 0) return "0 %"
  if (p < 0.1) return "<0,1 %"
  if (p < 10) return p.toFixed(1).replace(".", ",") + " %"
  return Math.round(p) + " %"
}

function formatCount(n) {
  n = Number(n || 0)
  if (n >= 1000000) return (n / 1000000).toFixed(1).replace(".", ",") + " M"
  if (n >= 10000) return Math.round(n / 1000) + " mil"
  return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ".")
}

function joinPath(root, names) {
  var base = String(root || "/").replace(/\/+$/, "")
  if (!names || names.length === 0) return base || "/"
  return base + "/" + names.join("/")
}

function childNamed(node, name) {
  var kids = node && node.c ? node.c : []
  for (var i = 0; i < kids.length; i++)
    if (!kids[i].o && kids[i].n === name) return kids[i]
  return null
}

function nodeAt(tree, names) {
  var node = tree
  for (var i = 0; node && i < names.length; i++) node = childNamed(node, names[i])
  return node
}

// La parte de `names` que todavía existe en el árbol (tras un reescaneo).
function validPrefix(tree, names) {
  var node = tree, out = []
  for (var i = 0; node && i < names.length; i++) {
    node = childNamed(node, names[i])
    if (!node || !node.d) break
    out.push(names[i])
  }
  return out
}

function kindOf(node) {
  if (!node) return "file"
  if (node.o) return "others"
  if (node.d) return "dir"
  if (node.l) return "link"
  return "file"
}

function labelOf(node) {
  if (node.o) return node.o + (node.o === 1 ? " elemento más" : " elementos más")
  return node.n
}

// ---- Mapa de rectángulos (squarified, Bruls et al.) ----
function worstRatio(row, side) {
  var sum = 0, max = 0, min = Infinity
  for (var i = 0; i < row.length; i++) {
    sum += row[i].area
    max = Math.max(max, row[i].area)
    min = Math.min(min, row[i].area)
  }
  if (sum <= 0 || min <= 0) return Infinity
  var s2 = side * side, sum2 = sum * sum
  return Math.max(s2 * max / sum2, sum2 / (s2 * min))
}

// items: [{ value, … }] de mayor a menor. Devuelve [{ item, x, y, w, h }].
function squarify(items, x, y, w, h) {
  var out = []
  var total = 0
  for (var i = 0; i < items.length; i++) total += Math.max(0, items[i].value)
  if (total <= 0 || w <= 1 || h <= 1) return out
  var scale = w * h / total
  var rest = []
  for (i = 0; i < items.length; i++)
    if (items[i].value > 0) rest.push({ item: items[i], area: items[i].value * scale })

  while (rest.length > 0) {
    var side = Math.min(w, h)
    var row = [], best = Infinity, n = 0
    while (n < rest.length) {
      var test = row.concat([rest[n]])
      var worst = worstRatio(test, side)
      if (row.length > 0 && worst > best) break
      row = test
      best = worst
      n++
    }
    rest = rest.slice(row.length)
    var rowArea = 0
    for (i = 0; i < row.length; i++) rowArea += row[i].area
    var thick = rowArea / side
    if (w >= h) {
      var yy = y
      for (i = 0; i < row.length; i++) {
        var hh = row[i].area / thick
        out.push({ item: row[i].item, x: x, y: yy, w: thick, h: hh })
        yy += hh
      }
      x += thick
      w -= thick
    } else {
      var xx = x
      for (i = 0; i < row.length; i++) {
        var ww = row[i].area / thick
        out.push({ item: row[i].item, x: xx, y: y, w: ww, h: thick })
        xx += ww
      }
      y += thick
      h -= thick
    }
  }
  return out
}

// ---- Anillos (sunburst) ----
// items: los hijos ya coloreados del nivel actual ({ name, size, node, color,
// kind }). Devuelve arcos { depth, a0, a1, path, name, size, color, kind, dir }
// con ángulos en radianes desde arriba y en sentido horario.
function sunburst(items, total, maxDepth) {
  var arcs = []
  if (total <= 0) return arcs
  var minSpan = 2 * Math.PI / 720
  var a = 0
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    var span = it.size / total * 2 * Math.PI
    arcs.push({ depth: 1, a0: a, a1: a + span, path: [it.name], name: it.label, size: it.size,
                color: it.color, colorIndex: it.colorIndex, kind: it.kind })
    if (it.node && it.node.c && span > minSpan * 4)
      addArcs(arcs, it.node, a, span, 2, [it.name], it.color, it.colorIndex, maxDepth, minSpan)
    a += span
  }
  return arcs
}

function addArcs(arcs, node, a0, span, depth, path, color, colorIndex, maxDepth, minSpan) {
  if (depth > maxDepth || !node.c || node.s <= 0) return
  var a = a0
  for (var i = 0; i < node.c.length; i++) {
    var c = node.c[i]
    var s = c.s / node.s * span
    if (s >= minSpan) {
      var kind = kindOf(c)
      var childPath = c.o ? path : path.concat([c.n])
      arcs.push({ depth: depth, a0: a, a1: a + s, path: childPath, name: labelOf(c), size: c.s,
                  color: color, colorIndex: colorIndex, kind: kind })
      if (c.c && s > minSpan * 4)
        addArcs(arcs, c, a, s, depth + 1, childPath, color, colorIndex, maxDepth, minSpan)
    }
    a += s
  }
}

// ---- Árbol desplegable ----
// Filas visibles: los hijos de `items` (nivel actual) y, dentro de cada
// carpeta desplegada, sus hijos. `expanded` = { "a/b": true }.
function treeRows(items, basePath, expanded, total) {
  var rows = []
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    pushRow(rows, it.node, it.name, it.label, it.kind, it.size, 0, basePath.concat(it.kind === "others" || it.kind === "system" ? [] : [it.name]), expanded, total, it.color)
  }
  return rows
}

function pushRow(rows, node, name, label, kind, size, depth, path, expanded, total, color) {
  var key = path.join("/")
  var isDir = kind === "dir"
  var open = isDir && !!expanded[key]
  rows.push({ depth: depth, name: name, label: label, kind: kind, size: size, path: path, key: key,
              pct: total > 0 ? size / total : 0, expandable: isDir && !!node && (!!node.p || (node.c && node.c.length > 0)),
              partial: !!(node && node.p), expanded: open, color: color, denied: !!(node && node.e && isDir) })
  if (!open || !node || !node.c) return
  for (var i = 0; i < node.c.length; i++) {
    var c = node.c[i]
    var k = kindOf(c)
    pushRow(rows, c, c.n, labelOf(c), k, c.s, depth + 1, c.o ? path : path.concat([c.n]), expanded, total, color)
  }
}
