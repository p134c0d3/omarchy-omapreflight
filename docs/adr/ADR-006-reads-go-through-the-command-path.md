# ADR-006 — File reads go through the command path, not `FileView`

**Status:** Accepted (v0.1.1)
**Prompted by:** the marketplace security review of the v0.1.0 submission,
[HANCORE-linux/omarchy-plugin-marketplace#2558](https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/2558)

## Context

Reads were a `FileView` inside `core/FileReadJob.qml`: set `path`, flip
`preload`, take `text()` on `loaded`, with a timer so a load that never
finished could not strand the scan. The safety argument for it rested entirely
on `FileReader`'s path allowlist — absolute, no `..` segment, inside one of
three approved directories, matched on a segment boundary.

The marketplace reviewer's finding was that the allowlist checks a *name*, and
a name is not a guarantee about the thing at the other end of it:

> `FileReadJob.qml` still calls `FileView.text()` without a byte ceiling or
> descriptor-level no-follow/regular-file validation. The path allowlist does
> not prevent an allowlisted replaceable path from being a symlink, special
> file, or oversized file, so a scan can read unintended content, block, or
> retain unbounded data.

All three are real, and each fails differently:

- **Symlink.** `~/.config/omarchy/shell.json` replaced by a link to
  `~/.ssh/id_ed25519` is still an allowlisted path. `FileView` follows it.
- **Special file.** A FIFO at an allowlisted path never completes the read. The
  job's timer kept the *scan* alive, but the underlying read still hung.
- **Size.** `text()` returns the whole file. Commands were capped at 256 KiB of
  stdout while file reads were capped at nothing — an inconsistency in the
  plugin's own bounded-work table.

The residual-risks section already conceded the symlink case ("there is no
`realpath` available to QML") and argued it was bounded because every read is
inert. That answers disclosure. It does not answer blocking or memory, and
"the content only becomes evidence text" is a weaker promise than "the file was
never opened."

Quickshell 0.3.x `FileView` has no open flags, no file-type property and no
size cap. So the gap could not be closed where the read was.

## Decision

Reads move to the command path, which was already hardened for exactly this
class of problem — argv arrays with no shell, declared data arguments, bounded
stdout, a timeout with SIGTERM → SIGKILL → abandon escalation, and one process
at a time. A read becomes two commands (`core/ReadPolicy.js`):

```
stat -c '%F|%s' -- <path>
dd if=<path> iflag=nofollow,nonblock,fullblock,count_bytes bs=65536 count=262145 status=none
```

`stat` **without** `-L` uses `lstat(2)`, so a symlink reports as `symbolic
link` rather than as whatever it points at. Type and size are settled before a
byte of content is read, and a refusal is free.

`dd` moves the guarantee into `open(2)`:

- `nofollow` is `O_NOFOLLOW` — if the path became a symlink after the `stat`,
  the kernel fails the open with `ELOOP`. There is no window in which a
  swapped-in link is followed.
- `nonblock` is `O_NONBLOCK` — a FIFO substituted for the same reason returns
  immediately instead of hanging.
- `count_bytes` with `count` is the byte ceiling, enforced by the reader rather
  than by trusting the size `stat` reported.

The ceiling is 256 KiB, matching the stdout cap. The read asks for one byte
past it so an oversized file is *observed*, not inferred from a length that
happened to land on the limit.

`core/FileReadJob.qml` is deleted. `FileView` now appears only in
`core/FileWriteJob.qml`, where it is used for atomic writes to one directory
the plugin owns — a write names its own destination, so none of the above
applies to it.

## Consequences

**The two steps are not redundant.** Step 1 produces the sentence the user
reads: *"path is a symbolic link, not a regular file."* Step 2 produces the
guarantee: even if step 1 was raced, the open refuses. A type check alone is
TOCTOU; open flags alone cannot explain themselves to a user. Both, or neither.

**`ExecPolicy` gained prefixed data arguments.** `dd`'s only way to name a file
is `if=<path>`, so `dataArgs` entries may now be `{ index, prefix }`. The
prefix is a literal the plugin authored; the policy strips it and applies every
existing path rule to what follows. Without this, `if=-rf` would read as
ordinary data because the argument starts with `i`.

**Two processes per file read instead of none.** Only two files are ever read
for content — `shell.json` and the plugin's own `baseline.json` — and
`CheckEngine` memoizes reads per scan, so this is four short-lived commands per
scan against a 120 s ceiling. Measured cost is in the low milliseconds.

**The allowlist got narrower at the same time.** `~/.config/hypr/` was on the
read allowlist and nothing read from it; those files are only ever measured
(`stat`, `sha256sum`). It was removed, leaving the Omarchy config directory and
the plugin's state directory.

**A residual risk is retired and a smaller one stated.** "Symlinks are not
resolved" becomes "paths are not canonicalized": a symlink at an allowlisted
path can no longer redirect a read, but a symlink in a *parent* directory is
still followed. Closing that needs canonicalization QML does not have, and it
requires write access to `~/.config/omarchy` — which is already enough to
change what the plugin reads by editing the file.

## Alternatives considered

**A bundled helper (`python3` with `os.open(O_NOFOLLOW)` + `fstat` +
`S_ISREG`).** This is the only option that reaches `fstat`-on-the-descriptor
regular-file validation, rather than `lstat`-before-plus-`O_NOFOLLOW`-during.
Rejected: it adds an interpreter dependency to a plugin that requires only what
a stock Omarchy install has, and it ships executable code where the current
answer ships an argv. The failure modes it would close beyond `dd` — a device
node at an allowlisted path — require root to create in a directory the user
owns, and are bounded by the byte ceiling regardless.

**`stat` alone, then `FileView`.** Rejected outright: that is a pure TOCTOU
check. It would have satisfied the letter of the finding and none of its
substance.

**`head -c` instead of `dd`.** Bounds bytes, has no `O_NOFOLLOW`. The byte
ceiling was the easy half of the finding.
