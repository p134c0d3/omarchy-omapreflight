.pragma library

// Every parser boundary in OmaPreflight goes through here.
//
// Spec §27.3: a parser exception must become a failed or unknown check result,
// never a crash in the shell process we are a guest in. JSON.parse throwing on
// a truncated command output is the single most likely way that happens, so it
// is wrapped once, here, instead of in every call site.

function parse(text) {
  var raw = String(text === undefined || text === null ? "" : text)
  if (raw.trim().length === 0) {
    return { ok: false, value: null, error: "empty output" }
  }
  try {
    return { ok: true, value: JSON.parse(raw), error: "" }
  } catch (e) {
    return { ok: false, value: null, error: "invalid JSON: " + String(e && e.message ? e.message : e) }
  }
}

// Same contract, but also asserts the shape the caller expects, so a check
// never has to guess whether `.length` is safe to touch.
function parseArray(text) {
  var parsed = parse(text)
  if (!parsed.ok) return parsed
  if (!Array.isArray(parsed.value)) {
    return { ok: false, value: null, error: "expected a JSON array" }
  }
  return parsed
}

function parseObject(text) {
  var parsed = parse(text)
  if (!parsed.ok) return parsed
  if (parsed.value === null || typeof parsed.value !== "object" || Array.isArray(parsed.value)) {
    return { ok: false, value: null, error: "expected a JSON object" }
  }
  return parsed
}

// Trim + drop blank lines. Command output that is "empty" is frequently a
// couple of newlines, and treating that as content produces phantom findings.
function nonEmptyLines(text) {
  var raw = String(text === undefined || text === null ? "" : text)
  var lines = raw.split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line.length > 0) out.push(line)
  }
  return out
}

function firstLine(text) {
  var lines = nonEmptyLines(text)
  return lines.length > 0 ? lines[0] : ""
}

// Keep evidence blocks readable. Raw stdout must not dominate a report (§26).
function clip(text, maxLines, maxChars) {
  var limitLines = maxLines || 20
  var limitChars = maxChars || 4000
  var raw = String(text === undefined || text === null ? "" : text)
  var lines = raw.split("\n")
  var truncated = false
  if (lines.length > limitLines) {
    lines = lines.slice(0, limitLines)
    truncated = true
  }
  var out = lines.join("\n")
  if (out.length > limitChars) {
    out = out.substring(0, limitChars)
    truncated = true
  }
  return truncated ? out + "\n… (truncated)" : out
}
