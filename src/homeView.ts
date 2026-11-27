import { invoke } from "@tauri-apps/api/core";
import { emit, listen } from "@tauri-apps/api/event";
import * as history from "./historyStore";
import { accelTokens, isMacOS, keyGlyph } from "./shortcuts";
import { formatBytes, speechInfo } from "./modelCatalog";
import { speechModelShortName } from "./speechModels";
import { errorMessage } from "./errors";
import { icon } from "./icons";
import { notice } from "./confirmDialog";

// Home, as on the Mac: the new-dictation screen. How to dictate, a box to try
// it in (type, or dictate into it, and keep it as a note), the week in four
// numbers (homeStats.ts) and the model.

interface HomeSettings {
  recordingShortcut: string;
  recordingShortcutMode: "toggle" | "push-to-talk";
  transcriptionLocation: "local" | "remote-host" | "cloud";
  model: string;
  remoteUrl: string;
  audioDevice: string;
}

const mac = isMacOS();
const homeTitle = document.getElementById("homeTitle")!;
const composer = document.getElementById("composer")!;
const input = document.getElementById("composerInput") as HTMLTextAreaElement;
const placeholder = document.getElementById("composerPlaceholder")!;
const kind = document.getElementById("composerKind")!;
const saved = document.getElementById("composerSaved")!;
const openSaved = document.getElementById("composerOpen") as HTMLButtonElement;
const saveButton = document.getElementById("composerSave") as HTMLButtonElement;
const dictateButton = document.getElementById("composerDictate") as HTMLButtonElement;
const engineName = document.getElementById("engineName")!;
const engineWhere = document.getElementById("engineWhere")!;
const modelCard = document.getElementById("homeModelCard")!;
const micSelect = document.getElementById("micPickerSelect") as HTMLSelectElement;
const deviceSelect = document.getElementById("audioDeviceSelect") as HTMLSelectElement | null;

let settings: HomeSettings | null = null;
let pillState = "idle";
let savedId: string | null = null;
let awaitingInto = false;
let listenStart = 0;
let clockTimer: ReturnType<typeof setInterval> | undefined;

function shortcutKeys(): string[] {
  return accelTokens(settings?.recordingShortcut ?? "").map(keyGlyph);
}
function shortcutText(): string {
  const keys = shortcutKeys();
  return mac ? keys.join("") : keys.join("+");
}
const hold = () => settings?.recordingShortcutMode === "push-to-talk";

function keycap(text: string, outline = false): HTMLElement {
  const k = document.createElement("kbd");
  k.className = outline ? "keycap keycap--outline" : "keycap";
  k.textContent = text;
  return k;
}

// ── Heading and placeholder ──

function renderHeading(): void {
  const key = shortcutText() || "your shortcut";
  homeTitle.textContent = `${hold() ? "Hold" : "Press"} ${key} and speak.`;

  const parts: (string | HTMLElement)[] = ["Try it here.", hold() ? "Hold" : "Press", keycap(shortcutText() || "shortcut", true), "and say:"];
  const words = "“Can you send the revised quote to Aoife by Thursday?”".split(" ");
  placeholder.replaceChildren();
  for (const part of parts) {
    placeholder.append(typeof part === "string" ? Object.assign(document.createElement("span"), { textContent: part }) : part);
  }
  for (const word of words) placeholder.append(Object.assign(document.createElement("strong"), { textContent: word }));
  placeholder.append(Object.assign(document.createElement("span"), { textContent: "Or type a note." }));
}

// ── The box ──

function hasDraft(): boolean { return input.value.trim() !== ""; }

function grow(): void {
  input.style.height = "auto";
  input.style.height = `${Math.min(Math.max(input.scrollHeight, 48), 220)}px`;
}

