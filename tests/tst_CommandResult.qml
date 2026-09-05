import QtQuick
import QtTest
import "../core/CommandResult.js" as CommandResult

TestCase {
  name: "CommandResult"

  function test_exit_zero_requires_complete_evidence_data() {
    return [
      { tag: "stdout limit", flag: "stdoutTruncated" },
      { tag: "stderr limit", flag: "stderrTruncated" },
      { tag: "timeout", flag: "timedOut" },
      { tag: "cancelled", flag: "cancelled" },
      { tag: "start failure", flag: "startFailed" },
      { tag: "abandoned", flag: "abandoned" },
      { tag: "blocked", flag: "blocked" }
    ]
  }

  function test_exit_zero_requires_complete_evidence(data) {
    var input = { exitCode: 0, stdout: "partial", stderr: "" }
    input[data.flag] = true
    var result = CommandResult.finish(input)
    compare(result.ok, false)
    if (data.flag.indexOf("Truncated") >= 0) {
      verify(result.stderr.indexOf("capture limit") >= 0)
      verify(result.error.indexOf("incomplete") >= 0)
    }
  }

  function test_ordinary_exit_codes() {
    compare(CommandResult.finish({ exitCode: 0 }).ok, true)
    compare(CommandResult.finish({ exitCode: 1 }).ok, false)
  }
}
