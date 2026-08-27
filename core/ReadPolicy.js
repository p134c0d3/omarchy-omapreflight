.pragma library

// The file-read policy, as pure functions.
//
// `ExecPolicy` answers "may this path be named at all?". This module answers
// the questions that only the kernel can settle: is the thing at that path a
// regular file, how big is it, and — at the moment it is opened — is it still
// the same thing the policy approved?
//
// A path allowlist cannot answer any of those. A path is a name, and a name
// inside a directory the user owns can be replaced with a symlink to
// `~/.ssh/id_ed25519`, with a FIFO that never returns a byte, or with a file
// that grew to a gigabyte since the last scan. So a read here is two steps:
//
//   1. `stat -c '%F|%s'` — *without* `-L`, so a symlink reports as a symlink
//      rather than as whatever it points at. Type and size are decided before
//      any content is read, and a refusal costs nothing.
//
//   2. `dd if=… iflag=nofollow,nonblock,fullblock,count_bytes count=<ceiling+1>`
//      — the read itself, with the guarantee moved into the open(2) flags:
//
//        * `nofollow` is `O_NOFOLLOW`. If the path became a symlink between
//          step 1 and step 2, the kernel fails the open with ELOOP. This is
//          what makes the type check above non-bypassable rather than
//          advisory — there is no window in which a swapped-in symlink is
//          followed, because the refusal happens inside the syscall.
//        * `nonblock` is `O_NONBLOCK`. A FIFO swapped in for the same reason
//          returns immediately instead of hanging the read.
//        * `count_bytes` + `count` is the byte ceiling, enforced by the reader
//          rather than by trusting the size seen in step 1.
//
// Step 1 is the diagnosis — it produces the message the user reads. Step 2 is
// the enforcement — it holds even if step 1 was lied to. Neither is sufficient
// alone, which is why both are here.
//
// `dd` is coreutils, alongside the `stat`, `df` and `sha256sum` the plugin
// already requires. Nothing is bundled and no interpreter is involved.

// 256 KiB, deliberately the same bound `CommandJob` puts on stdout. The files
// OmaPreflight reads are `shell.json` and its own baseline; both are kilobytes.
// The ceiling exists so that a file which is *not* those cannot become a
// resident copy of itself inside the shell process.
var CEILING_BYTES = 262144

// The read is asked for one byte past the ceiling, so "the file is too big" is
// something the reader observes rather than something it infers from a length
// that happens to land exactly on the limit.
var READ_BYTES = CEILING_BYTES + 1

// ---- step 1: what is at this path ------------------------------------

// No `-L`. The default is lstat(2), which is the entire reason this is useful:
// `-L` would cheerfully report a symlink to `/etc/shadow` as a regular file.
function probeArgv(path) {
  return ["stat", "-c", "%F|%s", "--", String(path)]
}

// The path is the only externally-sourced argument, and it is a path.
function probeDataArgs() {
  return [4]
}

// `stat -c '%F|%s'` → "regular file|5282". The separator is a literal in our
// own format string, so it cannot be confused with anything in the output.
function parseProbe(text) {
  var line = String(text || "").split("\n")[0].trim()
  var bar = line.lastIndexOf("|")
  if (bar <= 0) return { ok: false, type: "", sizeBytes: 0 }

  var size = Number(line.substring(bar + 1))
  if (!isFinite(size) || size < 0) return { ok: false, type: "", sizeBytes: 0 }

  return { ok: true, type: line.substring(0, bar), sizeBytes: size }
}

// GNU stat distinguishes an empty regular file from a populated one, and both
// are perfectly ordinary things for a config file to be.
function isRegularFile(type) {
  return type === "regular file" || type === "regular empty file"
}

// "" means the read may proceed. Anything else is the reason the user sees.
function probeRefusal(probe) {
  if (!probe || !probe.ok) return "could not be identified"
  if (!isRegularFile(probe.type)) return "is a " + probe.type + ", not a regular file"
  if (probe.sizeBytes > CEILING_BYTES) {
    return "is " + probe.sizeBytes + " bytes, above the " + describeCeiling() + " read limit"
  }
  return ""
}

// ---- step 2: the bounded read ----------------------------------------

function readArgv(path) {
  return [
    "dd",
    "if=" + String(path),
    // nofollow: O_NOFOLLOW. nonblock: O_NONBLOCK. fullblock: `count` counts
    // data, not short reads. count_bytes: `count` is bytes rather than blocks.
    "iflag=nofollow,nonblock,fullblock,count_bytes",
    "bs=65536",
    "count=" + READ_BYTES,
    "status=none"
  ]
}

// `if=` is the only way to hand `dd` a filename, so this is the one place the
// plugin declares a data argument that carries a prefix. `ExecPolicy` strips
// the declared prefix and applies the ordinary path rules to what is left.
function readDataArgs() {
  return [{ index: 1, prefix: "if=" }]
}

// Characters, not bytes: `StdioCollector` has already decoded the stream. A
// multi-byte file decodes to fewer characters than it occupies, so this can
// only under-report — it never calls a file oversized that is not. The size
// check in step 1 is what catches the general case; this catches the file that
// grew after being measured.
function exceededCeiling(text) {
  return String(text || "").length > CEILING_BYTES
}

// ---- failures --------------------------------------------------------

// Both commands report an open failure the same way:
//
//   stat: cannot statx '/home/u/.config/omarchy/shell.json': No such file …
//   dd: failed to open '/home/u/.config/omarchy/shell.json': Too many levels …
//
// The caller already knows the path, so only the errno text is kept. That also
// keeps a home directory out of a string that ends up in a report.
function describeFailure(stderr, fallback) {
  var line = String(stderr || "").split("\n")[0].trim()
  var colon = line.lastIndexOf(": ")
  var reason = colon >= 0 ? line.substring(colon + 2).trim() : line
  return reason.length > 0 ? reason : String(fallback || "read failed")
}

// A file that is not there is not an error. Several checks treat absence as a
// perfectly good answer, so it is reported separately.
function isMissing(stderr) {
  return String(stderr || "").indexOf("No such file or directory") >= 0
}

function describeCeiling() {
  return (CEILING_BYTES / 1024) + " KiB"
}
