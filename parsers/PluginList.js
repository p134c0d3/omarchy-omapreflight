.pragma library
.import "Json.js" as Json

// Parser for `omarchy plugin list --json`.
//
// Verified shape on Omarchy 4.0.1 — a bare array, and thinner than the
// engineering spec assumed. Each entry carries:
//
//   id, name, kinds, enabled, active, canDisable, firstParty, clonedFrom
//
// It does **not** carry a source directory and it does **not** carry a version
// (spec §17.4 assumed both). So a plugin's directory has to be derived as
// `<pluginsDir>/<id>` and its version read from that directory's own
// manifest.json. That derivation is the reason `plugins.*` checks are the
// first in the catalog to pass an externally-sourced value to a process, and
// why they declare it (see docs/security.md).

function parse(text) {
  var parsed = Json.parseArray(text)
  if (!parsed.ok) {
    return { ok: false, error: parsed.error, plugins: [], count: 0 }
  }

  var plugins = []
  for (var i = 0; i < parsed.value.length; i++) {
    var entry = parsed.value[i]
    if (!entry || typeof entry !== "object") continue
    var id = String(entry.id || "")
    if (id.length === 0) continue

    plugins.push({
      id: id,
      name: String(entry.name || id),
      kinds: Array.isArray(entry.kinds) ? entry.kinds.map(String) : [],
      enabled: entry.enabled === true,
      active: entry.active === true,
      canDisable: entry.canDisable === true,
      firstParty: entry.firstParty === true,
      clonedFrom: String(entry.clonedFrom || "")
    })
  }

  plugins.sort(function (a, b) { return a.id.localeCompare(b.id) })
  return { ok: true, error: "", plugins: plugins, count: plugins.length }
}

function thirdParty(list) {
  var out = []
  var plugins = list && list.plugins ? list.plugins : []
  for (var i = 0; i < plugins.length; i++) {
    if (!plugins[i].firstParty) out.push(plugins[i])
  }
  return out
}

function enabled(list) {
  var out = []
  var plugins = list && list.plugins ? list.plugins : []
  for (var i = 0; i < plugins.length; i++) {
    if (plugins[i].enabled) out.push(plugins[i])
  }
  return out
}

function counts(list) {
  var plugins = list && list.plugins ? list.plugins : []
  var result = { total: plugins.length, firstParty: 0, thirdParty: 0, enabled: 0, active: 0 }
  for (var i = 0; i < plugins.length; i++) {
    if (plugins[i].firstParty) result.firstParty++
    else result.thirdParty++
    if (plugins[i].enabled) result.enabled++
    if (plugins[i].active) result.active++
  }
  return result
}

// A plugin id is part of a path and part of an argv, so its shape is checked
// before either. This mirrors the id rule the shell itself enforces:
// `^[A-Za-z0-9][A-Za-z0-9._-]*$`. Anything else is refused rather than
// sanitized — there is no legitimate id that needs rescuing.
var ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

function isSafeId(id) {
  var value = String(id || "")
  if (!ID_PATTERN.test(value)) return false
  // Belt and braces: the pattern already excludes both, but a directory
  // component that is "." or ".." would be a traversal even though every
  // character in it is allowed.
  return value !== "." && value !== ".."
}

// Derived, because the CLI does not tell us. Returns "" for an id that has no
// business being turned into a path.
function directoryFor(pluginsDir, id) {
  if (!isSafeId(id)) return ""
  var base = String(pluginsDir || "")
  if (base.length === 0) return ""
  if (base.charAt(base.length - 1) === "/") base = base.substring(0, base.length - 1)
  return base + "/" + String(id)
}
