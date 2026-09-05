# Security policy

## Reporting a vulnerability

Please report suspected vulnerabilities privately, through GitHub's
[private vulnerability reporting](https://github.com/p134c0d3/omarchy-omapreflight/security/advisories/new)
on this repository. That opens a private advisory only the maintainer can see.

Please do not open a public issue for a security problem first.

Include what you have: the version or commit, what the plugin did, and what you
expected instead. A reproduction is welcome but not required — a clear
description of the weakness is enough to start.

Expect an acknowledgement within a week. If a report turns out to be valid,
the fix and the advisory are published together, and you are credited unless
you would rather not be.

## Scope

In scope — anything that lets OmaPreflight be used against the machine it runs
on:

- executing a command the plugin did not intend to execute, including through
  an argument that is read as an option;
- reading or writing a path outside the documented allowlists;
- doing anything privileged, or attempting to;
- making a network request;
- leaking data into a diagnostic report that sanitization should have removed;
- wedging or crashing `omarchy-shell`, including through unbounded output,
  unbounded runtime, or a scan that never terminates.

The optional terminal companion is also in scope, including unintended updater
launches, continuation after an unapproved checklist, and unsafe state-file or
IPC handling. Its documented handoff to Omarchy on an explicit
`omapreflight update` invocation is intentional; Omarchy's subsequent network
and privilege operations belong to the updater. See
[the integration boundary](docs/adr/ADR-008-optional-update-gate.md).

Out of scope:

- weaknesses in Omarchy, Quickshell, Hyprland, or any tool OmaPreflight queries
  — please report those to their projects;
- the fact that the plugin runs unsandboxed, which is a property of the Omarchy
  plugin system and is documented in [docs/security.md](docs/security.md);
- the fact that Quickshell's IPC socket is reachable by any process running as
  the same user, for the same reason;
- residual risks already listed in [docs/security.md](docs/security.md), unless
  you have found a way to exploit one that the document does not anticipate.

## Supported versions

The most recent release is supported. This is a young project on a rolling
distribution; fixes go to `main` and a new version is tagged.

## What this plugin does on your machine

The complete list of external commands run, files read, and files written is in
the [README](README.md#what-it-does-on-your-machine), and the reasoning behind
each limit is in [docs/security.md](docs/security.md). If the plugin ever does
something not on that list, that is a bug worth reporting.
