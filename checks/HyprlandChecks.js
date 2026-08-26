.pragma library
.import "../core/ResultModel.js" as R
.import "../parsers/Json.js" as Json
.import "../parsers/HyprctlOutput.js" as HyprctlOutput
.import "../parsers/FileMeta.js" as FileMeta

// Spec §17.3 — Hyprland.
//
// Read-only compositor queries. OmaPreflight never dispatches a keyword, never
// reloads the config, and never parses arbitrary Lua — deciding whether a
// binding is semantically reachable is explicitly deferred (§18) because there
// is no reliable evidence source for it yet.

var CONFIG_ERRORS = {
  id: "hyprland.config-errors",
  title: "Hyprland configuration errors",
  category: "hyprland",
  description: "Asks the running compositor whether it is currently reporting "
    + "configuration errors.",
  requiredCapabilities: ["hyprland"],
  defaultSeverity: "error",
  timeoutMs: 5000,
  run: function (ctx, done) {
    ctx.exec(["hyprctl", "configerrors"], { timeoutMs: 5000 }, function (result) {
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not ask Hyprland about configuration errors.",
          details: result.stderr ? [Json.clip(result.stderr, 5)] : [],
          evidence: [R.evidence("command", "hyprctl configerrors", "exit " + result.exitCode)]
        })
        return
      }

      var parsed = HyprctlOutput.parseConfigErrors(result.stdout)
      if (parsed.count === 0) {
        done({
          status: R.STATUS.PASS,
          summary: "Hyprland reports no configuration errors.",
          evidence: [R.evidence("command", "hyprctl configerrors", "")]
        })
        return
      }

      done({
        status: R.STATUS.FAIL,
        summary: parsed.count === 1
          ? "Hyprland is reporting a configuration error."
          : "Hyprland is reporting " + parsed.count + " configuration errors.",
        details: parsed.errors.slice(0, 10),
        evidence: [R.evidence("command", "hyprctl configerrors", Json.clip(result.stdout, 20))],
        remediation: "Run `hyprctl configerrors` in a terminal and fix the reported lines "
          + "before updating, so a post-update problem is not confused with this one."
      })
    })
  }
}

// The Omarchy user configuration files this plugin will look at. An explicit,
// closed list — never a directory walk (§24, §33.6). Absence is normal: an
// untouched Omarchy has few of these, and defaults apply.
var USER_CONFIG_FILES = [
  "hyprland.lua",
  "bindings.lua",
  "monitors.lua",
  "input.lua",
  "looknfeel.lua",
  "autostart.lua"
]

var LIVE_BINDINGS = {
  id: "hyprland.live-bindings",
  title: "Hyprland key bindings",
  category: "hyprland",
  description: "Counts the bindings the running compositor currently has. "
    + "Evidence for comparing against a baseline after an update.",
  requiredCapabilities: ["hyprland"],
  defaultSeverity: "info",
  timeoutMs: 5000,
  // Evidence collection. Whether a binding is semantically *reachable* is
  // explicitly deferred (§18) — there is no reliable evidence source for it,
  // and guessing would be exactly the fake heuristic the spec rules out.
  material: false,
  run: function (ctx, done) {
    ctx.exec(["hyprctl", "binds", "-j"], { timeoutMs: 5000 }, function (result) {
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read the live key bindings.",
          material: false,
          evidence: [R.evidence("command", "hyprctl binds -j", "exit " + result.exitCode)]
        })
        return
      }

      var parsed = HyprctlOutput.parseBinds(result.stdout)
      if (!parsed.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "This Hyprland does not report bindings as JSON.",
          material: false,
          evidence: [R.evidence("command", "hyprctl binds -j", parsed.error)]
        })
        return
      }

      var details = []
      if (parsed.submaps.length > 0) {
        details.push("Submaps: " + parsed.submaps.join(", ") + ".")
      }

      ctx.fact("hyprland.bindingCount", parsed.count)
      done({
        status: R.STATUS.PASS,
        summary: parsed.count + " bindings are active.",
        details: details,
        evidence: [R.evidence("command", "hyprctl binds -j", parsed.count + " bindings")]
      })
    })
  }
}

