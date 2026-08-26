import QtQuick
import "ResultModel.js" as R

// Runs the check catalog and turns it into results.
//
// Serial by choice (spec §13): correctness matters more than shaving seconds
// off a diagnostic run, and a serial engine makes the time ceiling, the
// progress figure, and cancellation all mean something exact.
//
// The engine guarantees four things, and the rest of the plugin is written
// assuming them:
//
//   1. Every check produces exactly one result. A check that throws, hangs,
//      returns nothing, or calls back twice still produces exactly one.
//   2. A scan always reaches a terminal state — completed or not completed —
//      and `finished` fires exactly once per scan.
//   3. Nothing overlaps. A second start() while a scan is running is refused,
//      not queued (§9.5).
//   4. An incomplete scan yields readiness UNKNOWN, never a partial verdict
//      dressed up as a full one (§16).
QtObject {
  id: root

  property var runner: null          // CommandRunner
  property var fileReader: null      // FileReader
  property var capabilities: null    // CapabilityRegistry
  property var baseline: null        // BaselineStore
  property var store: null           // PreflightStore

  // Check definitions, in execution order. Plain JS objects from checks/*.js.
  property var checks: []

  // Paths handed to every check so no check has to resolve them itself.
  property var paths: ({})

  // §23.6. The ceiling is a real ceiling: when it fires the scan stops and
  // reports itself incomplete rather than running on.
  property int scanCeilingMs: 120000
  property int defaultCheckTimeoutMs: 8000

  signal finished(bool completed, var results)
  signal progressed(int index, int total, string phase)

  property bool running: false
  property string scanId: ""
  property bool _cancelRequested: false
  property string _abortReason: ""
  property var _results: []
  // Structured facts a check chose to record, as opposed to the prose it
  // reported. Results are for people; facts are what the baseline is built
  // from and compared against, and deriving one from the other by parsing
  // summary text would be a bad idea that works right up until someone
  // improves a sentence.
  property var facts: ({})
  property var _memo: ({})
  property var _fileMemo: ({})
  property var _pending: ({})
  property int _index: 0
  property var _activeDone: null

  function start(reason) {
    if (running) return "busy"
    if (!runner || !store || !capabilities) return "not-ready"

    running = true
    _cancelRequested = false
    _abortReason = ""
    _results = []
    facts = ({})
    _memo = ({})
    _fileMemo = ({})
    _pending = ({})
    _index = 0
    scanId = "scan-" + Date.now()

    store.scanRunning = true
    store.scanId = scanId
    store.scanProgress = 0
    store.scanPhase = "Detecting capabilities"
    store.errors = []
    store.changed()

    _ceiling.interval = Math.max(10000, root.scanCeilingMs)
    _ceiling.start()

    // The baseline is re-read at the start of every scan rather than once at
    // mount. The shell is long-lived — a session lasts days — and a baseline
    // recorded, replaced, or removed in between must be the one the recovery
    // checks compare against, not whatever was on disk when the plugin loaded.
    _loadBaseline(function () {
      root._beginCapabilityPhase()
    })

    return scanId
  }

  function _loadBaseline(next) {
    if (!baseline || typeof baseline.load !== "function") {
      next()
      return
    }
    baseline.load(function () { next() })
  }

  function _beginCapabilityPhase() {
    // Capability detection is step zero of the scan, not a separate lifecycle.
    // Its cost is visible in the progress figure for the same reason.
    capabilities.refresh(_exec, function () {
      if (root._cancelRequested) {
        root._finish(false)
        return
      }
      root.store.capabilities = root.capabilities.capabilities
      root._runNext()
    })
  }

  function cancel(reason) {
    if (!running) return
    _cancelRequested = true
    _abortReason = String(reason || "Scan cancelled.")
    if (runner) runner.cancelAll()
    // If a check is mid-flight its `done` is settled here so the scan does not
    // wait on a command that has already been told to stop.
    if (_activeDone) _activeDone({ status: R.STATUS.UNKNOWN, summary: _abortReason, material: false })
  }

  // ---- execution -------------------------------------------------------

  function _runNext() {
    if (_cancelRequested) {
      _finish(false)
      return
    }
    if (_index >= checks.length) {
      _finish(true)
      return
    }

    var definition = checks[_index]
    var position = _index

    store.scanProgress = checks.length > 0 ? position / checks.length : 0
    store.scanPhase = String(definition.title || definition.id || "")
    store.changed()
    root.progressed(position, checks.length, store.scanPhase)

    if (!capabilities.satisfies(definition.requiredCapabilities || [])) {
      _record(R.skippedResult(definition,
        capabilities.missingReason(definition.requiredCapabilities || [])))
      _advance()
      return
    }

    var startedAt = new Date().toISOString()
    var startedMs = Date.now()
    var settled = false

    var done = function (fields) {
      if (settled) return
      settled = true
      root._activeDone = null
      root._watchdog.stop()

      var payload = fields || {}
      payload.startedAt = startedAt
      payload.durationMs = Date.now() - startedMs

      var result
      try {
        result = R.makeResult(definition, payload)
      } catch (e) {
        // Normalization itself failing is a bug in a check's payload. It still
        // must not take the scan down (§27.3).
        result = R.makeResult(definition, {
          status: R.STATUS.UNKNOWN,
          summary: "Result could not be normalized: " + String(e),
          startedAt: startedAt
        })
      }
      root._record(result)
      root._advance()
    }

    _activeDone = done
    _watchdog.interval = Math.max(1000, (definition.timeoutMs || defaultCheckTimeoutMs) + 2000)
    _watchdog.start()

    try {
      definition.run(_context(), done)
    } catch (e) {
      // A check that throws synchronously is contained here. The scan carries
      // on and the failure is visible as an UNKNOWN with the reason attached.
      done({
        status: R.STATUS.UNKNOWN,
        summary: "Check raised an error and could not complete.",
        details: [String(e && e.message ? e.message : e)]
      })
    }
  }

  function _advance() {
    _index++
    // Yield between checks so a long catalog cannot monopolize the event loop
    // and freeze the bar (§27.2).
    Qt.callLater(root._runNext)
  }

  function _record(result) {
    var next = _results.slice()
    next.push(result)
    _results = next
    store.results = next
    store.changed()
  }

  function _finish(completed) {
    if (!running) return
    running = false
    _activeDone = null
    _watchdog.stop()
    _ceiling.stop()

    store.results = _results
    store.environment = root.facts
    store.categories = R.groupByCategory(_results)
    store.readiness = R.aggregateReadiness(_results, completed)
    store.scanRunning = false
    store.scanProgress = 1
    store.scanPhase = ""
    store.lastScanAt = new Date().toISOString()
    if (completed) store.lastCompletedScanId = scanId
    if (!completed && _abortReason !== "") {
      var errors = store.errors.slice()
      errors.push(_abortReason)
      store.errors = errors
    }
    store.changed()

    root.finished(completed, _results)
  }

  // ---- the context handed to each check --------------------------------

  function _context() {
    return {
      exec: root._exec,
      readFile: root._readFile,
      capabilities: root.capabilities,
      baseline: root.baseline,
      paths: root.paths,
      scanId: root.scanId,
      fact: root._recordFact,
      facts: function () { return root.facts },
      now: function () { return new Date().toISOString() }
    }
  }

  // Record a structured fact under a dotted path: fact("omarchy.version", "4.0.1-1").
  // Intermediate objects are created as needed, so a check never has to know
  // whether it is the first to write into a branch.
  function _recordFact(path, value) {
    var segments = String(path).split(".")
    var node = root.facts
    for (var i = 0; i < segments.length - 1; i++) {
      if (!node[segments[i]] || typeof node[segments[i]] !== "object") node[segments[i]] = {}
      node = node[segments[i]]
    }
    node[segments[segments.length - 1]] = value
  }

  // Memoized so two checks citing the same command pay for it once, and so
  // capability probes and checks share their evidence rather than duplicating
  // process launches. `opts.fresh` opts out.
  function _exec(argv, opts, callback) {
    var options = opts || {}
    var key = JSON.stringify(argv)

    if (options.fresh !== true && root._memo[key] !== undefined) {
      var cached = root._memo[key]
      Qt.callLater(function () { callback(cached) })
      return
    }

    if (root._pending[key] !== undefined) {
      root._pending[key].push(callback)
      return
    }

    root._pending[key] = [callback]
    root.runner.run(argv, options, function (result) {
      root._memo[key] = result
      var waiting = root._pending[key] || []
      delete root._pending[key]
      for (var i = 0; i < waiting.length; i++) waiting[i](result)
    })
  }

  // Memoized for the same reason as _exec: two checks frequently need two
  // different facts out of one file, and reading it twice would be both slower
  // and capable of disagreeing with itself.
  function _readFile(path, callback) {
    if (!root.fileReader) {
      Qt.callLater(function () {
        callback({ path: path, ok: false, missing: false, text: "", error: "no file reader", refused: true, durationMs: 0 })
      })
      return
    }

    var key = String(path)
    if (root._fileMemo[key] !== undefined) {
      var cached = root._fileMemo[key]
      Qt.callLater(function () { callback(cached) })
      return
    }

    root.fileReader.read(path, function (result) {
      root._fileMemo[key] = result
      callback(result)
    })
  }

  // ---- watchdogs -------------------------------------------------------

  // Per-check. Bounds a check that never calls back at all — the failure mode
  // a per-command timeout cannot cover.
  property Timer _watchdog: Timer {
    repeat: false
    onTriggered: {
      if (!root.running || !root._activeDone) return
      // Whatever this check started is no longer wanted, and leaving it
      // running would push its cost onto the next check's budget.
      if (root.runner) root.runner.cancelAll()
      root._activeDone({
        status: R.STATUS.UNKNOWN,
        summary: "Check exceeded its time budget and was stopped."
      })
    }
  }

  // Whole scan. Fires once; the scan is then incomplete by definition.
  property Timer _ceiling: Timer {
    repeat: false
    onTriggered: {
      if (!root.running) return
      root.cancel("Scan exceeded its " + Math.round(root.scanCeilingMs / 1000) + "s ceiling and was stopped.")
    }
  }
}
