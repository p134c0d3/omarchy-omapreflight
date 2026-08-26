# ADR-004 — Theming, and legibility on a non-blurred layer surface

**Status:** Partially superseded by
[ADR-005](ADR-005-window-not-layer-surface.md) (Milestone 1)

> The theming half of this decision stands and is unchanged: every colour and
> metric comes from `Color.*` / `Style.*`, and the repository contains no colour
> literals.
>
> The alpha-floor half is obsolete. It existed because a layer surface only gets
> compositor blur if a Hyprland layer rule names its namespace, and those rules
> list first-party namespaces. The diagnostic surface is now a real window
> (ADR-005), so it gets Omarchy's normal window blur and opacity rules and uses
> the theme's tokens unmodified. The reasoning below is kept because it is still
> the correct analysis for any *layer* surface a future version of this plugin
> might add.

## Context

The plugin must follow whatever Omarchy theme is applied, with no per-theme
special-casing. Colours and metrics therefore come exclusively from the shell's
theme singletons — `Color.*` and `Style.*` from `qs.Commons`. The repository
contains **no** colour literals; `scripts/check` can be extended to keep it that
way.

That part is straightforward. The complication is translucency.

Omarchy's own full-screen surfaces are translucent *because* the compositor
blurs what is behind them. Blur is applied by a Hyprland layer rule that names
namespaces explicitly. The currently installed theme, for example, allows blur
only for:

```
^(omarchy-bar|omarchy-menu|omarchy-notifications|omarchy-osd|omarchy-clipboard
 |omarchy-emojis|omarchy-image-selector|omarchy-keyboard-panel|omarchy-polkit
 |omarchy-reminders|omarchy-network-qr)$
```

A third-party plugin cannot appear in that list, and must not squat a first-party
namespace to sneak in. So on such a theme the menu tokens — designed to be read
through frosted glass — render as plain transparency, with the desktop legible
straight through the card.

Measured on this machine: `Color.menu.background` resolved to `#db101317`
(alpha 0.86) and the overlay was unreadable over bright content.

## Decision

1. Take every colour from the theme. Use the `menu` token group, which is what
   Omarchy's own full-screen surfaces use (`omarchy.clipboard` documents sharing
   it so that theming the menu themes the overlay too).

2. Keep the theme's hue and raise **only the alpha floor** for the two surfaces
   that would otherwise be see-through:

   ```qml
   cardFill:  Qt.rgba(background.r, background.g, background.b, Math.max(background.a, 0.97))
   scrimFill: Qt.rgba(scrim.r,      scrim.g,      scrim.b,      Math.max(scrim.a,      0.72))
   ```

3. Document an optional Hyprland layer rule for users who want true frosted
   glass (see README). With blur present the floor is harmless.

## Why this is not per-theme customization

`Math.max` never lowers a value and never changes a hue, so the floor is inert on
any theme whose menu background is already opaque. Of the 15 themes installed on
the development machine, 9 ship no `shell.menu.toml` at all and inherit
Omarchy's default alpha of `1.0` — for those the expression evaluates to exactly
the theme's own colour. Only themes that deliberately choose translucency are
affected, and only because the blur that justifies that choice is unavailable to
us.

## Alternatives rejected

- **Honour the alpha unconditionally.** Correct in principle, unreadable in
  practice on translucent themes, with no recourse the plugin can offer.
- **Reuse a first-party namespace** to inherit blur. Squatting; would also let
  our surface be caught by rules meant for Omarchy's own windows.
- **Have the plugin run `hyprctl keyword layerrule ...`.** Mutating compositor
  state from a diagnostic plugin violates the read-only invariant (§33), and
  would not persist.
- **A `FloatingWindow` instead of a layer surface** (the approach
  `b.okomart` takes) picks up ordinary window blur, but turns a transient
  diagnostic overlay into a managed window.

## Consequences

- Under a translucent theme the overlay reads as near-solid unless the user adds
  a blur rule for `omapreflight-overlay`.
- If a future Omarchy release offers a supported way for plugin layers to opt
  into blur, the floor should be removed in favour of it.
