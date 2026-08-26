.pragma library
.import "Json.js" as Json

// Parser for `systemctl --user --failed --no-legend --no-pager`.
//
// `--no-legend` removes the header and the trailing summary, so every line is
// a unit. On a healthy system there are no lines at all, which is the case
// worth getting right: empty output means "nothing failed", not "could not
// tell". The check distinguishes the two by the exit code.
//
// Columns are UNIT LOAD ACTIVE SUB DESCRIPTION, with a leading bullet on units
// systemd wants to draw attention to.

function parse(text) {
  var lines = Json.nonEmptyLines(text)
  var units = []

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]

    // systemd prefixes attention-worthy rows with "●" or "*" depending on
    // whether it thinks the terminal can take it.
    if (line.charAt(0) === "●" || line.charAt(0) === "*") {
      line = line.substring(1).trim()
    }

    var fields = line.split(/\s+/)
    if (fields.length < 1 || fields[0].length === 0) continue

    var unit = fields[0]
    // A line that does not name a unit is not one; `--no-legend` should have
    // removed the summary, but an older systemd or a locale surprise should
    // not become a phantom failed service.
    if (unit.indexOf(".") < 0) continue

    units.push({
      unit: unit,
      load: fields.length > 1 ? fields[1] : "",
      active: fields.length > 2 ? fields[2] : "",
      sub: fields.length > 3 ? fields[3] : "",
      description: fields.length > 4 ? fields.slice(4).join(" ") : ""
    })
  }

  return { ok: true, units: units, count: units.length }
}

function unitNames(parsed) {
  var names = []
  var units = parsed && parsed.units ? parsed.units : []
  for (var i = 0; i < units.length; i++) names.push(units[i].unit)
  return names
}
