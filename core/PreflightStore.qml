import QtQuick

// Reactive state for the whole plugin. Deliberately dumb: it holds values and
// notifies, it never runs commands or parses anything. The service owns it and
// every surface reads it (spec §13 PreflightStore).
//
// This is a plain QtObject rather than a `pragma Singleton` on purpose — see
// docs/adr/ADR-001-shared-state.md.
QtObject {
  id: root

  // ---- readiness -----------------------------------------------------
  // Finite vocabulary only (spec §3.1). No numeric score, ever.
  readonly property string readyState: "ready"
  readonly property string reviewState: "review"
  readonly property string notRecommendedState: "not_recommended"
  readonly property string unknownState: "unknown"

  // "neutral" is the pre-scan state: distinct from "unknown", which means a
  // scan ran and could not establish the facts.
  property string readiness: "neutral"

  // ---- scan lifecycle ------------------------------------------------
  property bool scanRunning: false
  property string scanId: ""
  property real scanProgress: 0          // 0..1, -1 when indeterminate
  property string scanPhase: ""
  property var lastScanAt: null          // ISO-8601 string or null
  property string lastCompletedScanId: ""

  // ---- results -------------------------------------------------------
  property var results: []               // ResultModel result objects
  property var categories: ({})          // categoryId -> {pass, warn, fail, unknown, skipped}
  property var capabilities: ({})        // capability id -> bool
  property var environment: ({})         // versions discovered this scan
  property var baseline: null
  property var errors: []                // internal failures worth surfacing

  // Stamped by the service so summary() is self-contained (QtObject exposes no
  // usable `parent` in QML, so the store cannot reach back up).
  property string pluginVersion: ""

  signal changed()

  function reset() {
    readiness = "neutral"
    scanRunning = false
    scanId = ""
    scanProgress = 0
    scanPhase = ""
    results = []
    categories = ({})
    errors = []
    changed()
  }

  // A compact, JSON-serializable view for IPC callers and the bar widget.
  function summary() {
    return {
      pluginVersion: pluginVersion,
      readiness: readiness,
      scanRunning: scanRunning,
      lastScanAt: lastScanAt,
      lastCompletedScanId: lastCompletedScanId,
      counts: countsByStatus(),
      capabilities: capabilities
    }
  }

  function countsByStatus() {
    var counts = { pass: 0, warn: 0, fail: 0, unknown: 0, skipped: 0 }
    for (var i = 0; i < results.length; i++) {
      var status = results[i] && results[i].status ? String(results[i].status) : ""
      if (counts[status] !== undefined) counts[status]++
    }
    return counts
  }
}
