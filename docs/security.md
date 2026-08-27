# Security model

OmaPreflight runs inside `omarchy-shell`. The marketplace is explicit about
what that means:

> The marketplace validates listings, not plugin security. Plugins run
> unsandboxed.

There is no sandbox, no permission prompt, and no privilege boundary between
this plugin and the rest of the session. A defect here is a defect in the
user's desktop. This document states what the plugin is allowed to do, what
enforces each limit, and what remains a real risk after all of it.

Every invariant below is enforced in code and re-checked by `scripts/check`,
which fails the build when one regresses. A guard that only exists in prose is
not a guard.

---

## What OmaPreflight is

A read-only diagnostic. It answers "what would break if I update?" by asking
the system questions and reporting the answers.

It does not update anything, install anything, restore anything, downgrade
anything, or contact the network. Everything it learns stays on the machine
until the user chooses to share a report.

There is exactly one thing it does that is not a read — a named, runtime
Hyprland window rule so its own report window opens floating and centred. It is
spelled out in full in invariant 11 rather than buried, because a document that
claims "read-only" and then quietly does something else is worse than one that
does not make the claim.

## Trust boundaries

Four kinds of input cross into the plugin. Each is treated as untrusted.

| Source | Why it is untrusted | Handled by |
|---|---|---|
| **Command output** — `omarchy`, `hyprctl`, `pacman`, `systemctl`, `df`, `git` | Another program's stdout is data, and a future version can change its shape without warning | `parsers/*.js`, all parsing behind `parsers/Json.js` |
| **File contents** — `shell.json`, the plugin's own baseline | User-editable, and may be malformed, mid-write, or not a regular file at all | `core/FileReader.qml` + `core/ReadPolicy.js` + parsers |
| **Names and paths from disk** — plugin ids, plugin directories | Anyone who can create a directory chooses its name | `core/CommandRunner.qml` data-argument rules |
| **IPC calls** — `omarchy-shell p134c0d3.omapreflight …` | Any process running as the user can call it | `Service.qml` — the surface is read-only and takes no arguments |

The plugin's *own* source, its check definitions, and the literal argv it
builds are trusted. That is the line: anything OmaPreflight wrote is trusted,
anything it read is not.

---

## Enforced invariants

### 1. No shell, ever — CWE-78

Commands are argv arrays. There is no `sh -c`, no string concatenation into a
command, and no place where a shell could re-parse anything.

- Enforced in `core/CommandRunner.qml` (`shellBinaries` refusal list).
- Guarded by `scripts/check`: `no shell command construction`.

This makes classic OS command injection structurally impossible rather than
merely avoided. There is no quoting to get wrong because nothing is quoted.

### 2. Untrusted arguments are declared and validated — CWE-88, CWE-22

Removing the shell does not remove *argument* injection. A value the plugin did
not author becomes an option the moment it starts with a dash — `--upload-pack=…`
passed where a repository path was expected needs no metacharacters at all.

Any argv element sourced from outside the plugin must be declared:

```js
ctx.exec(["git", "-C", dir, "status", "--porcelain=v1"],
         { dataArgs: [2], allowedRoots: [ctx.paths.pluginsDir] }, cb)
```

A declared data argument must:

- not be empty;
- not begin with `-`;
- contain no control characters (including NUL);
- and, if it looks like a path: be absolute, contain no `..` segment, and sit
  inside one of `allowedRoots`.

Root matching is prefix matching **on a segment boundary**, so an allowlisted
`…/omarchy/plugins` is not satisfied by `…/omarchy/plugins-evil`. Traversal
detection is segment-wise, so a directory legitimately named `..config` is not
a false positive.

Checks should also place `--` before positional data where the target program
honours it. The leading-dash rule is what covers the programs that do not.

The scheme is opt-in-by-declaration rather than inferred, so `grep -rn dataArgs`
enumerates every point at which external input reaches a process.

### 3. One place starts a process, one place reads a file

