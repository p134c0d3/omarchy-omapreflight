.pragma library

// The execution and path policy, as pure functions.
//
// This is the single source of truth for "is OmaPreflight allowed to do this?"
// — CommandRunner, FileReader and FileWriter all delegate here rather than
// each carrying its own copy of the rules. Three implementations of a path
// check is three chances to fix a bug in two of them.
//
// It is pure JavaScript for two reasons. It is directly unit-testable, which
// a QML type depending on Quickshell's C++ plugin is not (qmltestrunner cannot
// load that plugin outside a shell process). And it is readable end to end in
// one screen, which is what a security-relevant policy should be.
//
// The reasoning behind each rule lives in docs/security.md. The rules
// themselves live here, and tests/tst_ExecPolicy.qml is their specification.

// Binaries that exist to raise privilege. OmaPreflight is read-only and
// unprivileged by design; a check that needs root returns SKIPPED and
// documents the manual command instead (spec §23.4).
var PRIVILEGE_BINARIES = [
  "sudo", "sudoedit", "pkexec", "doas", "su", "run0", "machinectl"   // privilege-escalation denylist
]

// Shell interpreters are refused outright rather than audited. No check in the
// catalog needs shell syntax, so allowing one would only create a place for a
// future interpolation bug to live (spec §23.1, §23.2).
var SHELL_BINARIES = [
  "sh", "bash", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "busybox", "env", "eval"
]

// ---- argv ------------------------------------------------------------

// "" means acceptable. Anything else is the human-readable reason, which is
// surfaced to the user as a check result rather than swallowed.
//
// `options.dataArgs` lists the indices of arguments that came from outside the
// plugin; `options.allowedRoots` bounds any of those that are paths.
function validateArgv(argv, options) {
  if (!Array.isArray(argv) || argv.length === 0) return "empty command"

  for (var i = 0; i < argv.length; i++) {
    if (typeof argv[i] !== "string") return "argument " + i + " is not a string"
    var control = controlCharacterAt(argv[i])
    if (control >= 0) {
      return "argument " + i + " contains a control character (0x" + control.toString(16) + ")"
    }
  }

  var binary = argv[0]
  if (binary.length === 0) return "empty program name"

  var base = basename(binary)
  if (PRIVILEGE_BINARIES.indexOf(base) >= 0) return "refusing to run privileged helper '" + base + "'"
  if (SHELL_BINARIES.indexOf(base) >= 0) return "refusing to run interpreter '" + base + "'"

  // The program name is never allowed to come from outside, so it is checked
  // here rather than left to the data rules below.
  if (base.charAt(0) === "-") return "refusing a program name that looks like an option"

  return validateDataArgs(argv, options || {})
}

// Every externally-sourced argument, checked as data rather than as syntax.
function validateDataArgs(argv, options) {
  var indices = options && Array.isArray(options.dataArgs) ? options.dataArgs : []
  var roots = options && Array.isArray(options.allowedRoots) ? options.allowedRoots : []

  for (var n = 0; n < indices.length; n++) {
    var index = indices[n]
    if (typeof index !== "number" || index < 1 || index >= argv.length) {
      return "declared data argument " + index + " is out of range"
    }

    var value = argv[index]
    if (value.length === 0) return "data argument " + index + " is empty"

    // CWE-88. A leading dash is all it takes; no metacharacter is involved,
    // and no amount of removing the shell prevents it.
    if (value.charAt(0) === "-") {
      return "data argument " + index + " starts with '-' and would be read as an option"
    }

    // Path-shaped data gets the path rules (CWE-22).
    if (value.indexOf("/") >= 0) {
      var refusal = pathRefusal(value, roots)
      if (refusal !== "") return "data argument " + index + " " + refusal
    }
  }
  return ""
}

// ---- paths -----------------------------------------------------------

// "" means acceptable. `roots` empty means "any absolute, traversal-free path",
// which is only ever right for a caller that has already bounded the path
// another way.
function pathRefusal(path, roots) {
  var value = String(path === undefined || path === null ? "" : path)
  if (value.length === 0) return "is empty"

  // A relative path resolves against a working directory that no caller here
  // has an opinion about, which makes it unanalyzable rather than merely
  // inconvenient.
  if (value.charAt(0) !== "/") return "is a relative path"
  if (hasTraversal(value)) return "contains a parent traversal"

  var list = Array.isArray(roots) ? roots : []
  if (list.length === 0) return ""
  if (isUnderRoot(value, list)) return ""
  return "is outside the permitted roots"
}

// Segment-wise, so a directory legitimately named "..config" is not a false
// positive and "/a/../../etc" is caught.
function hasTraversal(path) {
  var segments = String(path).split("/")
  for (var i = 0; i < segments.length; i++) {
    if (segments[i] === "..") return true
  }
  return false
}

// Prefix matching on a segment boundary. The classic bug this avoids: an
// allowlisted "…/omarchy/plugins" must not admit "…/omarchy/plugins-evil".
function isUnderRoot(path, roots) {
  var value = String(path)
  for (var i = 0; i < roots.length; i++) {
    var root = String(roots[i])
    if (root.length === 0) continue
    while (root.length > 1 && root.charAt(root.length - 1) === "/") {
      root = root.substring(0, root.length - 1)
    }
    if (value === root) return true
    if (value.indexOf(root + "/") === 0) return true
  }
  return false
}

// ---- primitives ------------------------------------------------------

// Returns the offending code point, or -1. Covers the NUL that would truncate
// an argument at the syscall boundary as well as newlines and escapes, which
// cannot split argv without a shell but do corrupt whatever reads them.
function controlCharacterAt(value) {
  var text = String(value)
  for (var i = 0; i < text.length; i++) {
    var code = text.charCodeAt(i)
    if (code < 0x20 || code === 0x7f) return code
  }
  return -1
}

function basename(path) {
  var value = String(path)
  var slash = value.lastIndexOf("/")
  return slash >= 0 ? value.substring(slash + 1) : value
}
