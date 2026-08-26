# Privacy

OmaPreflight is a local diagnostic. Nothing it learns leaves your machine
unless you choose to share it.

There is no network code in the plugin at all — no telemetry, no update check,
no crash reporting, no remote fetch. `scripts/check` fails the build if any
appears. `git` is used only for local, read-only queries; nothing fetches and
no remote is contacted.

## What it collects, and where each thing comes from

Everything below stays in memory during a scan, and reaches disk only if you
record a baseline or save a report.

| Collected | Source |
|---|---|
| Omarchy version and release channel | `omarchy version`, `omarchy channel current` |
| Quickshell version | `pacman -Qo /usr/bin/quickshell` |
| Hyprland version, binding count, submap names | `hyprctl version`, `hyprctl binds -j` |
| Monitor names, resolutions, refresh rates, scale | `hyprctl monitors -j` |
| Hyprland config errors, if any | `hyprctl configerrors` |
| Whether six named Hyprland config files exist, and their size, mtime and SHA-256 | `stat`, `sha256sum` |
| Whether `shell.json` parses, its schema version, bar layout size, and a change fingerprint | reading `~/.config/omarchy/shell.json` |
| Installed plugin ids, names, kinds, enabled state, first-party flag | `omarchy plugin list --json` |
| Whether each third-party plugin validates | `omarchy plugin validate <dir>` |
| Uncommitted-change counts and commit ids in plugin checkouts | `git -C <dir> status`, `git -C <dir> rev-parse HEAD` |
| Names of failed systemd user units | `systemctl --user --failed` |
| Free space and mount points for `/` and your home | `df -Pk` |
| Root filesystem type | `findmnt -n -o FSTYPE -- /` |

That is the complete list. The [check catalog](check-catalog.md) says which
check each line belongs to.

## What it never collects

Not "does not currently" — there is no code path that could:

- **the contents of any file.** `shell.json` is parsed for its structure and
  then discarded; the Hyprland config files are only ever hashed. A baseline
  records a hash, never a line;
- anything outside `~/.config/omarchy/`, `~/.config/hypr/`, and OmaPreflight's
  own state directory. There is no recursive scan and no API to add one;
- browser history, passwords, SSH keys, auth tokens, `.env` files, project
  source, shell history, clipboard contents, notification contents, personal
  documents, Wi-Fi credentials, or DBus secrets;
- your username, hostname or IP address as a deliberate act — they can appear
  incidentally in command output, which is what the report sanitizer is for.

## What reaches disk

Two files, both under `${XDG_STATE_HOME:-~/.local/state}/omapreflight/`, in a
directory created with mode `0700`:

**`baseline.json`** — written only when you ask for it (`B` in the report
window, or the IPC `baseline` method). Metadata only: versions, fingerprints,
hashes, sizes, mtimes, plugin ids and commit ids. The builder enumerates the
fields it will write, so "metadata only" is a property of the code rather than
of every caller remembering.

**`reports/<timestamp>.md`** — written only when you ask for it (`S`, or the
`report` method). Sanitized, and stamped with a line telling you to review it
before posting.

Nothing else is written. Not into the plugin checkout, not into your Omarchy or
Hyprland configuration, not anywhere under `/usr/share/omarchy`. No
configuration file is ever modified.

## Sanitization

A report replaces, at minimum:

- your home path with `~`, and other users' home directories with `/home/<user>`
- your username and hostname where they appear as words
- email addresses, UUIDs, MAC and Bluetooth addresses
- IP addresses, except loopback and the unspecified address, which carry no
  identity and are frequently the point of a finding
- `/run/user/<uid>` and temporary paths
- the value on any line whose key name advertises a secret — `token`,
  `password`, `api_key`, `Authorization`, and similar

Path components are not treated as key names, so a directory called
`/home/bob/secret` survives intact. Over-redaction is not the safe side of this
trade-off: a report that eats its own diagnostic content is a report people
stop sanitizing.

**Sanitization is pattern matching and cannot be complete.** Every report says
so, in the header and again at the end. Read it before you post it.

## What other processes on your machine can see

The plugin answers IPC on `p134c0d3.omapreflight`, and Quickshell's IPC socket
has no authentication — any process running as you can call it, including
`status` and `results`.

The mitigation is scope rather than access control: everything those methods
return is derived from commands and files the same process could run and read
directly. The IPC surface adds convenience, not privilege. It takes no
arguments and executes nothing arbitrary.

## The one thing that is not a read

OmaPreflight registers a Hyprland window rule at runtime so its report window
opens floating and centred — the one thing a Wayland client cannot ask for
itself. It is scoped by class and title to this plugin's own window, written to
no file, and gone when the compositor restarts. It is described in full in
[security.md](security.md) and in
[ADR-005](adr/ADR-005-window-not-layer-surface.md).

## Verifying any of this

None of the above requires trust:

```bash
grep -rn "dataArgs" checks/          # every point external input reaches a process
grep -rn "ctx.exec" checks/          # every command the catalog runs
grep -rn "readFile\|allowedPrefixes" # every file it may read
scripts/check                        # fails if a network call or a shell appears
```

The plugin is a few thousand lines of QML and JavaScript with no build step and
no binaries. It is meant to be read.
