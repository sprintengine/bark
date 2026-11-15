// Generates every app icon and brand tile from the sheepdog sources in logo/dog/.
//
//   node design/brand/_tools/gen-dog-icons.mjs
//
// Needs Node 22+, Playwright and sharp (`npm i playwright sharp` anywhere up the tree
// from the directory you run it in; outside the repo is fine) and Google Chrome or a
// Playwright Chromium (set CHROME to choose one). Run `npx tauri icon
// design/brand/logo/dog/app-icon-1024.png` first if src-tauri/icons needs its file set
// recreating; this script then redraws every file in it.
//
// Sources:
//   logo/dog/dog-photo.png   the photograph, square, cropped so the face is centred
//   logo/dog/dog-mark.svg    the one-colour mark traced from the photo's white markings
//
// The icon is a raster: Chrome composites one 1024 master (Apple's 824/1024 tile, the
// photo filling it, a hairline edge and the shadow) and sharp scales it down with
// Lanczos, sharpening a little at 64 px and below. Every size uses the same art.
//
// Writes:
//   logo/dog/app-icon-1024.png, readme-header.png
//   apps/macos/{Fairspoken,FairspokenServer}/Resources/Assets.xcassets/AppIcon.appiconset/*.png
//   apps/macos/Fairspoken/Resources/Assets.xcassets/BrandTile.imageset (BrandMark's photo)
//   apps/macos/Packages/FairspokenUI/Sources/FairspokenUI/DogMarkPaths.swift
//   apps/android/app/src/main/res: the launcher's photo foreground, black background
//     and the mark as its monochrome (themed) layer
//   src-tauri/icons: every PNG, icon.icns, icon.ico, the iOS set (full-bleed) and the
//     Android set (the photo as the adaptive foreground)
//   src/assets/brand/dog-tile.jpg (the Tauri app's brand tiles)
//   src-tauri/src/host/dashboard.html: the header tile's inline image
import { readFileSync, writeFileSync, readdirSync, mkdirSync, rmSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO = fileURLToPath(new URL('../../../', import.meta.url));
const DOG = REPO + 'design/brand/logo/dog/';

async function load(name) {
  try { return await import(name); } catch {}
  const mod = await import(createRequire(path.join(process.cwd(), 'x.js')).resolve(name));
  return mod.default ?? mod;
}
const sharp = (await load('sharp')).default ?? (await load('sharp'));
const pw = await load('playwright').catch(() => load('playwright-core'));
const chromium = pw.chromium ?? pw.default.chromium;

// ── Sources ──────────────────────────────────────────────────────────────
const PHOTO = DOG + 'dog-photo.png';
const MARK = readFileSync(DOG + 'dog-mark.svg', 'utf8').match(/<path id="dog"[^>]*\sd="([^"]+)"/)[1];
// The mark's extent on the photo's 1024 grid.
const BOX = { x: 366, y: 28, w: 489, h: 952 };
const round = (v, p = 3) => +v.toFixed(p);
const dataUri = (buf, type = 'image/png') => `data:${type};base64,${buf.toString('base64')}`;

// ── The tile ─────────────────────────────────────────────────────────────
// Apple's macOS grid: an 824 body on a 1024 canvas, 100 in from each side, with
// continuous corners and a soft shadow in the margin. Each corner is a superellipse
// quadrant 1.528 radii long (as in Apple's continuous corners), with the exponent
// that puts its midpoint where a 185.4 circular corner would be.
function continuousRect(x, y, size, radius = 185.4, steps = 48) {
  const e = 1.528 * radius;
  const n = Math.log(2) / -Math.log(1 - (radius * (1 - Math.SQRT1_2)) / e);
  const pts = [];
  const corners = [[x + size - e, y + e, 1, -1], [x + size - e, y + size - e, 1, 1], [x + e, y + size - e, -1, 1], [x + e, y + e, -1, -1]];
  corners.forEach(([cx, cy, sx, sy], k) => {
    for (let i = 0; i <= steps; i++) {
      let t = (i / steps) * (Math.PI / 2);
      if (k % 2 === 0) t = Math.PI / 2 - t;
      pts.push(`${round(cx + sx * e * Math.cos(t) ** (2 / n), 2)} ${round(cy + sy * e * Math.sin(t) ** (2 / n), 2)}`);
    }
  });
  return `M${pts.join('L')}Z`;
}
const TILE = continuousRect(100, 100, 824);
const photo824 = await sharp(PHOTO).resize(824, 824, { kernel: 'lanczos3' }).png().toBuffer();

