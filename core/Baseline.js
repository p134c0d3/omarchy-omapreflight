.pragma library
.import "../parsers/Json.js" as Json

// The baseline document: how it is built from a scan's facts, how it is read
// back, and how a later scan is compared against it.
//
// Pure, so the shape and the comparison can be tested exhaustively without a
// filesystem. `BaselineStore.qml` does the I/O and nothing else.
//
// Schema version is explicit from day one (spec §14.3). A baseline written by
// a future OmaPreflight must be recognised as "newer than me" rather than
// misread — the same courtesy the plugin extends to shell.json.

var SCHEMA_VERSION = 1

// Spec §19. Metadata only — no file contents, ever.
function build(facts, pluginVersion, createdAt) {
  var f = facts || {}
  var omarchy = f.omarchy || {}
  var quickshell = f.quickshell || {}
  var hyprland = f.hyprland || {}
  var shell = f.shell || {}
  var plugins = f.plugins || {}

  return {
    schemaVersion: SCHEMA_VERSION,
    createdAt: String(createdAt || ""),
    pluginVersion: String(pluginVersion || ""),
    omarchy: {
      version: String(omarchy.version || ""),
      channel: String(omarchy.channel || "")
    },
    quickshell: {
      version: String(quickshell.version || "")
    },
    hyprland: {
      version: String(hyprland.version || ""),
      bindingCount: typeof hyprland.bindingCount === "number" ? hyprland.bindingCount : null,
      monitors: Array.isArray(hyprland.monitors) ? hyprland.monitors.map(String) : []
    },
    shell: {
      configFingerprint: String(shell.configFingerprint || ""),
      configVersion: shell.configVersion === undefined ? null : shell.configVersion
    },
    plugins: _buildPlugins(plugins),
    files: _buildFiles(hyprland.files)
  }
}

// Rebuilt field by field rather than copied.
//
// A `.slice()` here would be a shallow copy, so whatever keys a caller happened
// to put on a file record would ride along into the baseline — and the one
// promise this document makes is that it holds metadata and never contents
// (§19). Enumerating the four permitted fields makes that a property of the
// builder instead of a property of every caller remembering.
function _buildFiles(files) {
  if (!Array.isArray(files)) return []
  var out = []
  for (var i = 0; i < files.length; i++) {
    var file = files[i]
    if (!file || !file.path) continue
    out.push({
      path: String(file.path),
      sha256: String(file.sha256 || ""),
      mtime: String(file.mtime || ""),
      size: typeof file.size === "number" ? file.size : 0
    })
  }
  return out
}

function _buildPlugins(plugins) {
  var inventory = Array.isArray(plugins.thirdParty) ? plugins.thirdParty : []
  var gitState = plugins.gitState && typeof plugins.gitState === "object" ? plugins.gitState : {}
  var out = []

  for (var i = 0; i < inventory.length; i++) {
    var entry = inventory[i]
    if (!entry || !entry.id) continue
    var git = gitState[entry.id] || {}
    out.push({
      id: String(entry.id),
      version: String(entry.version || ""),
      gitHead: String(git.gitHead || ""),
      dirty: git.dirty === true,
      enabled: entry.enabled === true
    })
  }

  out.sort(function (a, b) { return a.id.localeCompare(b.id) })
  return out
}

// Read back defensively. This is a file on disk that a future version, a
// half-finished write, or a text editor could have touched.
function parse(text) {
  var parsed = Json.parseObject(text)
  if (!parsed.ok) return { ok: false, baseline: null, error: parsed.error }

  var value = parsed.value
  if (typeof value.schemaVersion !== "number") {
    return { ok: false, baseline: null, error: "baseline has no schema version" }
  }
  if (value.schemaVersion > SCHEMA_VERSION) {
    return {
      ok: false,
      baseline: null,
      error: "baseline schema version " + value.schemaVersion
        + " is newer than this version of OmaPreflight understands"
    }
  }

  return { ok: true, baseline: value, error: "" }
}

function summarize(baseline) {
  if (!baseline) return { present: false }
  return {
    present: true,
    createdAt: String(baseline.createdAt || ""),
    pluginVersion: String(baseline.pluginVersion || ""),
    omarchyVersion: baseline.omarchy ? String(baseline.omarchy.version || "") : "",
    channel: baseline.omarchy ? String(baseline.omarchy.channel || "") : "",
    pluginCount: Array.isArray(baseline.plugins) ? baseline.plugins.length : 0,
    fileCount: Array.isArray(baseline.files) ? baseline.files.length : 0
  }
}