`Process` may only be instantiated in `core/CommandJob.qml`. `FileView` may
only be instantiated in `core/FileReadJob.qml` (reads) and
`core/FileWriteJob.qml` (atomic writes). Both rules are checked structurally by
`scripts/check`, which fails if a site appears anywhere else.

This is what makes the rules above meaningful. A validation routine that can be
bypassed by declaring a `Process` somewhere else is documentation, not
security.

### 4. Never privileged — CWE-269

`sudo`, `pkexec`, `doas`, `su`, `run0` and `machinectl` are refused by name
before a process is created. A check that would need privilege returns
`SKIPPED` and documents the manual command for the user to run themselves.

This is why `recovery.snapshot-capability` reports snapshots as a mechanism
that exists rather than one OmaPreflight can use: `omarchy snapshot` advertises
`requires_sudo: true`, so the capability registry marks the route present and
the capability unavailable.

### 5. Reads are narrow and never recursive — CWE-22

`FileReader` carries an explicit allowlist of directory prefixes: the Omarchy
config directory and OmaPreflight's own state directory. There is no recursive
mode and no API to add one at runtime. `$HOME` is never walked. Two files are
ever read for content — `~/.config/omarchy/shell.json` and the plugin's own
`baseline.json`. The Hyprland config directory is deliberately *not* on the
list: those files are only measured (`stat`, `sha256sum` — size and hash, never
contents, §17.3), so read access to them would be wider than the catalog needs.

One directory is *listed* rather than read: `~/.config/omarchy/plugins/`, to
find plugins the shell silently refused. The listing is one level deep and the
bound is in the argv itself — `find <dir> -mindepth 1 -maxdepth 1 -type d` — so
"this is not a recursive scan" is visible in the command rather than resting on
a flag the reader has to know the meaning of. Names that come back are gated by
the plugin-id pattern before becoming a path.

### 5a. A read is opened no-follow, type-checked and byte-bounded — CWE-59, CWE-770

An allowlist of *names* cannot say what is at a name. A path inside a directory
the user owns can be replaced with a symlink to `~/.ssh/id_ed25519`, with a FIFO
that never returns a byte, or with a file that grew to a gigabyte since the last
scan. Quickshell's `FileView` — which the read path used until v0.1.1 — exposes
no open flags, no file-type check and no size cap, so none of those could be
closed at that layer.

Reads therefore go through the command path, in two steps (`core/ReadPolicy.js`):

| Step | Command | What it settles |
|---|---|---|
| 1 | `stat -c '%F\|%s' -- <path>` | Type and size. No `-L`, so a symlink reports as a symlink rather than as its target. A non-regular or oversized path is refused before a byte is read. |
| 2 | `dd if=<path> iflag=nofollow,nonblock,fullblock,count_bytes bs=65536 count=262145 status=none` | The read itself. `O_NOFOLLOW`, `O_NONBLOCK`, and a byte ceiling — enforced by the kernel and by the reader, not by trusting step 1. |

