# Optional pre-update checklist

`omapreflight update` is an optional terminal entry point to the normal Omarchy
updater. With auto-run enabled, it shows the full diagnostic checklist before
continuing. With auto-run disabled, it goes directly to Omarchy without scanning
or contacting the plugin.

**This does not intercept `omarchy update` or Omarchy's update button.** The
installed Omarchy has no native pre-update hook. No PATH override or system
package modification is installed. The design is recorded in
[ADR-008](adr/ADR-008-optional-update-gate.md).

## Setup

Update the plugin to a commit containing the terminal companion. Python 3 is
required. Install the dedicated launcher once:

```bash
mkdir -p "$HOME/.local/bin"
ln -s "$HOME/.config/omarchy/plugins/p134c0d3.omapreflight/scripts/omapreflight" "$HOME/.local/bin/omapreflight"
```

If that name already exists, inspect it rather than overwriting it. The symlink
keeps using the installed plugin's script after plugin updates. If `~/.local/bin`
is not on PATH, use `~/.local/bin/omapreflight` explicitly. Developers can run
`scripts/omapreflight` directly from the repository.

Plugin activation and auto-run are separate settings:

```bash
omarchy plugin enable p134c0d3.omapreflight
omapreflight auto-run enable
omapreflight auto-run status
```

The plugin must be running to perform a scan. Turning auto-run off does not
disable the bar widget or manual scans. Disabling the plugin does not turn
auto-run off: an enabled gate with an unavailable service stops the update.

## Commands

| Command | Behavior |
|---|---|
| `omapreflight auto-run enable` | Persistently enable the gate for the companion. |
| `omapreflight auto-run disable` | Persistently disable it; the default on a fresh install. |
| `omapreflight auto-run status` | Print the current preference and its scope. |
| `omapreflight pre-update` | Run the optional gate without launching an update. An accepted gate saves its pre-update record. |
| `omapreflight pre-update -y` | Test the gate without prompts or an update. REVIEW stops. |
| `omapreflight update` | Run the optional gate, then the normal Omarchy updater. |
| `omapreflight update -y` | Run without preflight prompts; if accepted, pass `-y` to Omarchy. |

Help is available with `omapreflight --help` and each command's `--help`.

## Checklist and continuation

Every check is printed, including PASS and SKIPPED. WARN, FAIL, UNKNOWN and
SKIPPED include available details and remediation. Informational findings are
marked explicitly.

| Outcome | What happens |
|---|---|
| READY | Save the checklist/baseline and continue automatically. |
| REVIEW | Ask whether to continue; the default answer is no. |
| NOT RECOMMENDED / blocker | Stop. |
| Incomplete, cancelled, replaced, timed-out or unavailable scan | Stop. |
| REVIEW with `-y` or noninteractive input | Stop without asking. |

The companion acquires Omarchy's update lock before scanning and keeps it while
you review the checklist. Only its own scan can be cancelled by its cleanup
handler. After acceptance, Omarchy handles its normal confirmation, snapshot,
network access, package updates, migrations, and restart decisions. Preflight
does not replace Omarchy's confirmation or snapshot handling.

The checks describe the current system. They do not fetch the proposed package
versions or prove that those versions will work. Automatic postflight is not
implemented yet.

## Saved state

Files live in `${XDG_STATE_HOME:-~/.local/state}/omapreflight/`:

- `update-settings.json`: the enabled flag and schema version.
- `pre-update.json`: the most recently accepted scan's sanitized checklist,
  scan metadata, and metadata baseline. It replaces the previous pre-update
  record and leaves the manual `baseline.json` unchanged.

Both files are written atomically with mode `0600`. If the pre-update record
cannot be saved, continuation stops. A record proves only that preflight was
accepted, not that an update ran or succeeded. Test-only `pre-update` can create
one too. Sanitization is best effort; review the file before sharing it.

The native `${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock` is opened separately.
It is released when the command exits, but the file stays in place. Do not delete
it to try to bypass an active update.

## Troubleshooting

| Message or behavior | Next step |
|---|---|
| Service unavailable | Enable the OmaPreflight plugin. After a development deployment, restart the shell so the new service IPC is loaded. |
| A scan is already busy | Let it finish or cancel it in the plugin, then retry. The gate requires a fresh scan it owns. |
| Plugin validity is UNKNOWN because the cap was reached | Read the coverage note. The current scan validates at most 12 plugin directories; unchecked plugins are not considered safe. REVIEW requires an interactive decision. |
| Baseline comparison is incomplete | Inspect the missing evidence named in the checklist. Missing facts are not proof that nothing changed. |
| Unrecognized update settings | Inspect `update-settings.json`, or explicitly reset the preference with `auto-run enable` or `auto-run disable`. Malformed settings never silently bypass the gate. |
| Another update is running | Wait for it to finish; the gate does not bypass the native lock. |
| A normal Omarchy update did not show preflight | Use `omapreflight update`; the ordinary command and button are outside this integration's scope. |

To opt out, run `omapreflight auto-run disable`. To remove the launcher, remove
the symlink you installed at `~/.local/bin/omapreflight`. Plugin removal leaves
its state files behind for you to retain or delete.
