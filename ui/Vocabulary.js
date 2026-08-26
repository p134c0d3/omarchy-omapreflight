.pragma library

// One place that decides how a status or a readiness reads on screen.
//
// Spec §27.1: no information may be carried by colour alone. Every state here
// has a glyph *and* a word, and the colour is only ever a third, redundant
// cue. Reading this file should make it obvious that removing all colour would
// leave the UI fully legible.
//
// The glyphs are the six already proven to render in the Omarchy bar font.
// Picking an unverified codepoint is how a status silently becomes a hollow
// box on someone else's font configuration.

function statusGlyph(status) {
  switch (String(status)) {
  case "pass": return "󰄬"
  case "warn": return "󰀦"
  case "fail": return "󰅚"
  case "unknown": return "󰋗"
  case "skipped": return "󰝦"
  default: return "󰋗"
  }
}

function statusLabel(status) {
  switch (String(status)) {
  case "pass": return "PASS"
  case "warn": return "WARN"
  case "fail": return "FAIL"
  case "unknown": return "UNKNOWN"
  case "skipped": return "SKIPPED"
  default: return "UNKNOWN"
  }
}

function readinessGlyph(readiness, scanning) {
  if (scanning) return "󰔟"
  switch (String(readiness)) {
  case "ready": return "󰄬"
  case "review": return "󰀦"
  case "not_recommended": return "󰅚"
  case "unknown": return "󰋗"
  default: return "󰝦"
  }
}

function readinessLabel(readiness, scanning) {
  if (scanning) return "Checking"
  switch (String(readiness)) {
  case "ready": return "Ready"
  case "review": return "Review"
  case "not_recommended": return "Not recommended"
  case "unknown": return "Unknown"
  default: return "No scan yet"
  }
}

// The one-line explanation under the badge. These are deliberately plain and
// deliberately not reassuring: "Ready" means the checks that ran found nothing,
// not that an update is guaranteed to be uneventful (§3.1, §4).
function readinessBlurb(readiness, scanning) {
  if (scanning) return "Running checks."
  switch (String(readiness)) {
  case "ready": return "Nothing the checks look at is currently a problem."
  case "review": return "Some findings are worth reading before you update."
  case "not_recommended": return "Something is failing that an update would likely make worse."
  case "unknown": return "The scan could not establish enough to give a verdict."
  default: return "Run a scan to see where this machine stands."
  }
}

// Whether the readiness deserves the muted treatment: no scan has run, so
// there is nothing to report rather than nothing to worry about.
function readinessIsNeutral(readiness) {
  var value = String(readiness)
  return value !== "ready" && value !== "review"
    && value !== "not_recommended" && value !== "unknown"
}

// Counts, rendered the way a person would say them out loud. Zero-valued
// statuses are omitted rather than shown as "0 warnings".
function countsSentence(counts) {
  if (!counts) return ""
  var parts = []
  if (counts.fail > 0) parts.push(counts.fail + (counts.fail === 1 ? " failure" : " failures"))
  if (counts.warn > 0) parts.push(counts.warn + (counts.warn === 1 ? " warning" : " warnings"))
  if (counts.unknown > 0) parts.push(counts.unknown + " unknown")
  if (counts.skipped > 0) parts.push(counts.skipped + " skipped")
  if (counts.pass > 0) parts.push(counts.pass + " passed")
  return parts.join(" · ")
}

// "3 minutes ago" style, from an ISO timestamp. Falls back to the raw string
// rather than inventing a time it cannot compute.
function relativeTime(isoString, nowMs) {
  if (!isoString) return "never"
  var then = Date.parse(String(isoString))
  if (isNaN(then)) return String(isoString)

  var deltaSeconds = Math.round(((nowMs || Date.now()) - then) / 1000)
  if (deltaSeconds < 0) return "just now"
  if (deltaSeconds < 45) return "just now"
  if (deltaSeconds < 90) return "a minute ago"

  var minutes = Math.round(deltaSeconds / 60)
  if (minutes < 60) return minutes + " minutes ago"

  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours === 1 ? "an hour ago" : hours + " hours ago"

  var days = Math.round(hours / 24)
  return days === 1 ? "yesterday" : days + " days ago"
}