/**
 * The 1024 master. `forPx` is the size it will be scaled to: the hairline edge and
 * the server's ruled lines are drawn heavier for small sizes so they survive.
 */
function tileSvg({ server = false, forPx = 1024 } = {}) {
  const k = Math.max(1, 64 / forPx);
  const edge = Math.min(4 * k, 48), rule = Math.min(5 * k, 40);
  // Fairspoken Server keeps the dog and tells itself apart, as its old icon did, with
  // faint ruled lines across the tile, like the front of a rack. They show on the black
  // fur and vanish into the white.
  const rules = server
    ? `<g clip-path="url(#tile)" stroke="#fff" stroke-opacity="${forPx <= 32 ? 0.14 : 0.1}" stroke-width="${rule}">` +
      [0, 1, 2, 3, 4, 5, 6].map((i) => `<path d="M100 ${218 + i * 98}H924"/>`).join('') + '</g>'
    : '';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
<defs>
<clipPath id="tile"><path d="${TILE}"/></clipPath>
<linearGradient id="edge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".32"/><stop offset=".5" stop-color="#fff" stop-opacity=".12"/><stop offset="1" stop-color="#fff" stop-opacity=".18"/></linearGradient>
<filter id="shadow" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".32"/></filter>
</defs>
<path d="${TILE}" fill="#000" filter="url(#shadow)"/>
<image href="${dataUri(photo824)}" x="100" y="100" width="824" height="824" clip-path="url(#tile)"/>
${rules}
<path d="${TILE}" fill="none" stroke="url(#edge)" stroke-width="${edge * 2}" clip-path="url(#tile)"/>
</svg>
`;
}

// ── Rendering ────────────────────────────────────────────────────────────
const chrome = process.env.CHROME ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const browser = await chromium.launch(existsSync(chrome) ? { executablePath: chrome } : {});
// One fixed viewport at least as large as any render: resizing it between renders
// can leave a screenshot of a stale, half-laid-out frame.
const page = await browser.newPage({ deviceScaleFactor: 1, viewport: { width: 1024, height: 1024 } });
async function render(svg, w = 1024, h = w) {
  await page.setContent(`<!doctype html><style>html,body{margin:0;background:transparent}img{display:block;width:${w}px;height:${h}px}</style>` +
    `<img src="${dataUri(Buffer.from(svg), 'image/svg+xml')}">`);
  await page.evaluate(() => document.images[0].decode().then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))));
  return page.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: w, height: h } });
}
/**
 * Lanczos down to `px`, sharpened a little at 64 px and below. At 16 px the grey chest
 * fur crowds the face, so a steeper curve there keeps the white blaze and muzzle ahead
 * of it (grey ~150 stays put, darker greys drop, near-whites clip to white). Values
 * up to 70, the tile's dark fur and its hairline edge, are left alone.
 */
async function scale(master, px) {
  let img = sharp(master).resize(px, px, { kernel: 'lanczos3' });
  if (px <= 64) img = img.sharpen({ sigma: px <= 32 ? 0.5 : 0.6, m1: 0.6, m2: 2 });
  if (px > 16) return img.png({ compressionLevel: 9 }).toBuffer();
  const { data, info } = await img.ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let i = 0; i < data.length; i += 4) {
    for (let c = 0; c < 3; c++) {
      const v = data[i + c];
      data[i + c] = Math.max(Math.min(v, 70), Math.min(255, Math.round(CONTRAST_16 * v - (CONTRAST_16 - 1) * 150)));
    }
  }
  return sharp(data, { raw: info }).png({ compressionLevel: 9 }).toBuffer();
}
const CONTRAST_16 = 1.3;
const masters = new Map();
async function icon(px, { server = false } = {}) {
  // The master only changes with the line weights, which only change at 32 px and
  // below, so share it between the sizes that draw the same weights.
  const forPx = px <= 32 ? px : 1024;
  const key = `${server}:${forPx}`;
  if (!masters.has(key)) masters.set(key, await render(tileSvg({ server, forPx })));
  const master = masters.get(key);
  return px === 1024 ? master : scale(master, px);
}

writeFileSync(DOG + 'app-icon-1024.png', await icon(1024));

// ── macOS ────────────────────────────────────────────────────────────────
const MAC_SIZES = [16, 32, 128, 256, 512].flatMap((pt) => [[pt, 1], [pt, 2]]);
for (const [dir, server] of [['Fairspoken', false], ['FairspokenServer', true]]) {
  const out = `${REPO}apps/macos/${dir}/Resources/Assets.xcassets/AppIcon.appiconset/`;
  for (const [pt, s] of MAC_SIZES) writeFileSync(`${out}icon_${pt}x${pt}${s === 2 ? '@2x' : ''}.png`, await icon(pt * s, { server }));
}
// BrandMark's tile: the photo full-bleed (the view rounds and edges it).
{
  const dir = `${REPO}apps/macos/Fairspoken/Resources/Assets.xcassets/BrandTile.imageset/`;
  mkdirSync(dir, { recursive: true });
  writeFileSync(dir + 'brand-tile.png', await sharp(PHOTO).resize(128, 128, { kernel: 'lanczos3' }).png().toBuffer());
  writeFileSync(dir + 'brand-tile@2x.png', await sharp(PHOTO).resize(256, 256, { kernel: 'lanczos3' }).png().toBuffer());
  writeFileSync(dir + 'Contents.json', JSON.stringify({
    images: [{ filename: 'brand-tile.png', idiom: 'mac', scale: '1x' }, { filename: 'brand-tile@2x.png', idiom: 'mac', scale: '2x' }],
    info: { author: 'xcode', version: 1 },
  }, null, 2) + '\n');
}

// ── Tauri ────────────────────────────────────────────────────────────────
const TAURI = REPO + 'src-tauri/icons/';
for (const file of readdirSync(TAURI)) {
  const m = file.match(/^(?:(\d+)x\1(@2x)?|Square(\d+)x\3Logo|StoreLogo|icon)\.png$/);
  if (!m) continue;
  const px = file === 'icon.png' ? 512 : file === 'StoreLogo.png' ? 50 : m[3] ? Number(m[3]) : Number(m[1]) * (m[2] ? 2 : 1);
  writeFileSync(TAURI + file, await icon(px));
}
const iconset = path.join(tmpdir(), `dog-${process.pid}.iconset`);
mkdirSync(iconset, { recursive: true });
for (const [pt, s] of MAC_SIZES) writeFileSync(`${iconset}/icon_${pt}x${pt}${s === 2 ? '@2x' : ''}.png`, await icon(pt * s));
execFileSync('iconutil', ['-c', 'icns', iconset, '-o', TAURI + 'icon.icns']);
rmSync(iconset, { recursive: true });
{
  const sizes = [32, 16, 24, 48, 64, 256];
  const images = [];
  for (const px of sizes) images.push(await icon(px));
  const header = Buffer.alloc(6 + 16 * sizes.length);
  header.writeUInt16LE(1, 2); header.writeUInt16LE(sizes.length, 4);
  let offset = header.length;
  sizes.forEach((px, i) => {
    const e = 6 + 16 * i;
    header.writeUInt8(px % 256, e); header.writeUInt8(px % 256, e + 1);
    header.writeUInt16LE(1, e + 4); header.writeUInt16LE(32, e + 6);
    header.writeUInt32LE(images[i].length, e + 8); header.writeUInt32LE(offset, e + 12);
    offset += images[i].length;
  });
  writeFileSync(TAURI + 'icon.ico', Buffer.concat([header, ...images]));
}
// iOS draws its own corners: the photo full-bleed, opaque.
if (existsSync(TAURI + 'ios')) {
  for (const file of readdirSync(TAURI + 'ios')) {
    const m = file.match(/^AppIcon-([\d.]+)(?:x[\d.]+)?@(\d)x/);
    if (!m) continue;
    const px = Math.round(Number(m[1]) * Number(m[2]));
    let img = sharp(PHOTO).resize(px, px, { kernel: 'lanczos3' }).flatten({ background: '#000' });
    if (px <= 64) img = img.sharpen({ sigma: 0.6, m1: 0.6, m2: 2 });
    writeFileSync(`${TAURI}ios/${file}`, await img.png().toBuffer());
  }
}

// ── Android ──────────────────────────────────────────────────────────────
// Adaptive icons are 108 dp with the middle 72 dp visible: the photo fills that
// middle, and the rest is black (the photo's own edges are dark fur).
const DENSITIES = [['mdpi', 1], ['hdpi', 1.5], ['xhdpi', 2], ['xxhdpi', 3], ['xxxhdpi', 4]];
async function adaptiveForeground(px) {
  const inner = Math.round((px * 72) / 108);
  const face = await sharp(PHOTO).resize(inner, inner, { kernel: 'lanczos3' }).toBuffer();
  const pad = Math.floor((px - inner) / 2);
  return sharp({ create: { width: px, height: px, channels: 4, background: '#000000ff' } })
    .composite([{ input: face, left: pad, top: pad }]).png({ compressionLevel: 9 }).toBuffer();
}
const ANDROID = REPO + 'apps/android/app/src/main/res/';
for (const [d, k] of DENSITIES) {
  mkdirSync(`${ANDROID}mipmap-${d}`, { recursive: true });
  writeFileSync(`${ANDROID}mipmap-${d}/ic_launcher_foreground.png`, await adaptiveForeground(108 * k));
  if (existsSync(`${TAURI}android/mipmap-${d}`)) writeFileSync(`${TAURI}android/mipmap-${d}/ic_launcher_foreground.png`, await adaptiveForeground(108 * k));
}
if (existsSync(TAURI + 'android/values/ic_launcher_background.xml')) {
  writeFileSync(TAURI + 'android/values/ic_launcher_background.xml',
    '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n  <color name="ic_launcher_background">#000000</color>\n</resources>\n');
}
{
  // The monochrome layer: the mark, 58 dp tall in the 108 dp canvas.
  const s = 58 / BOX.h, tx = 54 - (BOX.x + BOX.w / 2) * s, ty = 54 - (BOX.y + BOX.h / 2) * s;
  writeFileSync(ANDROID + 'drawable/ic_launcher_monochrome.xml', `<?xml version="1.0" encoding="utf-8"?>
<!-- The sheepdog mark (design/brand/logo/dog/dog-mark.svg), for themed icons.
     Generated by design/brand/_tools/gen-dog-icons.mjs. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <group android:translateX="${round(tx, 4)}" android:translateY="${round(ty, 4)}"
        android:scaleX="${round(s, 6)}" android:scaleY="${round(s, 6)}">
        <path android:fillColor="#FFFFFFFF" android:fillType="evenOdd"
            android:pathData="${MARK}" />
    </group>
</vector>
`);
  writeFileSync(ANDROID + 'drawable/ic_launcher_background.xml', `<?xml version="1.0" encoding="utf-8"?>
<!-- Black, as behind the photo. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#FF000000" android:pathData="M0,0h108v108h-108z" />
</vector>
`);
}

// ── Web ──────────────────────────────────────────────────────────────────
mkdirSync(REPO + 'src/assets/brand', { recursive: true });
writeFileSync(REPO + 'src/assets/brand/dog-tile.jpg', await sharp(PHOTO).resize(192, 192, { kernel: 'lanczos3' }).jpeg({ quality: 86, mozjpeg: true }).toBuffer());
{
  const file = REPO + 'src-tauri/src/host/dashboard.html';
  const html = readFileSync(file, 'utf8');
  const jpg = await sharp(PHOTO).resize(64, 64, { kernel: 'lanczos3' }).sharpen({ sigma: 0.6 }).jpeg({ quality: 84, mozjpeg: true }).toBuffer();
  const next = html.replace(/(<img class="logo-photo" src=")[^"]*(")/, `$1${dataUri(jpg, 'image/jpeg')}$2`);
  if (next === html && !html.includes(dataUri(jpg, 'image/jpeg'))) throw new Error('dashboard.html: no <img class="logo-photo" src="…"> to update');
  writeFileSync(file, next);
}

// ── README header: the photo on a dark rounded card, no text ─────────────
{
  const W = 960, H = 420, side = 372;
  const face = await sharp(PHOTO).resize(side * 2, side * 2, { kernel: 'lanczos3' }).png().toBuffer();
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${W} ${H}" width="${W}" height="${H}">
<defs>
<linearGradient id="v" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".1" stop-color="#fff"/><stop offset=".72" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<linearGradient id="h" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".12" stop-color="#fff"/><stop offset=".88" stop-color="#fff"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<mask id="mv"><rect x="${(W - side) / 2}" y="${(H - side) / 2}" width="${side}" height="${side}" fill="url(#v)"/></mask>
<mask id="mh"><rect x="${(W - side) / 2}" y="${(H - side) / 2}" width="${side}" height="${side}" fill="url(#h)"/></mask>
</defs>
<rect width="${W}" height="${H}" rx="36" fill="#000"/>
<g mask="url(#mh)"><image href="${dataUri(face)}" x="${(W - side) / 2}" y="${(H - side) / 2}" width="${side}" height="${side}" mask="url(#mv)"/></g>
</svg>`;
  // At 2x, so it stays sharp on high-density screens where the README shows it 480 wide.
  const p2 = await browser.newPage({ deviceScaleFactor: 2, viewport: { width: W, height: H } });
  await p2.setContent(`<!doctype html><style>html,body{margin:0;background:transparent}img{display:block;width:${W}px;height:${H}px}</style><img src="${dataUri(Buffer.from(svg), 'image/svg+xml')}">`);
  await p2.evaluate(() => document.images[0].decode().then(() => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))));
  const hi = await p2.screenshot({ omitBackground: true, clip: { x: 0, y: 0, width: W, height: H } });
  await p2.close();
  writeFileSync(DOG + 'readme-header.png', await sharp(hi).png({ compressionLevel: 9 }).toBuffer());
}

await browser.close();

// ── Swift (FairspokenUI's DogMark) ───────────────────────────────────────
writeFileSync(REPO + 'apps/macos/Packages/FairspokenUI/Sources/FairspokenUI/DogMarkPaths.swift', `// Generated by design/brand/_tools/gen-dog-icons.mjs from design/brand/logo/dog/dog-mark.svg. Do not edit.
import CoreGraphics

extension DogMark {
    /// The mark's extent on the photo's 1024 grid.
    static let box = CGRect(x: ${BOX.x}, y: ${BOX.y}, width: ${BOX.w}, height: ${BOX.h})

    /// The blaze, the muzzle with the nose cut out, the open mouth with its tongue and
    /// lower lip, and the catchlights (even-odd).
    static let pathData = "${MARK}"
}
`);
console.log('done');
