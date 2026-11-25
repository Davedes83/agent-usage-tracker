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

function fmtAgo(ms, now) {
  var t = Number(ms)
  if (!isFinite(t) || t <= 0) return ""
  var base = isFinite(Number(now)) ? Number(now) : Date.now()
  var secs = Math.max(0, (base - t) / 1000)
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