# Cyberpunk Work Style

A local DeepSeek Harness bundle that restyles the Web UI as a neon night city.

## What it does

| Layer | Effect |
| --- | --- |
| `ctx.theme.overrideTokens()` layer | Replaces the alias-layer palette: deep-space surfaces, cyan ink, magenta alerts, neon borders and elevation stroke, mono interface type, sharper corner radii. |
| Appearance (light / dark / system) | Still works — the layer ships both variants: **Night City** (dark) and **Daylight Hacker** (light). |
| `shell.overlay` entry | Click-through CRT scanline field with a soft vignette. |
| `conversation.composer.dock` entry | Pulsing neon status line under the composer card. |

Everything is registered through the Client services and disposed with the
plugin; no DOM outside the components is written.

## Install

```
plugin_manager install_bundle target=<absolute path to this directory>
```

The bundle is linked, not copied, so keep this directory where it is. Remove it
with `plugin_manager remove_bundle` (or disable the `cyberpunk-theme` row) to
return to the stock style.

## Notes

- The UI font becomes monospace; an explicit font-family set in **Settings →
  Appearance → Font** stays overridden while this bundle is installed.
- The token layer follows the Appearance preference, so switching Light/Dark
  swaps between the two cyberpunk variants instead of disabling the style.
