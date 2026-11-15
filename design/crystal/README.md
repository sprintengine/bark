# Crystal: the Bark app theme

One look for every Bark surface: the Mac apps (SwiftUI, Liquid Glass), the desktop app
(Tauri web UI), the host's web dashboard and the Android app.

Crystal is **a frosted frame around opaque content**. The window's chrome (the sidebar) is the
system's own frost; everything you read or act on stands on solid, rounded cards. Colour is a
hint, not a theme: one accent, used sparingly, plus a coloured tile per place in the sidebar.
The clients and the server differ only in the accent, so you can tell them apart at a glance:

| Surface | Accent hint |
| --- | --- |
| Clients (Bark for Mac, desktop app, Android) | **Green** (sage / emerald) |
| Server (Bark Server, the host web dashboard) | **Red** (garnet) |

No orange/blue gradients, no saturated colour blobs, no rainbow charts.

## Materials

The rule that everything else follows: **only the chrome is frosted, and the frost is never
stacked.**

- **The frost.** On macOS the window uses the native `underWindowBackground` material behind a
  transparent webview (`tauri.conf.json`). The theme's `page` colour is painted **once**, on
  `body`, at 52% (`color-mix(in srgb, var(--crystal-page) 52%, transparent)`), and every layer
  above it that belongs to the chrome stays transparent, so the desktop's blur shows through
  evenly. Elsewhere (Windows, Linux, reduced transparency) `body` paints `page` opaque and the
  layout is unchanged.
- **The canvas.** The content column is one opaque card (`canvas`), inset 4px from the window's
  top, right and bottom edges so a thin line of frost frames it. Radius 12.
- **Cards.** Groups on the canvas are opaque `card`s: radius 12, a hairline edge at 8–10%
  alpha, a 1px inner top highlight, and a tight two-layer shadow
  (`0 1px 2px` + `0 2px 8px -2px`). A list of things (recent dictations) is a stack of cards
  4px apart rather than rows in one card.
- **Blur in CSS** is allowed only on small, short-lived surfaces that float over content:
  popovers, menus, tooltips and toasts (`blur(14px) saturate(1.1)`, over a dense fill). Never
  on a card, a pane or anything over live content.

### Rows on the frost

A sidebar row's hover, pressed and selected fills are mixed toward transparent (45%, 50% and
60% of their opaque inks), so a row tints the frost instead of laying a slab over it. A row
wears one state at a time: nothing stacks. On an opaque window the same inks are used solid.

Each sidebar place has a 22px rounded-square tile in its own hue with a white glyph drawn in
the style of the system symbols (Home green, Notes amber, Dictionary orange, Models indigo,
Activity pink, Settings grey); blue, teal and violet are kept for the setup guide's tiles. The tiles are the only decorative colour.

## Tokens

All tokens live in `src/crystalTokens.css`; the vendored design-system tokens are re-pointed at
them, so components follow without local overrides.

### Grounds and ink

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `page` | `#E6E9ED` | `#202328` | Window colour (52% over the frost on a Mac) |
| `canvas` | `#F6F7F9` | `#151719` | The content column |
| `card` | `#FFFFFF` | `#1D2023` | Cards on the canvas |
| `card-edge` | ink at 9% | white at 8% | Card and control hairline |
| `card-highlight` | white at 90% | white at 4.5% | 1px inner top edge |
| `hairline` | ink at 9% | white at 8% | Dividers inside a card |
| `ink` | `#16191D` | `#E9ECEF` | Primary text |
| `ink-2` | `#59636D` | `#A3ACB5` | Secondary text (≥ 4.5:1 on card and canvas) |
| `ink-3` | `#6A747E` | `#8B949D` | Tertiary text, placeholders |
| `row-hover` / `row-active` / `row-selected` | `#F2F4F6` / `#DFE3E8` / `#CDD3DA` | `#33373D` / `#3B4047` / `#434950` | Sidebar row inks (mixed toward transparent under the frost) |

### Accent and status

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `accent` | `#237A50` | `#5CCB94` | Primary buttons, selection, focus, "in use", the time-saved figure |
| `tint` / `tint-strong` | accent at 8% / 16% | accent at 10% / 18% | Selected-row fill, focus halo, soft badges |
| `ok` | `#237A50` | `#5CCB94` | Ready, allowed |
| `warn` | `#94660F` | `#E7B95A` | Needs a look |
| `error` | `#B4283C` | `#FF7D8E` | Failed |
| `live` | `#D93B2F` | `#FF6A5E` | Microphone on |

Status colours are functional, never decorative. On the server, errors keep an icon
(`exclamationmark.triangle`) so they never read as the red accent.

### Shape, type and motion

- **Radii:** 12 for cards and the canvas, 8 for rows, fields and wells, 6 for push buttons and
  popups, capsule for chips, filters and the pill.
- **Type:** the system font stack (SF Pro / Segoe UI / Roboto), 13px body, tracking `-0.01em`.
  The scale is 11 / 12 / 13 / 14 / 16 / 28: micro labels, meta, body, section titles, card
  titles, page titles. Numbers are rounded and tabular. Shortcuts are keycaps.
- **Motion:** 120ms (hover, press), 180ms (toggles, disclosure), 260ms (entering content),
  all on `cubic-bezier(0.2, 0.8, 0.2, 1)`. `prefers-reduced-motion` turns transitions and
  loops off; the information stays.
- **Light and dark** are both first-class: every token has both values, and every screen is
  checked in both.

## Controls

- Push buttons are bordered bezels on the card colour with the top highlight; the primary one
  is the accent. One primary per view.
- Segmented controls and the Settings tab strip are a grey track whose chosen segment is a
  raised chip, not an accent fill.
- Switches are capsules with a round white thumb, accent when on.
- Ratings (a model's speed and accuracy) are five short steps, filled in the accent.

## Screens

- **Home** leads with one card of four figures (average pace, words, apps used, time saved),
  then the latest dictations as cards with their app, when, and copy, with "See all" to Notes.
- **Models** is a library table: favourite, name with badges (EN, Recommended, New), kind
  (speech or polish), speed and accuracy ratings, size, where it runs, and one action. Search,
  filters and column sorting sit above it; a row opens to its details.
- **Onboarding** is its own centred window (720 × 860) with a softly tinted top: one step at a
  time, a large icon tile and title, rounded cards, and one primary button; optional steps
  offer Skip or Not now.
- **The pill** is an opaque capsule (translucency smudges at that size). Recording shows the
  live dot, a nine-bar level meter, the timer and "Stop" with the shortcut.

## Glass on the other platforms

- SwiftUI: `.glassEffect(.regular, in: .rect(cornerRadius: 12))` for chrome, grouped in one
  `GlassEffectContainer` per screen. No glass on glass. Content cards are opaque. Tint glass
  only for the one primary control on a screen, with the accent.
- Android: the backdrop library's glass for chrome only, a 1px highlight edge; content on
  opaque cards.

## Bark for Mac: a frosted sidebar beside solid content

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

## Writing

- One line of subtitle at most. If the title says it, drop the subtitle.
- No paragraphs that explain the UI. Name the control well instead.
- Labels in sentence case. Buttons are verbs ("Pair", "Copy", "Test").
- Advanced and rarely changed settings go behind a disclosure, not on the first screen.
