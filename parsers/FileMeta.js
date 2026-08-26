.pragma library
.import "Json.js" as Json

// Parsers for the file metadata `hyprland.user-config-presence` collects
// (spec §17.3): existence, size, mtime and hash — never contents.
//
// That distinction is the whole point. The check needs to say "your
// bindings.lua changed since the baseline", which a hash answers, without ever
// putting a line of the user's configuration into a report.
//
// Both commands take several paths at once and both keep going past a missing
// one, printing what they found on stdout and the failures on stderr with a
// non-zero exit. So stdout is parsed regardless of exit code, and a path that
// is simply absent is a normal result rather than an error.

// `stat -c '%s %Y %n' -- <paths...>`  →  "5282 1787626873 /path/to/file"
function parseStat(text) {
  var lines = Json.nonEmptyLines(text)
  var byPath = {}
  var count = 0

  for (var i = 0; i < lines.length; i++) {
    var match = /^(\d+)\s+(\d+)\s+(.+)$/.exec(lines[i])
    if (!match) continue
    byPath[match[3]] = {
      path: match[3],
      sizeBytes: Number(match[1]),
      mtime: Number(match[2])
    }
    count++
  }

  return { ok: true, byPath: byPath, count: count }
}

// `sha256sum -- <paths...>`  →  "<64 hex>  /path/to/file"
function parseHashes(text) {
  var lines = Json.nonEmptyLines(text)
  var byPath = {}
  var count = 0

  for (var i = 0; i < lines.length; i++) {
    var match = /^([0-9a-f]{64})\s+[ *]?(.+)$/i.exec(lines[i])
    if (!match) continue
    byPath[match[2]] = match[1]
    count++
  }

  return { ok: true, byPath: byPath, count: count }
}

// Merge the two into one record per requested path. A path that neither
// command reported is absent, which several callers treat as a perfectly good
// answer.
function combine(paths, stats, hashes) {
  var files = []
  for (var i = 0; i < paths.length; i++) {
    var path = String(paths[i])
    var meta = stats.byPath[path]
    files.push({
      path: path,
      present: meta !== undefined,
      sizeBytes: meta ? meta.sizeBytes : 0,
      mtime: meta ? meta.mtime : 0,
      // Short form: a full SHA-256 in a report is 64 characters of noise, and
      // 12 is plenty to tell two versions of a config file apart.
      hash: hashes.byPath[path] ? String(hashes.byPath[path]).substring(0, 12) : ""
    })
  }
  return files
}

function formatBytes(bytes) {
  var value = Number(bytes)
  if (!isFinite(value) || value < 0) return "unknown"
  if (value < 1024) return value + " B"
  if (value < 1048576) return (Math.round(value / 102.4) / 10) + " KiB"
  return (Math.round(value / 104857.6) / 10) + " MiB"
}

// mtime is seconds since the epoch; ISO is what the baseline stores and what a
// report should show.
function isoFromMtime(mtime) {
  var seconds = Number(mtime)
  if (!isFinite(seconds) || seconds <= 0) return ""
  return new Date(seconds * 1000).toISOString()
}
