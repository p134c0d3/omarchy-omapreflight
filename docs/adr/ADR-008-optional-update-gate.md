# ADR-008: An optional terminal gate before Omarchy update

Status: accepted for the initial companion, 2026-09-04.

## Context

The user requested an enable/disable setting for automatically running the full
checklist before an update, continuing when accepted. On installed Omarchy 4.0.2,
`bin/omarchy-update` has no pre-update hook. Its post-update hook runs before AUR
and other remaining stages, and the hook runner swallows failures. The unified
CLI dispatches through absolute paths, so shadowing only `omarchy-update` would
not cover `omarchy update`.

## Decision

Provide an optional Python 3 companion: `omapreflight auto-run enable|disable|status`,
`omapreflight update [-y]`, and `omapreflight pre-update [-y]`. Auto-run defaults
to off. Disabled mode never contacts the service. Enabled mode requires the
plugin running; it does not enable the plugin or start another Quickshell.

No PATH overrides, update-button modifications, package hooks, or changes under
`/usr/share/omarchy` are installed. A dedicated symlink in `~/.local/bin` is an
optional installation step. Ordinary update entry points remain unchanged.
This is the first attachment point, not a claim of native interception.

The companion holds `${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock` throughout
preflight and passes its FD to the updater as `OMARCHY_UPDATE_LOCK_FD`, following
the installed updater's contract. The transcript launcher was verified to retain
that descriptor. The lock prevents concurrent normal updates during preflight.

## Gate policy

Each invocation owns a fresh scan ID. Polling and the final `updateSnapshot`
response must match it. The snapshot contains all expected results, sanitized
with the report sanitizer, and the metadata baseline in one synchronous IPC
response. Replaced, cancelled, incomplete, malformed, or unavailable scans stop.
`cancelScan` compares the expected ID atomically before cancelling.

READY continues. REVIEW needs explicit interactive acceptance. Blockers and
UNKNOWN stop. `-y` and noninteractive input never authorize REVIEW. Informational
findings remain visible. The companion also checks result severities/materiality
before accepting a READY payload.

A private atomic `pre-update.json` preserves the accepted checklist and baseline
before handoff; write failure stops continuation. The manual baseline is unchanged.
This file means "preflight accepted", not "update completed". Postflight and
update completion tracking remain future work.

## Safety boundary changes

QML diagnostics retain their existing command/file wrappers. The separate
terminal companion uses one bounded Python IPC adapter (5 seconds, 512 KiB total
output), a 130-second scan deadline, no-follow regular-file settings reads
(8 KiB), and private atomic state writes (512 KiB). It uses the standard library
only and makes no network requests.

Its only non-state file write is the native update lock: a narrow exception to
the original plugin-only policy needed to serialize the requested update entry
point. The lock is not unlinked on release, preserving inode-based exclusion.

The final `execv` delegates the explicit update to Omarchy with argv intact.
Omarchy owns its privileges, network activity, interaction, and package handling.
Never apply a diagnostic timeout to the updater or kill it as a timed-out check.
The companion itself runs no privileged helpers or package commands.

## Limits

This scans the current system; it adds no pending-version fetch or compatibility
forecast. Automatic postflight and a headless engine are not implemented.
An upstream native pre-hook is separate follow-up work. Direct updater
invocations bypass the companion. `pre-update` is a standalone gate test, not
an installed native hook.