// What changed between the baseline and the current facts.
//
// This is deliberately a *description*, not a judgement. "Your Omarchy version
// differs from the baseline" is a fact; whether that is good, expected, or a
// sign of a failed rollback is for the check — and ultimately the reader — to
// decide (§3.1).
function compare(baseline, facts) {
  if (!baseline) return { comparable: false, reason: "no baseline", changes: [] }
  var f = facts || {}
  var changes = []

  _compareValue(changes, "Omarchy version",
    _at(baseline, ["omarchy", "version"]), _at(f, ["omarchy", "version"]))
  _compareValue(changes, "Release channel",
    _at(baseline, ["omarchy", "channel"]), _at(f, ["omarchy", "channel"]))
  _compareValue(changes, "Quickshell version",
    _at(baseline, ["quickshell", "version"]), _at(f, ["quickshell", "version"]))
  _compareValue(changes, "Hyprland version",
    _at(baseline, ["hyprland", "version"]), _at(f, ["hyprland", "version"]))
  _compareValue(changes, "shell.json",
    _at(baseline, ["shell", "configFingerprint"]), _at(f, ["shell", "configFingerprint"]))

  _compareFiles(changes, baseline.files, _at(f, ["hyprland", "files"]))
  _comparePlugins(changes, baseline.plugins, f.plugins)

  return { comparable: true, reason: "", changes: changes }
}

function _at(object, pathSegments) {
  var node = object
  for (var i = 0; i < pathSegments.length; i++) {
    if (!node || typeof node !== "object") return undefined
    node = node[pathSegments[i]]
  }
  return node
}

// A value missing on either side is "not comparable", not "changed". Reporting
// a change because a check was skipped this time would be a lie by omission.
function _compareValue(changes, label, before, after) {
  var a = before === undefined || before === null ? "" : String(before)
  var b = after === undefined || after === null ? "" : String(after)
  if (a.length === 0 || b.length === 0) return
  if (a === b) return
  changes.push({ kind: "value", label: label, before: a, after: b })
}

function _compareFiles(changes, before, after) {
  if (!Array.isArray(before) || !Array.isArray(after)) return

  var baselineByPath = {}
  for (var i = 0; i < before.length; i++) {
    if (before[i] && before[i].path) baselineByPath[before[i].path] = before[i]
  }

  var seen = {}
  for (var j = 0; j < after.length; j++) {
    var current = after[j]
    if (!current || !current.path) continue
    seen[current.path] = true
    var previous = baselineByPath[current.path]
    if (!previous) {
      changes.push({ kind: "file-added", label: current.path })
      continue
    }
    if (previous.sha256 && current.sha256 && previous.sha256 !== current.sha256) {
      changes.push({ kind: "file-changed", label: current.path,
                     before: previous.sha256, after: current.sha256 })
    }
  }

  for (var path in baselineByPath) {
    if (!seen[path]) changes.push({ kind: "file-removed", label: path })
  }
}

function _comparePlugins(changes, before, after) {
  if (!Array.isArray(before)) return
  var inventory = after && Array.isArray(after.thirdParty) ? after.thirdParty : null
  if (!inventory) return

  var baselineById = {}
  for (var i = 0; i < before.length; i++) {
    if (before[i] && before[i].id) baselineById[before[i].id] = before[i]
  }

  var gitState = after.gitState && typeof after.gitState === "object" ? after.gitState : {}
  var seen = {}

  for (var j = 0; j < inventory.length; j++) {
    var entry = inventory[j]
    if (!entry || !entry.id) continue
    seen[entry.id] = true

    var previous = baselineById[entry.id]
    if (!previous) {
      changes.push({ kind: "plugin-added", label: entry.id })
      continue
    }

    var head = gitState[entry.id] ? String(gitState[entry.id].gitHead || "") : ""
    if (previous.gitHead && head && previous.gitHead !== head) {
      changes.push({ kind: "plugin-updated", label: entry.id,
                     before: previous.gitHead.substring(0, 7),
                     after: head.substring(0, 7) })
    }
  }

  for (var id in baselineById) {
    if (!seen[id]) changes.push({ kind: "plugin-removed", label: id })
  }
}

function describeChange(change) {
  switch (change.kind) {
  case "value": return change.label + ": " + change.before + " → " + change.after
  case "file-changed": return change.label + " changed since the baseline"
  case "file-added": return change.label + " is new since the baseline"
  case "file-removed": return change.label + " is gone since the baseline"
  case "plugin-added": return "Plugin added: " + change.label
  case "plugin-removed": return "Plugin removed: " + change.label
  case "plugin-updated": return "Plugin " + change.label + " moved from "
    + change.before + " to " + change.after
  default: return change.label
  }
}
