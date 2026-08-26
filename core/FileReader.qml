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

  // CWE-22. Three rules, in order of how much they matter:
  //
  //   absolute      — a relative path resolves against a working directory
  //                   this object has no opinion about;
  //   no traversal  — checked segment-wise, so a directory legitimately named
  //                   "..config" passes and "/a/../../etc/shadow" does not;
  //   inside a root — prefix matched on a segment boundary, so an allowlisted
  //                   ".../omarchy/plugins" cannot be satisfied by
  //                   ".../omarchy/plugins-evil".
  //
  // Note what this does *not* do: resolve symlinks. It cannot — there is no
  // realpath available to QML — so an attacker who can already plant a symlink
  // inside an allowlisted directory can redirect a read. That is documented as
  // a residual risk in docs/security.md rather than papered over here, and it
  // is bounded by the fact that every read is inert: the content only ever
  // becomes evidence text.
  function _refusalFor(target) {
    if (target.length === 0) return "empty path"
    if (target.indexOf("/") !== 0) return "path is not absolute"
    if (_hasTraversal(target)) return "path contains a parent traversal"
    if (allowedPrefixes.length === 0) return ""
    if (_isUnderRoot(target, allowedPrefixes)) return ""
    return "path is outside the OmaPreflight read allowlist"
  }

  function _hasTraversal(path) {
    var segments = path.split("/")
    for (var i = 0; i < segments.length; i++) {
      if (segments[i] === "..") return true
    }
    return false
  }

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
}
