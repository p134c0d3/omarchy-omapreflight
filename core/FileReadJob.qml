import QtQuick
import Quickshell.Io

// One asynchronous file read, with a guaranteed terminal state.
//
// Spec §27.2 rules out blocking the UI thread on file I/O, so FileView's
// synchronous mode is never used. The timer exists because a `loaded` or
// `loadFailed` that never arrives (an unreadable special file, a path on a
// wedged mount) would otherwise strand the scan.
//
// A missing file is not an error here. Several checks treat absence as a
// perfectly good answer, so `missing` is reported separately from `error`.
QtObject {
  id: job

  property string path: ""
  property int timeoutMs: 3000

  signal finished(var result)

  property bool _done: false
  property real _startedAtMs: 0
  property string _text: ""
  property string _error: ""
  property bool _missing: false

  function start() {
    if (_done || _startedAtMs > 0) return
    _startedAtMs = Date.now()
    _timeout.interval = Math.max(250, job.timeoutMs)
    _timeout.start()
    // Path first, then preload. FileView only begins an asynchronous load when
    // preload flips true, so this ordering is what keeps the object inert until
    // start() is called — a FileView that is preloading an empty path would
    // fail immediately and settle the job before it ever had a real path.
    _view.path = job.path
    _view.preload = true
  }

  property FileView _view: FileView {
    // Errors are handled by this object and turned into results; letting
    // FileView also print them would put noise in the shell log for the
    // entirely normal case of an absent optional config file (§31).
    printErrors: false
    watchChanges: false
    preload: false

    onLoaded: {
      if (job._startedAtMs === 0) return
      job._text = String(job._view.text())
      job._finalize()
    }

    onLoadFailed: function (error) {
      if (job._startedAtMs === 0) return
      job._missing = error === FileViewError.FileNotFound
      job._error = FileViewError.toString(error)
      job._finalize()
    }
  }

  property Timer _timeout: Timer {
    repeat: false
    onTriggered: {
      if (job._done) return
      job._error = "timed out reading file"
      job._finalize()
    }
  }

  function _finalize() {
    if (_done) return
    _done = true
    _timeout.stop()
    job.finished({
      path: job.path,
      ok: job._error === "",
      missing: job._missing,
      text: job._text,
      error: job._error,
      durationMs: _startedAtMs > 0 ? Math.max(0, Math.round(Date.now() - _startedAtMs)) : 0
    })
  }
}
