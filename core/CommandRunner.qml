import QtQuick
import "ExecPolicy.js" as ExecPolicy

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
//
// ---------------------------------------------------------------------------
// Untrusted arguments
//
// There is no shell here, so classic OS command injection (CWE-78) is
// structurally impossible: argv is an array and the kernel never re-parses it.
// The live risk is the quieter one — *argument* injection (CWE-88). A value
// that OmaPreflight did not author (a plugin id from `omarchy plugin list`, a
// directory name on disk) becomes an option rather than data the moment it
// starts with a dash. `--upload-pack=…` as a "repository path" is the textbook
// case, and it needs no metacharacters at all.
//
// So any argv element sourced from outside this plugin must be declared:
//
//     run(["git", "-C", dir, "status", "--porcelain=v1"],
//         { dataArgs: [2], allowedRoots: [pluginsDir] }, cb)
//
// Declared data arguments are validated as data: no leading dash, no control
// characters, and — when they look like paths — absolute, traversal-free, and
// inside an explicit root. Callers should also place `--` ahead of positional
// data where the target program honours it; the leading-dash rule is what
// covers the programs that do not.
//
// The rule is deliberately opt-in-by-declaration rather than inferred. A
// reviewer can grep for `dataArgs` and see every place external input reaches
// a process, which is not true of any scheme that tries to guess.
QtObject {
  id: root

  property int defaultTimeoutMs: 5000
  property int stdoutLimit: 262144
  property int stderrLimit: 65536

  readonly property bool busy: _current !== null
  property int queuedCount: 0

  // The privilege and interpreter denylists, the argument rules and the path
  // rules all live in core/ExecPolicy.js as pure functions, so they can be
  // unit-tested directly and so FileReader and FileWriter share exactly the
  // same path logic rather than each carrying a copy.
  readonly property var privilegeBinaries: ExecPolicy.PRIVILEGE_BINARIES
  readonly property var shellBinaries: ExecPolicy.SHELL_BINARIES

  property var _queue: []
  property var _current: null
  property int _nextId: 1

  property Component _jobComponent: Component { CommandJob {} }

  // Queue a command. Returns an id for logging; the result arrives on the
  // callback. `options`: { timeoutMs, env, cwd, stdoutLimit, stderrLimit }.
  function run(argv, options, callback) {
    var opts = options || {}
    var id = "cmd-" + (_nextId++)

    var refusal = validate(argv, opts)
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

  // "" means acceptable. Anything else is the human-readable reason, which is
  // surfaced to the user as the check's result rather than swallowed.
  function validate(argv, options) {
    return ExecPolicy.validateArgv(argv, options || {})
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
