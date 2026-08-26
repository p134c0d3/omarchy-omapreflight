import QtQuick
import "ResultModel.js" as R
import "Baseline.js" as Baseline

// Reads and writes the baseline — a record of a state this machine was
// observed in, so a later scan can say what changed.
//
// Metadata only (spec §19). Versions, fingerprints, hashes, sizes and mtimes.
// **Never file contents.** A baseline that carried the user's configuration
// would be a backup, and a backup is a different product with different
// promises about where it lives and who can read it. The v0.1 baseline is
// something you could paste into an issue after a glance.
//
// Writes are atomic and then verified: the file is written, read back, and
// parsed before it is treated as current. A baseline is the thing you reach
// for when something has already gone wrong, so "it wrote successfully" is not
// a good enough standard for it (§14.2).
QtObject {
  id: root

  property var fileReader: null
  property var fileWriter: null
  property string path: ""
  property string pluginVersion: ""

  // The loaded baseline, or null. `loaded` distinguishes "no baseline" from
  // "not looked yet", which the recovery checks genuinely need to tell apart.
  property var baseline: null
  property bool loaded: false
  property string lastError: ""

  signal changed()

  function load(callback) {
    if (!fileReader || path.length === 0) {
      lastError = "no baseline path"
      loaded = true
      if (callback) callback(null)
      return
    }

    fileReader.read(path, function (file) {
      root.loaded = true
      if (file.missing) {
        root.baseline = null
        root.lastError = ""
        root.changed()
        if (callback) callback(null)
        return
      }
      if (!file.ok) {
        root.baseline = null
        root.lastError = file.error
        root.changed()
        if (callback) callback(null)
        return
      }

      var parsed = Baseline.parse(file.text)
      root.baseline = parsed.ok ? parsed.baseline : null
      root.lastError = parsed.ok ? "" : parsed.error
      root.changed()
      if (callback) callback(root.baseline)
    })
  }

  // Build a baseline from the facts of the scan that just finished, write it,
  // and only then treat it as current.
  function save(facts, callback) {
    if (!fileWriter || path.length === 0) {
      if (callback) callback({ ok: false, error: "no baseline path" })
      return
    }

    var candidate = Baseline.build(facts, root.pluginVersion, new Date().toISOString())
    var text = JSON.stringify(candidate, null, 2)

    fileWriter.write(path, text, function (result) {
      if (!result.ok) {
        root.lastError = result.error
        if (callback) callback({ ok: false, error: result.error })
        return
      }

      // Write-then-verify. The write reported success; this asks the
      // filesystem whether it agrees, and whether what came back still parses.
      root.load(function (reloaded) {
        var verified = reloaded !== null
        if (!verified) root.lastError = "baseline was written but could not be read back"
        if (callback) callback({
          ok: verified,
          error: verified ? "" : root.lastError,
          path: root.path,
          baseline: reloaded
        })
      })
    })
  }

  function has() {
    return baseline !== null
  }

  function summary() {
    return Baseline.summarize(baseline)
  }

  function compareTo(facts) {
    return Baseline.compare(baseline, facts)
  }
}
