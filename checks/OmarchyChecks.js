.pragma library
.import "../core/ResultModel.js" as R
.import "../parsers/Json.js" as Json
.import "../parsers/OmarchyVersion.js" as OmarchyVersion
.import "../parsers/ShellConfig.js" as ShellConfig

// Spec §17.2 — Omarchy.
//
// Every command here comes from the CLI's own advertised catalog. None of them
// mutate anything: `shell.json` is read and never written, and the version and
// channel are queried, never set.

var VERSION = {
  id: "omarchy.version",
  title: "Omarchy version",
  category: "omarchy",
  description: "Records the installed Omarchy version, which anchors the "
    + "baseline comparison and every bug report.",
  requiredCapabilities: ["omarchy.version"],
  defaultSeverity: "error",
  timeoutMs: 5000,
  run: function (ctx, done) {
    ctx.exec(["omarchy", "version"], { timeoutMs: 5000 }, function (result) {
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read the Omarchy version.",
          details: result.stderr ? [Json.clip(result.stderr, 5)] : [],
          evidence: [R.evidence("command", "omarchy version", "exit " + result.exitCode)]
        })
        return
      }

      var parsed = OmarchyVersion.parseVersion(result.stdout)
      if (!parsed.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "The Omarchy version could not be interpreted: " + parsed.error + ".",
          evidence: [R.evidence("command", "omarchy version", Json.clip(result.stdout, 3))]
        })
        return
      }

      done({
        status: R.STATUS.PASS,
        summary: "Omarchy " + parsed.version + ".",
        evidence: [R.evidence("command", "omarchy version", parsed.version)]
      })
    })
  }
}

var CHANNEL = {
  id: "omarchy.channel",
  title: "Release channel",
  category: "omarchy",
  description: "Records which release channel this machine follows.",
  requiredCapabilities: ["omarchy.channel"],
  defaultSeverity: "info",
  timeoutMs: 5000,
  run: function (ctx, done) {
    ctx.exec(["omarchy", "channel", "current"], { timeoutMs: 5000 }, function (result) {
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read the release channel.",
          material: false,
          evidence: [R.evidence("command", "omarchy channel current", "exit " + result.exitCode)]
        })
        return
      }

      var parsed = OmarchyVersion.parseChannel(result.stdout)
      if (!parsed.known) {
        // A channel name this plugin does not recognize is information, not a
        // fault. The channel list is Omarchy's to grow.
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Release channel reported as '" + parsed.channel + "', which this version of OmaPreflight does not recognize.",
          material: false,
          evidence: [R.evidence("command", "omarchy channel current", parsed.channel)]
        })
        return
      }

      var details = []
      if (parsed.channel !== "stable") {
        // Channel changes readiness *context*, never the verdict by itself
        // (§17.2). Saying so in a detail line is the honest middle ground.
        details.push("Non-stable channels receive changes earlier and with less soak time.")
      }

      done({
        status: R.STATUS.PASS,
        summary: "Following the " + parsed.channel + " channel.",
        details: details,
        evidence: [R.evidence("command", "omarchy channel current", parsed.channel)]
      })
    })
  }
}

var SHELL_CONFIG_READABLE = {
  id: "omarchy.shell-config-readable",
  title: "Shell configuration readable",
  category: "omarchy",
  description: "Reads ~/.config/omarchy/shell.json and confirms it parses. "
    + "The file is never modified.",
  requiredCapabilities: [],
  defaultSeverity: "error",
  timeoutMs: 4000,
  run: function (ctx, done) {
    ctx.readFile(ctx.paths.shellConfig, function (file) {
      if (file.missing) {
        // Absence is a perfectly good answer: Omarchy runs on defaults (§17.2).
        done({
          status: R.STATUS.PASS,
          summary: "No shell.json is present, so Omarchy shell defaults are in effect.",
          evidence: [R.evidence("file", ctx.paths.shellConfig, "not present")]
        })
        return
      }

      if (!file.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read shell.json: " + file.error + ".",
          evidence: [R.evidence("file", ctx.paths.shellConfig, file.error)]
        })
        return
      }

      var parsed = ShellConfig.parse(file.text)
      if (!parsed.ok) {
        done({
          status: R.STATUS.FAIL,
          summary: "shell.json is present but does not parse: " + parsed.error + ".",
          details: ["The shell falls back to defaults when it cannot read this file, "
            + "so bar layout and plugin selection may not be what you expect."],
          evidence: [R.evidence("file", ctx.paths.shellConfig, parsed.error)],
          remediation: "Inspect the file with `jq . ~/.config/omarchy/shell.json` to find the syntax error."
        })
        return
      }

      var details = []
      if (parsed.hasBar) {
        details.push("Bar: " + parsed.barWidgetCount + " widget(s) across "
          + parsed.barSections.join(", ") + ".")
      }

      done({
        status: R.STATUS.PASS,
        summary: "shell.json is present and parses cleanly.",
        details: details,
        evidence: [R.evidence("file", ctx.paths.shellConfig,
          "top-level keys: " + parsed.topLevelKeys.join(", "))]
      })
    })
  }
}

var SHELL_CONFIG_VERSION = {
  id: "omarchy.shell-config-version",
  title: "Shell configuration schema",
  category: "omarchy",
  description: "Checks the shell.json schema version against what this plugin understands.",
  requiredCapabilities: [],
  defaultSeverity: "warning",
  timeoutMs: 4000,
  run: function (ctx, done) {
    ctx.readFile(ctx.paths.shellConfig, function (file) {
      if (file.missing) {
        done({
          status: R.STATUS.SKIPPED,
          summary: "No shell.json to version-check.",
          material: false
        })
        return
      }

      if (!file.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read shell.json: " + file.error + ".",
          material: false
        })
        return
      }

      var parsed = ShellConfig.parse(file.text)
      if (!parsed.ok) {
        // The parse failure is already reported by shell-config-readable.
        // Repeating it as a second finding would inflate the count without
        // adding information.
        done({
          status: R.STATUS.SKIPPED,
          summary: "shell.json does not parse, so its schema version cannot be read.",
          material: false
        })
        return
      }

      if (parsed.version === null) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "shell.json declares no schema version.",
          material: false,
          evidence: [R.evidence("file", ctx.paths.shellConfig, "no 'version' key")]
        })
        return
      }

      if (!parsed.versionSupported) {
        // Being ahead of this plugin is Omarchy's prerogative. UNKNOWN, never
        // "corrupt" (§17.2).
        done({
          status: R.STATUS.UNKNOWN,
          summary: "shell.json declares schema version " + parsed.version
            + ", which this version of OmaPreflight does not know.",
          details: ["This usually means Omarchy is newer than the plugin. "
            + "Checks that read shell.json may be less accurate until OmaPreflight catches up."],
          evidence: [R.evidence("file", ctx.paths.shellConfig, "version " + parsed.version)]
        })
        return
      }

      done({
        status: R.STATUS.PASS,
        summary: "shell.json schema version " + parsed.version + " is understood.",
        evidence: [R.evidence("file", ctx.paths.shellConfig, "version " + parsed.version)]
      })
    })
  }
}

var ALL = [VERSION, CHANNEL, SHELL_CONFIG_READABLE, SHELL_CONFIG_VERSION]
