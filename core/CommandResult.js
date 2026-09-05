.pragma library

// Exit zero is insufficient when the command's evidence is incomplete.
function finish(result) {
  result.ok = result.exitCode === 0 && !result.timedOut && !result.cancelled
    && !result.startFailed && !result.abandoned && !result.blocked
    && !result.stdoutTruncated && !result.stderrTruncated
  if (result.stdoutTruncated || result.stderrTruncated) {
    var reason = "Command output exceeded its capture limit; evidence is incomplete."
    result.error = reason
    result.stderr = reason + (result.stderr ? "\n" + result.stderr : "")
  }
  return result
}
