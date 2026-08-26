.pragma library
.import "../core/ResultModel.js" as R
.import "../parsers/Json.js" as Json
.import "../parsers/PacmanQuery.js" as PacmanQuery

// Spec §17.1 — Environment.
//
// These checks establish what OmaPreflight is standing on before anything else
// draws a conclusion. They are cheap, they run first, and several later checks
// are capability-gated on what they discover.

var OMARCHY_PRESENT = {
  id: "environment.omarchy-present",
  title: "Omarchy CLI",
  category: "environment",
  description: "Confirms the Omarchy command-line interface is installed and responds.",
  requiredCapabilities: [],
  // A blocker, and the only one in this category. If the Omarchy CLI cannot be
  // reached, `omarchy update` is not a thing that can be run at all — that is
  // a genuine "do not proceed", not a caveat (§16).
  defaultSeverity: "blocker",
  timeoutMs: 8000,
  run: function (ctx, done) {
    var caps = ctx.capabilities
    var probe = caps.probeResult("omarchyCommands")

    if (caps.has("omarchy.cli")) {
      done({
        status: R.STATUS.PASS,
        summary: "The Omarchy CLI is installed and responded.",
        evidence: [R.evidence("command", "omarchy commands --json", "exit 0")]
      })
      return
    }

    var reason = "The Omarchy CLI did not respond."
    if (probe && probe.blocked) reason = "The Omarchy CLI probe was refused: " + probe.blockedReason
    else if (probe && probe.startFailed) reason = "The `omarchy` command could not be started. Is Omarchy installed?"
    else if (probe && probe.timedOut) reason = "The `omarchy` command did not answer within its time budget."

    done({
      status: probe && probe.timedOut ? R.STATUS.UNKNOWN : R.STATUS.FAIL,
      summary: reason,
      evidence: probe ? [R.evidence("command", "omarchy commands --json", Json.clip(probe.stderr, 5))] : [],
      remediation: "Check that the `omarchy` package is installed and that `omarchy version` runs in a terminal."
    })
  }
}

var COMMAND_DISCOVERY = {
  id: "environment.command-discovery",
  title: "Command catalog",
  category: "environment",
  description: "Reads the CLI's own command catalog, which is what decides "
    + "which checks are allowed to run.",
  requiredCapabilities: ["omarchy.cli"],
  defaultSeverity: "error",
  timeoutMs: 8000,
  run: function (ctx, done) {
    var caps = ctx.capabilities
    var catalog = caps.catalog

    if (!caps.has("omarchy.commandsJson") || !catalog) {
      var probe = caps.probeResult("omarchyCommands")
      done({
        status: R.STATUS.UNKNOWN,
        // Material: without the catalog every capability-gated check degrades,
        // so the scan genuinely knows less than it should.
        summary: "Could not read the command catalog, so capability detection is incomplete.",
        details: probe && probe.stderr ? [Json.clip(probe.stderr, 5)] : [],
        evidence: [R.evidence("command", "omarchy commands --json", probe ? "exit " + probe.exitCode : "not run")]
      })
      return
    }

    var details = []
    if (catalog.hiddenCount > 0) {
      details.push(catalog.hiddenCount + " hidden route(s) were ignored.")
    }

    done({
      status: R.STATUS.PASS,
      summary: catalog.count + " command routes advertised by the CLI.",
      details: details,
      evidence: [R.evidence("command", "omarchy commands --json", catalog.count + " routes")]
    })
  }
}

var HYPRLAND_PRESENT = {
  id: "environment.hyprland-present",
  title: "Hyprland IPC",
  category: "environment",
  description: "Confirms the Hyprland control socket is reachable from this session.",
  requiredCapabilities: [],
  defaultSeverity: "warning",
  timeoutMs: 3000,
  run: function (ctx, done) {
    var caps = ctx.capabilities

    if (caps.has("hyprland")) {
      var version = caps.hyprlandVersion
      done({
        status: R.STATUS.PASS,
        summary: version && version.ok
          ? "Hyprland " + version.version + " is running and reachable."
          : "Hyprland IPC is reachable.",
        evidence: [R.evidence("command", "hyprctl version", version ? version.raw : "")]
      })
      return
    }

    var probe = caps.probeResult("hyprctlVersion")
    done({
      status: R.STATUS.WARN,
      summary: "Hyprland IPC is not reachable, so compositor checks cannot run.",
      details: ["This is expected if the shell is running outside a Hyprland session."],
      evidence: probe ? [R.evidence("command", "hyprctl version", Json.clip(probe.stderr, 5))] : []
    })
  }
}

var QUICKSHELL_VERSION = {
  id: "environment.quickshell-version",
  title: "Quickshell version",
  category: "environment",
  description: "Records the Quickshell version. Informational, and the single "
    + "most useful line in a shell bug report.",
  requiredCapabilities: [],
  defaultSeverity: "info",
  timeoutMs: 5000,
  // Purely informational: not knowing it should not move readiness (§16).
  material: false,
  run: function (ctx, done) {
    // Quickshell does not expose its own version to QML, so the package
    // database is the only safe source. Asking which package owns the binary
    // avoids guessing a package name — this machine has moved between
    // `quickshell-git` and `quickshell` already.
    ctx.exec(["pacman", "-Qo", "/usr/bin/quickshell"], { timeoutMs: 5000 }, function (result) {
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not determine the Quickshell version.",
          material: false,
          evidence: [R.evidence("command", "pacman -Qo /usr/bin/quickshell",
            result.startFailed ? "pacman is not available" : "exit " + result.exitCode)]
        })
        return
      }

      var parsed = PacmanQuery.parseOwner(result.stdout)
      done({
        status: parsed.ok ? R.STATUS.PASS : R.STATUS.UNKNOWN,
        summary: parsed.ok
          ? "Quickshell " + parsed.version + " (package " + parsed.packageName + ")."
          : "Could not parse the Quickshell package version.",
        material: false,
        evidence: [R.evidence("command", "pacman -Qo /usr/bin/quickshell", Json.clip(result.stdout, 3))]
      })
    })
  }
}

var ALL = [OMARCHY_PRESENT, COMMAND_DISCOVERY, HYPRLAND_PRESENT, QUICKSHELL_VERSION]
