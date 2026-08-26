# Screenshots

| File | Shows |
|---|---|
| [`report-window.png`](report-window.png) | The full report window: all 21 checks, six categories, worst-first |
| [`finding-expanded.png`](finding-expanded.png) | A failing check expanded to its evidence and suggested next step |
| [`quick-panel.png`](quick-panel.png) | The bar widget and its quick panel — the verdict and what needs attention |
| [`../preview.png`](../preview.png) | Marketplace card |

## Reproducing them

All of these are real scans of a real machine. Nothing is mocked — there is no
demo mode inside the plugin and no way to make it report something it did not
observe.

The failing check is genuine: `scripts/demo` creates a plugin with an invalid
manifest, which the shell drops during discovery and never mentions again, and
the real check finds it.

```bash
scripts/demo                                     # create the fault, scan
omarchy-shell shell summon p134c0d3.omapreflight # open the window
# capture, then:
scripts/demo --clean                             # remove the fault, rescan
```

The theme is whatever is applied — every colour here is a theme token, so these
will look different on yours.
