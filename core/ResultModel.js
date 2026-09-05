.pragma library

// Pure result vocabulary and aggregation. No QML, no I/O, no side effects —
// which is the point: spec §16 requires the readiness aggregator to be pure
// logic with fixture tests, and tests/tst_ResultModel.qml is those tests.
//
// Vocabulary note: the spec writes the status and readiness vocabularies in
// upper case (§15.3, §16). They are stored lower case throughout the plugin
// and upper-cased only for display and for the Markdown report. One casing in
// the data model, one at the edges.

var STATUS = {
  PASS: "pass",
  WARN: "warn",
  FAIL: "fail",
  UNKNOWN: "unknown",
  SKIPPED: "skipped"
}

var SEVERITY = {
  INFO: "info",
  WARNING: "warning",
  ERROR: "error",
  BLOCKER: "blocker"
}

var READINESS = {
  // "neutral" is not in the spec's vocabulary because the spec describes the
  // outcome of a scan. It is the state before any scan has run, and it must be
  // distinguishable from UNKNOWN, which means a scan ran and could not
  // establish the facts (§3.2).
  NEUTRAL: "neutral",
  READY: "ready",
  REVIEW: "review",
  NOT_RECOMMENDED: "not_recommended",
  UNKNOWN: "unknown"
}

var STATUS_ORDER = [STATUS.FAIL, STATUS.WARN, STATUS.UNKNOWN, STATUS.PASS, STATUS.SKIPPED]
var SEVERITY_ORDER = [SEVERITY.INFO, SEVERITY.WARNING, SEVERITY.ERROR, SEVERITY.BLOCKER]

function isStatus(value) {
  return STATUS_ORDER.indexOf(value) >= 0
}

function isSeverity(value) {
  return SEVERITY_ORDER.indexOf(value) >= 0
}

function normalizeStatus(value) {
  var v = String(value === undefined || value === null ? "" : value).toLowerCase()
  return isStatus(v) ? v : STATUS.UNKNOWN
}

function normalizeSeverity(value) {
  var v = String(value === undefined || value === null ? "" : value).toLowerCase()
  return isSeverity(v) ? v : SEVERITY.INFO
}

function statusLabel(status) {
  return normalizeStatus(status).toUpperCase()
}

function readinessLabel(readiness) {
  switch (readiness) {
  case READINESS.READY: return "READY"
  case READINESS.REVIEW: return "REVIEW"
  case READINESS.NOT_RECOMMENDED: return "NOT RECOMMENDED"
  case READINESS.UNKNOWN: return "UNKNOWN"
  default: return "NO SCAN YET"
  }
}

function severityRank(severity) {
  var index = SEVERITY_ORDER.indexOf(normalizeSeverity(severity))
  return index < 0 ? 0 : index
}

function statusRank(status) {
  var index = STATUS_ORDER.indexOf(normalizeStatus(status))
  return index < 0 ? STATUS_ORDER.length : index
}

// ---- construction ----------------------------------------------------

function evidence(type, label, value) {
  return {
    type: String(type || "text"),
    label: String(label || ""),
    value: value === undefined || value === null ? "" : String(value)
  }
}

// Severity is derived from status unless a check states otherwise, so a check
// only has to think about severity when it genuinely differs from the default.
function defaultSeverityFor(def, status) {
  switch (status) {
  case STATUS.FAIL:
    return normalizeSeverity(def && def.defaultSeverity ? def.defaultSeverity : SEVERITY.ERROR)
  case STATUS.WARN:
    return SEVERITY.WARNING
  default:
    return SEVERITY.INFO
  }
}

function makeResult(def, fields) {
  var definition = def || {}
  var f = fields || {}
  var status = normalizeStatus(f.status)
  var severity = f.severity !== undefined && f.severity !== null
    ? normalizeSeverity(f.severity)
    : defaultSeverityFor(definition, status)

  var result = {
    id: String(f.id || definition.id || "unknown.check"),
    title: String(f.title || definition.title || definition.id || "Check"),
    category: String(f.category || definition.category || "other"),
    status: status,
    severity: severity,
    summary: String(f.summary === undefined || f.summary === null ? "" : f.summary),
    details: Array.isArray(f.details) ? f.details.map(String) : [],
    evidence: Array.isArray(f.evidence) ? f.evidence.slice() : [],
    remediation: f.remediation === undefined ? null : f.remediation,
    // Whether a WARN or UNKNOWN should pull readiness down to REVIEW.
    // A missing optional capability is not material (§16); an unreadable
    // Omarchy version is.
    material: f.material === undefined
      ? (definition.material === undefined ? true : !!definition.material)
      : !!f.material,
    startedAt: f.startedAt === undefined || f.startedAt === null ? null : String(f.startedAt),
    durationMs: typeof f.durationMs === "number" ? Math.max(0, Math.round(f.durationMs)) : 0,
    fingerprint: ""
  }
  result.fingerprint = fingerprint(result)
  return result
}

