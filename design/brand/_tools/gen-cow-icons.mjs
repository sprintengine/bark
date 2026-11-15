// Generates every app icon from the cow mark's vector masters in logo/cow/.
//
//   node design/brand/_tools/gen-cow-icons.mjs
//
// Needs Node 22+ and Playwright (`npm i playwright` anywhere up the tree from the
// directory you run it in, outside the repo is fine) with Google Chrome or a
// Playwright Chromium. Set CHROME to a browser binary to choose one.
//
// Masters (hand-finished SVG, the 1024 grid of the icon artwork):
//   logo/cow/cow-mark.svg          full detail, for 128 px and up
//   logo/cow/cow-mark-medium.svg   no eyes, five bars, for 48 to 96 px
//   logo/cow/cow-mark-small.svg    thickened, three bars, for 17 to 32 px
//   logo/cow/cow-mark-tiny.svg     thicker still, two bars, for 16 px
//
// Writes:
//   logo/cow/app-icon.svg, app-icon-server.svg   the Mac tiles, as vectors
//   logo/cow/app-icon-1024.png                   the Tauri master (`npx tauri icon` input)
//   logo/cow/readme-header.svg                   the README header
//   apps/macos/{Fairspoken,FairspokenServer}/Resources/Assets.xcassets/AppIcon.appiconset/*.png
//   src-tauri/icons: icon.icns, icon.ico and the small square PNGs, each from the right
//     master for its size (run `npx tauri icon design/brand/logo/cow/app-icon-1024.png`
//     first for the rest; this then replaces the sizes it would only have scaled down,
//     makes the iOS set full-bleed and the Android adaptive foreground the mark alone)
//   apps/android/app/src/main/res/drawable/ic_launcher_{background,foreground}.xml
//   apps/macos/Packages/FairspokenUI/Sources/FairspokenUI/CowMarkPaths.swift
//
// Not written, so copy them by hand when a master changes: the inline SVGs in
// home.html (sidebar: small; empty state: medium), src/onboarding.ts (ICONS.cow:
// medium) and src-tauri/src/host/dashboard.html (header: small), each the master's
// shapes in currentColor on a square viewBox of "76 57.5 871 871".
import { readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = fileURLToPath(new URL('../../../', import.meta.url));
const COW = REPO + 'design/brand/logo/cow/';

// ── Masters ──────────────────────────────────────────────────────────────
function readMark(file) {
  const svg = readFileSync(COW + file, 'utf8');
  const cow = svg.match(/<path id="cow"([^>]*)\/>/)[1];
  const attr = (name) => cow.match(new RegExp(`\\s${name}="([^"]+)"`))?.[1];
  const bars = [...svg.matchAll(/<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"/g)]
    .map((m) => m.slice(1).map(Number));
  return {
    cow: attr('d'),
    stroke: Number(attr('stroke-width') ?? 0),
    eyes: svg.match(/<path id="eyes" d="([^"]+)"/)?.[1] ?? '',
    bars, // [x, y, width, height], ends fully rounded
  };
}
const MARKS = {
  full: readMark('cow-mark.svg'), medium: readMark('cow-mark-medium.svg'),
  small: readMark('cow-mark-small.svg'), tiny: readMark('cow-mark-tiny.svg'),
};
for (const [kind, mark] of Object.entries(MARKS)) mark.kind = kind;
/** The master to draw when the whole icon is `px` pixels square. */
const markFor = (px) => (px <= 16 ? MARKS.tiny : px <= 32 ? MARKS.small : px <= 96 ? MARKS.medium : MARKS.full);

// The mark's extent on the 1024 grid, for centring and scaling.
const BOX = { x: 76, y: 183, w: 871, h: 620 };
const round = (v, p = 3) => +v.toFixed(p);

/** The mark as SVG, its box centred on (cx, cy) and `width` wide. */
function glyph(mark, { cx, cy, width, fill = '#fff' }) {
  const s = width / BOX.w;
  const tx = cx - (BOX.x + BOX.w / 2) * s, ty = cy - (BOX.y + BOX.h / 2) * s;
  const stroke = mark.stroke ? ` stroke="${fill}" stroke-width="${mark.stroke}" stroke-linejoin="round"` : '';
  const bars = mark.bars.map(([x, y, w, h]) => `<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${w / 2}"/>`).join('');
  return `<g fill="${fill}" transform="translate(${round(tx)} ${round(ty)}) scale(${round(s, 5)})">` +
    `<path fill-rule="evenodd"${stroke} d="${mark.cow}"/>` + (mark.eyes ? `<path d="${mark.eyes}"/>` : '') + bars + '</g>';
}

// ── The Mac tile ─────────────────────────────────────────────────────────
// Apple's macOS grid: an 824 body on a 1024 canvas, 100 in from each side, with
// continuous corners and a soft shadow in the margin. Each corner is a superellipse
// quadrant 1.528 radii long (as in Apple's continuous corners), with the exponent
// that puts its midpoint where a 185.4 circular corner would be; its curvature
// falls to zero where it meets the straight sides, so there is no visible joint.
function continuousRect(x, y, size, radius = 185.4, steps = 48) {
  const e = 1.528 * radius;
  const n = Math.log(2) / -Math.log(1 - (radius * (1 - Math.SQRT1_2)) / e);
  const pts = [];
  // Corners clockwise from top right: centre of the quadrant and its direction.
  const corners = [[x + size - e, y + e, 1, -1], [x + size - e, y + size - e, 1, 1], [x + e, y + size - e, -1, 1], [x + e, y + e, -1, -1]];
  corners.forEach(([cx, cy, sx, sy], k) => {
    for (let i = 0; i <= steps; i++) {
      let t = (i / steps) * (Math.PI / 2);
      if (k % 2 === 0) t = Math.PI / 2 - t; // walk each quadrant in path order
      const u = Math.cos(t) ** (2 / n), v = Math.sin(t) ** (2 / n);
      pts.push(`${round(cx + sx * e * u, 2)} ${round(cy + sy * e * v, 2)}`);
    }
  });
  return `M${pts.join('L')}Z`;
}
const TILE = continuousRect(100, 100, 824);
// The glyph's width on the tile, per master: the smaller masters sit larger so
// their shapes keep a pixel or more.
const GLYPH_WIDTH = { full: 664, medium: 690, small: 730, tiny: 770 };
// Optical centre: the bars carry weight low and right, so the box sits a touch
// left of and above the tile's centre.
const GLYPH_CENTRE = { cx: 506, cy: 506 };

function appIcon(mark, { server = false } = {}) {
  const { kind } = mark;
  const line = { full: 4, medium: 10, small: 22, tiny: 40 }[kind];
  // Fairspoken Server keeps the client's cow and tells itself apart, as its old
  // icon did, with faint ruled lines across the tile, like the front of a rack.
  const rules = server
    ? `<g clip-path="url(#tile)" stroke="#fff" stroke-opacity="${kind === 'full' ? 0.085 : 0.12}" stroke-width="${Math.max(5, line)}">` +
      [0, 1, 2, 3, 4, 5, 6].map((i) => `<path d="M100 ${218 + i * 98}H924"/>`).join('') + '</g>'
    : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
<clipPath id="tile"><path d="${TILE}"/></clipPath>
<linearGradient id="fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${server ? '#303036' : '#2a2a2d'}"/><stop offset="1" stop-color="${server ? '#0d0e11' : '#0a0a0b'}"/></linearGradient>
<linearGradient id="edge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".30"/><stop offset=".5" stop-color="#fff" stop-opacity=".10"/><stop offset="1" stop-color="#fff" stop-opacity=".16"/></linearGradient>
<filter id="shadow" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".32"/></filter>
</defs>
<path d="${TILE}" fill="url(#fill)" filter="url(#shadow)"/>
${rules}
<path d="${TILE}" fill="none" stroke="url(#edge)" stroke-width="${line}" clip-path="url(#tile)"/>
${glyph(mark, { ...GLYPH_CENTRE, width: GLYPH_WIDTH[kind] })}
</svg>
`;
}

// The README header: the mark alone on a dark rounded backdrop, no name.
function readmeHeader() {
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 420" width="960" height="420" role="img" aria-label="A black-and-white cow with its mouth open and voice level bars coming out of it">
<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#202023"/><stop offset="1" stop-color="#09090a"/></linearGradient></defs>
<rect width="960" height="420" rx="36" fill="url(#bg)"/>
${glyph(MARKS.full, { cx: 476, cy: 210, width: 470 })}
</svg>
`;
}

// ── Rendering ────────────────────────────────────────────────────────────
async function loadPlaywright() {
  for (const name of ['playwright', 'playwright-core']) {
    try { return await import(name); } catch {}
    try { return await import(createRequire(path.join(process.cwd(), 'x.js')).resolve(name)); } catch {}
  }
  throw new Error('Playwright not found: npm i playwright in this directory or a parent');
}
const pw = await loadPlaywright();
const chromium = pw.chromium ?? pw.default.chromium;
const chrome = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = await chromium.launch(existsSync(chrome) ? { executablePath: chrome } : {});
// One fixed viewport at least as large as any render: resizing it between renders
// can leave a screenshot of a stale, half-laid-out frame.
const page = await browser.newPage({ deviceScaleFactor: 1, viewport: { width: 1024, height: 1024 } });
async function png(svg, size, out) {
  await page.setContent(`<!doctype html><style>html,body{margin:0;background:transparent}img{display:block;width:${size}px;height:${size}px}</style>` +
    `<img src="data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}">`);
  // Decoded and painted: two frames after decode() settles.
  await page.evaluate(() => document.images[0].decode().then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))));
  const buf = await page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
  if (out) writeFileSync(out, buf);
  return buf;
}
const iconPng = (px, opts) => png(appIcon(markFor(px), opts), px);