var LIVE_MONITORS = {
  id: "hyprland.live-monitors",
  title: "Monitors",
  category: "hyprland",
  description: "Records the current output layout. Useful when a display "
    + "behaves differently after an update.",
  requiredCapabilities: ["hyprland"],
  defaultSeverity: "info",
  timeoutMs: 5000,
  material: false,
  run: function (ctx, done) {
    ctx.exec(["hyprctl", "monitors", "-j"], { timeoutMs: 5000 }, function (result) {
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read the monitor layout.",
          material: false,
          evidence: [R.evidence("command", "hyprctl monitors -j", "exit " + result.exitCode)]
        })
        return
      }

      var parsed = HyprctlOutput.parseMonitors(result.stdout)
      if (!parsed.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "This Hyprland does not report monitors as JSON.",
          material: false,
          evidence: [R.evidence("command", "hyprctl monitors -j", parsed.error)]
        })
        return
      }

      // Name and mode only. The `description` field carries the panel's serial
      // number, and a diagnostic report has no use for it (§17.3, §24).
      var lines = []
      for (var i = 0; i < parsed.monitors.length; i++) {
        lines.push(HyprctlOutput.describeMonitor(parsed.monitors[i]))
      }

      ctx.fact("hyprland.monitors", lines)
      var summary = parsed.count === 1
        ? "1 monitor connected."
        : parsed.count + " monitors connected."
      if (parsed.disabledCount > 0) summary += " " + parsed.disabledCount + " disabled."

      done({
        status: R.STATUS.PASS,
        summary: summary,
        details: lines,
        evidence: [R.evidence("command", "hyprctl monitors -j", lines.join("\n"))]
      })
    })
  }
}

var USER_CONFIG_PRESENCE = {
  id: "hyprland.user-config-presence",
  title: "Hyprland user configuration",
  category: "hyprland",
  description: "Records which Omarchy Hyprland config files exist, and their "
    + "size, modification time and hash. Never their contents.",
  requiredCapabilities: [],
  defaultSeverity: "info",
  timeoutMs: 8000,
  material: false,
  run: function (ctx, done) {
    var directory = String(ctx.paths.hyprConfigDir || "")
    if (directory.length === 0) {
      done(R.skippedResult(USER_CONFIG_PRESENCE, "No Hyprland configuration directory is known."))
      return
    }

    var paths = []
    for (var i = 0; i < USER_CONFIG_FILES.length; i++) {
      paths.push(directory + "/" + USER_CONFIG_FILES[i])
    }

    // The paths are built from $HOME, which is environment — outside data by
    // the plugin's own definition — so they are declared and bounded even
    // though this check authored their file names. `--` keeps a path that
    // somehow began with a dash from being read as an option; the runner
    // refuses that case anyway, and both together is the point.
    var statArgv = ["stat", "-c", "%s %Y %n", "--"].concat(paths)
    var statData = []
    for (var s = 4; s < statArgv.length; s++) statData.push(s)

    ctx.exec(statArgv, { timeoutMs: 5000, dataArgs: statData, allowedRoots: [directory] },
      function (statResult) {
        if (statResult.blocked) {
          done({
            status: R.STATUS.UNKNOWN,
            summary: "Refused to inspect the Hyprland configuration: " + statResult.blockedReason + ".",
            material: false
          })
          return
        }

        // stat exits non-zero when any path is missing while still printing the
        // ones it found, so stdout is what matters, not the exit code.
        var stats = FileMeta.parseStat(statResult.stdout)

        var hashArgv = ["sha256sum", "--"].concat(paths)
        var hashData = []
        for (var h = 2; h < hashArgv.length; h++) hashData.push(h)

        ctx.exec(hashArgv, { timeoutMs: 8000, dataArgs: hashData, allowedRoots: [directory] },
          function (hashResult) {
            var hashes = hashResult.blocked
              ? { ok: false, byPath: {}, count: 0 }
              : FileMeta.parseHashes(hashResult.stdout)

            var files = FileMeta.combine(paths, stats, hashes)
            var present = []
            var details = []
            var recorded = []

            for (var f = 0; f < files.length; f++) {
              if (!files[f].present) continue
              present.push(files[f])
              recorded.push({
                path: "~/.config/hypr/" + USER_CONFIG_FILES[f],
                sha256: files[f].hash,
                mtime: FileMeta.isoFromMtime(files[f].mtime),
                size: files[f].sizeBytes
              })
              details.push(USER_CONFIG_FILES[f] + " — "
                + FileMeta.formatBytes(files[f].sizeBytes)
                + (files[f].hash ? ", " + files[f].hash : ""))
            }

            ctx.fact("hyprland.files", recorded)

            if (present.length === 0) {
              done({
                status: R.STATUS.PASS,
                summary: "No Omarchy Hyprland config files are present, so defaults apply.",
                material: false
              })
              return
            }

            done({
              status: R.STATUS.PASS,
              summary: present.length + " of " + USER_CONFIG_FILES.length
                + " Omarchy Hyprland config files are present.",
              details: details,
              material: false,
              evidence: [R.evidence("file", directory, details.join("\n"))]
            })
          })
      })
  }
}

var ALL = [CONFIG_ERRORS, LIVE_BINDINGS, LIVE_MONITORS, USER_CONFIG_PRESENCE]
