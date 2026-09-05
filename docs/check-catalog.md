# Check catalog

Every check OmaPreflight runs, what it actually does, and what each outcome
means. `scripts/check` fails if a check exists in the code and not in this
table, or the other way round — a catalog that drifts from the code is worse
than no catalog.

Twenty-one checks across six categories. Every one of them is a read.

## How to read the outcomes

| Status | Means |
|---|---|
| `PASS` | The check ran and found nothing wrong. |
| `WARN` | Worth reading before you update. Rarely a reason not to. |
| `FAIL` | Something is wrong now. With severity `blocker`, readiness becomes NOT RECOMMENDED. |
| `UNKNOWN` | The check ran and could not establish the answer. Not a pass. |
| `SKIPPED` | The check does not apply here — usually a missing capability. Never affects readiness. |

A check is **material** if a `WARN` or `UNKNOWN` from it should pull readiness down to
REVIEW. Informational checks are not material: failing to read the Quickshell
version is not a reason to hesitate before updating, and treating it as one
would train people to ignore the verdict.
`FAIL` always affects readiness, even for an informational check; a blocker
failure always produces NOT RECOMMENDED. See [ADR-007](adr/ADR-007-informational-warnings.md).

---

## environment

What OmaPreflight is standing on. These run first because the rest of the
catalog is capability-gated on what they establish.

### `environment.omarchy-present`
Confirms the Omarchy CLI responds. **Blocker** — the only one in this category.
If `omarchy` cannot be reached, `omarchy update` is not a thing that can be run
at all, which is a genuine "do not proceed" rather than a caveat.
*Runs:* `omarchy commands --json` (shared with the capability probe).

### `environment.command-discovery`
Reads the CLI's own command catalog, which decides which checks are allowed to
run at all. Material: without it, every capability-gated check degrades, so the
scan genuinely knows less than it should.
*Requires:* `omarchy.cli`.

### `environment.hyprland-present`
Confirms the Hyprland control socket is reachable. `WARN` when it is not, with
a note that this is expected outside a Hyprland session.
*Runs:* `hyprctl version`.

### `environment.quickshell-version`
Records the Quickshell version. Informational, not material — and the single
most useful line in a shell bug report. Quickshell does not expose its own
version to QML, so the package database is the only safe source; asking which
package owns the binary avoids guessing a package name.
*Runs:* `pacman -Qo /usr/bin/quickshell`.

---

## omarchy

### `omarchy.version`
Records the installed version. Anchors the baseline comparison and every bug
report.
*Runs:* `omarchy version`. *Requires:* `omarchy.version`.

### `omarchy.channel`
Records the release channel. A non-stable channel is reported with a note that
changes arrive earlier and with less soak time — channel changes readiness
*context*, never the verdict by itself. A channel name this version does not
recognise is `UNKNOWN` and not material: the channel list is Omarchy's to grow.
*Runs:* `omarchy channel current`. *Requires:* `omarchy.channel`.

### `omarchy.shell-config-readable`
Reads `~/.config/omarchy/shell.json` and confirms it parses. Absence is a
`PASS` — Omarchy runs on defaults. A present file that does not parse is a
`FAIL`, because the shell silently falls back to defaults and the bar will not
be what you expect. The file is never modified.

### `omarchy.shell-config-version`
Checks the schema version against what this plugin understands. A **newer**
schema is `UNKNOWN`, never "corrupt" — being ahead of this plugin is Omarchy's
prerogative.

---

## hyprland

Read-only compositor queries. No keyword is ever dispatched, no config is
reloaded, and no Lua is parsed — deciding whether a binding is semantically
reachable is deferred, because there is no reliable evidence source for it.

### `hyprland.config-errors`
Asks the running compositor whether it is reporting configuration errors.
Non-empty output is a `FAIL`. Hyprland 0.56.2 prints blank lines when clean,
and treating those as content would produce a phantom failure on every scan.
*Runs:* `hyprctl configerrors`. *Requires:* `hyprland`.

### `hyprland.live-bindings`
Counts active bindings. Evidence for the baseline comparison. Not material.
*Runs:* `hyprctl binds -j`. *Requires:* `hyprland`.

### `hyprland.live-monitors`
Records the output layout: name, resolution, refresh rate, scale. **Not** the
`description` field, which carries the panel's serial number and has no place
in a diagnostic report. Not material.
*Runs:* `hyprctl monitors -j`. *Requires:* `hyprland`.

### `hyprland.user-config-presence`
Records which of six named Omarchy Hyprland config files exist, and their size,
mtime and SHA-256 — **never their contents**. An explicit, closed list; there is
no directory walk. Absence is normal and reported as such. Not material.
*Files:* `hyprland.lua`, `bindings.lua`, `monitors.lua`, `input.lua`,
`looknfeel.lua`, `autostart.lua`.
*Runs:* `stat -c '%s %Y %n' -- <paths>`, `sha256sum -- <paths>`.

---

## plugins

The first checks whose commands take a value OmaPreflight did not author. A
plugin id is a directory name anyone can create, and it becomes both a path and
an argv element — so each is declared as a data argument with an allowed root,
and the id's shape is checked before it becomes a path at all. See
[security.md](security.md).

