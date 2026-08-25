# Working on OmaPreflight

Read `OmaPreflight_ENGINEERING_SPEC.md` (the design spec this project is built
from) before changing code, and `docs/environment.md` before trusting any
remembered Omarchy or Quickshell API.

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

- Never call `sudo`. A check needing privilege returns `SKIPPED — requires
  privilege` and documents the manual command.
- Never create a second Quickshell process.
- Never edit anything under `/usr/share/omarchy`.
- Never make a network request. No telemetry, no remote fetch.
- Never recursively scan `$HOME`. Approved paths only.
- Never write outside `${XDG_STATE_HOME:-~/.local/state}/omapreflight/`.
- Never build a command with `sh -c` or interpolate values into shell text. Pass
  argument arrays.
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
2. `scripts/check` passes (manifest validation, qmllint, safety greps).
3. `scripts/dev-install` and exercise the change in the running shell.
4. Say what remains unknown.

Keep commits small and purpose-specific.

## Definition of done for a check

Stable id, category, user-facing title, declared capability requirements,
deterministic runner, timeout, parser, correct `PASS`/`WARN`/`FAIL`/`UNKNOWN`/
`SKIPPED` behaviour, evidence, remediation text where useful, fixtures for
success / failure / malformed input, and a privacy review.
