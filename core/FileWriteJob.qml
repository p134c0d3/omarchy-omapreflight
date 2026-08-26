import QtQuick
import Quickshell.Io

// One asynchronous file write, with a guaranteed terminal state.
//
// Atomic (spec §14.2): the write lands in a temporary file and is renamed into
// place, so a report or a baseline is never observed half-written — including
// when the shell exits mid-write. Nothing here ever overwrites a file
// partially.
QtObject {
  id: job

  property string path: ""
  property string contents: ""
  property int timeoutMs: 5000

  signal finished(var result)

  property bool _done: false
  property real _startedAtMs: 0
  property string _error: ""

  function start() {
    if (_done || _startedAtMs > 0) return
    _startedAtMs = Date.now()
    _timeout.interval = Math.max(250, job.timeoutMs)
    _timeout.start()
    _view.path = job.path
    _view.setText(job.contents)
  }

  property FileView _view: FileView {
    printErrors: false
    watchChanges: false
    preload: false
    blockWrites: false
    atomicWrites: true

    onSaved: {
      if (job._startedAtMs === 0) return
      job._finalize()
    }

    onSaveFailed: function (error) {
      if (job._startedAtMs === 0) return
      job._error = FileViewError.toString(error)
      job._finalize()
    }
  }

  property Timer _timeout: Timer {
    repeat: false
    onTriggered: {
      if (job._done) return
      job._error = "timed out writing file"
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
      error: job._error,
      bytes: job.contents.length,
      durationMs: _startedAtMs > 0 ? Math.max(0, Math.round(Date.now() - _startedAtMs)) : 0
    })
  }
}
