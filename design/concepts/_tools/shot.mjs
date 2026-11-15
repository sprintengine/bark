// Headless-Chrome screenshot helper for the design concepts (CDP over the
// built-in WebSocket in Node >= 22). No dependencies.
//
//   node shot.mjs <url> <out.png> [--dark] [--width 980] [--height 680]
//                 [--scale 2] [--stub] [--state '{"empty":true}'] [--desktop]
//                 [--wait 1200] [--eval "js"]
//
// --stub injects tauri-stub.js, a fake window.__TAURI_INTERNALS__ with
// fictional sample data, so the real windows render outside Tauri. --state
// passes options to it (see the top of tauri-stub.js). --desktop paints a
// soft wallpaper behind the page, standing in for the desktop that the macOS
// window material frosts, so a transparent window reads as it does on a Mac.
import { spawn } from "node:child_process";
import { writeFileSync, mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const args = process.argv.slice(2);
const url = args[0];
const out = args[1];
const flag = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return fallback;
  const v = args[i + 1];
  return v === undefined || v.startsWith("--") ? true : v;
};
const dark = Boolean(flag("dark", false));
const width = Number(flag("width", 980));
const height = Number(flag("height", 680));
const scale = Number(flag("scale", 2));
const wait = Number(flag("wait", 1500));
const stub = Boolean(flag("stub", false));
const evalJs = flag("eval", "");
const reduced = Boolean(flag("reduced", false));
const state = flag("state", "{}");
const desktop = Boolean(flag("desktop", false));

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const port = 9300 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(join(tmpdir(), "fs-shot-"));
const chrome = spawn(CHROME, [
  "--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`,
  "--no-first-run", "--no-default-browser-check", "--hide-scrollbars",
  "--enable-gpu", "--use-angle=metal", "--enable-unsafe-swiftshader", "about:blank",
], { stdio: "ignore" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let target;
for (let i = 0; i < 50 && !target; i++) {
  await sleep(150);
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    target = list.find((t) => t.type === "page");
  } catch { /* chrome still starting */ }
}
if (!target) { chrome.kill(); throw new Error("Chrome did not start"); }

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener("open", r, { once: true }));
let seq = 0;
const pending = new Map();
const logs = [];
ws.addEventListener("message", (event) => {
  const msg = JSON.parse(event.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  if (msg.method === "Runtime.exceptionThrown") logs.push("EXC " + (msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text));
  if (msg.method === "Runtime.consoleAPICalled" && ["error", "warning"].includes(msg.params.type)) logs.push(msg.params.type + " " + msg.params.args.map((a) => a.value ?? a.description).join(" "));
});
const send = (method, params = {}) => new Promise((resolve) => {
  const id = ++seq; pending.set(id, resolve); ws.send(JSON.stringify({ id, method, params }));
});

await send("Runtime.enable");
await send("Page.enable");
await send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: scale, mobile: false });
await send("Emulation.setEmulatedMedia", { features: [
  { name: "prefers-color-scheme", value: dark ? "dark" : "light" },
  { name: "prefers-reduced-motion", value: reduced ? "reduce" : "no-preference" },
] });
if (stub) {
  const here = dirname(fileURLToPath(import.meta.url));
  await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `window.__STUB_OPTIONS__ = ${state};\n${readFileSync(join(here, "tauri-stub.js"), "utf8")}`,
  });
}
if (desktop) {
  // The OS frost is a heavily blurred, lightly tinted desktop: a still, soft
  // gradient is a fair stand-in. !important beats the pages' own transparent
  // html background; body's tint still sits on top of it, as on a Mac.
  const wallpaper = dark
    ? "radial-gradient(70% 90% at 15% 10%, #2c3a46, transparent 70%), radial-gradient(60% 80% at 90% 90%, #3a3042, transparent 70%), #20242b"
    : "radial-gradient(70% 90% at 15% 10%, #c9dbe6, transparent 70%), radial-gradient(60% 80% at 90% 90%, #e3d6e4, transparent 70%), #dfe4ea";
  await send("Page.addScriptToEvaluateOnNewDocument", {
    source: `document.addEventListener("DOMContentLoaded", () => { const s = document.createElement("style"); s.textContent = 'html { background: ${wallpaper} !important; }'; document.head.append(s); });`,
  });
}
await send("Page.navigate", { url });
await sleep(wait);
if (evalJs) {
  const r = await send("Runtime.evaluate", { expression: evalJs, awaitPromise: true });
  if (r.result?.exceptionDetails) logs.push("EVAL " + JSON.stringify(r.result.exceptionDetails.exception?.description));
  await sleep(Number(flag("after", 600)));
}
const perfSecs = Number(flag("perf", 0));
if (perfSecs) {
  // Main-thread busy time of the renderer over the window (excludes the GPU process).
  await send("Performance.enable", { timeDomain: "timeTicks" });
  const metric = async () => Object.fromEntries((await send("Performance.getMetrics")).result.metrics.map((m) => [m.name, m.value]));
  const a = await metric(); await sleep(perfSecs * 1000); const b = await metric();
  const busy = (b.TaskDuration - a.TaskDuration) / (b.Timestamp - a.Timestamp);
  const script = (b.ScriptDuration - a.ScriptDuration) / (b.Timestamp - a.Timestamp);
  console.log(`perf ${perfSecs}s: renderer main-thread busy ${(busy * 100).toFixed(2)}% · script ${(script * 100).toFixed(2)}%`);
}
const shot = await send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false });
writeFileSync(out, Buffer.from(shot.result.data, "base64"));
if (logs.length) console.log(logs.slice(0, 15).join("\n"));
console.log("saved", out);
ws.close();
chrome.kill();

