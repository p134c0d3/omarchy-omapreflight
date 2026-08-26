# ADR-002 — Serial execution, and every axis of work bounded

**Status:** Accepted (Milestone 1)

## Context

OmaPreflight runs inside `omarchy-shell`, the single Quickshell process that
draws the user's entire desktop — the bar, the panels, the menus, the lock
screen. There is no process boundary. A plugin that blocks that process stops
the desktop repainting; a plugin that leaks work into it degrades everything
else the user is doing.

A scan runs external commands. Commands can hang, produce unbounded output,
ignore SIGTERM, or simply be slow on a loaded machine. Any of those, unhandled,
becomes "my bar froze".

The obvious design is concurrent execution with a per-command timeout: run the
catalog in parallel, finish sooner. For a diagnostic that would be a poor
trade.

## Decision

**Exactly one command runs at a time, and exactly one check runs at a time.**
`CommandRunner` queues; `CheckEngine` iterates. Every axis of work has a
declared ceiling:

| Axis | Bound |
|---|---|
| stdout per command | 256 KiB, enforced while the stream is arriving |
| stderr per command | 64 KiB |
| Command lifetime | per-command timeout → SIGTERM → SIGKILL → abandon |
| Check lifetime | a watchdog beyond the check's own command budget |
| Scan lifetime | 120 s, after which the scan reports itself incomplete |
| Concurrency | one process |
| Overlapping scans | refused, not queued |
| Plugins inspected per scan | 12, and the result says when that cap bit |

The engine yields between checks through `Qt.callLater`, so a long catalog
cannot monopolize the event loop even while every individual step is fast.

## Why serial is worth the seconds

**The scan ceiling becomes meaningful.** With one command in flight, "this scan
will not exceed 120 seconds" is a property of the design. With N in flight and
a shared machine, it is a hope.

**Progress becomes exact.** "6 of 21 — Hyprland configuration errors" is true.
A parallel engine can report a fraction, but not what it is currently doing,
and a diagnostic that cannot say what it is doing is hard to trust when it
hangs.

**Cancellation becomes simple and total.** One in-flight process to terminate,
one queue to drain. Every pending callback still fires, marked cancelled, so no
check is left waiting forever.

**The plugin is never the reason the machine is busy.** A diagnostic tool that
makes the system feel worse while asking whether the system is well has
undermined its own answer.

The cost is real and small: a full 21-check scan takes about seven seconds on
this machine, most of it waiting on `omarchy plugin validate` running once per
third-party plugin. Correctness is worth more than five of those seconds.

## Consequences

- A check that hangs delays the ones behind it. Bounded by the per-check
  watchdog, which cancels the runner's in-flight work before moving on, so the
  cost does not accumulate onto the next check's budget.
- The scan ceiling can fire mid-catalog. When it does, the scan is **incomplete**
  and readiness is `UNKNOWN` — never a partial verdict presented as a whole one.
- Output caps are enforced during collection rather than after, so a runaway
  command is stopped rather than buffered. That is why `StdioCollector` is used
  with `waitForEnd: false`.
- Caps that bite are announced. `plugins.third-party-validation` says when it
  checked only the first twelve. A silent truncation reads as "covered
  everything".

## Alternatives rejected

**Small bounded concurrency (2–4 commands).** Would shave a few seconds. Costs
the exact-progress property, complicates cancellation, and makes the time
ceiling probabilistic. The spec's own guidance — correctness over shaving two
seconds — points the same way.

**Per-command timeout with no output cap.** A command that never exits but
prints constantly would consume memory in the shell process until the timeout,
which is the failure this is meant to prevent.

**SIGKILL immediately on timeout.** Denies a well-behaved process the chance to
exit cleanly. The escalation costs one second and is kinder to anything holding
a lock.

**No scan ceiling, relying on per-command timeouts.** Twenty-one checks with a
15-second budget each is five minutes of worst case. A ceiling makes the bound
one number a user can reason about.
