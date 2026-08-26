import QtQuick
import "ExecPolicy.js" as ExecPolicy

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

  // CWE-22, via the shared policy in core/ExecPolicy.js: absolute, no `..`
  // segment, and inside one of the allowlisted roots — matched on a segment
  // boundary, so an allowlisted ".../omarchy" cannot be satisfied by
  // ".../omarchy-evil".
  //
  // Note what this does *not* do: resolve symlinks. It cannot — QML has no
  // realpath — so an attacker who can already plant a symlink inside an
  // allowlisted directory can redirect a read. That is documented as a
  // residual risk in docs/security.md rather than papered over here, and it is
  // bounded by the fact that every read is inert: the content only ever
  // becomes evidence text.
  function _refusalFor(target) {
    var refusal = ExecPolicy.pathRefusal(target, root.allowedPrefixes)
    if (refusal === "") return ""
    if (refusal === "is outside the permitted roots") return "path is outside the OmaPreflight read allowlist"
    return "path " + refusal
  }
}
