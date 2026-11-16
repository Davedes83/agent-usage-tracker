.pragma library

// Formatting helpers shared by the bar widget and the popup panel. Pure
// functions only: this file is loaded as a JS library, so it never touches Qt
// or QML state.

function fmtInt(value) {
  var n = Number(value)
  if (!isFinite(n)) n = 0
  n = Math.round(n)
  var s = String(Math.abs(n))
  var out = ""
  while (s.length > 3) {
    out = "," + s.slice(-3) + out
    s = s.slice(0, -3)
  }
  return (n < 0 ? "-" : "") + s + out
}

function fmtTokens(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return "0"
  if (n >= 1e9) return (n / 1e9).toFixed(2) + "B"
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (n >= 1e4) return Math.round(n / 1e3) + "K"
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
  return String(Math.round(n))
}

// Spend display. Tiny numbers keep enough precision to be meaningful, since a
// single cheap request is often well under a cent.
function fmtCost(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return "$0.00"
  if (n < 0.01) return "$" + n.toFixed(4)
  if (n < 1000) return "$" + n.toFixed(2)
  return "$" + fmtInt(n)
}

// Compact form for the bar: omit cents noise but never show a bare "$0.00"
// for real spend.
function fmtCostShort(value) {
  var n = Number(value)
  if (!isFinite(n) || n <= 0) return "$0.00"
  if (n < 0.01) return "<$0.01"
  if (n < 1000) return "$" + n.toFixed(2)
  return "$" + fmtInt(n)
}

function fmtAgo(ms) {
  var t = Number(ms)
  if (!isFinite(t) || t <= 0) return ""
  var secs = Math.max(0, (Date.now() - t) / 1000)
  if (secs < 60) return "just now"
  if (secs < 3600) return Math.floor(secs / 60) + "m ago"
  if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
  if (secs < 7 * 86400) return Math.floor(secs / 86400) + "d ago"
  var d = new Date(t)
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return months[d.getMonth()] + " " + d.getDate()
}

// "nvidia/nemotron-3-nano-omni" -> "nemotron-3-nano-omni" for compact rows;
// ids without a slash are returned unchanged.
function shortModel(id) {
  var s = String(id || "")
  var slash = s.indexOf("/")
  return slash > 0 ? s.slice(slash + 1) : s
}

function pct(part, total) {
  var p = Number(part)
  var t = Number(total)
  if (!isFinite(p) || !isFinite(t) || t <= 0) return 0
  return Math.max(0, Math.min(100, (p / t) * 100))
}

// Percentage width string for the tiny share bars in the provider list.
function barWidth(part, total, maxPx) {
  var px = Math.round((pct(part, total) / 100) * Number(maxPx || 100))
  return Math.max(px, part > 0 ? 2 : 0)
}

// --- panel-specific helpers ---

function fmtPct(value) {
  var n = Number(value)
  if (!isFinite(n)) return "0%"
  return Math.round(n) + "%"
}

function fmtDuration(ms) {
  var s = Math.max(0, Math.round(Number(ms) / 1000))
  if (s < 60) return s + "s"
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s"
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  return h + "h " + m + "m"
}

// Safe property access for QML bindings that might hit undefined
function get(obj, path, fallback) {
  var parts = String(path).split(".")
  var cur = obj
  for (var i = 0; i < parts.length; i++) {
    if (cur === null || cur === undefined) return fallback
    cur = cur[parts[i]]
  }
  return cur === undefined ? fallback : cur
}