function renderComposer(): void {
  const listening = pillState === "recording" || pillState === "starting";
  const busy = pillState === "transcribing";
  composer.dataset.state = listening ? "listening" : busy ? "transcribing" : "idle";
  placeholder.hidden = hasDraft() || listening || document.activeElement === input;
  saveButton.hidden = !hasDraft() || listening;
  dictateButton.hidden = hasDraft() && !listening;
  dictateButton.innerHTML = icon(listening ? "stop" : "mic", 1.8);
  dictateButton.setAttribute("aria-label", listening ? "Stop dictation" : "Start dictation");
  dictateButton.title = listening ? "Stop" : "Dictate here";
  dictateButton.disabled = busy;
  dictateButton.classList.toggle("is-busy", busy);

  if (listening) {
    const status = document.createElement("span");
    status.className = "listening";
    const dot = document.createElement("span");
    dot.className = "live-dot";
    const time = document.createElement("span");
    time.className = "listening-time num";
    time.id = "composerClock";
    const bars = document.createElement("span");
    bars.className = "level-bars";
    bars.id = "composerBars";
    for (let i = 0; i < 24; i++) bars.append(document.createElement("i"));
    status.append(dot, time, bars);
    kind.replaceChildren(status);
    kind.classList.add("is-live");
  } else if (busy) {
    kind.replaceChildren(Object.assign(document.createElement("span"), { className: "spinner" }), document.createTextNode("Transcribing…"));
    kind.classList.add("is-live");
  } else {
    kind.classList.remove("is-live");
    kind.replaceChildren(Object.assign(document.createElement("span"), { className: "type-glyph" }), document.createTextNode("Note"));
  }
  kind.hidden = savedId !== null && !listening && !busy;
  saved.hidden = !kind.hidden;
  tickClock();
}

function tickClock(): void {
  const el = document.getElementById("composerClock");
  if (!el) return;
  const s = Math.max(0, Math.floor((Date.now() - listenStart) / 1000));
  el.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

let levels: number[] = new Array(24).fill(0);
function pushLevel(rms: number): void {
  const bars = document.getElementById("composerBars");
  if (!bars) return;
  const level = Math.min(1, Math.sqrt(Math.max(0, rms)) * 3.2);
  levels = [...levels.slice(1), level];
  bars.querySelectorAll("i").forEach((bar, i) => { (bar as HTMLElement).style.transform = `scaleY(${0.15 + levels[i] * 0.85})`; });
}

async function saveNote(): Promise<void> {
  const text = input.value.trim();
  if (!text) return;
  try {
    const note = await invoke<{ id: string }>("add_note", { text });
    input.value = "";
    savedId = note.id;
    grow();
    await history.refresh();
  } catch (error) {
    await notice("Couldn't save the note", errorMessage(error));
  }
  renderComposer();
}

input.addEventListener("input", () => { savedId = null; grow(); renderComposer(); });
input.addEventListener("focus", renderComposer);
input.addEventListener("blur", renderComposer);
input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && (mac ? event.metaKey : event.ctrlKey)) { event.preventDefault(); void saveNote(); }
});
composer.addEventListener("click", (event) => {
  if (!(event.target as HTMLElement).closest("button, textarea")) input.focus();
});
saveButton.addEventListener("click", () => void saveNote());
openSaved.addEventListener("click", () => {
  if (savedId) document.dispatchEvent(new CustomEvent("bark-navigate", { detail: { route: `dictation/${savedId}` } }));
});
dictateButton.addEventListener("click", () => {
  // The words come back here when the dictation lands, not into this button.
  awaitingInto = pillState === "idle" || pillState === "error";
  input.blur();
  void emit("pill-toggle-recording").catch(() => {});
});

void listen<{ state: string }>("pill-state", (event) => {
  const next = event.payload?.state ?? "idle";
  if ((next === "recording" || next === "starting") && pillState !== "recording" && pillState !== "starting") listenStart = Date.now();
  pillState = next;
  clearInterval(clockTimer);
  if (next === "recording") clockTimer = setInterval(tickClock, 1000);
  if (next === "idle" || next === "error") { if (next === "error") awaitingInto = false; }
  renderComposer();
}).catch(() => {});
void listen<{ rms: number }>("audio-level", (event) => pushLevel(event.payload?.rms ?? 0)).catch(() => {});
void listen("transcript-history-updated", async () => {
  if (!awaitingInto) return;
  awaitingInto = false;
  const latest = await invoke<{ text: string }[]>("get_transcript_history").catch(() => []);
  const text = latest[0]?.text?.trim();
  if (!text) return;
  input.value = input.value.trim() ? `${input.value.trim()} ${text}` : text;
  savedId = null;
  grow();
  renderComposer();
}).catch(() => {});

// ── Where dictation runs, and the model ──

function modelState(): { label: string; tone: "ok" | "busy" | "error" | "idle" } {
  const state = document.getElementById("modelDownload")?.dataset.state;
  switch (state) {
    case "ready": return { label: "Ready", tone: "ok" };
    case "loading": return { label: "Preparing", tone: "busy" };
    case "error": return { label: "Needs attention", tone: "error" };
    default: return { label: "Not downloaded", tone: "idle" };
  }
}

function serverState(): { label: string; tone: string } {
  const text = document.getElementById("remoteStatus")?.textContent ?? "";
  if (/Connected/.test(text)) return { label: "Reachable", tone: "info" };
  if (/Checking/.test(text)) return { label: "Checking", tone: "neutral" };
  if (/Unavailable/.test(text)) return { label: "Not reachable", tone: "error" };
  return { label: "Not checked", tone: "neutral" };
}

