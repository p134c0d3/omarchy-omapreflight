.pragma library
.import "../core/ResultModel.js" as R
.import "../parsers/Json.js" as Json
.import "../parsers/SystemctlFailed.js" as SystemctlFailed
.import "../parsers/DiskUsage.js" as DiskUsage

// Spec §17.5 — Runtime.
//
// Services and storage: two things that are frequently already broken before
// an update and get blamed on it afterwards.

var FAILED_USER_UNITS = {
  id: "runtime.failed-user-units",
  title: "Failed user services",
  category: "runtime",
  description: "Lists systemd user units currently in a failed state.",
  requiredCapabilities: ["systemd.user"],
  defaultSeverity: "warning",
  timeoutMs: 6000,
  run: function (ctx, done) {
    // Non-interactive by construction: `--no-pager` is what keeps systemctl
    // from waiting on a pager that has no terminal (§23.3).
    ctx.exec(["systemctl", "--user", "--failed", "--no-legend", "--no-pager"],
      { timeoutMs: 6000 }, function (result) {
        if (!result.ok) {
          done({
            status: R.STATUS.UNKNOWN,
            summary: "Could not ask systemd about failed user services.",
            details: result.stderr ? [Json.clip(result.stderr, 5)] : [],
            evidence: [R.evidence("command", "systemctl --user --failed", "exit " + result.exitCode)]
          })
          return
        }

        var parsed = SystemctlFailed.parse(result.stdout)
        if (parsed.count === 0) {
          done({
            status: R.STATUS.PASS,
            summary: "No user services are in a failed state.",
            evidence: [R.evidence("command", "systemctl --user --failed", "")]
          })
          return
        }

        // A warning, not a blocker (§17.5). A failed user unit is worth seeing
        // before an update precisely so it is not mistaken for a consequence
        // of one, but it rarely means "do not update".
        done({
          status: R.STATUS.WARN,
          summary: parsed.count === 1
            ? "1 user service is in a failed state."
            : parsed.count + " user services are in a failed state.",
          details: SystemctlFailed.unitNames(parsed),
          evidence: [R.evidence("command", "systemctl --user --failed",
            Json.clip(result.stdout, 12))],
          remediation: "Check it with `systemctl --user status <unit>` — knowing it was "
            + "already failing saves blaming the update for it later."
        })
      })
  }
}

// Root and home are separate checks because they are frequently separate
// filesystems, and because they fill for different reasons: root fills with
// packages, home fills with everything else.
//
// Both are literal definitions that delegate to one shared runner. A factory
// returning built objects would be tidier to write and would hide the ids from
// `scripts/check`, which compares the declared ids against
// docs/check-catalog.md — and a catalog that silently stops covering a check is
// exactly the drift that guard exists to catch.
var DISK_ROOT = {
  id: "runtime.disk-space-root",
  title: "Free space on /",
  category: "runtime",
  description: "Checks free space on the root filesystem, where packages land.",
  requiredCapabilities: [],
  defaultSeverity: "error",
  timeoutMs: 5000,
  run: function (ctx, done) { _checkFreeSpace(ctx, done, DISK_ROOT, "/") }
}

var DISK_HOME = {
  id: "runtime.disk-space-home",
  title: "Free space on home",
  category: "runtime",
  description: "Checks free space on the filesystem holding your home "
    + "directory, where reports and baselines land.",
  requiredCapabilities: [],
  defaultSeverity: "error",
  timeoutMs: 5000,
  run: function (ctx, done) { _checkFreeSpace(ctx, done, DISK_HOME, String(ctx.paths.home || "")) }
}

function _checkFreeSpace(ctx, done, definition, target) {
  if (target.length === 0) {
    done(R.skippedResult(definition, "No home directory is known."))
    return
  }

  // -P is the POSIX single-line-per-filesystem format and -k fixes the block
  // size, so nothing has to parse a human-readable suffix.
  ctx.exec(["df", "-Pk", "--", target],
    { timeoutMs: 5000, dataArgs: [3] }, function (result) {
      if (result.blocked) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Refused to check free space: " + result.blockedReason + "."
        })
        return
      }
      if (!result.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not read free space for " + target + ".",
          evidence: [R.evidence("command", "df -Pk " + target, "exit " + result.exitCode)]
        })
        return
      }

      var usage = DiskUsage.parse(result.stdout)
      if (!usage.ok) {
        done({
          status: R.STATUS.UNKNOWN,
          summary: "Could not interpret df output: " + usage.error + ".",
          evidence: [R.evidence("command", "df -Pk " + target, Json.clip(result.stdout, 4))]
        })
        return
      }

      var free = DiskUsage.formatGiB(usage.availableGiB)
      var assessment = DiskUsage.assess(usage)
      var evidence = [R.evidence("command", "df -Pk " + target,
        usage.mountedOn + " — " + free + " free of "
        + DiskUsage.formatGiB(usage.totalKiB / 1048576))]

      // The thresholds are conservative and documented, and they are not a
      // prediction of how much an update needs — nothing here can know that,
      // and claiming to would be the kind of invented heuristic §18 rules out.
      if (assessment.level === "critical") {
        done({
          status: R.STATUS.FAIL,
          // A blocker: an update that runs out of space part-way through is the
          // single most reliable way to end up with a broken system.
          severity: R.SEVERITY.BLOCKER,
          summary: "Only " + free + " free on " + usage.mountedOn + ".",
          details: ["Below the " + assessment.threshold + " GiB floor OmaPreflight treats as unsafe. "
            + "This is a conservative fixed threshold, not an estimate of what an update needs."],
          evidence: evidence,
          remediation: "Free some space before updating — `omarchy update pkg prune` and "
            + "`omarchy update orphan pkgs` are the usual first moves."
        })
        return
      }

      if (assessment.level === "low") {
        done({
          status: R.STATUS.WARN,
          summary: free + " free on " + usage.mountedOn + ".",
          details: ["Under " + assessment.threshold + " GiB. Probably fine, worth knowing."],
          evidence: evidence
        })
        return
      }

      done({
        status: R.STATUS.PASS,
        summary: free + " free on " + usage.mountedOn + " (" + usage.usedPercent + "% used).",
        evidence: evidence
      })
    })
}

var ALL = [FAILED_USER_UNITS, DISK_ROOT, DISK_HOME]
