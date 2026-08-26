.pragma library
.import "EnvironmentChecks.js" as EnvironmentChecks
.import "OmarchyChecks.js" as OmarchyChecks
.import "HyprlandChecks.js" as HyprlandChecks
.import "PluginChecks.js" as PluginChecks
.import "RuntimeChecks.js" as RuntimeChecks
.import "RecoveryChecks.js" as RecoveryChecks

// The catalog, in execution order.
//
// Order matters in one direction only: the environment checks run first
// because everything downstream is capability-gated on what they establish.
// Within a category, order is cosmetic — the display sorts by severity anyway.

var CATEGORIES = [
  { id: "environment", title: "Environment", description: "What OmaPreflight is standing on." },
  { id: "omarchy", title: "Omarchy", description: "Version, channel, and shell configuration." },
  { id: "hyprland", title: "Hyprland", description: "Compositor state and configuration." },
  { id: "plugins", title: "Plugins", description: "Installed plugins and their validity." },
  { id: "runtime", title: "Runtime", description: "Services and storage." },
  { id: "recovery", title: "Recovery", description: "What you could fall back to." }
]

function all() {
  return []
    .concat(EnvironmentChecks.ALL)
    .concat(OmarchyChecks.ALL)
    .concat(HyprlandChecks.ALL)
    .concat(PluginChecks.ALL)
    .concat(RuntimeChecks.ALL)
    .concat(RecoveryChecks.ALL)
}

function categoryTitle(id) {
  for (var i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].id === id) return CATEGORIES[i].title
  }
  return String(id)
}

function categoryOrder(id) {
  for (var i = 0; i < CATEGORIES.length; i++) {
    if (CATEGORIES[i].id === id) return i
  }
  return CATEGORIES.length
}

function byId(id) {
  var checks = all()
  for (var i = 0; i < checks.length; i++) {
    if (checks[i].id === id) return checks[i]
  }
  return null
}
