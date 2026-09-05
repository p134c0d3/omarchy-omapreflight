# Architecture

How OmaPreflight is put together, and why each piece is where it is.

## The shape of it

```
                        ┌───────────────────────────────┐
  omarchy-shell ───────►│  Service.qml                  │  mounted exactly once
   mounts one per       │  · owns all shared state      │  per plugin id
   plugin id            │  · owns the IPC target        │
                        └───────────────────────────────┘
                                      │ owns
        ┌─────────────────────────────┼─────────────────────────────┐
        ▼                             ▼                             ▼
  PreflightStore              CheckEngine                    CommandRunner
  reactive state              serial, cancellable,           the only place a
  the UI binds to             one result per check           process starts
                                      │                             │
                                      │ uses                        ▼
                                      ▼                       CommandJob
                              CapabilityRegistry              one process,
                              BaselineStore                   guaranteed to end
                              FileWriter
                              FileReader ──► back through CommandRunner:
                                      │       stat, then no-follow bounded dd
                                      │ runs
                                      ▼
                              checks/*.js  ──uses──►  parsers/*.js
                              pure definitions        pure text → data

  Surfaces read the store; they never run anything themselves:

    BarWidget.qml   bar?.shell?.serviceFor(id)      badge + quick panel
    Overlay.qml     injected by the panel loader    the report window
```

## The load-bearing decisions

### The service is the shared state

Not a QML singleton. `shell.qml:reloadPlugins()` destroys service instances and
calls `Qt.clearComponentCache()`, but engine-cached singletons survive that —
producing exactly the stale state, duplicated timers and repeated check
execution a plugin must not have. The shell mounts exactly one `Service.qml`
per plugin id, which makes it the natural and correct home.

Full reasoning: [ADR-001](adr/ADR-001-shared-state.md).

### Logic that matters is pure JavaScript

The readiness aggregator, every parser, the sanitizer, the execution policy and
the baseline document are `.js` modules. The QML types are thin wrappers that
own I/O and lifecycle and delegate the thinking.

This started as a preference and became a constraint: `qmltestrunner` cannot
load Quickshell's C++ QML plugin outside a shell process, so anything living in
a QML type that touches Quickshell is untestable. That pressure improved the
design — 186 tests exist because the logic is somewhere they can reach it.

The division to keep: **QML does I/O and lifetime; JavaScript does decisions.**

### One place starts a process, one place reads a file, one place writes

`Process` may only be instantiated in `core/CommandJob.qml`, and `FileView`
only in `core/FileWriteJob.qml`. `scripts/check` fails the build if a second
site appears.

This is what makes the validation in `core/ExecPolicy.js` mean anything. A rule
that can be bypassed by declaring a `Process` elsewhere is documentation, not
enforcement. See [security.md](security.md).

Reads have no `FileView` at all. `FileReader` goes through the command path —
`stat` for the file's type and size, then `dd` with `O_NOFOLLOW`, `O_NONBLOCK`
and a byte ceiling — because `FileView` offers no open flags, no type check and
no size cap, and an allowlist of names cannot promise anything about what is at
a name. The policy and the argv live in `core/ReadPolicy.js`;
[ADR-006](adr/ADR-006-reads-go-through-the-command-path.md) is the reasoning.

### Execution is serial

One command at a time, one check at a time. That is a deliberate trade of a few
seconds for three properties that are worth more in a diagnostic tool: the scan
ceiling means something exact, the progress figure is exact rather than estimated,
and a plugin that runs commands is never the reason the machine feels busy.

### Failure is a result, never an exception

Every path ends in a check result. A check that throws, hangs, calls back
twice, or returns nothing still produces exactly one. A command that cannot
start, times out, or is refused becomes `UNKNOWN` with the reason attached. A
scan that does not complete yields readiness `UNKNOWN` rather than a partial
verdict presented as a whole one.

The plugin runs inside the user's desktop shell. A plugin that throws there can
take the desktop with it.

## A scan, start to finish

1. `Service.runPreflight()` → `CheckEngine.start()`. A second start while one
   is running is **refused**, not queued.
2. The baseline is re-read from disk. The shell is long-lived; a baseline
   recorded or replaced since mount must be the one compared against.
3. `CapabilityRegistry.refresh()` runs three probes — the Omarchy command
   catalog, `hyprctl version`, and failed user units. Capabilities are derived
   from what the CLI *advertises*, and a route that requires privilege is
   recorded as present but **not callable**.