Step 1 is the diagnosis: it produces the sentence the user reads ("path is a
symbolic link, not a regular file"). Step 2 is the enforcement: if the path is
swapped between the two steps, `O_NOFOLLOW` fails the open with `ELOOP` rather
than following the link, and `O_NONBLOCK` means a substituted FIFO cannot hang
the scan. Neither step is sufficient alone, which is why both are there — there
is no window in which a swapped-in symlink is followed, because the refusal
happens inside the syscall.

The ceiling is 256 KiB, the same bound `CommandJob` puts on stdout. The read
asks for one byte past it, so "this file is too big" is observed rather than
inferred from a length that happened to land on the limit; a file that grew
after being measured is refused rather than half-parsed.

`dd` and `stat` are coreutils, alongside the `df` and `sha256sum` the plugin
already requires. Nothing is bundled and no interpreter is involved.

- Enforced in `core/ReadPolicy.js` (the policy and the argv) and
  `core/FileReader.qml` (the sequencing).
- Guarded by `scripts/check`: `FileView` may now only be instantiated in
  `core/FileWriteJob.qml`, the read command may only be built in
  `core/ReadPolicy.js`, and the open flags themselves are asserted.
- Specified by `tests/tst_ReadPolicy.qml`.

This invariant exists because the marketplace security review for the v0.1.0
submission found the earlier `FileView.text()` read unbounded and
un-type-checked. See [ADR-006](adr/ADR-006-reads-go-through-the-command-path.md).

### 6. Bounded work — CWE-770

Unbounded resource use inside a shell process is a desktop that stops
repainting, so every axis is capped:

| Axis | Limit | Where |
|---|---|---|
| stdout per command | 256 KiB, enforced while the stream arrives | `CommandJob` |
| stderr per command | 64 KiB | `CommandJob` |
| Bytes per file read | 256 KiB, refused at `stat` and again by `dd`'s byte count | `ReadPolicy` |
| Command lifetime | per-command timeout, then SIGTERM → SIGKILL → abandon | `CommandJob` |
| Check lifetime | per-check watchdog beyond the command budget | `CheckEngine` |
| Scan lifetime | 120 s ceiling; the scan then reports itself incomplete | `CheckEngine` |
| Concurrency | exactly one process at a time | `CommandRunner` |
| Overlapping scans | refused, not queued | `CheckEngine` |

The output caps are enforced *during* collection, not after, so a runaway
command is stopped rather than buffered.

### 7. No dynamic code — CWE-94

No `eval`, no `new Function`, no `Qt.createQmlObject`, no `Qt.include`. Every
string the plugin holds came from another program's output, and none of it is
ever executed. Guarded by `scripts/check`.

`JSON.parse` is the only deserializer used. It cannot construct objects or
invoke code (unlike, say, a language-level unpickler), and its output is
treated as an untyped bag: parsers read fields defensively and coerce types
rather than assuming a shape (CWE-502 by construction).

### 8. No network — and nothing to exfiltrate through

The MVP makes no network requests of any kind. `git` is only ever invoked with
local, read-only subcommands; nothing fetches, and no remote is contacted.
Guarded by `scripts/check`.

### 9. Errors are results, not exceptions — CWE-703

Every failure path produces a check result. Parser exceptions are contained,
command failures become `UNKNOWN`, missing capabilities become `SKIPPED`, and a
scan that did not complete yields readiness `UNKNOWN` rather than a partial
verdict presented as a full one. A plugin that throws inside the shell is a
plugin that can take the desktop down with it.

### 10. Writes stay in one directory

The only writable location is
`${XDG_STATE_HOME:-~/.local/state}/omapreflight/`. Nothing is written into the
plugin checkout, nothing under `/usr/share/omarchy` is touched, and no
configuration file is ever modified — `shell.json` and the Hyprland configs are
opened read-only.

### 11. One action is not a read, and it is bounded

The diagnostic surface is a real window (ADR-005), which is what makes
`SUPER`+drag move it like anything else on the desktop. A Wayland client cannot
ask to be floating, so the service registers a Hyprland window rule once per
shell session:

```lua
hl.window_rule({
  name  = "omapreflight-window",
  match = { class = "^org.quickshell$", title = "^OmaPreflight$" },
  float = true, center = true
})
```

handed to `hyprctl eval`, because Omarchy configures Hyprland through the Lua
parser and `hyprctl keyword` refuses to work with it.

Passing a string to another process to evaluate deserves scrutiny, so:

- **the string is a literal.** Nothing from the environment, a file, or another
  command's output is interpolated into it. There is no input to inject. This
  is the property that makes it defensible, and it is asserted at the point the
  string is built in `Service.qml`;
- **it is scoped** by class *and* title to this plugin's own window;
- **it is named**, so re-registering replaces the rule rather than accumulating
  rules;
- **it is runtime-only** — no file is written, no user configuration is
  touched, and the rule disappears when the compositor restarts;
- **it is optional.** If it fails, the window still opens and works, tiled
  rather than floating, and the reason is logged once.

If a future change ever needs to interpolate a value into that string, it
should not. Add a check that refuses instead.

---

## Information exposure — CWE-200

Two paths carry collected data outward, and they are the ones worth thinking
hardest about.

**Diagnostic reports.** A report is written locally and shared only if the user
chooses to. It is sanitized first — home paths, hostnames, usernames,
addresses, and lines containing obvious secret-shaped key names — and it
carries a header saying to review it before posting. Sanitization is
best-effort by nature and the report says so; claiming it is complete would be
the actual security failure.

**IPC.** `status` and `results` return what the scan collected to any process
running as the same user. Quickshell's IPC socket has no authentication and
cannot be given any. The mitigation is scope, not access control: everything
returned is derived from commands and files that the same process could run and
read directly. The IPC surface adds convenience, not privilege.

## Residual risks

Stated plainly, because a security document that lists only solved problems is
not describing reality.

- **Paths are not canonicalized.** There is still no `realpath` available to
  QML, so the allowlist match is on the path as written. What that no longer
  buys an attacker is the read itself: a symlink at an allowlisted path is
  refused by `stat` and, if it appears after that, by `O_NOFOLLOW` at the open
  (invariant 5a). A symlink in a *parent* directory of an allowlisted path is
  still followed — closing that would need canonicalization QML cannot do, and
  it requires write access to `~/.config/omarchy` or `~/.local/state`, which is
  already enough to change what the plugin reads by simply editing the file.
- **`PATH` is inherited.** Binaries are resolved through the session's `PATH`
  rather than pinned to absolute paths. This is deliberate: a diagnostic tool
  must report on the installation the user actually has, including one placed
  by `omarchy dev link`. An attacker who can write to a directory on the user's
  `PATH` already has code execution as that user, so pinning would buy little
  and cost correctness.
- **Environment is inherited.** Children inherit the session environment plus
  `LC_ALL=C`. `LD_PRELOAD` and friends are not stripped; if they are hostile,
  the session is already compromised.
- **Sanitization is heuristic.** It catches the shapes it knows. Review before
  posting.
- **TOCTOU.** State can change between a check reading it and the user acting
  on the report. This is inherent to diagnostics and is why every finding
  carries a timestamp and its evidence.

## Reviewing a change

The questions worth asking, in order:

1. Does it introduce a `Process` outside `core/CommandJob.qml`, or a `FileView`
   outside `core/FileWriteJob.qml`?
2. Does any argv element come from command output, a file, or a directory
   listing? If so, is it declared in `dataArgs` with the right `allowedRoots`?
3. Does it widen `FileReader.allowedPrefixes`, and does it need to?
4. Does it read a file any way other than through `FileReader` — that is,
   without the no-follow open, the type check and the byte ceiling?
5. Can it produce unbounded output, an unbounded loop, or an unbounded number
   of commands?
6. Does every new failure path end in a check result?
7. Does anything new reach the report, and is it sanitized?

`scripts/check` answers 1 mechanically and part of 4. The rest need eyes.

## Reporting a vulnerability

See [SECURITY.md](../SECURITY.md).

## References

The rules above are the local application of general guidance, not invented
here:

- [OWASP OS Command Injection Defense Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/OS_Command_Injection_Defense_Cheat_Sheet.html)
  — argv separation, allowlisting, the `--` separator.
- [2025 CWE Top 25](https://cwe.mitre.org/data/definitions/1435.html) — CWE-22
  path traversal, CWE-78/77 command injection, CWE-94 code injection, CWE-200
  information exposure, CWE-502 untrusted deserialization, CWE-770 unbounded
  resources.
- [OWASP Path Traversal](https://owasp.org/www-community/attacks/Path_Traversal)
  — normalize, then validate against known-good roots.
- [OpenSSF argument injection lab](https://best.openssf.org/labs/argument-injection.html)
  — leading-dash rejection and the `--` separator.
- [Omarchy plugin publishing requirements](https://omarchyplugins.com/publish)
  — the unsandboxed-execution statement this document responds to.
