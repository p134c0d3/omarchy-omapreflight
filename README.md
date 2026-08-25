# OmaPreflight

**Know what an update will break — before you run it.**

OmaPreflight is an Omarchy-aware change-intelligence plugin. It establishes a
known-good picture of your system before a change, detects high-confidence
problems, and explains what is different afterwards — locally, read-only, with no
telemetry and no automatic fixes.

It does not replace `omarchy update`, snapshots, or your package manager. It is
the evidence layer around them.

> **Status: 0.1.0 — runtime foundation.** The plugin loads, mounts its service,
> renders its bar widget, and opens its overlay. The diagnostic engine and check
> catalogue land in the next milestones. It reports honestly that no checks have
> run rather than showing placeholder results.

## Design principles

- **Evidence over scores.** No "93% safe". Readiness is one of `READY`,
  `REVIEW`, `NOT_RECOMMENDED`, `UNKNOWN`, and every state traces to concrete
  check results.
- **Unknown is a valid answer.** Absence of evidence is never reported as safety.
- **Read-only by default.** It observes and explains. It does not change your
  system.
- **Local only.** No network access, ever. Reports are written to disk for you to
  review before sharing.

## Install

Review the source before enabling it — Omarchy plugins run unsandboxed inside
`omarchy-shell`.

```bash
omarchy plugin add https://github.com/p134c0d3/omarchy-omapreflight.git
```

Accept the prompt to enable it during installation. For an unattended install
from a repository you already trust:

```bash
omarchy plugin add https://github.com/p134c0d3/omarchy-omapreflight.git --enable --yes
```

The widget lands in the right bar section. Move it with:

```bash
omarchy bar move p134c0d3.omapreflight --section center
```

## Update

```bash
omarchy plugin update p134c0d3.omapreflight
omarchy plugin update --all
```

## Use

- **Click the bar widget** for the quick panel: current readiness, what needs
  attention, when it last ran.
- **Open the full overlay** for the engineering surface:

  ```bash
  omarchy-shell shell toggle p134c0d3.omapreflight
  ```

  `Esc` closes it. Because the plugin declares an `overlay` kind, `summon`,
  `hide` and `toggle` route to the overlay — the quick panel is opened by
  clicking the widget.

Bind the overlay to a key in `~/.config/hypr/bindings.lua` if you want it on a
shortcut:

```lua
o.bind("SUPER, P", "OmaPreflight", "omarchy-shell shell toggle p134c0d3.omapreflight")
```

## IPC

The service registers the target `p134c0d3.omapreflight`:

```bash
omarchy-shell p134c0d3.omapreflight ping      # -> ok
omarchy-shell p134c0d3.omapreflight status    # -> JSON summary
omarchy-shell p134c0d3.omapreflight run       # run the check suite
```

The IPC surface is deliberately small. It does not expose arbitrary command
execution.

## Theming

Every colour and metric comes from the active Omarchy theme's tokens
(`Color.*`, `Style.*`). There are no hard-coded colours and no light/dark
assumptions — switch themes and the plugin follows.

One caveat worth knowing. Omarchy's own full-screen surfaces are translucent
because the compositor blurs behind them, and blur is granted by a Hyprland layer
rule that lists first-party namespaces explicitly. A third-party overlay cannot
be in that list, so on a theme that makes menus translucent, OmaPreflight raises
its own alpha floor to stay readable (it never changes the theme's hue, and is
inert on themes that are already opaque — see
[ADR-004](docs/adr/ADR-004-theming-and-layer-legibility.md)).

If you would rather have true frosted glass, allow blur for this namespace in
`~/.config/hypr/looknfeel.lua`:

```lua
hl.layer_rule({ match = { namespace = "omapreflight-overlay" }, blur = true, ignore_alpha = 0.06 })
```

## What it does on your machine

Stated plainly, because you are running it unsandboxed:

| Behaviour | Detail |
|---|---|
| **Commands run** | Read-only diagnostics only: `omarchy`, `hyprctl`, `systemctl --user`, `df`, `git status` inside plugin checkouts. Never `sudo`. Never an interactive command. |
| **Files read** | `~/.config/omarchy/shell.json`, approved `~/.config/hypr/*.lua` config files (size/hash/mtime only), plugin manifests. It never recursively scans `$HOME`. |
| **Files written** | Only `${XDG_STATE_HOME:-~/.local/state}/omapreflight/` — state, baseline, and reports you ask for. |
| **Network** | None. |
| **Background work** | Runs inside the existing `omarchy-shell` process. No daemon, no second Quickshell instance, no systemd unit, no install hook. |
| **Privileges** | None. A diagnostic that would need privilege is reported as `SKIPPED — requires privilege`, with the manual command documented. |

See [docs/privacy.md](docs/privacy.md) once the engine lands for the full data
model.

## Development

```bash
scripts/check         # manifest validation + qmllint + safety invariants
scripts/dev-install   # deploy to ~/.config/omarchy/plugins and restart the shell
```

`dev-install` restarts the shell deliberately: `service`-kind QML is served from
a cached component across a hot reload, so an edited `Service.qml` keeps running
its previous source until the shell process restarts. See
[docs/environment.md](docs/environment.md) for that and other verified runtime
behaviour.

## Licence

MIT — see [LICENSE](LICENSE).
