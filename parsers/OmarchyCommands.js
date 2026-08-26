.pragma library
.import "Json.js" as Json

// Parser for `omarchy commands --json`.
//
// This is the plugin's capability ground truth (spec §17.1
// environment.command-discovery, §28). The rule it exists to enforce: never
// assume a command from the spec still exists, and never invoke a binary just
// because it happens to be on disk. If the CLI does not advertise a route,
// OmaPreflight does not call it.
//
// Verified shape on Omarchy 4.0.1 — the payload is an object, not an array:
//
//   {
//     "ok": true,
//     "commands": [
//       { "route": "omarchy plugin list", "binary": "omarchy-plugin-list",
//         "group": "plugin", "name": "list", "summary": "...",
//         "requires_sudo": false, "hidden": false, "args": "[--json]",
//         "examples": [...], "aliases": [], "filename_route": "...",
//         "routes": ["omarchy plugin list"] }
//     ]
//   }
//
// A route may advertise several spellings in `routes`; all of them are indexed.

function parse(text) {
  var parsed = Json.parseObject(text)
  if (!parsed.ok) {
    return { ok: false, error: parsed.error, routes: [], byRoute: {}, count: 0, hiddenCount: 0 }
  }

  var payload = parsed.value
  var commands = payload.commands
  if (!Array.isArray(commands)) {
    return { ok: false, error: "payload has no 'commands' array", routes: [], byRoute: {}, count: 0, hiddenCount: 0 }
  }

  var routes = []
  var byRoute = {}
  var hiddenCount = 0

  for (var i = 0; i < commands.length; i++) {
    var command = commands[i]
    if (!command || typeof command !== "object") continue

    if (command.hidden === true) {
      hiddenCount++
      continue
    }

    var entry = {
      route: String(command.route || ""),
      binary: String(command.binary || ""),
      group: String(command.group || ""),
      summary: String(command.summary || ""),
      args: String(command.args || ""),
      // Carried so a capability can say "the route exists but needs privilege"
      // rather than the plugin discovering that by being refused (§23.4).
      requiresPrivilege: command.requires_sudo === true
    }

    var spellings = Array.isArray(command.routes) && command.routes.length > 0
      ? command.routes
      : [entry.route]

    for (var j = 0; j < spellings.length; j++) {
      var spelling = String(spellings[j] || "").trim()
      if (spelling.length === 0) continue
      if (!byRoute[spelling]) {
        byRoute[spelling] = entry
        routes.push(spelling)
      }
    }
  }

  routes.sort()
  return {
    ok: true,
    error: "",
    routes: routes,
    byRoute: byRoute,
    count: routes.length,
    hiddenCount: hiddenCount,
    // `ok: false` from the CLI itself is different from unparseable output.
    cliReportedOk: payload.ok !== false
  }
}

function hasRoute(catalog, route) {
  return !!(catalog && catalog.byRoute && catalog.byRoute[route])
}

// True only when the route exists *and* OmaPreflight is allowed to run it.
// A privileged route is discoverable but not callable (§23.4).
function isCallable(catalog, route) {
  var entry = catalog && catalog.byRoute ? catalog.byRoute[route] : null
  return !!entry && entry.requiresPrivilege !== true
}

function routesInGroup(catalog, group) {
  if (!catalog || !catalog.byRoute) return []
  var out = []
  for (var route in catalog.byRoute) {
    if (catalog.byRoute[route].group === group) out.push(route)
  }
  out.sort()
  return out
}
