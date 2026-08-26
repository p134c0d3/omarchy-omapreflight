# ADR-005 — The diagnostic surface is a window, not a layer surface

**Status:** Accepted (Milestone 1)
**Supersedes:** the translucency half of
[ADR-004](ADR-004-theming-and-layer-legibility.md)

## Context

The full diagnostic surface was originally a `PanelWindow` — a Wayland
layer-shell surface on the overlay layer, full-screen, with a scrim, exclusive
keyboard focus, and a centred card drawn inside it. That is how Omarchy's own
overlays work, and copying the first-party pattern seemed obviously right.

It was wrong for this content, for a reason that only shows up in use: **you
cannot move or resize a layer surface.**

Omarchy binds the standard Hyprland window gestures:

```lua
o.bind("SUPER + mouse:272", "Move window",   hl.dsp.window.drag(),   { mouse = true })
o.bind("SUPER + mouse:273", "Resize window", hl.dsp.window.resize(), { mouse = true })
```

Both are consuming, and both dispatch on *windows*. A layer surface is not a
window, so:

- Hyprland swallows `SUPER`+drag before the surface ever sees it, and then has
  nothing to act on;
- the gesture that works on every other thing on the screen silently does
  nothing here.

The first attempt at fixing this implemented move and resize *inside* the
surface — a drag strip across the header, eight resize handles around the card,
and geometry persisted to the state directory. It worked, and it was the wrong
answer. It reimplemented, worse, something the compositor already does well,
and it invented a second gesture vocabulary for one window on a system where
every other window answers to the first one.

There was also a second, quieter symptom. A layer surface gets compositor blur
only if a Hyprland layer rule names its namespace, and those rules list
first-party namespaces explicitly. A third-party namespace gets no blur, so a
theme's translucent menu tokens rendered as plain transparency with the desktop
legible straight through the card. ADR-004 worked around that with an alpha
floor.

## Decision

The diagnostic surface is a `FloatingWindow` — a real XDG toplevel, titled
`OmaPreflight`, class `org.quickshell`.

Because it is a window:

- `SUPER`+left-drag moves it and `SUPER`+right-drag resizes it, natively, with
  no code here at all;
- it gets Omarchy's normal window blur and opacity rules, so the theme's own
  tokens are used unmodified and the alpha floor is gone with the reason for
  it;
- it takes focus, tabs, and stacks like anything else on the workspace;
- it can sit beside a terminal while you act on what it says, which is what a
  diagnostic report is actually for.

The window sizes itself to its content — `implicitHeight` is the height the
results want — so the list scrolls only when the content genuinely exceeds what
the screen can show.

One thing a Wayland client cannot do is ask to be floating. So the service
registers a Hyprland window rule at runtime:

```lua
hl.window_rule({
  name  = "omapreflight-window",
  match = { class = "^org.quickshell$", title = "^OmaPreflight$" },
  float = true, center = true
})
```

registered with `hyprctl eval`, once per shell session.

`hyprctl keyword` would be the obvious way to do that and does not work:
Omarchy configures Hyprland through the Lua parser, and keyword refuses with
*"can't work with non-legacy parsers. Use eval."* Registering a named rule
through `hyprctl eval` is also what the `b.okomart` plugin does for its own
window, so this follows the ecosystem rather than inventing a mechanism.

This is the only thing OmaPreflight does that is not a read, and it is bounded
deliberately:

- **scoped** by class *and* title to this plugin's own window;
- **named**, so re-registering replaces rather than accumulates;
- **runtime-only** — no file is written, no user configuration is touched, and
  the rule is gone when the compositor restarts;
- **literal** — nothing from the environment, a file, or another command's
  output is interpolated into the Lua. That last property is what makes handing
  a string to `hyprctl eval` defensible at all, and it is asserted in
  `Service.qml` where the string is built.

If the rule cannot be registered — `hyprctl` missing, a future Hyprland that
declines it — the window still opens and works; it is tiled instead of
floating, and the reason is logged once.

## Consequences

**Gained.** Native move, resize, focus and stacking. Normal blur and opacity.
A window that can be kept open beside the thing it is describing. Roughly 200
lines of geometry code, drag handling, resize handles and geometry persistence
deleted, along with the tests that existed only to prove that arithmetic was
right.

**Lost.** The modal scrim and click-outside-to-dismiss. `Esc` still closes it,
and a report you want to read *while* doing something else never wanted a modal
in the first place.

**Accepted.** One runtime compositor call, documented above, in
[docs/security.md](../security.md), and in the README's "What it does on your
machine" table. A plugin that promises to be read-only owes the reader an
explicit account of the single exception rather than a footnote.

## Alternatives rejected

**Keep the layer surface and implement move/resize in QML.** Built, and
discarded. A worse imitation of the compositor, a second gesture vocabulary,
and geometry state to persist and clamp — all to avoid being a window when
being a window was the answer.

**Keep the layer surface and document that it cannot be moved.** Defensible for
a HUD. Not defensible for a report the user is expected to read, act on, and
keep open.

**Ship a window rule for the user to paste into `looknfeel.lua`.** Correct in
spirit and poor in practice: the surface is unusable-by-default until a manual
config edit, for behaviour every other window has for free.

**Write the rule into the user's Hyprland configuration.** Ruled out. Editing
user configuration is exactly what this plugin promises never to do, and a
transient runtime rule achieves the same result without touching a file.
