import QtQuick
import "ResultModel.js" as R
import "Sanitizer.js" as Sanitizer
import "../checks/Registry.js" as Registry

// Builds the sanitized Markdown diagnostic report (spec §26).
//
// Three properties the report has to have, in priority order:
//
//   1. It is safe to paste. Everything goes through the sanitizer, and the
//      header says to review it anyway, because sanitization of free-form
//      command output is pattern matching and can only ever be best-effort.
//   2. It is readable by a person. Summarized evidence first; raw blocks only
//      where a check actually failed (§26: "raw stdout should not dominate").
//   3. It is honest. UNKNOWN and SKIPPED are reported as themselves, and the
//      readiness line says whether the scan completed.
//
// Nothing here is ever uploaded. The report is written into the state
// directory and the user decides what happens next (§24).
QtObject {
  id: root

  property var store: null
  property var capabilities: null
  property string pluginVersion: ""
  property var paths: ({})
  property var sanitizeContext: null

  readonly property string reviewNotice: "Review this report before posting it publicly."

  function build() {
    var context = sanitizeContext || Sanitizer.makeContext({})
    var results = store && store.results ? store.results : []
    var summary = R.summarize(results, store && store.lastCompletedScanId === store.scanId)

    var out = []
    out.push("# OmaPreflight Diagnostic Report")
    out.push("")
    out.push("> " + reviewNotice)
    out.push("")
    _appendHeader(out, context)
    _appendReadiness(out, summary, results)
    _appendFindings(out, results, context)
    _appendPassing(out, results)
    _appendCapabilities(out)
    _appendSanitizationNote(out)

    return out.join("\n") + "\n"
  }

  function suggestedPath() {
    var stamp = new Date().toISOString().replace(/[:.]/g, "").replace("Z", "Z")
    return String(paths.stateDir || "") + "/reports/" + stamp + ".md"
  }

  // ---- sections --------------------------------------------------------

  function _appendHeader(out, context) {
    out.push("Generated: " + new Date().toISOString())
    out.push("OmaPreflight: " + (pluginVersion || "unknown"))
    out.push("Omarchy: " + _fact("omarchy.version", context))
    out.push("Channel: " + _fact("omarchy.channel", context))
    out.push("Quickshell: " + _fact("environment.quickshell-version", context))
    out.push("Hyprland: " + _fact("environment.hyprland-present", context))
    out.push("")
  }

  function _appendReadiness(out, summary, results) {
    out.push("## Readiness")
    out.push("")
    out.push(R.readinessLabel(store ? store.readiness : "neutral"))
    if (store && store.readiness === R.READINESS.UNKNOWN) {
      out.push("")
      out.push("_The scan did not complete, so this verdict reflects missing information "
        + "rather than a clean or a failing system._")
    }
    out.push("")

    out.push("## Summary")
    out.push("")
    var counts = summary.counts
    out.push("- " + counts.pass + " passed")
    out.push("- " + counts.warn + (counts.warn === 1 ? " warning" : " warnings"))
    out.push("- " + counts.fail + (counts.fail === 1 ? " failure" : " failures"))
    out.push("- " + summary.blockers + (summary.blockers === 1 ? " blocker" : " blockers"))
    out.push("- " + counts.unknown + " unknown")
    out.push("- " + counts.skipped + " skipped")
    out.push("")
  }

  function _appendFindings(out, results, context) {
    var findings = []
    for (var i = 0; i < results.length; i++) {
      var status = results[i].status
      if (status === R.STATUS.PASS) continue
      findings.push(results[i])
    }
    findings = R.sortForDisplay(findings)

    out.push("## Findings")
    out.push("")
    if (findings.length === 0) {
      out.push("_Nothing to report: every check that ran passed._")
      out.push("")
      return
    }

    for (var f = 0; f < findings.length; f++) {
      var safe = Sanitizer.sanitizeResult(findings[f], context)
      out.push("### " + R.statusLabel(safe.status) + " — " + safe.title)
      out.push("")
      out.push(safe.summary)
      out.push("")

      if (safe.details.length > 0) {
        for (var d = 0; d < safe.details.length; d++) out.push("- " + safe.details[d])
        out.push("")
      }

      if (safe.remediation) {
        out.push("**Suggested next step:** " + safe.remediation)
        out.push("")
      }

      // Raw evidence only where something is actually wrong. A report full of
      // command output from passing checks buries the two lines that matter.
      var wantsRaw = safe.status === R.STATUS.FAIL || safe.status === R.STATUS.WARN
      if (wantsRaw && safe.evidence.length > 0) {
        out.push("<details><summary>Evidence</summary>")
        out.push("")
        for (var e = 0; e < safe.evidence.length; e++) {
          var item = safe.evidence[e]
          out.push("`" + item.label + "`")
          out.push("")
          out.push("```")
          out.push(item.value.length > 0 ? item.value : "(no output)")
          out.push("```")
          out.push("")
        }
        out.push("</details>")
        out.push("")
      }

      out.push("_" + safe.id + " · " + safe.fingerprint + "_")
      out.push("")
    }
  }

  // Passing checks are listed by name only. What passed matters — it says what
  // was actually looked at — but it does not need a paragraph each.
  function _appendPassing(out, results) {
    var passing = []
    for (var i = 0; i < results.length; i++) {
      if (results[i].status === R.STATUS.PASS) passing.push(results[i])
    }
    if (passing.length === 0) return

    out.push("## Passed")
    out.push("")
    for (var p = 0; p < passing.length; p++) {
      out.push("- " + Registry.categoryTitle(passing[p].category) + " — " + passing[p].title)
    }
    out.push("")
  }

  function _appendCapabilities(out) {
    if (!capabilities) return
    var list = capabilities.asList()
    if (list.length === 0) return

    out.push("## Capabilities")
    out.push("")
    out.push("What this machine could be asked. A check whose capability is "
      + "missing is skipped rather than guessed at.")
    out.push("")
    for (var i = 0; i < list.length; i++) {
      out.push("- " + (list[i].available ? "yes" : "no ") + " · " + list[i].id)
    }
    out.push("")
  }

  function _appendSanitizationNote(out) {
    out.push("## Sanitization")
    out.push("")
    out.push("Home paths, usernames, hostnames, hardware and network addresses, "
      + "temporary paths, and values whose key names suggest a secret were "
      + "replaced automatically. That is pattern matching, not a guarantee.")
    out.push("")
    out.push(reviewNotice)
  }

  // Pull a one-line fact out of a check result for the header block.
  function _fact(checkId, context) {
    var results = store && store.results ? store.results : []
    for (var i = 0; i < results.length; i++) {
      if (results[i].id !== checkId) continue
      return Sanitizer.sanitize(results[i].summary, context)
    }
    return "unknown"
  }
}
