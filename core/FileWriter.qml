import QtQuick
import "ExecPolicy.js" as ExecPolicy

// The only place in OmaPreflight that writes a file.
//
// The allowlist here is one directory: `${XDG_STATE_HOME:-~/.local/state}/omapreflight/`.
// Not the plugin checkout, not the Omarchy configuration, not anywhere the
// user's own settings live. OmaPreflight reads configuration and never edits
// it (spec §3.3, §33), and the narrowest possible write surface is what makes
// that claim checkable rather than aspirational.
QtObject {
  id: root

  property string stateDir: ""         // the single writable directory
  property int defaultTimeoutMs: 5000
  property Component _jobComponent: Component { FileWriteJob {} }

  function write(path, contents, callback) {
    var target = String(path || "")

    var refusal = _refusalFor(target)
    if (refusal !== "") {
      Qt.callLater(function () {
        if (callback) callback({ path: target, ok: false, error: refusal, refused: true, bytes: 0, durationMs: 0 })
      })
      return
    }

    var job = _jobComponent.createObject(root, {
      path: target,
      contents: String(contents === undefined || contents === null ? "" : contents),
      timeoutMs: root.defaultTimeoutMs
    })

    if (job === null) {
      Qt.callLater(function () {
        if (callback) callback({ path: target, ok: false, error: "could not create file write job", refused: false, bytes: 0, durationMs: 0 })
      })
      return
    }

    job.finished.connect(function (result) {
      job.destroy()
      result.refused = false
      if (callback) callback(result)
    })
    job.start()
  }

  // Same shared path rules as FileReader, with exactly one permitted root.
  function _refusalFor(target) {
    if (stateDir.length === 0) return "no writable directory is configured"
    var refusal = ExecPolicy.pathRefusal(target, [root.stateDir])
    if (refusal === "") return ""
    if (refusal === "is outside the permitted roots") return "path is outside the OmaPreflight state directory"
    return "path " + refusal
  }
}