At most **12** third-party plugins are inspected per scan, to stay inside the
scan's time ceiling. When that cap bites, the result says so.

### `plugins.discovery`
Reads the plugin inventory. Reports totals by provenance and enabled state.
*Runs:* `omarchy plugin list --json`. *Requires:* `omarchy.pluginList`.

### `plugins.third-party-validation`
Compares the plugin directories on disk against the plugins the shell actually
loaded, then validates both what is missing from that list and what is on it.

This is the check most likely to tell you something you did not know. The
shell's `PluginRegistry` drops a plugin with an invalid manifest during
discovery, warns **once** into the shell log, and carries on — so the plugin
disappears from every menu, every list, and the plugin manager itself, with no
explanation anywhere the user is looking. Validating only the plugins the CLI
reports would never find it: everything on that list has already passed the
same validator.

Two distinct failures, both reported as `FAIL`:

- **installed but not loaded** — a directory on disk that the shell refused.
  The result says so explicitly, because "your plugin is silently gone" is a
  different problem from "your plugin has a bug";
- **listed but invalid** — the manifest is well formed enough for discovery,
  but the validator rejects it. A missing entry-point file lands here.

One broken plugin never stops the rest. Directory names that are not usable
plugin ids are reported as ignored rather than silently skipped.
If directory listing fails, the plugin cap is reached, a name is unusable, or
a validation command cannot complete, the result is `UNKNOWN` unless another
plugin has a confirmed validation failure (`FAIL`). Partial coverage never
produces `PASS`.
*Runs:* `find <plugins> -mindepth 1 -maxdepth 1 -type d -printf '%f\n'` — a
single level, bounded in the argv itself — then `omarchy plugin validate <dir>`
per plugin, 15 s each.
*Requires:* `omarchy.pluginList`, `omarchy.pluginValidate`.

### `plugins.local-changes`
Reports uncommitted changes in git-managed plugin checkouts. `WARN`, and **not
material** — local edits are a fact about the machine, not a fault. This exists
to explain why `omarchy plugin update` might refuse to fast-forward. Nothing
fetches and no remote is contacted.
*Runs:* `git -C <dir> status --porcelain=v1`, `git -C <dir> rev-parse HEAD`.

---

## runtime

### `runtime.failed-user-units`
Lists systemd user units in a failed state. `WARN`, not a blocker: knowing a
unit was already failing is what stops the update being blamed for it later.
*Runs:* `systemctl --user --failed --no-legend --no-pager` (shared with the
capability probe). *Requires:* `systemd.user`.

### `runtime.disk-space-root`
Free space on the root filesystem, where packages land.

### `runtime.disk-space-home`
Free space on the filesystem holding your home directory, where reports and
baselines land. Checked separately from root because the two are frequently
separate filesystems that fill for different reasons.

Both use the same thresholds:

| Free space | Outcome |
|---|---|
| under 2 GiB | `FAIL`, severity **blocker** |
| under 5 GiB | `WARN` |
| otherwise | `PASS` |

The thresholds are fixed and conservative. They are **not** an estimate of what
an update needs — nothing here can know that, and claiming otherwise would be
the kind of invented heuristic this project refuses to ship. They exist to
catch "this machine is nearly full", which is a real and common reason an
update goes badly.
*Runs:* `df -Pk -- <path>`.

---

## recovery

What you could fall back to. The theme running through all three is refusing to
overstate.

### `recovery.snapshot-capability`
Reports whether a snapshot mechanism appears to exist. It does not — and cannot
— confirm a usable snapshot is present: `omarchy snapshot` advertises
`requires_sudo: true`, so OmaPreflight can see the mechanism and can never
exercise it. On btrfs with the route present it reports "snapshots look
possible" and tells you to confirm with `snapper list` as root. It never
reports "snapshots available". Not material.
*Runs:* `findmnt -n -o FSTYPE -- /`.

### `recovery.baseline-present`
Reports whether a baseline has been recorded. Absent is `UNKNOWN` and
deliberately **not material** — it is the state every machine starts in, and
turning a fresh install into REVIEW would cost more in ignored verdicts than
the missing baseline does. The remediation says how to record one.

### `recovery.version-baseline-match`
Compares the current system against the baseline: versions, the shell.json
fingerprint, config file hashes, and plugin git heads.

Moving *forward* is what an update is for, so a newer version is reported and
not warned about. Moving *backward* is `WARN` — that usually means a rollback,
and it changes what the rest of the report means. When the two versions cannot
be meaningfully ordered, the result says so rather than guessing.
`SKIPPED` when there is no baseline. Not material.
Missing versions, inventories, file hashes, or previously recorded git revisions
produce an incomplete comparison (`UNKNOWN`). Confirmed changes still appear
in the details. “Nothing has changed” requires complete comparison evidence.

---

## Deliberately not implemented

These are listed so their absence reads as a decision rather than an oversight.
None of them has a reliable evidence source, and shipping a guess dressed as a
check is worse than shipping nothing:

ABI compatibility prediction · "this update will break Qt" · dependency graph
simulation for AUR packages · parsing arbitrary Hyprland Lua to prove every
`require()` · proving every keybinding is semantically reachable · kernel module
compatibility · NVIDIA driver forecasting · mirror sync reputation ·
crowdsourced known-bad updates.
