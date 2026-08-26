# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Diagnostic engine (Milestone 1) and the security model.

### Added

- `core/CommandJob.qml` / `core/CommandRunner.qml` — the only place a process
  starts. argv arrays only; privilege helpers and shell interpreters refused
  before a process exists; stdout capped at 256 KiB and stderr at 64 KiB while
  the stream is still arriving; SIGTERM → SIGKILL → abandon escalation so every
  run reaches a terminal state; execution serialized to one command at a time.
- `core/FileReadJob.qml` / `core/FileReader.qml` — the only place a file is
  read, against an explicit directory allowlist with no recursive mode.
- `core/CheckEngine.qml` — serial execution with per-check watchdogs and a
  120 s scan ceiling, one result per check however the check misbehaves, no
  overlapping scans, and readiness `UNKNOWN` for any scan that did not
  complete. Command and file results are memoized per scan.
- `core/CapabilityRegistry.qml` — capabilities derived from the CLI's own
  `omarchy commands --json`. A privileged route is recorded as present but not
  callable, so `omarchy snapshot` never reads as "snapshots available".
- `core/ResultModel.js` — status, severity and readiness vocabulary plus the
  pure readiness aggregator.
- Nine checks across `environment`, `omarchy` and `hyprland`.
- Result UI: findings in the quick panel, the full catalog in the overlay
  grouped by category and sorted worst-first, with expandable evidence and full
  keyboard navigation.
- Sanitized Markdown reports (§26), written into the state directory and never
  uploaded: `core/Sanitizer.js`, `core/ReportBuilder.qml`, `core/FileWriter.qml`
  with atomic writes, and Save/Copy actions plus `S`/`C` keys in the overlay.
  The reports directory is created 0700.
- `cancel`, `results`, `report`, `openPanel`, `closePanel` and `togglePanel` on
  the service IPC target. The panel methods live on the service, not the
  widget, because one widget instance exists per screen: the service routes
  through the shell's own bar resolver, which picks the instance on the focused
  output instead of whichever copy claimed a target name first.
- `core/ExecPolicy.js` — the execution and path policy as pure functions, shared
  by CommandRunner, FileReader and FileWriter so one implementation of the path
  rules exists rather than three.
- Test suite: 131 cases across the readiness aggregator, every parser, the
  sanitizer and the execution policy, run with `scripts/test`. Parser fixtures
  are real output captured from a live machine.
- `docs/security.md` — threat model, trust boundaries, the enforced invariants
  with their CWE mapping, and the residual risks that are *not* mitigated.
- `SECURITY.md` — private vulnerability reporting and scope.
- Argument-injection defence (CWE-88): externally-sourced argv elements are
  declared via `dataArgs` and validated — no leading dash, no control
  characters, and paths must be absolute, free of `..` segments, and inside a
  declared root matched on a segment boundary.
- `scripts/check` gained structural invariants (`Process` only in
  `core/CommandJob.qml`, `FileView` only in `core/FileReadJob.qml`), a
  dynamic-code guard, a detached-process guard, and a `--portable` mode.
- GitHub Actions workflow running the portable checks on every push and pull
  request.

### Changed

- **The diagnostic surface is a window, not a full-screen overlay.** It was a
  layer-shell surface, which cannot be moved or resized: Omarchy binds
  `SUPER`+drag and `SUPER`+right-drag to window management, both consuming, and
  a layer surface never receives them. It is now a `FloatingWindow`, so those
  gestures work natively, it takes normal window blur and opacity, and it can
  stay open beside a terminal. It sizes itself to its content and scrolls only
  when the results genuinely do not fit. See
  [ADR-005](docs/adr/ADR-005-window-not-layer-surface.md).
- The service registers a named, scoped, runtime Hyprland window rule so that
  window opens floating and centred — the one thing a Wayland client cannot ask
  for itself. No file is written and nothing is interpolated into the rule.
- The alpha floor from ADR-004 is gone with the reason for it: a window gets
  compositor blur without needing a layer-namespace allowlist entry.
- Path validation is segment-wise rather than substring-based, so `..config` is
  no longer a false positive and `plugins-evil` no longer satisfies an
  allowlisted `plugins` root.

## [0.1.0] — 2026-08-24

Runtime foundation (Milestone 0). The plugin loads and its surfaces work; the
diagnostic engine is not implemented yet and the UI says so rather than showing
placeholder results.

### Added

- Multi-kind plugin manifest declaring `service`, `bar-widget` and `overlay`.
- `Service.qml` — the single mounted instance that owns shared state, plus the
  `p134c0d3.omapreflight` IPC target with `ping`, `status` and `run`.
- `core/PreflightStore.qml` — reactive state with a finite readiness vocabulary
  and no numeric scoring.
- `BarWidget.qml` — readiness badge and quick panel, built on `qs.Ui.Panel`.
  Status is carried by glyph and label, never by colour alone.
- `Overlay.qml` — full-screen diagnostic surface with keyboard focus and `Esc`
  to close.
- `scripts/check` — manifest validation, `qmllint` with the `qs` import shim, and
  safety-invariant greps.
- `scripts/dev-install` — deploy and restart the shell, because service QML is
  cached across hot reloads.
- `docs/environment.md` and ADRs 001 and 004.

### Fixed

- Bar widget rendered nothing because the root did not forward its button's
  implicit size, so the bar allocated a zero-width slot.
