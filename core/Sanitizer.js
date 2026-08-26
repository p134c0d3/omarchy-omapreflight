.pragma library

// Redaction for anything that leaves the machine by the user's own hand.
//
// Spec §25. The rules here are the documented minimum: home paths, usernames,
// hostnames, hardware and network addresses, temporary paths, and lines whose
// key names advertise a secret.
//
// Two things this file will not do.
//
// It will not claim to be complete. Sanitization of free-form command output
// is pattern matching against a moving target, and a report that says
// "sanitized" without qualification invites someone to paste it without
// reading. Every report carries the review-before-posting header, and
// docs/security.md says the same thing in the same words.
//
// It will not silently drop information. A redaction is always visible as a
// placeholder — `~`, `<user>`, `<ip>` — so a reader can tell the difference
// between "this was removed" and "this was empty", and can ask for the raw
// value if a diagnosis actually needs it.

// Order matters. Home paths are rewritten before bare usernames, otherwise
// "/home/alice/x" becomes "/home/<user>/x" instead of "~/x".
function makeContext(options) {
  var o = options || {}
  return {
    home: String(o.home || ""),
    user: String(o.user || ""),
    host: String(o.host || "")
  }
}

function sanitize(text, context) {
  var value = String(text === undefined || text === null ? "" : text)
  if (value.length === 0) return value

  var ctx = context || makeContext({})

  if (ctx.home.length > 0) {
    value = value.split(ctx.home).join("~")
  }

  // Other users' home directories are still someone's name.
  value = value.replace(/\/home\/[A-Za-z0-9._-]+/g, "/home/<user>")
  value = value.replace(/\/root\b/g, "/<root>")

  // Email before the bare-username rule. Otherwise "alice@example.com" becomes
  // "<user>@example.com", which redacts the half that mattered least and keeps
  // the domain.
  value = value.replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/g, "<email>")

  if (ctx.user.length > 1) {
    value = _replaceWord(value, ctx.user, "<user>")
  }
  if (ctx.host.length > 1) {
    value = _replaceWord(value, ctx.host, "<host>")
  }

  // Runtime and temporary paths leak uids and per-boot identifiers, and are
  // never diagnostically interesting in a shared report.
  value = value.replace(/\/run\/user\/[0-9]+/g, "/run/user/<uid>")
  value = value.replace(/\/tmp\/[A-Za-z0-9._-]+/g, "/tmp/<temp>")

  // Hardware and network addresses. Bluetooth device addresses share the MAC
  // shape, so one rule covers both.
  value = value.replace(/\b(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\b/g, "<mac>")
  value = value.replace(/\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b/g, _maskIPv4)
  value = value.replace(/\b(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}\b/g, "<ipv6>")

  value = value.replace(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/g, "<uuid>")

  return _redactSecretLines(value)
}

// Loopback and the unspecified address carry no identity and are frequently
// the whole point of a finding, so they survive.
function _maskIPv4(match) {
  if (match === "127.0.0.1" || match === "0.0.0.0" || match === "255.255.255.255") return match
  return "<ip>"
}

var _SECRET_KEY = /(pass(word|wd|phrase)?|secret|token|api[_-]?key|apikey|auth(orization)?|bearer|credential|private[_-]?key|session[_-]?id)/i

// Line-oriented, because command output is line-oriented. A line whose key
// name advertises a secret loses its value; if there is no recognizable
// key/value split, the whole line goes, because guessing which half was the
// secret is exactly the wrong bet to make.
//
// Path components do not count as key names. "/home/bob/secret" is a
// directory, and redacting the line it appears on would destroy real
// diagnostic content — which is how sanitization earns a reputation for making
// reports useless, and how people end up turning it off.
function _redactSecretLines(text) {
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (!_SECRET_KEY.test(_withoutPathTokens(lines[i]))) continue

    var separator = lines[i].search(/[:=]/)
    if (separator >= 0) {
      lines[i] = lines[i].substring(0, separator + 1) + " <redacted>"
    } else {
      lines[i] = "<redacted line>"
    }
  }
  return lines.join("\n")
}

// Blanks out every whitespace-delimited token containing a slash, so the
// keyword test only ever sees non-path text.
function _withoutPathTokens(line) {
  return line.replace(/\S*\/\S*/g, " ")
}

// Whole-word replacement. A username like "sam" must not turn "same" into
// "<user>e", and a two-character username is skipped entirely by the caller
// for the same reason.
function _replaceWord(text, word, replacement) {
  var escaped = word.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
  return text.replace(new RegExp("\\b" + escaped + "\\b", "g"), replacement)
}

// Sanitize a whole check result, in place on a copy. Evidence values are the
// riskiest field — they are the only place raw command output survives.
function sanitizeResult(result, context) {
  if (!result) return result

  var copy = {
    id: result.id,
    title: result.title,
    category: result.category,
    status: result.status,
    severity: result.severity,
    summary: sanitize(result.summary, context),
    details: [],
    evidence: [],
    remediation: result.remediation ? sanitize(result.remediation, context) : null,
    material: result.material,
    startedAt: result.startedAt,
    durationMs: result.durationMs,
    fingerprint: result.fingerprint
  }

  var details = result.details || []
  for (var i = 0; i < details.length; i++) copy.details.push(sanitize(details[i], context))

  var evidence = result.evidence || []
  for (var j = 0; j < evidence.length; j++) {
    copy.evidence.push({
      type: evidence[j].type,
      label: sanitize(evidence[j].label, context),
      value: sanitize(evidence[j].value, context)
    })
  }

  return copy
}
