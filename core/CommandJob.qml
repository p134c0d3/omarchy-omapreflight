import QtQuick
import Quickshell.Io

// A single external command execution, start to guaranteed terminal state.
//
// One job object per command run. CommandRunner creates these dynamically and
// destroys them when they finish, which is deliberate: a fresh Process and a
// fresh pair of StdioCollectors mean the captured output can only ever belong
// to this run. Reusing one Process across runs saves an allocation and buys a
// class of bug we do not want in a diagnostic tool.
//
// Everything the spec asks a command wrapper to guarantee (§13 CommandRunner,
// §23 Command Execution Safety) is enforced here:
//
//   * argv array only — there is no shell, so there is nothing to quote
//   * bounded stdout/stderr, enforced while the stream is still arriving
//   * a timeout that escalates SIGTERM -> SIGKILL -> abandon
//   * exactly one `finished` emission, no matter how the command ends
//
// Argument validity and the privilege/shell denylist are CommandRunner's job;
// by the time a CommandJob exists the argv has already been accepted.
QtObject {
  id: job

  // ---- inputs, set at creation ---------------------------------------
  property var argv: []
  property int timeoutMs: 5000

  // Measured in QString characters, not bytes. For the ASCII-ish output of
  // diagnostic commands the two are the same; where they are not, the
  // character count is the conservative one.
  property int stdoutLimit: 262144
  property int stderrLimit: 65536

  // Merged into the inherited environment (Process.clearEnvironment stays
  // false). LC_ALL=C is what keeps parsers stable across locales.
  property var environmentAdditions: ({ "LC_ALL": "C" })
  property string workingDirectory: ""

  // Emitted exactly once. See _finalize().
  signal finished(var result)

  // ---- terminal-state bookkeeping ------------------------------------
  property bool _done: false
  property bool _started: false
  property bool _sawExit: false
  property real _startedAtMs: 0
  property int _exitCode: -1
  property bool _timedOut: false
  property bool _cancelled: false
  property bool _abandoned: false
  property bool _startFailed: false
  property bool _stdoutTruncated: false
  property bool _stderrTruncated: false
  property string _stdoutText: ""
  property string _stderrText: ""

  function start() {
    if (_started || _done) return
    _started = true
    _startedAtMs = Date.now()
    _timeoutTimer.interval = Math.max(250, job.timeoutMs)
    _timeoutTimer.start()
    _process.running = true
  }

  function cancel() {
    if (_done) return
    _cancelled = true
    if (!_started) {
      _finalize()
      return
    }
    _terminate(15)
    _killTimer.start()
  }

  // ---- process -------------------------------------------------------
  property Process _process: Process {
    running: false
    command: job.argv
    workingDirectory: job.workingDirectory
    environment: job.environmentAdditions

    stdout: StdioCollector {
      // waitForEnd: false so the limit can be enforced against a runaway
      // command while it is still producing, rather than after we have already
      // buffered all of it.
      waitForEnd: false
      onDataChanged: job._absorbStdout(text)
      onStreamFinished: job._absorbStdout(text)
    }

    stderr: StdioCollector {
      waitForEnd: false
      onDataChanged: job._absorbStderr(text)
      onStreamFinished: job._absorbStderr(text)
    }

    onExited: function (exitCode) {
      job._sawExit = true
      job._exitCode = exitCode
      job._finalize()
    }

    // A command that cannot be started at all (missing binary, not executable)
    // does not necessarily reach `exited`. Running going false without an exit
    // is the reliable signal. callLater gives `exited` the chance to win the
    // race in the normal case.
    onRunningChanged: {
      if (!running) Qt.callLater(job._checkStartFailure)
    }
  }

  // ---- escalation timers ---------------------------------------------
  property Timer _timeoutTimer: Timer {
    repeat: false
    onTriggered: {
      if (job._done) return
      job._timedOut = true
      job._terminate(15)
      job._killTimer.start()
    }
  }

  property Timer _killTimer: Timer {
    interval: 1000
    repeat: false
    onTriggered: {
      if (job._done) return
      job._terminate(9)
      job._abandonTimer.start()
    }
  }

  // Last resort. A process that survives SIGKILL is not something a bar widget
  // can solve, but the scan must still reach a terminal state.
  property Timer _abandonTimer: Timer {
    interval: 1000
    repeat: false
    onTriggered: {
      if (job._done) return
      job._abandoned = true
      job._finalize()
    }
  }

  // ---- internals -----------------------------------------------------
  function _absorbStdout(text) {
    var value = String(text || "")
    if (value.length > job.stdoutLimit) {
      job._stdoutText = value.substring(0, job.stdoutLimit)
      job._stdoutTruncated = true
      job._abortForLimit()
    } else {
      job._stdoutText = value
    }
  }

  function _absorbStderr(text) {
    var value = String(text || "")
    if (value.length > job.stderrLimit) {
      job._stderrText = value.substring(0, job.stderrLimit)
      job._stderrTruncated = true
      job._abortForLimit()
    } else {
      job._stderrText = value
    }
  }

  function _abortForLimit() {
    if (_done || !_started) return
    _terminate(15)
    _killTimer.start()
  }

  function _terminate(signalNumber) {
    if (!_process.running) return
    _process.signal(signalNumber)
  }

  function _checkStartFailure() {
    if (_done || _sawExit || !_started) return
    _startFailed = true
    _finalize()
  }

  function _finalize() {
    if (_done) return
    _done = true
    _timeoutTimer.stop()
    _killTimer.stop()
    _abandonTimer.stop()
    if (_process.running) _process.running = false
    job.finished(job.result())
  }

  // The normalized shape every caller sees (spec §13). `ok` is the only
  // question most callers actually have.
  function result() {
    return {
      command: Array.isArray(argv) ? argv.slice() : [],
      exitCode: _exitCode,
      stdout: _stdoutText,
      stderr: _stderrText,
      timedOut: _timedOut,
      cancelled: _cancelled,
      abandoned: _abandoned,
      startFailed: _startFailed,
      blocked: false,
      blockedReason: "",
      stdoutTruncated: _stdoutTruncated,
      stderrTruncated: _stderrTruncated,
      durationMs: _startedAtMs > 0 ? Math.max(0, Math.round(Date.now() - _startedAtMs)) : 0,
      ok: !_timedOut && !_cancelled && !_startFailed && !_abandoned && _exitCode === 0
    }
  }
}
