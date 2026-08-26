.pragma library
.import "../core/ResultModel.js" as R
.import "../parsers/Json.js" as Json
.import "../parsers/HyprctlOutput.js" as HyprctlOutput

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

var ALL = [CONFIG_ERRORS]
