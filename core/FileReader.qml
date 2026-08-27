import QtQuick
import "ExecPolicy.js" as ExecPolicy
import "ReadPolicy.js" as ReadPolicy

// The only place in OmaPreflight that reads a file.
//
// Narrow by design (spec §24, §33.6): reads are single named paths, never a
// directory walk and never anything under $HOME that is not an Omarchy
// configuration file the catalog names explicitly. There is no recursive mode
// and there should never be one.
//
// ---------------------------------------------------------------------------
// Why this does not use FileView
//
// It did, until a marketplace security review pointed out what an allowlist of
// *names* cannot promise. `FileView.text()` opens whatever the path resolves to
// at that instant, follows symlinks, and returns the whole thing:
//
//   * a symlink planted in an allowlisted directory redirects the read
//   * a FIFO at an allowlisted path never completes the read
//   * a file that grew becomes a resident copy of itself in the shell process
//
// Quickshell's FileView exposes no open flags, no type check and no size cap,
// so none of those can be closed at that layer. The read therefore goes through
// the same hardened command path as everything else, where the guarantees live
// in the kernel's open(2) flags instead of in a promise about a string:
// `stat` decides the type and size, then `dd` re-opens with `O_NOFOLLOW` and
// `O_NONBLOCK` and reads a bounded number of bytes. `core/ReadPolicy.js` holds
// the reasoning and the argv; this file is the sequencing.
QtObject {
  id: root

  // The shared CommandRunner. Reads are queued and bounded on exactly the same
  // terms as every other process the plugin starts — one at a time, with a
  // timeout and a stdout cap — rather than on a second set of rules.
  property var runner: null

  property int defaultTimeoutMs: 3000

  // Paths OmaPreflight will read. A check asks for a path; if it is not
  // covered by this allowlist the read is refused and the check gets an
  // explicit reason rather than data. Keeping the policy here means a new
  // check cannot quietly widen it.
  property var allowedPrefixes: []

  readonly property int ceilingBytes: ReadPolicy.CEILING_BYTES

  function read(path, callback) {
    var target = String(path || "")

    var refusal = _refusalFor(target)
    if (refusal !== "") {
      _settle(callback, target, { error: refusal, refused: true })
      return
    }

    if (!root.runner) {
      _settle(callback, target, { error: "no command runner" })
      return
    }

    _probe(target, callback)
  }

  // ---- step 1: what is at this path ----------------------------------
  function _probe(target, callback) {
    root.runner.run(ReadPolicy.probeArgv(target), {
      timeoutMs: root.defaultTimeoutMs,
      dataArgs: ReadPolicy.probeDataArgs(),
      allowedRoots: root.allowedPrefixes
    }, function (result) {
      if (result.blocked) {
        _settle(callback, target, { error: result.blockedReason, refused: true, durationMs: result.durationMs })
        return
      }

      if (!result.ok) {
        // Absence is a normal answer, not a failure. Everything else — an
        // unreadable parent directory, a wedged mount, a timeout — is not.
        if (ReadPolicy.isMissing(result.stderr)) {
          _settle(callback, target, { missing: true, durationMs: result.durationMs })
          return
        }
        _settle(callback, target, {
          error: ReadPolicy.describeFailure(result.stderr, _commandFailure(result, "stat")),
          durationMs: result.durationMs
        })
        return
      }

      var probe = ReadPolicy.parseProbe(result.stdout)
      var probeRefusal = ReadPolicy.probeRefusal(probe)
      if (probeRefusal !== "") {
        _settle(callback, target, {
          error: "path " + probeRefusal, refused: true, durationMs: result.durationMs
        })
        return
      }

      _readBytes(target, callback, result.durationMs)
    })
  }

  // ---- step 2: the bounded, no-follow read ---------------------------
  function _readBytes(target, callback, elapsedMs) {
    root.runner.run(ReadPolicy.readArgv(target), {
      timeoutMs: root.defaultTimeoutMs,
      dataArgs: ReadPolicy.readDataArgs(),
      allowedRoots: root.allowedPrefixes,
      // One byte of headroom over what the read asks for, so the ceiling is
      // reported as a ceiling rather than silently truncated mid-stream.
      stdoutLimit: ReadPolicy.READ_BYTES
    }, function (result) {
      var duration = elapsedMs + result.durationMs

      if (result.blocked) {
        _settle(callback, target, { error: result.blockedReason, refused: true, durationMs: duration })
        return
      }

      if (!result.ok) {
        // The path changed identity between the two steps. O_NOFOLLOW turned
        // that into a failed open rather than a followed link, which is the
        // whole point of doing the read this way.
        if (ReadPolicy.isMissing(result.stderr)) {
          _settle(callback, target, { missing: true, durationMs: duration })
          return
        }
        _settle(callback, target, {
          error: ReadPolicy.describeFailure(result.stderr, _commandFailure(result, "dd")),
          durationMs: duration
        })
        return
      }

      // The file grew past the ceiling after it was measured. Returning the
      // prefix would hand a parser half a config file and let it report
      // "malformed", which is a worse answer than the true one.
      if (ReadPolicy.exceededCeiling(result.stdout)) {
        _settle(callback, target, {
          error: "file exceeds the " + ReadPolicy.describeCeiling() + " read limit",
          refused: true, durationMs: duration
        })
        return
      }

      _settle(callback, target, { ok: true, text: result.stdout, durationMs: duration })
    })
  }

  // ---- internals -----------------------------------------------------

  // Every path out of this object produces the same shape, exactly once, and
  // always on a later turn of the event loop — a caller must not have to know
  // whether its callback runs before or after `read()` returns. A check that
  // asked for a file always gets an answer it can turn into a result, never an
  // exception and never silence.
  //
  // The closure is rebuilt per call on purpose: `Qt.callLater` collapses
  // repeated calls that share a function reference, which would silently drop
  // one of two reads that happened to be given the same callback.
  function _settle(callback, target, fields) {
    var result = {
      path: target,
      ok: fields.ok === true,
      missing: fields.missing === true,
      text: fields.text !== undefined ? String(fields.text) : "",
      error: fields.error !== undefined ? String(fields.error) : "",
      refused: fields.refused === true,
      durationMs: fields.durationMs !== undefined ? Math.max(0, Math.round(fields.durationMs)) : 0
    }
    if (!callback) return
    Qt.callLater(function () { callback(result) })
  }

  // A command that never produced a diagnostic still has to say something.
  function _commandFailure(result, program) {
    if (result.timedOut) return "timed out reading file"
    if (result.cancelled) return "read cancelled"
    if (result.startFailed) return program + " is not available"
    if (result.abandoned) return program + " did not exit"
    return program + " exited " + result.exitCode
  }

  // CWE-22, via the shared policy in core/ExecPolicy.js: absolute, no `..`
  // segment, and inside one of the allowlisted roots — matched on a segment
  // boundary, so an allowlisted ".../omarchy" cannot be satisfied by
  // ".../omarchy-evil".
  //
  // This is the check on the *name*. What the name resolves to is decided in
  // core/ReadPolicy.js, because a name is all this function can see.
  function _refusalFor(target) {
    var refusal = ExecPolicy.pathRefusal(target, root.allowedPrefixes)
    if (refusal === "") return ""
    if (refusal === "is outside the permitted roots") return "path is outside the OmaPreflight read allowlist"
    return "path " + refusal
  }
}
