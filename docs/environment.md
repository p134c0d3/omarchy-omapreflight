# Verified environment

Everything here was measured on the target machine, not assumed. The engineering
spec (§9.1, §35) requires the installed system to outrank remembered API syntax,
so this file records what was actually observed and how to re-verify it.

Last verified: **2026-08-24**

| Component | Version | How to re-check |
|---|---|---|
| Omarchy | `4.0.0-1` | `omarchy version` |
| `$OMARCHY_PATH` | `/usr/share/omarchy` | `echo $OMARCHY_PATH` |
| Quickshell | `0.3.0` (AUR `quickshell-git`, rev `28771c7c`) | `qs --version` |
| Hyprland | `0.56.2` | `hyprctl version` |
| Qt | `6.11.2` (`qt6-declarative`) | `pacman -Q qt6-declarative` |
| `jq` | `/usr/bin/jq` | required by `omarchy plugin validate` |

## Runtime facts that shaped the design

### Terminal update gate verification — 2026-09-04

The companion was tested on Omarchy `4.0.2-1`, Quickshell `0.3.1-1`, and
Hyprland `0.56.2`. The earlier table records the original architecture spike;
these are the later integration observations:

- The installed updater has no pre-update hook. Its post-update hook precedes
  the AUR stage and cannot stand in for a final postflight.
- The unified CLI resolves its updater by absolute path.
- The native lock is `${XDG_RUNTIME_DIR:-/tmp}/omarchy-update.lock`, with its FD
  carried in `OMARCHY_UPDATE_LOCK_FD`. The installed updater recognizes the FD
  inherited from the companion, and the transcript launcher preserves it.
- The live service returned all 21 checks in a scan-specific snapshot and
  refused stale snapshot/cancellation IDs. Unattended REVIEW stopped; accepting
  REVIEW in test-only mode wrote the private pre-update record.
- Updater handoff was tested with a fake updater. No actual package update was
  performed during verification.

See [the usage guide](update-integration.md) and
[ADR-008](adr/ADR-008-optional-update-gate.md).

### Tooling is not on `PATH`

`qmllint` and `qmltestrunner` ship with `qt6-declarative` but live in
`/usr/lib/qt6/bin`, which is not on `PATH`. `scripts/check` uses the absolute
path.

### `qmllint` needs a `qs` import shim

`qmllint -I "$OMARCHY_PATH/shell"` — the invocation the spec suggests — does
**not** resolve `qs.Ui` / `qs.Commons`. Quickshell maps the shell *config root*
to the `qs` namespace, so the import root must itself contain an entry named
`qs`:

```bash
SHIM=$(mktemp -d); ln -sfn /usr/share/omarchy/shell "$SHIM/qs"
/usr/lib/qt6/bin/qmllint -I "$SHIM" -I /usr/lib/qt6/qml *.qml
```

The shim must be built **outside** the repository: `omarchy plugin validate`
rejects a symlink anywhere inside the plugin folder.

### Expected lint noise

`Style.font.*`, `Color.menu.*` and `Style.spacing.*` produce
`Member "..." not found on type "QObject"` warnings. This is a static-analysis
limit on QML singletons, not a defect: two first-party Omarchy files produce 134
of the same warnings under the same harness. `qmllint` still exits 0.

### Services are mounted once — but their code is cached

`shell.qml:_syncServices()` mounts exactly one instance per plugin id and
destroys it on disable, removal, or reload. Verified: one `service mounted` line,
and reloads produce balanced unmount/mount pairs with no duplicates.

**However**, editing `Service.qml` and saving does *not* take effect on hot
reload. The instance is destroyed and rebuilt, but from a cached component — the
new source keeps running the old code until the shell process restarts. Verified
by changing a log string and observing the previous string still emitted after
several reloads. `scripts/dev-install` therefore restarts the shell.

### Injected properties are not available in `Component.onCompleted`

The shell creates the object first and assigns `manifest` / `shell` afterwards.
Anything depending on the manifest must wait for `onManifestChanged`. Note also
that dependent bindings have not necessarily re-evaluated when that handler
runs, so read `manifest.version` directly rather than a property bound to it.

### Enabling a multi-kind plugin writes one entry

A plugin declaring `["service", "bar-widget", "overlay"]` is recorded **only** in
`bar.layout.<section>` — not in `plugins[]`. The service still mounts, because
`isEnabled()` is satisfied by the plugin id appearing anywhere in `shell.json`.

### Declaring `overlay` changes IPC routing

`shell.qml:isBarWidgetPanelPlugin()` returns false for any plugin that also
declares `panel`/`overlay`/`menu`. So
`omarchy-shell shell toggle p134c0d3.omapreflight` opens the **overlay**, not the
bar widget's quick panel. The quick panel opens by clicking the widget.

### One `IpcHandler` per target

The shell warns and drops a second handler registered on the same target. The
service owns `p134c0d3.omapreflight`; the bar widget leaves `ipcTarget` unset so
`qs.Ui.Panel`'s built-in handler stays disabled.

### `omarchy plugin list --json` is thin

Fields are `id, name, kinds, enabled, active, canDisable, firstParty,
clonedFrom`. There is no source directory and no version, so checks that need
either must resolve `~/.config/omarchy/plugins/<id>/manifest.json` themselves.

### Layer surfaces and blur

An overlay's `WlrLayershell.namespace` determines whether the compositor blurs
behind it, and blur rules name first-party namespaces explicitly. See
[ADR-004](adr/ADR-004-theming-and-layer-legibility.md).

### A bar widget must forward its implicit size

`Bar.qml` sizes each slot from the widget root's implicit size
(`implicitWidth: activeItem.implicitWidth`). A `qs.Ui.Panel` root whose button is
anchored with `anchors.fill: parent` therefore reports zero width and renders
nothing at all — with no warning in the log. Forward it explicitly, as the
first-party widgets do:

```qml
implicitWidth: button.implicitWidth
implicitHeight: button.implicitHeight
```

### Overlay placement is single-screen

A bare `PanelWindow` renders on one output and follows focus between monitors.
First-party overlays behave the same way. Multi-monitor mirroring would need
`Variants` over `Quickshell.screens`.
