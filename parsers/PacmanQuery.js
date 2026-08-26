.pragma library
.import "Json.js" as Json

// Parser for the two read-only pacman queries OmaPreflight uses.
//
// Only `-Q` forms are ever run: they read the local package database and touch
// nothing. OmaPreflight never syncs, never refreshes mirrors, and never
// contacts a remote (spec §24 network behavior, §17.4 "do not fetch").

// `pacman -Qo <path>` prints, with LC_ALL=C:
//   /usr/bin/quickshell is owned by quickshell 0.3.1-1
function parseOwner(text) {
  var line = Json.firstLine(text)
  if (line.length === 0) return { ok: false, packageName: "", version: "", raw: "" }

  var match = /is owned by\s+(\S+)\s+(\S+)\s*$/.exec(line)
  if (!match) return { ok: false, packageName: "", version: "", raw: line }

  return { ok: true, packageName: match[1], version: match[2], raw: line }
}

// `pacman -Q <name>` prints "name version" per line. Names that are not
// installed produce an error line on stderr and a non-zero exit, while the
// installed ones still print — so stdout is parsed regardless of exit code.
function parseQuery(text) {
  var lines = Json.nonEmptyLines(text)
  var packages = {}
  var count = 0
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split(/\s+/)
    if (parts.length < 2) continue
    packages[parts[0]] = parts[1]
    count++
  }
  return { ok: count > 0, packages: packages, count: count }
}