4. Checks run in catalog order. Each gets a context: a memoized `exec`, a
   memoized `readFile`, the capability registry, the baseline, resolved paths,
   and `fact()` for recording structured values.
5. A check whose capabilities are missing is `SKIPPED` with the reason. A check
   that misbehaves is contained. Every result is appended to the store as it
   arrives, so the UI fills in live.
6. On completion: results, facts, category counts and readiness land in the
   store; `finished` fires once.

Command and file results are memoized for the duration of a scan, so a probe
and the check that needs the same answer cost one process between them.

### Facts versus results

Checks produce two things. **Results** are prose for a person — a status, a
summary, details, evidence. **Facts** are structured values recorded through
`ctx.fact()`.

The baseline is built from facts, never from results. Deriving machine-readable
state by parsing summary text works right up until someone improves a sentence.
Saving requires the current scan to have completed. `Baseline.capture()` copies
its facts before asynchronous directory creation, so a new scan cannot replace
the state being saved. Cancelled scans cannot overwrite the baseline.

## Surfaces

Both read the store and call the service. Neither runs a command.

**`BarWidget.qml`** extends `qs.Ui.Panel` — the base built for "a bar button
plus a popup from one QML entry point". One instance exists **per screen**,
which is why its quick-panel IPC lives on the service and routes through
`Bar.summonBarWidget`, the host's own resolver, which picks the instance on the
focused output.

**`Overlay.qml`** is a `FloatingWindow` — a real toplevel, not a layer surface.
That is what makes `SUPER`+drag move it and `SUPER`+right-drag resize it: those
are window-management binds, and a layer surface never receives them. It sizes
itself to its content and lets Hyprland clamp to the monitor, so the list
scrolls only when the results genuinely do not fit.
See [ADR-005](adr/ADR-005-window-not-layer-surface.md).

Status is carried by a glyph and a word before it is carried by colour, and
every colour is a theme token — the repository contains no colour literals.
See [ADR-004](adr/ADR-004-theming-and-layer-legibility.md).

## Adding a check

1. Write it in the right `checks/*Checks.js` as a **literal object** with
   `id`, `title`, `category`, `description`, `requiredCapabilities`,
   `defaultSeverity`, `timeoutMs`, optional `material: false`, and
   `run(ctx, done)`. Literal, because `scripts/check` compares declared ids
   against the catalog documentation.
2. Put text parsing in `parsers/`, not in the check. Parsers are pure and
   fixture-tested; checks decide what a parse *means*.
3. If any argv element comes from command output, a file, or a directory
   listing, declare it: `{ dataArgs: [2], allowedRoots: [...] }`.
4. Call `done()` exactly once on every path, including the ones you think
   cannot happen.
5. Record structured values with `ctx.fact()` if the baseline should know them.
6. Add it to `docs/check-catalog.md`. The build fails otherwise.
7. Add fixtures: valid, empty, malformed, and a shape a future version might
   produce.

## Where things live

| Path | Holds |
|---|---|
| `Service.qml` | Lifecycle, shared state, IPC, orchestration. No parsing. |
| `core/*.qml` | I/O and lifetime: runner, jobs, engine, stores. |
| `core/*.js` | Decisions: result model, execution policy, sanitizer, baseline. |
| `checks/*.js` | Check definitions. Pure; no I/O of their own. |
| `parsers/*.js` | Text → data. Pure, defensive, never throw. |
| `ui/` | Presentation components shared by both surfaces. |
| `tests/` | 186 cases over the pure modules. |
| `scripts/` | `check`, `test`, `dev-install`. |

## Things worth knowing before you edit

Collected in [environment.md](environment.md), which is the file to read before
trusting any remembered Omarchy or Quickshell API. The short version:

- service QML is served from a **cached component** across a hot reload — an
  edited `Service.qml` keeps running its old source until the shell restarts,
  which is why `scripts/dev-install` restarts it;
- injected properties (`manifest`, `shell`, `bar`) are **not set** during
  `Component.onCompleted`; wait for the change signal;
- a bar widget must forward its button's implicit size, or the bar allocates a
  zero-width slot and the widget is invisible with nothing in the log;
- `BorderSurface.padding` does not inset children — it exposes insets the
  content must consume.
