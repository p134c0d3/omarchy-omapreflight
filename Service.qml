import QtQuick
import Quickshell
import Quickshell.Io
import "core" as Core

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

  // ---- state paths (spec §14.1) ---------------------------------------
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME") || (homeDir + "/.local/state")
  readonly property string stateDir: stateHome + "/omapreflight"

  function log(message) {
    console.log("[omapreflight] " + message)
  }

  // ---- public API (also the IPC surface, spec §32) ---------------------

  // Run the full deterministic check suite. Wired to the CheckEngine in M1;
  // until then it reports honestly rather than faking a result.
  function runPreflight() {
    if (store.scanRunning) return "busy"
    return "not-implemented"
  }

  function statusJson() {
    return JSON.stringify(store.summary())
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
  }

  Component.onDestruction: {
    root.log("service unmounted id=" + root.pluginId)
  }
}
