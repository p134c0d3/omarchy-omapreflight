.pragma library
.import "Json.js" as Json

// Parser for ~/.config/omarchy/shell.json.
//
// Three rules, all from spec §17.2:
//
//   * absence is not a fault — Omarchy runs on defaults when the file is not
//     there, so a missing file is a PASS with an explanatory summary;
//   * the file is never mutated, only read;
//   * an unknown future schema version is UNKNOWN, never "corrupt". Being
//     ahead of this plugin is Omarchy's prerogative.
//
// Verified top-level keys on Omarchy 4.0.1: version, bar, idle, plugins.

var SUPPORTED_VERSIONS = [1]

function parse(text) {
  var parsed = Json.parseObject(text)
  if (!parsed.ok) {
    return { ok: false, error: parsed.error, version: null, versionSupported: false }
  }

  var config = parsed.value
  var version = typeof config.version === "number" ? config.version : null
  var bar = config.bar && typeof config.bar === "object" ? config.bar : null
  var layout = bar && bar.layout && typeof bar.layout === "object" ? bar.layout : null

  return {
    ok: true,
    error: "",
    version: version,
    versionSupported: version !== null && SUPPORTED_VERSIONS.indexOf(version) >= 0,
    topLevelKeys: Object.keys(config).sort(),
    hasBar: bar !== null,
    barPosition: bar ? String(bar.position || "") : "",
    barSections: layout ? Object.keys(layout).sort() : [],
    barWidgetCount: layout ? _countLayout(layout) : 0,
    barWidgetIds: layout ? _layoutIds(layout) : [],
    // `plugins` is the shell's own plugin bookkeeping. Only its size is read
    // here; the authoritative plugin inventory comes from
    // `omarchy plugin list --json` (§17.4).
    pluginEntryCount: config.plugins && typeof config.plugins === "object"
      ? Object.keys(config.plugins).length : 0
  }
}

function _countLayout(layout) {
  var total = 0
  for (var section in layout) {
    var entries = layout[section]
    if (Array.isArray(entries)) total += entries.length
  }
  return total
}

function _layoutIds(layout) {
  var ids = []
  for (var section in layout) {
    var entries = layout[section]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (entry && typeof entry === "object" && entry.id) ids.push(String(entry.id))
    }
  }
  ids.sort()
  return ids
}
