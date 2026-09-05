import QtQuick
import Quickshell
import Quickshell.Io
import "core" as Core
import "core/Sanitizer.js" as Sanitizer
import "core/Baseline.js" as Baseline
import "checks/Registry.js" as Registry

// OmaPreflight service — the single long-lived object the shell mounts for this
// plugin. `shell.qml:_syncServices()` mounts exactly one instance per plugin id
// and destroys it on disable/removal/reload, so this is the natural home for
// shared state (ADR-001).
//
// Surfaces reach it two ways:
//   Overlay.qml    — injected by the shell panel loader (`if ("service" in item)`)
//   BarWidget.qml  — bar?.shell?.serviceFor("p134c0d3.omapreflight")
//
// It owns lifecycle and orchestration only. No parser logic lives here (§13).
Item {
  id: root

  // ---- injected by the shell on mount --------------------------------
  property var manifest: null
  property QtObject shell: null

  readonly property string pluginId: manifest && manifest.id
    ? String(manifest.id) : "p134c0d3.omapreflight"
  readonly property string pluginVersion: manifest && manifest.version
    ? String(manifest.version) : "0.0.0"
  readonly property string sourceDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir) : ""

  // ---- shared state ---------------------------------------------------
  property Core.PreflightStore store: Core.PreflightStore {
    pluginVersion: root.pluginVersion
  }

  // ---- paths (spec §14.1) ---------------------------------------------
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")
  readonly property string stateDir: stateHome + "/omapreflight"
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (homeDir + "/.config")

  readonly property string reportsDir: stateDir + "/reports"

  readonly property var paths: ({
    home: root.homeDir,
    stateDir: root.stateDir,
    reportsDir: root.reportsDir,
    configDir: root.configHome,
    omarchyConfigDir: root.configHome + "/omarchy",
    shellConfig: root.configHome + "/omarchy/shell.json",
    pluginsDir: root.configHome + "/omarchy/plugins",
    hyprConfigDir: root.configHome + "/hypr"
  })

  // ---- engine ---------------------------------------------------------
  property Core.CommandRunner runner: Core.CommandRunner {}

  property Core.FileReader fileReader: Core.FileReader {
    // Reads share the command runner: a read is a bounded, no-follow `stat` and
    // `dd` pair rather than a second I/O path with its own rules.
    runner: root.runner

    // The complete set of directories OmaPreflight will read from. There is no
    // recursive mode and no way for a check to widen this (§24, §33.6).
    //
    // The Hyprland config directory is deliberately absent: those files are
    // only ever *measured* — `stat` and `sha256sum`, size and hash, never
    // contents (§17.3) — so granting read access to them would widen the
    // allowlist past anything the catalog actually needs.
    allowedPrefixes: [
      root.configHome + "/omarchy/",
      root.stateDir + "/"
    ]
  }

  property Core.FileWriter fileWriter: Core.FileWriter {
    // One writable directory, for the whole plugin, forever.
    stateDir: root.stateDir
  }

  property Core.CapabilityRegistry capabilities: Core.CapabilityRegistry {}

  property Core.BaselineStore baselineStore: Core.BaselineStore {
    fileReader: root.fileReader
    fileWriter: root.fileWriter
    path: root.stateDir + "/baseline.json"
    pluginVersion: root.pluginVersion
  }

  property Core.ReportBuilder reportBuilder: Core.ReportBuilder {
    store: root.store
    capabilities: root.capabilities
    pluginVersion: root.pluginVersion
    paths: root.paths
    sanitizeContext: Sanitizer.makeContext({
      home: root.homeDir,
      user: Quickshell.env("USER") || ""
    })
  }

  property Core.CheckEngine engine: Core.CheckEngine {
    runner: root.runner
    fileReader: root.fileReader
    capabilities: root.capabilities
    baseline: root.baselineStore
    store: root.store
    paths: root.paths
    checks: Registry.all()

    onFinished: function (completed, results) {
      root.log("scan " + (completed ? "completed" : "did not complete")
        + " readiness=" + root.store.readiness
        + " checks=" + results.length)
    }
  }

  function log(message) {
    console.log("[omapreflight] " + message)
  }

  // ---- public API (also the IPC surface, spec §32) ---------------------

  // Run the full deterministic check suite. Returns the scan id, or "busy" if
  // one is already running — scans never overlap (§9.5).
  function runPreflight() {
    return String(engine.start("manual"))
  }

  function cancelPreflight() {
    if (!store.scanRunning) return "idle"
    engine.cancel("Scan cancelled.")
    return "cancelled"
  }

  function statusJson() {
    return JSON.stringify(store.summary())
  }

  // ---- reports (spec §26) ---------------------------------------------
  //
  // Written locally, never uploaded. `saveReport` returns the path through the
  // callback; the surfaces show it so the user knows exactly what exists and
  // where.
  // Returns the path it is writing to, synchronously, and delivers the outcome
  // through the callback. The path is deterministic, so a caller that only
  // wants to tell the user where the file will be does not have to wait.
  function saveReport(callback) {
    if (!store.results || store.results.length === 0) {
      if (callback) callback({ ok: false, error: "no scan results to report", path: "" })
      return ""
    }

    var markdown = reportBuilder.build()
    var target = reportBuilder.suggestedPath()

    // The directory may not exist yet, and a write into a missing directory
    // fails in a way that reads like a permissions problem. Create it first,
    // then write regardless of the mkdir's outcome — if it genuinely failed,
    // the write's own error is the more useful one to report.
    ensureStateDirs(function () {
      root.fileWriter.write(target, markdown, function (result) {
        if (!result.ok) root.log("report write failed: " + result.error)
        if (callback) callback(result)
      })
    })

    return target
  }

  // Record the current state as the baseline. Deliberately explicit: nothing
  // records one on its own, because a baseline captured automatically at the
  // wrong moment — mid-update, or with a broken config — is worse than no
  // baseline at all.
  function saveBaseline(callback) {
    var capture = Baseline.capture(store, root.engine.facts)
    if (!capture.ok) {
      if (callback) callback(capture)
      return ""
    }

    ensureStateDirs(function () {
      root.baselineStore.save(capture.facts, function (result) {
        if (!result.ok) root.log("baseline write failed: " + result.error)
        if (callback) callback(result)
      })
    })
    return baselineStore.path
  }

  // Copying is explicitly user-initiated, from a button. Nothing reaches the
  // clipboard on its own.
  function copyReport() {
    if (!store.results || store.results.length === 0) return "empty"
    Quickshell.clipboardText = reportBuilder.build()
    return "copied"
  }

  property bool stateDirsEnsured: false

  // 0700 so a report is not world-readable on a shared machine. The files
  // themselves land with the process umask; the directory mode is what
  // actually protects them.
  function ensureStateDirs(done) {
    if (stateDirsEnsured) {
      if (done) done()
      return
    }
    // Both directories are named explicitly. `-m` applies to the directories
    // mkdir is asked to create, not to the parents `-p` fills in, so naming
    // only the leaf would leave the state directory itself world-readable.
    runner.run(["mkdir", "-p", "-m", "700", root.stateDir, root.reportsDir],
               { timeoutMs: 4000, dataArgs: [4, 5], allowedRoots: [root.stateHome] },
               function (result) {
                 root.stateDirsEnsured = result.ok
                 if (!result.ok && result.blocked) root.log("state directory refused: " + result.blockedReason)
                 if (done) done()
               })
  }

  function resultsJson() {
    return JSON.stringify(store.results)
  }

  // One IPC response captures a completed scan's checklist and facts together.
  // The update gate must never combine status from one scan with another's
  // results, or accept an old READY while a new scan is running.
  function updateSnapshot(expectedScanId) {
    if (!expectedScanId || store.scanRunning || store.scanId !== expectedScanId
        || store.lastCompletedScanId !== expectedScanId) {
      return JSON.stringify({ ok: false, error: "the requested scan has not completed" })
    }
    return JSON.stringify({
      ok: true,
      schemaVersion: 1,
      scanId: store.scanId,
      completedAt: store.lastScanAt,
      pluginVersion: root.pluginVersion,
      readiness: store.readiness,
      checkCount: root.engine.checks.length,
      results: store.results.map(function (result) {
        return Sanitizer.sanitizeResult(result, root.reportBuilder.sanitizeContext)
      }),
      baseline: Baseline.build(store.environment, root.pluginVersion, store.lastScanAt)
    })
  }

  // ---- window rule -----------------------------------------------------
  //
  // The diagnostic surface is a real toplevel (ADR-005), which is what makes
  // SUPER+drag move it and SUPER+right-drag resize it — Omarchy binds those to
  // window management, and a layer-shell surface can never receive them. What
  // a Wayland client cannot do is ask to be floating, so the rule that says so
  // is registered with Hyprland at runtime.
  //
  // This is the one thing OmaPreflight does that is not a read. Three things
  // bound it:
  //
  //   * it is scoped by class *and* title to this plugin's own window;
  //   * it is a named rule, so re-registering replaces rather than accumulates;
  //   * it is runtime-only. No file is written and no user configuration is
  //     touched — the rule is gone when the compositor restarts.
  //
  // The Lua is a literal. Nothing from the environment, from a file, or from
  // another command's output is interpolated into it, which is the property
  // that makes handing a string to `hyprctl eval` defensible at all.
  //
  // `hyprctl keyword` would be the obvious alternative and does not work here:
  // Omarchy configures Hyprland through the Lua parser, and keyword refuses
  // with "can't work with non-legacy parsers. Use eval." This is also the
  // approach the b.okomart plugin uses for its own window.
  readonly property string windowRuleLua: 'hl.window_rule({ name = "omapreflight-window",'
    + ' match = { class = "^org.quickshell$", title = "^OmaPreflight$" },'
    + ' float = true, center = true })'

  property bool windowRuleRegistered: false
  property bool windowRuleReported: false

  function ensureWindowRule(done) {
    if (windowRuleRegistered) {
      if (done) done()
      return
    }
    runner.run(["hyprctl", "eval", root.windowRuleLua], { timeoutMs: 4000 }, function (result) {
      root.windowRuleRegistered = result.ok && String(result.stdout).trim() === "ok"
      if (!root.windowRuleRegistered && !root.windowRuleReported) {
        // Said once, not on every open. The window still works without the
        // rule; it is tiled instead of floating (§31: stay quiet in normal
        // operation).
        root.windowRuleReported = true
        root.log("window rule not registered ("
          + (result.blocked ? result.blockedReason
             : (result.startFailed ? "hyprctl unavailable"
                : String(result.stderr || ("exit " + result.exitCode)).trim()))
          + "); the report window will be tiled rather than floating")
      }
      if (done) done()
    })
  }

  // ---- quick panel routing ---------------------------------------------
  //
  // One instance of the bar widget exists per screen, so "open the panel" has
  // to answer "which one?". The shell already solved this: `Bar.findPanelWidget`
  // picks the instance on the output Hyprland currently has focused, which is
  // why `shell.summon` routes through the bar rather than through a per-target
  // IPC handler — a handler declared on the widget would only ever reach
  // whichever per-monitor copy registered first.
  //
  // So the panel's IPC lives here, on the single service instance, and
  // delegates to the host's own routing.
  function _bar() {
    return shell && shell.bar ? shell.bar : null
  }

  function openPanelSurface() {
    var bar = _bar()
    if (!bar || typeof bar.summonBarWidget !== "function") return "unavailable"
    return bar.summonBarWidget(root.pluginId) ? "open" : "no-panel"
  }

  function closePanelSurface() {
    var bar = _bar()
    if (!bar || typeof bar.hideBarWidget !== "function") return "unavailable"
    return bar.hideBarWidget(root.pluginId) ? "closed" : "no-panel"
  }

  function togglePanelSurface() {
    var bar = _bar()
    if (!bar || typeof bar.isBarWidgetOpen !== "function") return "unavailable"
    return bar.isBarWidgetOpen(root.pluginId) ? closePanelSurface() : openPanelSurface()
  }

  IpcHandler {
    // One IpcHandler per target name. This service owns the plugin's own
    // target; the bar widget's quick panel answers on
    // `p134c0d3.omapreflight.panel` so the two cannot collide.
    target: "p134c0d3.omapreflight"

    function ping(): string {
      return "ok"
    }

    function status(): string {
      return root.statusJson()
    }

    function run(): string {
      return root.runPreflight()
    }

    function cancel(): string {
      return root.cancelPreflight()
    }

    function results(): string {
      return root.resultsJson()
    }

    function updateSnapshot(scanId: string): string {
      return root.updateSnapshot(scanId)
    }

    function cancelScan(scanId: string): string {
      return root.store.scanId === scanId ? root.cancelPreflight() : "different-scan"
    }

    // Writes a sanitized Markdown report into the state directory and returns
    // the path it is being written to. Nothing is uploaded (§24).
    function report(): string {
      var path = root.saveReport(null)
      return path === "" ? "no-results" : path
    }

    // The bar widget's quick panel, on every screen that has one. Bindable to
    // a hotkey; without this the panel is mouse-only, because `shell toggle`
    // is claimed by the overlay.
    // Records the current scan as the baseline and returns where it was
    // written. Never automatic (§19).
    function baseline(): string {
      var path = root.saveBaseline(null)
      return path === "" ? "no-scan" : path
    }

    function openPanel(): string { return root.openPanelSurface() }
    function closePanel(): string { return root.closePanelSurface() }
    function togglePanel(): string { return root.togglePanelSurface() }
  }

  // The first scan is automatic but deliberately late: the shell has a bar to
  // draw and plugins to mount when it starts, and a diagnostic tool should not
  // be competing for that. Nothing about it is privileged or destructive, so
  // running it unprompted is safe (§13: trigger initial lightweight scan).
  property bool autoScanOnStart: true

  Timer {
    id: initialScan
    interval: 5000
    repeat: false
    running: false
    onTriggered: {
      if (!root.autoScanOnStart) return
      root.runPreflight()
    }
  }

  // The shell creates the object first and injects `manifest`/`shell` after
  // (shell.qml:ensureService), so injected values are NOT available in
  // Component.onCompleted. Anything that depends on the manifest must wait for
  // it to arrive — including this line, which would otherwise report 0.0.0.
  property bool announced: false

  onManifestChanged: {
    if (!manifest || announced) return
    announced = true
    // Logged so a duplicate mount is visible in the shell log immediately.
    // Normal operation stays quiet after this line (§31).
    // Read straight off the manifest: dependent bindings such as
    // `pluginVersion` have not necessarily re-evaluated yet when this handler
    // runs, so they would still report the pre-injection fallback.
    root.log("service mounted id=" + String(manifest.id)
      + " version=" + String(manifest.version))
    root.ensureWindowRule(null)
    // Loaded before the first scan so the recovery checks have something to
    // compare against on the very first run after a restart.
    root.baselineStore.load(null)
    initialScan.start()
  }

  Component.onDestruction: {
    // Stop anything in flight so a reload cannot leave an orphaned process
    // writing into a store that is about to be destroyed (§9.5).
    if (root.store.scanRunning) root.engine.cancel("Plugin unloaded.")
    root.log("service unmounted id=" + root.pluginId)
  }
}
