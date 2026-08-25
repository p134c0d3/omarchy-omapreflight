# ADR-001 — The service is the shared store

**Status:** Accepted (Milestone 0)

## Context

Every surface (bar widget, quick panel, overlay) must read one consistent view of
readiness, results and capabilities. The engineering spec (§9.3) proposed a local
QML singleton in `core/qmldir` as the preferred mechanism.

## Decision

`Service.qml` **is** the store. It owns a `core/PreflightStore.qml` instance and
exposes it as a property. Surfaces reach it two ways:

- `Overlay.qml` — injected by the shell's panel loader, which does
  `if ("service" in item) item.service = shell.serviceFor(pluginId)`.
- `BarWidget.qml` — `bar?.shell?.serviceFor("p134c0d3.omapreflight")`.

No `pragma Singleton`, no `core/qmldir`.

## Why not the singleton

1. **Hot reload.** `shell.qml:reloadPlugins()` destroys plugin service instances
   and calls `Qt.clearComponentCache()`. Engine-cached QML singletons are not
   torn down on that path, so a singleton store would survive a reload holding
   stale state and live timers — precisely the "duplicated timers / repeated
   check execution" the spec forbids in §9.5. A service instance is destroyed and
   rebuilt cleanly; verified by balanced unmount/mount log pairs.

2. **The shell already does this.** `omarchy.media` and `omarchy.audio` pair a
   service with UI and read shared state off the service instance. Following the
   host's own pattern means the shell's lifecycle guarantees apply to us.

3. **Guaranteed singleton anyway.** `_syncServices()` mounts exactly one instance
   per plugin id, so the property we wanted from a singleton is provided by the
   host.

## Consequences

- Every surface must guard `service` for null: it is briefly unset while the
  shell mounts plugins, and the bar widget may load before the service.
- Initialization that depends on `manifest` must happen in `onManifestChanged`,
  not `Component.onCompleted` — injected properties are not yet assigned there.
- Editing `Service.qml` requires a shell restart to take effect; see
  `docs/environment.md`.