// ── Vectors ──────────────────────────────────────────────────────────────
writeFileSync(COW + 'app-icon.svg', appIcon(MARKS.full));
writeFileSync(COW + 'app-icon-server.svg', appIcon(MARKS.full, { server: true }));
writeFileSync(COW + 'readme-header.svg', readmeHeader());
await png(appIcon(MARKS.full), 1024, COW + 'app-icon-1024.png');

// ── macOS asset catalogues ───────────────────────────────────────────────
const MAC_SIZES = [16, 32, 128, 256, 512].flatMap((pt) => [[pt, 1], [pt, 2]]);
for (const [dir, server] of [['Fairspoken', false], ['FairspokenServer', true]]) {
  const out = `${REPO}apps/macos/${dir}/Resources/Assets.xcassets/AppIcon.appiconset/`;
  for (const [pt, scale] of MAC_SIZES) {
    writeFileSync(`${out}icon_${pt}x${pt}${scale === 2 ? '@2x' : ''}.png`, await iconPng(pt * scale, { server }));
  }
}

// ── Tauri ────────────────────────────────────────────────────────────────
const TAURI = REPO + 'src-tauri/icons/';
// icon.icns from the client's own sizes, so 16 and 32 get the small master.
const iconset = path.join(tmpdir(), `cow-${process.pid}.iconset`);
mkdirSync(iconset, { recursive: true });
for (const [pt, scale] of MAC_SIZES) {
  writeFileSync(`${iconset}/icon_${pt}x${pt}${scale === 2 ? '@2x' : ''}.png`, await iconPng(pt * scale));
}
execFileSync('iconutil', ['-c', 'icns', iconset, '-o', TAURI + 'icon.icns']);
rmSync(iconset, { recursive: true });
// icon.ico: the same sizes `tauri icon` writes, PNG-compressed entries.
const icoSizes = [32, 16, 24, 48, 64, 256];
const icoImages = [];
for (const px of icoSizes) icoImages.push(await iconPng(px));
const header = Buffer.alloc(6 + 16 * icoSizes.length);
header.writeUInt16LE(0, 0); header.writeUInt16LE(1, 2); header.writeUInt16LE(icoSizes.length, 4);
let offset = header.length;
icoSizes.forEach((px, i) => {
  const e = 6 + 16 * i;
  header.writeUInt8(px % 256, e); header.writeUInt8(px % 256, e + 1);
  header.writeUInt16LE(1, e + 4); header.writeUInt16LE(32, e + 6);
  header.writeUInt32LE(icoImages[i].length, e + 8); header.writeUInt32LE(offset, e + 12);
  offset += icoImages[i].length;
});
writeFileSync(TAURI + 'icon.ico', Buffer.concat([header, ...icoImages]));
// The small PNGs `tauri icon` only scales down.
for (const [file, px] of [['32x32.png', 32], ['64x64.png', 64], ['Square30x30Logo.png', 30], ['Square44x44Logo.png', 44],
  ['Square71x71Logo.png', 71], ['Square89x89Logo.png', 89], ['StoreLogo.png', 50]]) {
  if (existsSync(TAURI + file)) writeFileSync(TAURI + file, await iconPng(px));
}

