import QtQuick
import QtTest
import "../core/ResultModel.js" as R

// Fixture tests for the readiness aggregator and the result vocabulary.
//
// Spec §16 requires this logic to be pure and fixture-tested, and the reason is
// the whole product: readiness is the one number-shaped thing OmaPreflight
// says, and it must never be wrong in the reassuring direction. A bug that
// turns a blocker into READY is worse than a crash.
TestCase {
  name: "ResultModel"

  function result(id, status, severity, material) {
    return R.makeResult(
      { id: id, title: id, category: "test" },
      { status: status, severity: severity, material: material })
  }

  // ---- construction ---------------------------------------------------

  function test_makeResult_fills_defaults() {
    var r = R.makeResult({ id: "a.b", title: "A", category: "omarchy" }, { status: "pass" })
    compare(r.id, "a.b")
    compare(r.title, "A")
    compare(r.category, "omarchy")
    compare(r.status, "pass")
    compare(r.severity, "info")
    compare(r.details.length, 0)
    compare(r.evidence.length, 0)
    compare(r.remediation, null)
    verify(r.fingerprint.length === 8)
  }

  function test_unrecognized_status_becomes_unknown() {
    // A check returning nonsense must not be able to invent a passing state.
    var r = R.makeResult({ id: "a" }, { status: "probably fine" })
    compare(r.status, "unknown")
  }

  function test_missing_status_becomes_unknown() {
    compare(R.makeResult({ id: "a" }, {}).status, "unknown")
    compare(R.makeResult({ id: "a" }, { status: null }).status, "unknown")
  }

  function test_severity_defaults_follow_status() {
    compare(R.makeResult({ id: "a" }, { status: "pass" }).severity, "info")
    compare(R.makeResult({ id: "a" }, { status: "warn" }).severity, "warning")
    compare(R.makeResult({ id: "a" }, { status: "fail" }).severity, "error")
    compare(R.makeResult({ id: "a", defaultSeverity: "blocker" },
                         { status: "fail" }).severity, "blocker")
    // The default only applies to FAIL: a passing check is never a blocker.
    compare(R.makeResult({ id: "a", defaultSeverity: "blocker" },
                         { status: "pass" }).severity, "info")
  }

  function test_fingerprint_is_stable_and_discriminating() {
    var a = R.makeResult({ id: "x" }, { status: "fail", summary: "disk full" })
    var b = R.makeResult({ id: "x" }, { status: "fail", summary: "disk full" })
    var c = R.makeResult({ id: "x" }, { status: "fail", summary: "disk nearly full" })
    compare(a.fingerprint, b.fingerprint)
    verify(a.fingerprint !== c.fingerprint)
  }

  // ---- readiness aggregation (§16) ------------------------------------

  function test_incomplete_scan_is_unknown_whatever_it_found() {
    var clean = [result("a", "pass")]
    compare(R.aggregateReadiness(clean, false), "unknown")
    // Even a scan that only found blockers is UNKNOWN if it did not finish:
    // an incomplete scan has not earned a verdict in either direction.
    compare(R.aggregateReadiness([result("a", "fail", "blocker")], false), "unknown")
  }

  function test_empty_completed_scan_is_unknown() {
    compare(R.aggregateReadiness([], true), "unknown")
  }

  function test_all_pass_is_ready() {
    compare(R.aggregateReadiness([result("a", "pass"), result("b", "pass")], true), "ready")
  }

  function test_failing_blocker_is_not_recommended() {
    var results = [result("a", "pass"), result("b", "fail", "blocker")]
    compare(R.aggregateReadiness(results, true), "not_recommended")
  }

  function test_blocker_severity_without_failure_does_not_block() {
    // Severity describes how bad the finding would be; status describes whether
    // it happened. Only the pair means "do not update".
    var results = [result("a", "pass"), result("b", "warn", "blocker")]
    compare(R.aggregateReadiness(results, true), "review")
  }

  function test_warning_is_review() {
    compare(R.aggregateReadiness([result("a", "pass"), result("b", "warn")], true), "review")
  }

  function test_non_blocking_failure_is_review() {
    compare(R.aggregateReadiness([result("a", "fail", "error")], true), "review")
  }

  function test_material_unknown_is_review() {
    compare(R.aggregateReadiness([result("a", "pass"), result("b", "unknown", "info", true)], true),
            "review")
  }

  function test_immaterial_unknown_does_not_disturb_ready() {
    // "We could not read the Quickshell version" is not a reason to hesitate
    // before updating.
    compare(R.aggregateReadiness([result("a", "pass"), result("b", "unknown", "info", false)], true),
            "ready")
  }

  function test_skipped_never_causes_review() {
    compare(R.aggregateReadiness([result("a", "pass"), result("b", "skipped")], true), "ready")
  }

  function test_blocker_outranks_everything_else() {
    var results = [result("a", "warn"), result("b", "unknown", "info", true),
                   result("c", "fail", "blocker"), result("d", "pass")]
    compare(R.aggregateReadiness(results, true), "not_recommended")
  }

  function test_null_entries_are_survivable() {
    // Defensive: a null in the list must not throw inside the one function the
    // whole verdict depends on.
    compare(R.aggregateReadiness([null, result("a", "pass")], true), "ready")
  }

  // ---- counting and grouping ------------------------------------------

  function test_countByStatus() {
    var counts = R.countByStatus([
      result("a", "pass"), result("b", "pass"), result("c", "warn"),
      result("d", "fail"), result("e", "unknown"), result("f", "skipped")])
    compare(counts.pass, 2)
    compare(counts.warn, 1)
    compare(counts.fail, 1)
    compare(counts.unknown, 1)
    compare(counts.skipped, 1)
  }

  function test_countBlockers_requires_both_fail_and_blocker() {
    compare(R.countBlockers([result("a", "fail", "blocker"),
                             result("b", "warn", "blocker"),
                             result("c", "fail", "error")]), 1)
  }

  function test_groupByCategory() {
    var groups = R.groupByCategory([
      R.makeResult({ id: "a", category: "omarchy" }, { status: "pass" }),
      R.makeResult({ id: "b", category: "omarchy" }, { status: "warn" }),
      R.makeResult({ id: "c", category: "hyprland" }, { status: "fail" })])
    compare(groups["omarchy"].results.length, 2)
    compare(groups["omarchy"].counts.pass, 1)
    compare(groups["omarchy"].counts.warn, 1)
    compare(groups["hyprland"].counts.fail, 1)
  }

  function test_sortForDisplay_puts_the_worst_first() {
    var sorted = R.sortForDisplay([
      result("a", "pass"), result("b", "skipped"), result("c", "fail"),
      result("d", "unknown"), result("e", "warn")])
    compare(sorted[0].status, "fail")
    compare(sorted[1].status, "warn")
    compare(sorted[2].status, "unknown")
    compare(sorted[3].status, "pass")
    compare(sorted[4].status, "skipped")
  }

  function test_sortForDisplay_does_not_mutate_its_input() {
    var input = [result("a", "pass"), result("b", "fail")]
    R.sortForDisplay(input)
    compare(input[0].status, "pass")
  }

  // ---- helpers ---------------------------------------------------------

  function test_skippedResult_is_never_material() {
    var r = R.skippedResult({ id: "a", material: true }, "no capability")
    compare(r.status, "skipped")
    compare(r.material, false)
    compare(r.summary, "no capability")
  }

  function test_labels_are_upper_case_at_the_edges() {
    compare(R.statusLabel("pass"), "PASS")
    compare(R.readinessLabel("not_recommended"), "NOT RECOMMENDED")
    compare(R.readinessLabel("neutral"), "NO SCAN YET")
  }
}
