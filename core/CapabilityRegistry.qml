import QtQuick
import "../parsers/OmarchyCommands.js" as OmarchyCommands
import "../parsers/HyprctlOutput.js" as HyprctlOutput

// What this machine can actually be asked, discovered rather than assumed.
//
// Spec §28: capability detection drives whether a check runs at all. A check
// whose capability is missing is SKIPPED with a reason — it is never a crash,
// and it is never quietly reported as a pass.
//
// Two rules the registry exists to enforce:
//
//   * A route is only "available" if the CLI advertises it. Finding a binary
//     on disk proves nothing about whether calling it is supported (§17.2).
//   * A route that requires privilege is discoverable but NOT callable.
//     `omarchy snapshot` is exactly this case on Omarchy 4.0.1 — the route is
//     real and `requires_sudo` is true, so OmaPreflight records that snapshots
//     exist as a mechanism while refusing to claim it can use them (§17.6,
//     §23.4).
QtObject {
  id: root

  // capability id -> bool
  property var capabilities: ({})
  // Parsed `omarchy commands --json`, kept so checks can cite it as evidence
  // instead of running the command a second time.
  property var catalog: null
  property var hyprlandVersion: null
  property bool ready: false

  // Probes are data so that adding a capability is a one-line change and the
  // cost of capability detection stays visible. Every probe result flows
  // through the engine's memo, so a check that needs the same command later
  // does not pay for it twice.
  readonly property var probes: [
    { key: "omarchyCommands", argv: ["omarchy", "commands", "--json"], timeoutMs: 8000 },
    { key: "hyprctlVersion", argv: ["hyprctl", "version"], timeoutMs: 3000 },
    // Doubles as the runtime.failed-user-units command. Because every probe
    // goes through the engine's memo, the check that needs this answer later
    // gets it for free rather than launching systemctl a second time.
    { key: "systemctlUserFailed", argv: ["systemctl", "--user", "--failed", "--no-legend", "--no-pager"], timeoutMs: 5000 }
  ]

  // Routes whose presence maps to a named capability. Kept declarative so the
  // mapping can be read at a glance and reviewed against the CLI.
  readonly property var routeCapabilities: ({
    "omarchy.version": "omarchy version",
    "omarchy.channel": "omarchy channel current",
    "omarchy.pluginList": "omarchy plugin list",
    "omarchy.pluginValidate": "omarchy plugin validate",
    "omarchy.pluginUpdate": "omarchy plugin update",
    "omarchy.snapshot": "omarchy snapshot"
  })

  property var _probeResults: ({})

  function has(id) {
    return capabilities[id] === true
  }

  // Human-readable reason a check was skipped, for the UI and the report.
  function missingReason(ids) {
    var missing = []
    for (var i = 0; i < (ids || []).length; i++) {
      if (!has(ids[i])) missing.push(ids[i])
    }
    if (missing.length === 0) return ""
    return "Requires " + missing.join(", ") + ", which is not available here."
  }

  function satisfies(ids) {
    for (var i = 0; i < (ids || []).length; i++) {
      if (!has(ids[i])) return false
    }
    return true
  }

  // `exec` is the engine's memoized command function: exec(argv, opts, cb).
  function refresh(exec, done) {
    ready = false
    _probeResults = ({})

    var remaining = probes.length
    if (remaining === 0) {
      _derive()
      if (done) done()
      return
    }

    for (var i = 0; i < probes.length; i++) {
      _runProbe(exec, probes[i], function () {
        remaining--
        if (remaining === 0) {
          root._derive()
          if (done) done()
        }
      })
    }
  }

  function _runProbe(exec, probe, next) {
    exec(probe.argv, { timeoutMs: probe.timeoutMs }, function (result) {
      root._probeResults[probe.key] = result
      next()
    })
  }

  function probeResult(key) {
    return _probeResults[key] || null
  }

  function _derive() {
    var caps = {}

    // ---- Omarchy CLI ------------------------------------------------
    var commands = _probeResults["omarchyCommands"]
    var cliRan = !!commands && !commands.startFailed && !commands.blocked
    caps["omarchy.cli"] = cliRan

    var parsedCatalog = null
    if (cliRan && commands.ok) {
      parsedCatalog = OmarchyCommands.parse(commands.stdout)
    }
    catalog = parsedCatalog
    caps["omarchy.commandsJson"] = !!parsedCatalog && parsedCatalog.ok

    for (var capId in routeCapabilities) {
      var route = routeCapabilities[capId]
      // isCallable is deliberately stricter than hasRoute: a privileged route
      // is present but unusable by this plugin.
      caps[capId] = !!parsedCatalog && OmarchyCommands.isCallable(parsedCatalog, route)
      caps[capId + ".route"] = !!parsedCatalog && OmarchyCommands.hasRoute(parsedCatalog, route)
    }

    // ---- systemd ----------------------------------------------------
    var systemd = _probeResults["systemctlUserFailed"]
    caps["systemd.user"] = !!systemd && systemd.ok

    // ---- Hyprland ---------------------------------------------------
    var hypr = _probeResults["hyprctlVersion"]
    var hyprOk = !!hypr && hypr.ok
    hyprlandVersion = hyprOk ? HyprctlOutput.parseVersion(hypr.stdout) : null
    caps["hyprland"] = hyprOk

    capabilities = caps
    ready = true
  }

  // Flat list for the UI's capability view (§7.3) and the report (§26).
  function asList() {
    var out = []
    for (var id in capabilities) {
      if (id.lastIndexOf(".route") === id.length - 6) continue
      out.push({ id: id, available: capabilities[id] === true })
    }
    out.sort(function (a, b) { return a.id.localeCompare(b.id) })
    return out
  }
}
