import QtQuick
import QtTest
import "../checks/PluginChecks.js" as Plugins
import "../checks/RecoveryChecks.js" as Recovery
import "../core/Baseline.js" as Baseline

TestCase {
  name: "CheckCoverage"

  function validate(names, outcome, note) {
    var result = null
    Plugins._validateAll({ exec: function (argv, opts, done) { done(outcome) } },
      function (r) { result = r }, "/plugins", { plugins: [] }, {}, names, note || "")
    return result
  }

  function test_validation_coverage_data() {
    var many = []
    for (var i = 0; i <= Plugins.MAX_PLUGINS; i++) many.push("test." + i)
    return [
      { tag: "empty directory", names: [], outcome: { ok: true }, expected: "pass" },
      { tag: "valid", names: ["test.plugin"], outcome: { ok: true }, expected: "pass" },
      { tag: "unreadable listing", names: null, outcome: { ok: true }, expected: "unknown" },
      { tag: "capped", names: many, outcome: { ok: true }, expected: "unknown" },
      { tag: "unsafe name", names: ["bad name"], outcome: { ok: true }, expected: "unknown" },
      { tag: "refused", names: ["test.plugin"], outcome: { blocked: true }, expected: "unknown" },
      { tag: "timeout", names: ["test.plugin"], outcome: { timedOut: true }, expected: "unknown" },
      { tag: "missing executable", names: ["test.plugin"], outcome: { startFailed: true }, expected: "unknown" },
      { tag: "truncated", names: ["test.plugin"], outcome: { stdoutTruncated: true }, expected: "unknown" },
      { tag: "invalid", names: ["test.plugin"], outcome: { ok: false, exitCode: 1, stderr: "invalid manifest" }, expected: "fail" }
    ]
  }

  function test_validation_coverage(data) {
    compare(validate(data.names, data.outcome).status, data.expected)
  }

  function test_failure_is_preserved_when_listing_is_incomplete() {
    var result = null
    Plugins._validateAll({ exec: function (argv, opts, done) { done({ ok: false, exitCode: 1 }) } },
      function (r) { result = r }, "/plugins", { plugins: [{ id: "test.plugin", firstParty: false }] },
      { "test.plugin": true }, null, "Could not list plugin directory")
    compare(result.status, "fail")
    verify(result.details.indexOf("Could not list plugin directory") >= 0)
  }

  function test_partial_baseline_check_retains_observed_changes() {
    var baseline = Baseline.build({ omarchy: { version: "4.0.1" } }, "0.1.1", "now")
    var result = null
    Recovery.VERSION_BASELINE_MATCH.run({
      baseline: {
        has: function () { return true },
        compareTo: function (facts) { return Baseline.compare(baseline, facts) }
      },
      facts: function () { return { omarchy: { version: "4.0.2" } } }
    }, function (r) { result = r })
    compare(result.status, "unknown")
    compare(result.details.length, 1)
    verify(result.details[0].indexOf("4.0.2") >= 0)
  }
}