// iOS draws its own corners, so its icons are full-bleed: the tile's fill to the
// edges and the glyph at the same share of the tile.
const fullBleed = (px) => {
  const mark = markFor(px), k = 1024 / 824;
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs><linearGradient id="fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2a2a2d"/><stop offset="1" stop-color="#0a0a0b"/></linearGradient></defs>
<rect width="1024" height="1024" fill="url(#fill)"/>
${glyph(mark, { cx: 512 + (GLYPH_CENTRE.cx - 512) * k, cy: 512 + (GLYPH_CENTRE.cy - 512) * k, width: GLYPH_WIDTH[mark.kind] * k })}
</svg>`;
};
for (const file of readdirSync(TAURI + 'ios')) {
  const m = file.match(/^AppIcon-([\d.]+)(?:x[\d.]+)?@(\d)x/);
  if (m) { const px = Math.round(Number(m[1]) * Number(m[2])); writeFileSync(`${TAURI}ios/${file}`, await png(fullBleed(px), px)); }
}
// Android adaptive icons: the mark alone in the 66/108 safe zone over a dark background colour.
for (const [dir, px] of [['mdpi', 108], ['hdpi', 162], ['xhdpi', 216], ['xxhdpi', 324], ['xxxhdpi', 432]]) {
  const fg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108" width="108" height="108">${glyph(MARKS.medium, { cx: 54, cy: 54, width: 58 })}</svg>`;
  const file = `${TAURI}android/mipmap-${dir}/ic_launcher_foreground.png`;
  if (existsSync(file)) writeFileSync(file, await png(fg, px));
}
if (existsSync(TAURI + 'android/values/ic_launcher_background.xml')) {
  writeFileSync(TAURI + 'android/values/ic_launcher_background.xml',
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n  <color name="ic_launcher_background">#151517</color>\n</resources>');
}

await browser.close();

// ── Android (adaptive launcher icon, 108 dp with a 66 dp safe circle) ───
const capsule = ([x, y, w, h]) => {
  const r = w / 2;
  return `M${x} ${y + r}a${r},${r} 0,0 1,${w},0v${h - w}a${r},${r} 0,0 1,${-w},0z`;
};
{
  const mark = MARKS.medium, width = 58, s = width / BOX.w;
  const tx = 54 - (BOX.x + BOX.w / 2) * s, ty = 54 - (BOX.y + BOX.h / 2) * s;
  const res = REPO + 'apps/android/app/src/main/res/drawable/';
  writeFileSync(res + 'ic_launcher_foreground.xml', `<?xml version="1.0" encoding="utf-8"?>
<!-- The cow mark (design/brand/logo/cow/cow-mark-medium.svg), white on the dark
     background layer. Generated by design/brand/_tools/gen-cow-icons.mjs. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <group android:translateX="${round(tx, 4)}" android:translateY="${round(ty, 4)}"
        android:scaleX="${round(s, 6)}" android:scaleY="${round(s, 6)}">
        <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd"
            android:pathData="${mark.cow}" />
        <path android:fillColor="#FFFFFFFF"
            android:pathData="${mark.bars.map(capsule).join('')}" />
    </group>
</vector>
`);
  writeFileSync(res + 'ic_launcher_background.xml', `<?xml version="1.0" encoding="utf-8"?>
<!-- Near-black, a touch lighter at the top, as on the Mac icon's tile. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr xmlns:aapt="http://schemas.android.com/aapt" name="android:fillColor">
            <gradient android:type="linear" android:startX="0" android:startY="0"
                android:endX="0" android:endY="108"
                android:startColor="#FF2A2A2D" android:endColor="#FF0A0A0B" />
        </aapt:attr>
    </path>
</vector>
`);
}

// ── Swift (FairspokenUI's CowMark) ───────────────────────────────────────
{
  const bars = (m) => m.bars.map(([x, y, w, h]) => `CGRect(x: ${x}, y: ${y}, width: ${w}, height: ${h})`).join(', ');
  writeFileSync(REPO + 'apps/macos/Packages/FairspokenUI/Sources/FairspokenUI/CowMarkPaths.swift', `// Generated by design/brand/_tools/gen-cow-icons.mjs from design/brand/logo/cow/. Do not edit.
import CoreGraphics

extension CowMark {
    /// The mark's extent on the 1024 grid of the masters.
    static let box = CGRect(x: ${BOX.x}, y: ${BOX.y}, width: ${BOX.w}, height: ${BOX.h})

    struct Master: Sendable {
        /// The white patches, ears and cheek, with the mouth and nostrils cut out (even-odd).
        let cow: String
        /// Lids and catchlights; empty in the smaller masters.
        let eyes: String
        /// Extra width that thickens the shapes, for the small master.
        let stroke: CGFloat
        /// The voice bars, fully rounded.
        let bars: [CGRect]
    }

${Object.entries(MARKS).map(([k, m]) => `    static let ${k} = Master(
        cow: "${m.cow}",
        eyes: "${m.eyes}",
        stroke: ${m.stroke},
        bars: [${bars(m)}])`).join('\n\n')}
}
`);
}
console.log('done');