function badge(text: string, tone: string): HTMLElement {
  return Object.assign(document.createElement("span"), { className: `badge badge--${tone}`, textContent: text });
}

function grow_row(title: string, b: HTMLElement, detail: string | null, control: HTMLElement): HTMLElement {
  const row = document.createElement("div");
  row.className = "grow";
  const text = document.createElement("div");
  text.className = "grow-text";
  const head = document.createElement("div");
  head.className = "grow-title";
  head.append(document.createTextNode(title), b);
  text.append(head);
  if (detail) text.append(Object.assign(document.createElement("div"), { className: "grow-detail", textContent: detail }));
  row.append(text, control);
  return row;
}

function renderModel(): void {
  if (!settings) return;
  const remote = settings.transcriptionLocation === "remote-host";
  const cloud = settings.transcriptionLocation === "cloud";
  engineName.textContent = remote ? "Bark Server" : cloud ? "Bark Cloud" : speechModelShortName(settings.model);
  engineWhere.textContent = remote || cloud ? "" : "This PC";
  engineWhere.hidden = remote || cloud;
  document.getElementById("engineChip")!.querySelector("svg")!.outerHTML = icon(remote ? "server" : "laptop", 1.6);

  const info = speechInfo(settings.model);
  const state = modelState();
  const size = Object.assign(document.createElement("span"), { className: "mono-meta", textContent: formatBytes(info.bytes) });
  const rows: HTMLElement[] = [grow_row(info.name, badge(state.label, state.tone === "error" ? "error" : "neutral"),
    null, size)];
  if (settings.remoteUrl.trim()) {
    const s = serverState();
    const use = document.createElement("button");
    use.type = "button";
    use.className = "btn";
    use.textContent = remote ? "Use This PC" : "Use Bark Server";
    use.addEventListener("click", () => {
      (document.querySelector<HTMLButtonElement>(`#locationSeg [data-value="${remote ? "local" : "remote-host"}"]`))?.click();
    });
    let host = settings.remoteUrl;
    try { host = new URL(settings.remoteUrl).host; } catch { /* as typed */ }
    rows.push(grow_row("Bark Server", badge(s.label, s.tone), host, use));
  }
  modelCard.replaceChildren(...rows);
}

for (const id of ["modelDownload", "remoteStatus"]) {
  const target = document.getElementById(id);
  if (target) new MutationObserver(renderModel).observe(target, { attributes: true, childList: true, characterData: true, subtree: true });
}

// ── The microphone picker in the top bar mirrors General › Microphone ──

function syncMicOptions(): void {
  if (!deviceSelect) return;
  const options = [...deviceSelect.options].map((o) => {
    const copy = new Option(o.value ? o.text : "System default", o.value);
    return copy;
  });
  micSelect.replaceChildren(...options);
  micSelect.value = deviceSelect.value;
  if (micSelect.selectedIndex < 0 && options.length) micSelect.selectedIndex = 0;
}
if (deviceSelect) {
  new MutationObserver(syncMicOptions).observe(deviceSelect, { childList: true, subtree: true, attributes: true });
  deviceSelect.addEventListener("change", syncMicOptions);
  micSelect.addEventListener("change", () => {
    deviceSelect.value = micSelect.value;
    deviceSelect.dispatchEvent(new Event("change", { bubbles: true }));
  });
}

// ── Settings ──

function apply(next: Partial<HomeSettings> | null | undefined): void {
  settings = {
    recordingShortcut: next?.recordingShortcut ?? "",
    recordingShortcutMode: next?.recordingShortcutMode ?? "toggle",
    transcriptionLocation: next?.transcriptionLocation ?? "local",
    model: next?.model ?? "parakeet-tdt-0.6b-v3",
    remoteUrl: next?.remoteUrl ?? "",
    audioDevice: next?.audioDevice ?? "",
  };
  renderHeading();
  renderModel();
  renderComposer();
  syncMicOptions();
  if (deviceSelect && micSelect.options.length <= 1) {
    micSelect.replaceChildren(new Option(settings.audioDevice || "System default", settings.audioDevice));
  }
}

let updated = false;
void listen<Partial<HomeSettings>>("settings-updated", (event) => { updated = true; apply(event.payload); })
  .then(() => invoke<Partial<HomeSettings>>("get_settings"))
  .then((loaded) => { if (!updated) apply(loaded); })
  .catch(() => apply(null));

grow();
renderComposer();
