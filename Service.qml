import QtQuick
import Quickshell
import Quickshell.Io
import "core" as Core
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

  readonly property var paths: ({
    home: root.homeDir,
    stateDir: root.stateDir,
    configDir: root.configHome,
    omarchyConfigDir: root.configHome + "/omarchy",
    shellConfig: root.configHome + "/omarchy/shell.json",
    pluginsDir: root.configHome + "/omarchy/plugins",
    hyprConfigDir: root.configHome + "/hypr"
  })

  // ---- engine ---------------------------------------------------------
  property Core.CommandRunner runner: Core.CommandRunner {}

  property Core.FileReader fileReader: Core.FileReader {
    // The complete set of directories OmaPreflight will read from. There is no
    // recursive mode and no way for a check to widen this (§24, §33.6).
    allowedPrefixes: [
      root.configHome + "/omarchy/",
      root.configHome + "/hypr/",
      root.stateDir + "/"
    ]
  }

  property Core.CapabilityRegistry capabilities: Core.CapabilityRegistry {}

  property Core.CheckEngine engine: Core.CheckEngine {
    runner: root.runner
    fileReader: root.fileReader
    capabilities: root.capabilities
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

  function resultsJson() {
    return JSON.stringify(store.results)
  }

  IpcHandler {
    // One IpcHandler per target. This service owns the plugin's target, which
    // is why BarWidget.qml leaves `ipcTarget` unset (qs.Ui.Panel would
    // otherwise register a second handler on the same name).
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
    initialScan.start()
  }

  Component.onDestruction: {
    // Stop anything in flight so a reload cannot leave an orphaned process
    // writing into a store that is about to be destroyed (§9.5).
    if (root.store.scanRunning) root.engine.cancel("Plugin unloaded.")
    root.log("service unmounted id=" + root.pluginId)
  }
}
