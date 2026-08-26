import QtQuick

// The only place in OmaPreflight that starts an external process.
//
// Two responsibilities:
//
//   1. Refuse anything that violates the execution-safety rules (spec §23,
//      §33) before a process exists. A refusal is a normal result with
//      `blocked: true` — callers turn it into UNKNOWN/SKIPPED, they never see
//      an exception.
//
//   2. Serialize execution. Exactly one command runs at a time, which is what
//      makes the scan's time ceiling meaningful and keeps a diagnostic tool
//      from being the reason the machine is busy. CheckEngine is serial for
//      the same reason (spec §13: correctness over shaving two seconds).
//
// Callbacks receive the CommandJob result shape, always, exactly once.
QtObject {
  id: root

  property int defaultTimeoutMs: 5000
  property int stdoutLimit: 262144
  property int stderrLimit: 65536

  readonly property bool busy: _current !== null
  property int queuedCount: 0

  // Binaries that exist to raise privilege. OmaPreflight is read-only and
  // unprivileged by design; a check that needs root returns SKIPPED and
  // documents the manual command instead (spec §23.4).
  readonly property var privilegeBinaries: [
    "sudo", "sudoedit", "pkexec", "doas", "su", "run0", "machinectl"   // privilege-escalation denylist
  ]

  // Shell interpreters are refused outright rather than audited. No check in
  // the catalog needs shell syntax, so allowing one would only create a place
  // for a future interpolation bug to live (spec §23.1, §23.2).
  readonly property var shellBinaries: [
    "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "busybox", "env", "eval"
  ]

  property var _queue: []
  property var _current: null
  property int _nextId: 1

  property Component _jobComponent: Component { CommandJob {} }

  // Queue a command. Returns an id for logging; the result arrives on the
  // callback. `options`: { timeoutMs, env, cwd, stdoutLimit, stderrLimit }.
  function run(argv, options, callback) {
    var opts = options || {}
    var id = "cmd-" + (_nextId++)

    var refusal = validate(argv)
    if (refusal !== "") {
      var blockedResult = _blockedResult(argv, refusal)
      Qt.callLater(function () {
        if (callback) callback(blockedResult)
      })
      return id
    }

    _queue.push({ id: id, argv: argv.slice(), opts: opts, callback: callback })
    queuedCount = _queue.length
    _pump()
    return id
  }

  // Drop everything not yet started and terminate what is running. Every
  // pending callback still fires, with `cancelled: true`, so no check can be
  // left waiting forever.
  function cancelAll() {
    var pending = _queue
    _queue = []
    queuedCount = 0
    for (var i = 0; i < pending.length; i++) {
      _deliverCancelled(pending[i])
    }
    if (_current !== null && _current.job) _current.job.cancel()
  }

  // "" means acceptable. Anything else is the human-readable reason.
  function validate(argv) {
    if (!Array.isArray(argv) || argv.length === 0) return "empty command"
    for (var i = 0; i < argv.length; i++) {
      if (typeof argv[i] !== "string") return "argument " + i + " is not a string"
      for (var c = 0; c < argv[i].length; c++) {
        if (argv[i].charCodeAt(c) === 0) return "argument " + i + " contains a NUL byte"
      }
    }
    var binary = argv[0]
    if (binary.length === 0) return "empty program name"
    var slash = binary.lastIndexOf("/")
    var base = slash >= 0 ? binary.substring(slash + 1) : binary
    if (privilegeBinaries.indexOf(base) >= 0) return "refusing to run privileged helper '" + base + "'"
    if (shellBinaries.indexOf(base) >= 0) return "refusing to run interpreter '" + base + "'"
    return ""
  }

  // ---- internals -----------------------------------------------------
  function _pump() {
    if (_current !== null) return
    if (_queue.length === 0) {
      queuedCount = 0
      return
    }

    var entry = _queue.shift()
    queuedCount = _queue.length

    var env = { "LC_ALL": "C" }
    if (entry.opts.env) {
      for (var key in entry.opts.env) env[key] = String(entry.opts.env[key])
    }

    var job = _jobComponent.createObject(root, {
      argv: entry.argv,
      timeoutMs: entry.opts.timeoutMs || root.defaultTimeoutMs,
      stdoutLimit: entry.opts.stdoutLimit || root.stdoutLimit,
      stderrLimit: entry.opts.stderrLimit || root.stderrLimit,
      environmentAdditions: env,
      workingDirectory: entry.opts.cwd || ""
    })

    if (job === null) {
      // Creation failure is a bug, not a runtime condition, but it must not
      // strand the queue.
      var failure = _blockedResult(entry.argv, "could not create command job")
      if (entry.callback) entry.callback(failure)
      Qt.callLater(root._pump)
      return
    }

    _current = { entry: entry, job: job }
    job.finished.connect(function (result) {
      root._onJobFinished(entry, job, result)
    })
    job.start()
  }

  function _onJobFinished(entry, job, result) {
    if (_current === null || _current.job !== job) return
    _current = null
    job.destroy()
    if (entry.callback) entry.callback(result)
    Qt.callLater(root._pump)
  }

  function _deliverCancelled(entry) {
    if (!entry.callback) return
    var result = _blockedResult(entry.argv, "")
    result.cancelled = true
    entry.callback(result)
  }

  function _blockedResult(argv, reason) {
    return {
      command: Array.isArray(argv) ? argv.slice() : [],
      exitCode: -1,
      stdout: "",
      stderr: "",
      timedOut: false,
      cancelled: false,
      abandoned: false,
      startFailed: false,
      blocked: reason !== "",
      blockedReason: reason,
      stdoutTruncated: false,
      stderrTruncated: false,
      durationMs: 0,
      ok: false
    }
  }
}
