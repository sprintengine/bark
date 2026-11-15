# Crystal: the Fairspoken app theme

One look for every Fairspoken surface: the Mac apps (SwiftUI, Liquid Glass), the desktop app
(Tauri web UI), the host's web dashboard and the Android app.

Crystal is **frosted silver glass on a cool, near-neutral backdrop**. Colour is a hint, not a
theme: one accent, used sparingly, at low saturation. The clients and the server differ only in
that hint, so you can tell them apart at a glance:

| Surface | Accent hint |
| --- | --- |
| Clients (Fairspoken for Mac, desktop app, Android) | **Green** (sage / emerald) |
| Server (Fairspoken Server, the host web dashboard) | **Red** (garnet) |

No orange/blue gradients, no saturated colour blobs, no rainbow charts.

## Tokens

### Neutrals (shared)

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `page` | `#EDEFF2` | `#0D0F12` | Window / page base |
| `page-sheen` | `#FFFFFF` | `#1B1F24` | Highlight in the backdrop gradient |
| `surface` | `rgba(255,255,255,0.62)` | `rgba(255,255,255,0.055)` | Glass card fill (web/Android; SwiftUI uses `.glassEffect`) |
| `surface-strong` | `rgba(255,255,255,0.82)` | `rgba(255,255,255,0.09)` | Popovers, focused fields |
| `edge` | `rgba(255,255,255,0.85)` | `rgba(255,255,255,0.10)` | 1px top/inner highlight on glass |
| `hairline` | `rgba(16,24,32,0.09)` | `rgba(255,255,255,0.08)` | Dividers, outer border |
| `ink` | `#15191D` | `#E8ECEF` | Primary text |
| `ink-2` | `#5B6670` | `#9AA4AD` | Secondary text |
| `ink-3` | `#8A949C` | `#6B747C` | Tertiary text, placeholders |

### Accents

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `client-accent` | `#2E8B5E` | `#5CCB94` | Client primary buttons, selection, focus, "ready" |
| `client-tint` | accent at 5–8% | accent at 8–12% | Backdrop wash, selected-row fill |
| `server-accent` | `#B2453E` | `#F07F76` | Server primary buttons, selection, focus |
| `server-tint` | accent at 5–8% | accent at 8–12% | Backdrop wash, selected-row fill |

### Status (functional, never decorative)

| Token | Light | Dark |
| --- | --- | --- |
| `ok` | `#2E8B5E` | `#5CCB94` |
| `warn` | `#9A6B12` | `#E7B95A` |
| `error` | `#B4283C` | `#FF7D8E` |
| `live` (microphone on) | `#D9483B` | `#FF6E62` |

On the server, errors keep an icon (`exclamationmark.triangle`) so they never read as the
red accent.

## Backdrop

A still (never animated) vertical sheen: `page-sheen` at the top fading to `page`, plus **one**
very soft, large, blurred radial wash of the surface's accent at ≤ 8% (light) / ≤ 12% (dark)
opacity in the top-leading corner. That's it: glass needs *something* to refract, but the
something should read as brushed silver, not colour.

## Glass

- SwiftUI: `.glassEffect(.regular, in: .rect(cornerRadius: 20))`, grouped in one
  `GlassEffectContainer` per screen. No glass on glass. Tint glass only for the one primary
  control on a screen, with the accent.
- Web: `background: var(--surface); backdrop-filter: blur(24px) saturate(160%);`
  `border: 1px solid var(--hairline); box-shadow: inset 0 1px 0 var(--edge), 0 8px 24px rgba(16,24,32,0.06);`
- Android: the backdrop library's glass with a white 0.55–0.65 surface, a 1px highlight edge.

Radii: 20 for cards, 12 for fields and rows, capsule for buttons and chips.

## Fairspoken for Mac: a frosted sidebar beside solid content

The Mac client keeps glass to the window's chrome and to small floating pieces. Content is opaque,
so it reads crisply and nothing translucent stacks on anything translucent.

- **Frost:** the window's background is the desktop blurred behind the window
  (`NSVisualEffectView`, material `.sidebar`, blending `.behindWindow`), with `frostTint` (the page
  tone at 52%) laid over it **once**. The sidebar stands on it directly. With Reduce Transparency
  the frost is `frostSolid`, the same tone, opaque.
- **Content:** one opaque card (`canvas`) beside the sidebar, inset 4 pt from the window's edges so
  a thin line of frost frames it. Inside it, solid cards (`card`): 12 pt corners, a `hairline`
  edge (8–10%, stronger with Increase Contrast), a 1 pt highlight along the top edge and a tight,
  soft shadow. Rows inside cards hover with `rowHover`; rows on the frost use `chromeHover` and
  `chromeSelected`, one alpha step over the tint.
- **Glass** only for the recording pill, toasts and popovers.
- **Sidebar:** each section has a coloured rounded-square icon tile (Home orange, Models indigo,
  Post-training purple, Settings grey); the engine status sits at the bottom.
- **Type:** system font, 13 pt body, six steps: 11 / 12 / 13 / 15 / 20 / 28 (`TypeScale`).
- **Motion:** 120 / 180 / 260 ms on one ease-out curve (`Motion`), none with Reduce Motion.
- **Primary action:** one per screen, an accent capsule drawn with an explicit fill
  (`PrimaryButtonStyle`).

| Token | Light | Dark |
| --- | --- | --- |
| `canvas` | `#F5F6F8` | `#111316` |
| `card` | `#FFFFFF` | `#1A1D21` |
| `frostTint` | `#EAEEF2` at 52% | `#090A0C` at 52% |
| `hairline` | `rgba(16,24,32,0.10)` | `rgba(255,255,255,0.09)` |

## Type

System font (SF Pro / system-ui / Roboto). Titles semibold with slightly tight tracking.
Numbers rounded and tabular. Addresses, tokens and timings in monospace.

## Writing

- One line of subtitle at most. If the title says it, drop the subtitle.
- No paragraphs that explain the UI. Name the control well instead.
- Labels in sentence case. Buttons are verbs ("Pair", "Copy", "Test").
- Advanced and rarely changed settings go behind a disclosure, not on the first screen.
