# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-08-25

First release. OmaPreflight answers "what would break if I update?" by asking
the system 21 questions and reporting the answers, with the evidence attached.

It is a read-only diagnostic. It updates nothing, installs nothing, restores
nothing, and makes no network requests.

### The product

- **21 checks** across environment, Omarchy, Hyprland, plugins, runtime and
  recovery. Each one names what it ran, what it found, and what to do about it.
  The full list is in [docs/check-catalog.md](docs/check-catalog.md).
- **A finite readiness vocabulary** — READY, REVIEW, NOT RECOMMENDED, UNKNOWN.
  No score, no percentage, and no verdict at all from a scan that did not
  finish.
- **UNKNOWN is a real answer.** A check that could not establish something says
  so instead of passing. A missing capability is SKIPPED with the reason.
- **Two surfaces.** A bar badge with a quick panel showing the verdict and what
  needs attention, and a report window with the full catalog, expandable
  evidence, and full keyboard navigation.
- **Diagnostic reports** — sanitized Markdown, written locally or copied to the
  clipboard, never uploaded, and stamped with a line telling you to review it
  before posting.
- **Baselines** — record the current state, and a later scan says exactly what
  changed: versions, config file hashes, plugin commits. Metadata only, never
  file contents. Recorded only when you ask.

### Notable behaviour

- The report window is a real toplevel, so `SUPER`+drag moves it and
  `SUPER`+right-drag resizes it like anything else on the desktop. It opens
  floating and centred, sizes itself to its content, and scrolls only when the
  results genuinely do not fit
  ([ADR-005](docs/adr/ADR-005-window-not-layer-surface.md)).
- `plugins.third-party-validation` compares the plugin directories on disk
  against what the shell actually loaded. The shell drops a plugin with an
  invalid manifest during discovery, warns once into its log, and carries on —
  so the plugin vanishes from every menu with no explanation. This is the check
  most likely to tell you something you did not know.
- `recovery.snapshot-capability` reports that snapshots *look possible* and
  never that they are available. `omarchy snapshot` requires privilege, so the
  plugin can see the mechanism and can never exercise it.
- Status is carried by a glyph and a word before it is carried by colour, and
  every colour is a theme token. The repository contains no colour literals.

### Safety

The plugin runs unsandboxed inside the shell that draws your desktop. The
limits it operates under are written down in
[docs/security.md](docs/security.md), mapped to the weaknesses they address,
and enforced by `scripts/check`:

- commands are argv arrays; there is no shell anywhere in the plugin;
- externally-sourced arguments are declared and validated — no leading dash, no
  control characters, and paths must be absolute, traversal-free and inside an
  explicit root;
- exactly one file may start a process, and two may touch a file, checked
  structurally so the validation cannot be routed around;
- no privilege, ever; no network; no dynamic code;
- every command is capped and timed out, every check has a watchdog, the whole
  scan has a 120 s ceiling, and one command runs at a time
  ([ADR-002](docs/adr/ADR-002-serial-execution-and-bounded-work.md));
- the only writable location is
  `${XDG_STATE_HOME:-~/.local/state}/omapreflight/`, created `0700`.

The single action that is not a read — a named, runtime, literal Hyprland
window rule for the plugin's own window — is documented in full rather than
footnoted.

### Engineering

- **Decisions live in pure JavaScript; QML owns I/O and lifetime**
  ([ADR-003](docs/adr/ADR-003-pure-javascript-for-decisions.md)). 186 tests run
  in under half a second with no compositor, no shell and no display, over the
  readiness aggregator, every parser, the sanitizer, the execution policy and
  the baseline document. Parser fixtures are real output captured from a live
  machine.
- **The service is the shared state, not a QML singleton**
  ([ADR-001](docs/adr/ADR-001-shared-state.md)) — singletons survive
  `Qt.clearComponentCache()` on plugin reload and would carry stale state and
  live timers across it.
- `scripts/check` validates the manifest, lints the QML, asserts the security
  invariants, and fails if the documented check catalog and the code disagree
  in either direction. `scripts/check --portable` and `scripts/test` run in CI.
- Seven corrections to the engineering spec, each found by verifying against
  the installed system rather than trusting the document, are recorded in
  [docs/environment.md](docs/environment.md).

### Known limitations

- Tested on Omarchy 4.0.1 / Quickshell 0.3.1 / Hyprland 0.56.2. Both Omarchy
  and Quickshell moved underneath this project while it was being built, which
  is why the plugin discovers rather than assumes.
- The report window opens on one output. Mirroring across monitors is not
  implemented.
- Sanitization is pattern matching and cannot be complete. Every report says so.
- Postflight ("what actually changed after the update?") and semantic
  configuration connectivity are deliberately out of scope for v0.1.
