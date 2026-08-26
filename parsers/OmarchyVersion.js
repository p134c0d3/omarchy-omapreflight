.pragma library
.import "Json.js" as Json

// `omarchy version` prints a bare package version, e.g. "4.0.1-1".
// `omarchy channel current` prints one of stable / rc / edge / dev.
//
// Both are parsed permissively. The version string's *shape* is not something
// OmaPreflight should have an opinion about — it only has to be recorded
// faithfully, compared to the baseline, and shown in a bug report.

var KNOWN_CHANNELS = ["stable", "rc", "edge", "dev"]

function parseVersion(text) {
  var line = Json.firstLine(text)
  if (line.length === 0) return { ok: false, version: "", error: "no output" }

  // Accept anything that starts with a digit and contains no whitespace.
  // Rejecting a future version format would be worse than recording it.
  if (!/^[0-9][^\s]*$/.test(line)) {
    return { ok: false, version: line, error: "unrecognized version format" }
  }
  return { ok: true, version: line, error: "" }
}

function parseChannel(text) {
  var line = Json.firstLine(text).toLowerCase()
  if (line.length === 0) return { ok: false, channel: "", known: false, error: "no output" }

  var known = KNOWN_CHANNELS.indexOf(line) >= 0
  // An unknown channel name is reported as-is and flagged as unrecognized.
  // It is information, not a failure: the channel list can grow.
  return { ok: true, channel: line, known: known, error: "" }
}

// Split "4.0.1-1" into comparable parts. Used for baseline comparison only;
// it deliberately does not try to be a general version-ordering function.
function components(version) {
  var raw = String(version || "")
  var dashIndex = raw.indexOf("-")
  var upstream = dashIndex >= 0 ? raw.substring(0, dashIndex) : raw
  var release = dashIndex >= 0 ? raw.substring(dashIndex + 1) : ""
  var parts = upstream.split(".").map(function (p) {
    var n = parseInt(p, 10)
    return isNaN(n) ? p : n
  })
  return { upstream: upstream, release: release, parts: parts }
}

function sameVersion(a, b) {
  return String(a || "") === String(b || "")
}

// -1 if a < b, 0 if equal, 1 if a > b, and **null when they cannot be
// meaningfully ordered**.
//
// The null case matters more than the others. Version ordering is where
// diagnostics quietly start lying: given "4.0.1-1" and "4.0.1-rc2" there is a
// defensible answer, and given a format this parser has never seen there is
// not. Returning null lets the caller say "different, and I cannot tell which
// way" instead of guessing — which is the whole point of the UNKNOWN status.
function compare(a, b) {
  var left = components(a)
  var right = components(b)
  if (left.upstream.length === 0 || right.upstream.length === 0) return null
  if (left.upstream === right.upstream) {
    return _compareRelease(left.release, right.release)
  }

  var length = Math.max(left.parts.length, right.parts.length)
  for (var i = 0; i < length; i++) {
    var l = left.parts[i]
    var r = right.parts[i]
    if (l === undefined) return -1
    if (r === undefined) return 1
    // A non-numeric component ("2rc1", "beta") is where ordering stops being
    // knowable. Say so rather than falling back on string comparison, which
    // would confidently put "10" before "9".
    if (typeof l !== "number" || typeof r !== "number") return null
    if (l !== r) return l < r ? -1 : 1
  }
  return _compareRelease(left.release, right.release)
}

function _compareRelease(a, b) {
  var left = parseInt(a, 10)
  var right = parseInt(b, 10)
  if (isNaN(left) || isNaN(right)) return a === b ? 0 : null
  if (left === right) return 0
  return left < right ? -1 : 1
}
