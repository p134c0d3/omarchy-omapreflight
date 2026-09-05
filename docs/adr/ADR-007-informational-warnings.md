# ADR-007: Informational warnings do not change readiness

Status: accepted, 2026-09-04.

The engineering spec §16 made every WARN affect readiness, while the shipped
local-change and recovery checks explicitly promised that their informational
findings would not. `material: false` only suppressed UNKNOWN in the aggregator.

Following the requested review fix, materiality now applies to both WARN and
UNKNOWN. These findings remain visible in the checklist and warning counts.
They do not change READY to REVIEW. FAIL still always affects readiness,
including when a check is marked informational, and a blocker failure always
produces NOT RECOMMENDED. An incomplete scan still produces UNKNOWN.

This keeps local edits and recovery context visible without treating them as
update blockers, while preserving the existing handling of proven failures.
