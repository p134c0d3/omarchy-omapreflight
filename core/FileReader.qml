import QtQuick

// The only place in OmaPreflight that reads a file.
//
// Narrow by design (spec §24, §33.6): reads are single named paths, never a
// directory walk and never anything under $HOME that is not an Omarchy
// configuration file the catalog names explicitly. There is no recursive mode
// and there should never be one.
QtObject {
  id: root

  property int defaultTimeoutMs: 3000
  property Component _jobComponent: Component { FileReadJob {} }

  // Paths OmaPreflight will read. A check asks for a path; if it is not
  // covered by this allowlist the read is refused and the check gets an
  // explicit reason rather than data. Keeping the policy here means a new
  // check cannot quietly widen it.
  property var allowedPrefixes: []

  function read(path, callback) {
    var target = String(path || "")

    var refusal = _refusalFor(target)
    if (refusal !== "") {
      Qt.callLater(function () {
        if (callback) callback({
          path: target, ok: false, missing: false, text: "",
          error: refusal, refused: true, durationMs: 0
        })
      })
      return
    }

    var job = _jobComponent.createObject(root, { path: target, timeoutMs: root.defaultTimeoutMs })
    if (job === null) {
      Qt.callLater(function () {
        if (callback) callback({
          path: target, ok: false, missing: false, text: "",
          error: "could not create file read job", refused: false, durationMs: 0
        })
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

  function _refusalFor(target) {
    if (target.length === 0) return "empty path"
    if (target.indexOf("/") !== 0) return "path is not absolute"
    if (target.indexOf("/..") >= 0) return "path contains a parent traversal"
    if (allowedPrefixes.length === 0) return ""

    for (var i = 0; i < allowedPrefixes.length; i++) {
      if (target.indexOf(String(allowedPrefixes[i])) === 0) return ""
    }
    return "path is outside the OmaPreflight read allowlist"
  }
}
