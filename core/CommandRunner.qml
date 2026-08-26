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
    if (!Array.isArray(argv) || argv.length === 0) return "empty command"

    for (var i = 0; i < argv.length; i++) {
      if (typeof argv[i] !== "string") return "argument " + i + " is not a string"
      var control = _controlCharacterAt(argv[i])
      if (control >= 0) {
        return "argument " + i + " contains a control character (0x" + control.toString(16) + ")"
      }
    }

    var binary = argv[0]
    if (binary.length === 0) return "empty program name"
    var slash = binary.lastIndexOf("/")
    var base = slash >= 0 ? binary.substring(slash + 1) : binary
    if (privilegeBinaries.indexOf(base) >= 0) return "refusing to run privileged helper '" + base + "'"
    if (shellBinaries.indexOf(base) >= 0) return "refusing to run interpreter '" + base + "'"

    // The program name itself is never allowed to come from outside, so it is
    // checked here rather than left to the data rules below.
    if (base.charAt(0) === "-") return "refusing a program name that looks like an option"

    return _validateDataArgs(argv, options || {})
  }

  // Every externally-sourced argument, checked as data.
  function _validateDataArgs(argv, options) {
    var indices = Array.isArray(options.dataArgs) ? options.dataArgs : []
    var roots = Array.isArray(options.allowedRoots) ? options.allowedRoots : []

    for (var n = 0; n < indices.length; n++) {
      var index = indices[n]
      if (typeof index !== "number" || index < 1 || index >= argv.length) {
        return "declared data argument " + index + " is out of range"
      }

      var value = argv[index]
      if (value.length === 0) return "data argument " + index + " is empty"

      // CWE-88. A dash is all it takes; no metacharacter is involved.
      if (value.charAt(0) === "-") {
        return "data argument " + index + " starts with '-' and would be read as an option"
      }

      // Path-shaped data gets the path rules (CWE-22). Relative paths are
      // refused outright: what they resolve against is the shell's working
      // directory, which is not something a check should be reasoning about.
      if (value.indexOf("/") >= 0) {
        if (value.charAt(0) !== "/") return "data argument " + index + " is a relative path"
        if (_hasTraversal(value)) return "data argument " + index + " contains a parent traversal"
        if (roots.length > 0 && !_isUnderRoot(value, roots)) {
          return "data argument " + index + " is outside the permitted roots"
        }
      }
    }
    return ""
  }

  // Returns the offending code point, or -1. Covers the NUL that would
  // truncate an argument as well as newlines and escapes, which cannot split
  // argv without a shell but do corrupt the output of whatever reads them.
  function _controlCharacterAt(value) {
    for (var i = 0; i < value.length; i++) {
      var code = value.charCodeAt(i)
      if (code < 0x20 || code === 0x7f) return code
    }
    return -1
  }

  // Segment-wise, so a directory legitimately named "..config" is not caught
  // and "/a/../../etc" is.
  function _hasTraversal(path) {
    var segments = path.split("/")
    for (var i = 0; i < segments.length; i++) {
      if (segments[i] === "..") return true
    }
    return false
  }

  // Prefix matching on a segment boundary: "/home/u/.config/omarchy/plugins"
  // must not admit "/home/u/.config/omarchy/plugins-evil".
  function _isUnderRoot(path, roots) {
    for (var i = 0; i < roots.length; i++) {
      var root = String(roots[i])
      if (root.length === 0) continue
      if (root.charAt(root.length - 1) !== "/") root = root + "/"
      if (path === root.substring(0, root.length - 1)) return true
      if (path.indexOf(root) === 0) return true
    }
    return false
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
