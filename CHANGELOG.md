# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

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
