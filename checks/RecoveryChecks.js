.pragma library
.import "../core/ResultModel.js" as R
.import "../core/Baseline.js" as Baseline
.import "../parsers/OmarchyVersion.js" as OmarchyVersion

// Spec §17.6 — Recovery.
//
// What you could fall back to if an update goes badly. The theme running
// through all three checks is refusing to overstate: a snapshot mechanism
// existing is not the same as snapshots being available, and a baseline you
// have not recorded is not a fault.

var SNAPSHOT_CAPABILITY = {
  id: "recovery.snapshot-capability",
  title: "System snapshots",
  category: "recovery",
  description: "Reports whether a snapshot mechanism appears to exist on this "
    + "machine. It does not — and cannot — confirm that a usable snapshot is "
    + "present.",
  requiredCapabilities: [],
  defaultSeverity: "warning",
  timeoutMs: 6000,
  // Not knowing does not move readiness. Snapshots are a safety net, and their
  // absence is a fact about the machine rather than a reason not to update.
  material: false,
  run: function (ctx, done) {
    var caps = ctx.capabilities

    if (!caps.has("omarchy.snapshot.route")) {
      done({
        status: R.STATUS.WARN,
        summary: "This Omarchy has no snapshot command, so there is no built-in rollback.",
        material: false,
        details: ["An update that goes wrong would have to be recovered by hand."]
      })
      return
    }

    // The route exists and requires privilege — `requires_sudo: true` on
    // Omarchy 4.0.1 — so OmaPreflight can see the mechanism and can never
    // exercise it. Claiming "snapshots available" on the strength of a command
    // existing is exactly what §17.6 forbids.
    // "/" is a literal this check authored, so it is not declared as a data
    // argument. Declaring plugin-authored values would dilute the one property
    // that makes `grep -rn dataArgs` useful: that every hit is external input.
    ctx.exec(["findmnt", "-n", "-o", "FSTYPE", "--", "/"], { timeoutMs: 4000 },
      function (result) {
        var filesystem = result.ok ? String(result.stdout || "").trim() : ""

        if (filesystem === "btrfs") {
          done({
            status: R.STATUS.PASS,
            summary: "Snapshots look possible: `omarchy snapshot` exists and / is btrfs.",
            details: [
              "OmaPreflight cannot verify that a snapshot actually exists — "
                + "`omarchy snapshot` requires privilege and this plugin never asks for it.",
              "Confirm for yourself by running `snapper list` as root before relying on it."
            ],
            material: false,
            evidence: [R.evidence("command", "findmnt -n -o FSTYPE /", filesystem)]
          })
          return
        }

        if (filesystem.length > 0) {
          done({
            status: R.STATUS.WARN,
            summary: "`omarchy snapshot` exists, but / is " + filesystem
              + " rather than btrfs, so snapper snapshots are unlikely to work.",
            material: false,
            evidence: [R.evidence("command", "findmnt -n -o FSTYPE /", filesystem)]
          })
          return
        }

        done({
          status: R.STATUS.UNKNOWN,
          summary: "A snapshot command exists, but whether snapshots are usable could not be established.",
          material: false,
          evidence: [R.evidence("command", "findmnt -n -o FSTYPE /",
            result.ok ? "no output" : "exit " + result.exitCode)]
        })
      })
  }
}

var BASELINE_PRESENT = {
  id: "recovery.baseline-present",
  title: "Baseline recorded",
  category: "recovery",
  description: "Reports whether OmaPreflight has a recorded baseline to "
    + "compare against.",
  requiredCapabilities: [],
  defaultSeverity: "info",
  timeoutMs: 4000,
  // Deliberately not material. Having no baseline is the state every machine
  // starts in, and turning a fresh install into REVIEW would train people to
  // ignore the verdict — which costs more than the missing baseline does.
  material: false,
  run: function (ctx, done) {
    var store = ctx.baseline
    if (!store) {
      done(R.skippedResult(BASELINE_PRESENT, "Baseline storage is unavailable."))
      return
    }

    if (!store.has()) {
      done({
        status: R.STATUS.UNKNOWN,
        summary: "No baseline has been recorded yet.",
        material: false,
        details: store.lastError && store.lastError.length > 0
          ? ["The existing baseline could not be read: " + store.lastError]
          : [],
        remediation: "Press B in the report window to record the current state as a baseline. "
          + "A later scan can then say exactly what changed."
      })
      return
    }

    var summary = store.summary()
    done({
      status: R.STATUS.PASS,
      summary: "Baseline recorded " + (summary.createdAt || "at an unknown time") + ".",
      details: [
        "Omarchy " + (summary.omarchyVersion || "unknown")
          + (summary.channel ? " on " + summary.channel : "") + " at the time.",
        summary.pluginCount + " third-party plugin(s) and "
          + summary.fileCount + " config file(s) recorded."
      ],
      material: false
    })
  }
}

var VERSION_BASELINE_MATCH = {
  id: "recovery.version-baseline-match",
  title: "Baseline comparison",
  category: "recovery",
  description: "Compares the current system against the recorded baseline.",
  requiredCapabilities: [],
  defaultSeverity: "warning",
  timeoutMs: 4000,
  material: false,
  run: function (ctx, done) {
    var store = ctx.baseline
    if (!store || !store.has()) {
      done(R.skippedResult(VERSION_BASELINE_MATCH, "No baseline to compare against."))
      return
    }

    var comparison = store.compareTo(ctx.facts ? ctx.facts() : null)
    if (!comparison.comparable || !comparison.complete) {
      done({
        status: R.STATUS.UNKNOWN,
        summary: "Baseline comparison is incomplete: " + comparison.reason + ".",
        details: comparison.changes.map(Baseline.describeChange),
        material: false
      })
      return
    }

    var lines = []
    for (var i = 0; i < comparison.changes.length; i++) {
      lines.push(Baseline.describeChange(comparison.changes[i]))
    }

    if (comparison.changes.length === 0) {
      done({
        status: R.STATUS.PASS,
        summary: "Nothing has changed since the baseline was recorded.",
        material: false
      })
      return
    }

    // Moving *forward* from the baseline is what an update is for, so a newer
    // version is reported and not warned about. Moving backward is the case
    // §17.6 actually cares about: it usually means a rollback happened, and
    // that changes what the rest of the report means.
    var baselineVersion = store.baseline && store.baseline.omarchy
      ? String(store.baseline.omarchy.version || "") : ""
    var currentVersion = ctx.facts && ctx.facts().omarchy
      ? String(ctx.facts().omarchy.version || "") : ""
    var order = OmarchyVersion.compare(currentVersion, baselineVersion)

    if (order === -1) {
      done({
        status: R.STATUS.WARN,
        summary: "This system is on an older Omarchy than the baseline ("
          + currentVersion + " vs " + baselineVersion + ").",
        details: ["That usually means a rollback. Findings below describe the state you rolled back to."]
          .concat(lines),
        material: false,
        remediation: "If the rollback was deliberate, record a new baseline so later scans compare "
          + "against where you actually are."
      })
      return
    }

    var summary = comparison.changes.length === 1
      ? "1 change since the baseline."
      : comparison.changes.length + " changes since the baseline."
    if (order === null && baselineVersion.length > 0 && currentVersion.length > 0
        && baselineVersion !== currentVersion) {
      summary += " Version ordering could not be determined."
    }

    done({
      status: R.STATUS.PASS,
      summary: summary,
      details: lines,
      material: false
    })
  }
}

var ALL = [SNAPSHOT_CAPABILITY, BASELINE_PRESENT, VERSION_BASELINE_MATCH]
