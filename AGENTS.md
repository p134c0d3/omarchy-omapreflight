# Working on OmaPreflight

Read `OmaPreflight_ENGINEERING_SPEC.md` (the design spec this project is built
from) before changing code, `docs/environment.md` before trusting any
remembered Omarchy or Quickshell API, and `docs/security.md` before touching
anything that runs a command or reads a file.

## Source of truth

When sources disagree, this is the order:

1. The current installed Omarchy source on the target machine (`$OMARCHY_PATH`).
2. The current official Omarchy manual.
3. Official Omarchy repository documentation.
4. Quickshell docs **matching the shipped version** (0.3.0 here, not latest).
5. The engineering spec.
6. Agent memory — last, always.

Verify against the installed source rather than recalling syntax. Several
statements in the spec turned out not to hold on the real system; each deviation
is recorded as an ADR in `docs/adr/`.

## Hard rules

The plugin runs unsandboxed inside the user's shell process. `docs/security.md`
is the reasoning; these are the rules that fall out of it, and `scripts/check`
enforces the ones a machine can.

- Never call `sudo`. A check needing privilege returns `SKIPPED — requires
  privilege` and documents the manual command.
- Never create a second Quickshell process.
- Never edit anything under `/usr/share/omarchy`.
- Never make a network request. No telemetry, no remote fetch.
- Never recursively scan `$HOME`. Approved paths only.
- Never write outside `${XDG_STATE_HOME:-~/.local/state}/omapreflight/`.
- Never build a command with `sh -c` or interpolate values into shell text. Pass
  argument arrays.
- **Never pass an externally-sourced value as an argument without declaring it.**
  Anything read from command output, a file, or a directory listing goes in
  `dataArgs`, with `allowedRoots` when it is a path. A value that starts with
  `-` becomes an option, and that is all argument injection needs.
- **`Process` is only ever instantiated in `core/CommandJob.qml`, and `FileView`
  only in `core/FileReadJob.qml`.** Everything else goes through
  `CommandRunner` / `FileReader`. This is checked structurally.
- Never evaluate a string as code — no `eval`, no `new Function`, no
  `Qt.createQmlObject`, no `Qt.include`.
- Never mutate user configuration.
- Every external process gets a timeout and bounded output.
- Never mark unverifiable compatibility as safe.

## Conventions

- Prefer the unified `omarchy <group> <action>` CLI over internal `omarchy-*`
  binaries; discover with `omarchy commands --json`.
- Parsers and check definitions are **pure JS modules** in `parsers/` and
  `checks/`, imported relatively (`import "parsers/DiskUsage.js" as DiskUsage`).
  Pure JS is what makes them testable without a shell. First-party precedent:
  `$OMARCHY_PATH/shell/plugins/panels/audio/Model.js`.
- A parser exception must become a failed/unknown check result, never a crash.
- All colours and metrics come from `Color.*` / `Style.*`. No literals.
- Log with the `[omapreflight]` prefix. Successful operation stays quiet.

## Before claiming a task is done

1. Restate the acceptance criterion being implemented.
2. `scripts/check` passes (manifest validation, qmllint, safety and structural
   invariants). `scripts/check --portable` is what CI runs.
3. `scripts/dev-install` and exercise the change in the running shell.
4. Say what remains unknown.

Keep commits small and purpose-specific.

## Definition of done for a check

Stable id, category, user-facing title, declared capability requirements,
deterministic runner, timeout, parser, correct `PASS`/`WARN`/`FAIL`/`UNKNOWN`/
`SKIPPED` behaviour, evidence, remediation text where useful, fixtures for
success / failure / malformed input, and a privacy review.

If the check runs a command with any argument it did not author, the review
also covers the `dataArgs` declaration and its `allowedRoots` — see the review
questions at the end of `docs/security.md`.
