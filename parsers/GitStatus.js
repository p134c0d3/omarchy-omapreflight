.pragma library
.import "Json.js" as Json

// Parsers for the two read-only git queries OmaPreflight runs inside plugin
// checkouts (spec §17.4 `plugins.local-changes`).
//
// Both are local. Nothing fetches, nothing contacts a remote, and nothing is
// ever written — this is informational, and its purpose is to explain why an
// update might refuse to fast-forward rather than to do anything about it.

// `git status --porcelain=v1`
//
// Each line is `XY<space>path`, where X is the index status and Y the worktree
// status. `??` is untracked. Renames carry ` -> ` in the path, which is left
// alone: this only ever counts and samples, never acts on a path.
function parseStatus(text) {
  // Deliberately not Json.nonEmptyLines(): that trims, and porcelain v1 is a
  // column format. " M file" (modified in the worktree) and "M  file" (staged)
  // differ only in leading whitespace, so trimming turns one into the other.
  var lines = _rawLines(text)
  var modified = 0
  var untracked = 0
  var staged = 0
  var samples = []

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.length < 3) continue

    var index = line.charAt(0)
    var worktree = line.charAt(1)
    var path = line.substring(3)

    if (index === "?" && worktree === "?") untracked++
    else {
      if (index !== " " && index !== "?") staged++
      if (worktree !== " " && worktree !== "?") modified++
    }

    if (samples.length < 5) samples.push(line)
  }

  return {
    ok: true,
    total: lines.length,
    modified: modified,
    untracked: untracked,
    staged: staged,
    clean: lines.length === 0,
    samples: samples
  }
}

// Split on newlines, dropping only lines that are entirely empty. Leading
// whitespace is data here.
function _rawLines(text) {
  var raw = String(text === undefined || text === null ? "" : text)
  var split = raw.split("\n")
  var out = []
  for (var i = 0; i < split.length; i++) {
    var line = split[i].replace(/\r$/, "")
    if (line.length === 0) continue
    out.push(line)
  }
  return out
}

// `git rev-parse HEAD`
function parseHead(text) {
  var line = Json.firstLine(text)
  if (!/^[0-9a-f]{7,40}$/i.test(line)) {
    return { ok: false, sha: "", shortSha: "" }
  }
  return { ok: true, sha: line, shortSha: line.substring(0, 7) }
}

function describe(status) {
  if (!status || status.clean) return "clean"
  var parts = []
  if (status.modified > 0) parts.push(status.modified + " modified")
  if (status.staged > 0) parts.push(status.staged + " staged")
  if (status.untracked > 0) parts.push(status.untracked + " untracked")
  return parts.join(", ")
}
