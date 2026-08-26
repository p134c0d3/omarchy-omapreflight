# ADR-003 — QML does I/O and lifetime; JavaScript makes the decisions

**Status:** Accepted (Milestone 1), reinforced by a constraint discovered while
writing the tests

## Context

The natural way to write a Quickshell plugin is in QML: types own their state,
bindings keep the UI in step, and logic lives in the handler where it is
needed. For a bar widget that is right.

For a diagnostic tool it is not. The things this plugin must be *correct* about
are all pure functions of their inputs:

- the readiness aggregator — the one verdict the product exists to produce;
- every parser, each turning another program's output into data;
- the sanitizer, which decides what may leave the machine;
- the execution policy, which decides whether a process may exist;
- the baseline document and the comparison built on it.

Every one of those has failure modes that are invisible on a healthy machine.
A readiness bug that turns a blocker into READY only shows up on a system that
already has a blocker. A sanitizer gap only shows up after someone has pasted a
token into a public issue. These need tests, and tests need the logic to be
reachable.

Then a hard constraint surfaced while writing them: **`qmltestrunner` cannot
load Quickshell's C++ QML plugin.** A test that instantiates a QML type
importing `Quickshell.Io` fails at compile with *"module Quickshell.Io plugin
quickshell-ioplugin not found"*. Anything meaningful living inside such a type
is untestable outside a running shell.

## Decision

**QML owns I/O, object lifetime and presentation. JavaScript owns every
decision.**

| QML (`.qml`) | JavaScript (`.js`) |
|---|---|
| `CommandJob` — one process, guaranteed to terminate | `ExecPolicy` — whether it may run at all |
| `CommandRunner` — the queue | |
| `FileReadJob` / `FileWriteJob` — the I/O | |
| `CheckEngine` — sequencing, watchdogs, contexts | `ResultModel` — status, severity, readiness |
| `BaselineStore` — reading and writing the file | `Baseline` — the document and the comparison |
| `Overlay`, `BarWidget`, `ui/*` — presentation | `Vocabulary` — glyphs, labels, phrasing |
| | `parsers/*` — text → data |
| | `checks/*` — definitions and what a parse means |
| | `Sanitizer` — what may leave the machine |

A QML type in the left column should be readable in one sitting and contain no
branch that a test would want to exercise.

## The test that forced the shape

The first version of the execution policy lived as methods on
`CommandRunner.qml`. `tests/tst_CommandRunner.qml` could not instantiate it —
the C++ plugin does not load — so the argument-injection rules, the privilege
denylist and the path checks had no coverage at all. They were the *most*
security-relevant code in the repository.

Moving them to `core/ExecPolicy.js` produced 32 tests, and a second benefit
that was not the goal: `CommandRunner`, `FileReader` and `FileWriter` had each
been carrying its own copy of the path rules. Three implementations of one
check is three chances to fix a bug in two of them. They now share one.

## Consequences

- 186 tests run in under half a second with no compositor, no shell, and no
  display. They run in CI on a plain Ubuntu runner.
- The QML types are thin enough to review by reading. `CommandRunner` is a
  queue; the judgement it applies is elsewhere and tested.
- Checks and parsers are portable. Nothing in `checks/` or `parsers/` imports a
  QML type, so they could be exercised by any harness.
- The cost is indirection: reading a check means opening the check, the parser,
  and sometimes the result model. Named modules and small files keep that
  navigable rather than maze-like.
- **A new rule to hold to:** if a QML type acquires a branch worth testing, the
  branch is in the wrong file.

## Alternatives rejected

**Logic in QML, tested by running the shell.** The only integration point that
exists, and it is how the surfaces *are* verified — `scripts/dev-install` and
exercising the live plugin. Unusable for exhaustive cases: there is no way to
present a malformed `df` output or a plugin id of `--upload-pack=evil` to a
running desktop.

**A C++ or Python test harness for the QML types.** Solves the plugin-loading
problem by adding a build step and a second language to a plugin that currently
has neither. Not worth it for a repository people are meant to read.

**`pragma Singleton` JS modules holding state.** Would make some plumbing
shorter, and reintroduces exactly the stale-state-across-reload problem
[ADR-001](ADR-001-shared-state.md) exists to avoid. The `.js` modules here are
`.pragma library` and hold no mutable state.
