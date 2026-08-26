.pragma library
.import "Json.js" as Json

// Parsers for the hyprctl surfaces OmaPreflight reads.
//
// All of them are read-only queries. OmaPreflight never dispatches a Hyprland
// keyword and never reloads the compositor.

// ---- hyprctl configerrors -------------------------------------------
//
// Clean output on Hyprland 0.56.2 is blank (verified: two empty lines). Older
// and newer builds have printed "no config errors" style banners, so those are
// filtered too rather than reported as an error line.
var _CLEAN_PATTERNS = [
  /^no\s+config\s+errors?/i,
  /^config\s+errors?:\s*none/i,
  /^\[?\s*ok\s*\]?$/i
]

function parseConfigErrors(text) {
  var lines = Json.nonEmptyLines(text)
  var errors = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var clean = false
    for (var p = 0; p < _CLEAN_PATTERNS.length; p++) {
      if (_CLEAN_PATTERNS[p].test(line)) { clean = true; break }
    }
    if (!clean) errors.push(line)
  }
  return { errors: errors, count: errors.length }
}

// ---- hyprctl version -------------------------------------------------
//
// "Hyprland 0.56.2 built from branch v0.56.2 at commit efb5099... clean (...)."
function parseVersion(text) {
  var line = Json.firstLine(text)
  if (line.length === 0) return { ok: false, version: "", tag: "", raw: "" }

  var match = /Hyprland\s+v?([0-9][0-9A-Za-z.\-]*)/.exec(line)
  var tagMatch = /Tag:\s*(v?[0-9][0-9A-Za-z.\-]*)/.exec(String(text || ""))
  return {
    ok: !!match,
    version: match ? match[1] : "",
    tag: tagMatch ? tagMatch[1] : "",
    raw: line
  }
}

// ---- hyprctl binds -j ------------------------------------------------
//
// Evidence collection only in v0.1. Deciding whether a binding is semantically
// reachable is explicitly deferred (§18) — guessing here would be exactly the
// fake heuristic the spec forbids.
function parseBinds(text) {
  var parsed = Json.parseArray(text)
  if (!parsed.ok) return { ok: false, error: parsed.error, count: 0, submaps: [], dispatchers: {} }

  var binds = parsed.value
  var submaps = {}
  var dispatchers = {}

  for (var i = 0; i < binds.length; i++) {
    var bind = binds[i]
    if (!bind || typeof bind !== "object") continue

    var submap = String(bind.submap || "")
    if (submap.length > 0) submaps[submap] = (submaps[submap] || 0) + 1

    var dispatcher = String(bind.dispatcher || "unknown")
    dispatchers[dispatcher] = (dispatchers[dispatcher] || 0) + 1
  }

  var submapNames = []
  for (var name in submaps) submapNames.push(name)
  submapNames.sort()

  return {
    ok: true,
    error: "",
    count: binds.length,
    submaps: submapNames,
    dispatchers: dispatchers
  }
}

// ---- hyprctl monitors -j ---------------------------------------------
//
// Only the identifiers and mode metadata a bug report actually needs (§17.3).
// Monitor descriptions carry serial numbers, so they are collected but the
// report sanitizer is what decides whether they survive into shared output.
function parseMonitors(text) {
  var parsed = Json.parseArray(text)
  if (!parsed.ok) return { ok: false, error: parsed.error, count: 0, monitors: [], disabledCount: 0 }

  var monitors = []
  var disabledCount = 0

  for (var i = 0; i < parsed.value.length; i++) {
    var m = parsed.value[i]
    if (!m || typeof m !== "object") continue
    if (m.disabled === true) disabledCount++

    monitors.push({
      name: String(m.name || ""),
      description: String(m.description || ""),
      width: Number(m.width) || 0,
      height: Number(m.height) || 0,
      refreshRate: Math.round((Number(m.refreshRate) || 0) * 100) / 100,
      x: Number(m.x) || 0,
      y: Number(m.y) || 0,
      scale: Number(m.scale) || 1,
      disabled: m.disabled === true,
      focused: m.focused === true
    })
  }

  return { ok: true, error: "", count: monitors.length, monitors: monitors, disabledCount: disabledCount }
}

function describeMonitor(monitor) {
  return monitor.name + " " + monitor.width + "x" + monitor.height
    + "@" + monitor.refreshRate + "Hz"
    + (monitor.scale !== 1 ? " scale " + monitor.scale : "")
    + (monitor.disabled ? " (disabled)" : "")
}
