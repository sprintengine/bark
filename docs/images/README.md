# README images

| Image | Files | Source |
| --- | --- | --- |
| Network hero, animated | `network-{light,dark}.svg` (+ static `.png` fallbacks) | `src/network.mjs` |
| App: model picker + live dictation | `app-dictation-{light,dark}.png` | `src/app-showcase.html` (real `home.html`, `index.html`, `cursor-preview.html`) |
| App: Home | `app-home-{light,dark}.png` | real `home.html`, captured with `shot.mjs` (below) |
| App: Models library | `app-models-{light,dark}.png` | real `home.html` on Models, one row opened |
| App: first-run setup | `app-onboarding-{light,dark}.png` | real `onboarding.html` (permissions, model, try it), joined by `src/onboarding-strip.py` |
| Host dashboard | `host-dashboard-{light,dark}.png` (dashboard is dark-only; the variant is the backdrop) | `src/host-showcase.html` + `src/host-mock.mjs` (real `src-tauri/src/host/dashboard.html`) |

The shared backdrop and window chrome live in `src/showcase.css`, and the palette matches
`src/design-system/tokens.css`. `src/tauri-stub.js` lets the real frontend run
in a plain browser.

## Regenerate

```bash
npm i --no-save playwright-core        # once, at the repo root (uses installed Google Chrome)
node docs/images/src/render.mjs        # everything, or: network | app | host
```

The script starts Vite and the mock host itself. It renders at 2x and runs
`pngquant` and `oxipng` when they're on `PATH` (`brew install pngquant oxipng`).
The network SVGs are generated output, so edit `src/network.mjs`, not the `.svg` files.

### Home, Models and setup

These are the real pages under Vite (`npm run dev -- --port 1537`), captured by
`design/concepts/_tools/shot.mjs`. `--stub` loads `design/concepts/_tools/tauri-stub.js`, a fake
Tauri bridge with fictional sample data, and `--desktop` paints a soft wallpaper behind the
transparent window where the macOS frost would be.

```bash
T=design/concepts/_tools/shot.mjs; U=http://localhost:1537
node $T $U/home.html home.png --stub --desktop --width 1100 --height 720            # add --dark
node $T $U/home.html models.png --stub --desktop --width 1100 --height 720 \
  --eval "document.querySelector('[data-screen=models]').click()"
node $T "$U/onboarding.html#permissions" permissions.png --stub --desktop --width 720 --height 860
node $T "$U/onboarding.html#model" model.png --stub --desktop --width 720 --height 860
node $T "$U/onboarding.html#try" try.png --stub --desktop --width 720 --height 860 --after 1200 \
  --eval "window.__stubEmit('transcript-history-updated',{item:{text:'Mostly emails and meeting notes.',durationSeconds:4.6}})"
python3 -I docs/images/src/onboarding-strip.py app-onboarding-light.png light permissions.png model.png try.png
```

Then `pngquant --ext .png --force` and `oxipng -o 3` as above.

## Product name

The name appears in exactly one place per source:

- `src/network.mjs`: `PRODUCT_NAME` (emitted as `<tspan id="product-name">` in each SVG).
- App screenshot: none in `src/`. The name comes from the app itself (`home.html`, "… Cloud" location option).
- Dashboard screenshot: none in `src/`. The name comes from the `brand-name` wordmark in `src-tauri/src/host/dashboard.html`.

To preview a candidate name without touching any app source, run
`PRODUCT_NAME=Foo node docs/images/src/render.mjs`. This regenerates the SVGs
and swaps the visible name in the rendered screenshots.

## Notes

- The SVGs embed Inter (SIL OFL 1.1, from `@fontsource/inter`) as base64. They
  contain only inline CSS animation: no scripts and no external requests, so they
  animate inside GitHub's `<img>` sandbox. They respect `prefers-reduced-motion`.
- The dashboard data is a fictional GP-practice scenario. The browser clock is frozen to
  `SCENARIO_NOW` in `src/host-mock.mjs`.
