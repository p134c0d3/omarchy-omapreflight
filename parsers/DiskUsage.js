.pragma library
.import "Json.js" as Json

// Parser for `df -Pk <path>`.
//
// `-P` is the POSIX output format, which guarantees one line per filesystem
// even when the device name is long — without it df wraps and the columns stop
// lining up. `-k` fixes the unit at 1024-byte blocks so nothing has to parse a
// human-readable suffix.
//
//   Filesystem       1024-blocks     Used Available Capacity Mounted on
//   /dev/mapper/root   486270976 68104880 415745440      15% /
//
// Fields are read from the right, because a device name can contain spaces and
// the mount point is the last field. That gives five known columns and lets
// whatever is left be the device.

function parse(text) {
  var lines = Json.nonEmptyLines(text)
  if (lines.length < 2) {
    return { ok: false, error: "no filesystem line in df output" }
  }

  // Last line, not second: a df that reports more than one filesystem is
  // unusual for a single path, and the last line is the one for the path asked
  // about.
  var fields = lines[lines.length - 1].split(/\s+/)
  if (fields.length < 6) {
    return { ok: false, error: "unexpected df output shape" }
  }

  var mountedOn = fields[fields.length - 1]
  var capacity = fields[fields.length - 2]
  var availableKiB = Number(fields[fields.length - 3])
  var usedKiB = Number(fields[fields.length - 4])
  var totalKiB = Number(fields[fields.length - 5])
  var filesystem = fields.slice(0, fields.length - 5).join(" ")

  if (!isFinite(availableKiB) || !isFinite(totalKiB) || totalKiB <= 0) {
    return { ok: false, error: "df reported unreadable block counts" }
  }

  return {
    ok: true,
    error: "",
    filesystem: filesystem,
    mountedOn: mountedOn,
    totalKiB: totalKiB,
    usedKiB: isFinite(usedKiB) ? usedKiB : 0,
    availableKiB: availableKiB,
    availableGiB: availableKiB / 1048576,
    capacity: capacity,
    usedPercent: Math.round((1 - availableKiB / totalKiB) * 100)
  }
}

// Thresholds, documented rather than tuned (spec §17.5).
//
// These are conservative and they are not a prediction of how much an update
// will need — nothing here can know that, and pretending otherwise is exactly
// the fake heuristic §18 rules out. They exist to catch "this machine is
// nearly full", which is a real and common reason an update goes badly.
var BLOCKER_GIB = 2
var WARNING_GIB = 5

function assess(usage) {
  if (!usage || !usage.ok) return { level: "unknown" }
  if (usage.availableGiB < BLOCKER_GIB) return { level: "critical", threshold: BLOCKER_GIB }
  if (usage.availableGiB < WARNING_GIB) return { level: "low", threshold: WARNING_GIB }
  return { level: "ok" }
}

function formatGiB(gib) {
  if (!isFinite(gib)) return "unknown"
  if (gib >= 100) return Math.round(gib) + " GiB"
  if (gib >= 10) return (Math.round(gib * 10) / 10) + " GiB"
  return (Math.round(gib * 100) / 100) + " GiB"
}