// A skipped result is a first-class outcome, not an error. It says the check
// could not apply and names why, and it never affects readiness.
function skippedResult(def, reason) {
  return makeResult(def, {
    status: STATUS.SKIPPED,
    summary: String(reason || "Not applicable on this system."),
    material: false
  })
}

// Parser and runner failures land here so the failure mode is always a result
// rather than an exception escaping into the shell (§27.3).
function unknownResult(def, reason, evidenceList) {
  return makeResult(def, {
    status: STATUS.UNKNOWN,
    summary: String(reason || "Could not establish this."),
    evidence: evidenceList || []
  })
}

// FNV-1a, 32-bit. Stable across runs for the same input, which is what makes
// it useful for telling whether something changed between scans.
//
// Not a security hash and never used as one: it is not collision-resistant and
// nothing here depends on it being so. Where a real digest is wanted — the
// config files in the baseline — the value comes from `sha256sum`.
function hashString(text) {
  var input = String(text === undefined || text === null ? "" : text)
  var hash = 0x811c9dc5
  for (var i = 0; i < input.length; i++) {
    hash ^= input.charCodeAt(i) & 0xff
    hash = (hash + ((hash << 1) + (hash << 4) + (hash << 7) + (hash << 8) + (hash << 24))) >>> 0
  }
  var hex = hash.toString(16)
  while (hex.length < 8) hex = "0" + hex
  return hex
}

function fingerprint(result) {
  return hashString([result.id, result.status, result.severity, result.summary].join("|"))
}

// ---- aggregation -----------------------------------------------------

function countByStatus(results) {
  var counts = { pass: 0, warn: 0, fail: 0, unknown: 0, skipped: 0 }
  var list = results || []
  for (var i = 0; i < list.length; i++) {
    var status = normalizeStatus(list[i] ? list[i].status : "")
    counts[status]++
  }
  return counts
}

function countBlockers(results) {
  var list = results || []
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!r) continue
    if (normalizeStatus(r.status) === STATUS.FAIL
        && normalizeSeverity(r.severity) === SEVERITY.BLOCKER) total++
  }
  return total
}

// Informational WARN and UNKNOWN findings remain visible without changing
// readiness (ADR-007). FAIL always affects readiness; SKIPPED never does.
//
// There is no numeric score here and there must never be one (§3.1).
function aggregateReadiness(results, scanCompleted) {
  if (!scanCompleted) return READINESS.UNKNOWN

  var list = results || []
  if (list.length === 0) return READINESS.UNKNOWN

  var blocking = false
  var needsReview = false

  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!r) continue
    var status = normalizeStatus(r.status)
    var severity = normalizeSeverity(r.severity)

    if (status === STATUS.FAIL && severity === SEVERITY.BLOCKER) blocking = true
    if (status === STATUS.FAIL) needsReview = true
    if (status === STATUS.WARN && r.material !== false) needsReview = true
    if (status === STATUS.UNKNOWN && r.material !== false) needsReview = true
  }

  if (blocking) return READINESS.NOT_RECOMMENDED
  if (needsReview) return READINESS.REVIEW
  return READINESS.READY
}

function groupByCategory(results) {
  var groups = {}
  var list = results || []
  for (var i = 0; i < list.length; i++) {
    var r = list[i]
    if (!r) continue
    var category = String(r.category || "other")
    if (!groups[category]) {
      groups[category] = { id: category, results: [], counts: { pass: 0, warn: 0, fail: 0, unknown: 0, skipped: 0 } }
    }
    groups[category].results.push(r)
    groups[category].counts[normalizeStatus(r.status)]++
  }
  return groups
}

// Worst first, then by declaration order within a status. Diagnostics are read
// top-down and the thing that needs attention belongs at the top.
function sortForDisplay(results) {
  var list = (results || []).slice()
  list.sort(function (a, b) {
    var byStatus = statusRank(a.status) - statusRank(b.status)
    if (byStatus !== 0) return byStatus
    var bySeverity = severityRank(b.severity) - severityRank(a.severity)
    if (bySeverity !== 0) return bySeverity
    return String(a.id).localeCompare(String(b.id))
  })
  return list
}

function summarize(results, scanCompleted) {
  return {
    readiness: aggregateReadiness(results, scanCompleted),
    counts: countByStatus(results),
    blockers: countBlockers(results),
    total: (results || []).length
  }
}
