import "./appearance";
import "./onboarding.css";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { accelTokens, keyGlyph, keyWord } from "./shortcuts";
import { SPEECH_MODELS, formatBytes, isMeasured, speechInfo } from "./modelCatalog";

// First-run setup in its own window: welcome, permissions, a microphone
// check, a speech model, a first dictation, the training-data choice, done.
// It opens until finished (onboarding.rs) and again from Settings → General.
// Every step can be passed; the app works with whatever was set.

type Step = "welcome" | "permissions" | "mic" | "model" | "try" | "improve" | "done";
const STEPS: Step[] = ["welcome", "permissions", "mic", "model", "try", "improve", "done"];
const STEP_NAMES: Record<Step, string> = {
  welcome: "Welcome", permissions: "Permissions", mic: "Microphone", model: "Model", try: "Try it", improve: "Improve", done: "Done",
};

type Permission = "granted" | "denied" | "not-determined" | "unknown" | "not-needed";
interface PermissionStatus { platform: "macos" | "windows" | "linux"; microphone: Permission; accessibility: Permission; inputMonitoring: Permission }
interface Settings {
  model: string;
  audioDevice?: string;
  recordingShortcut: string;
  recordingShortcutMode: "toggle" | "push-to-talk";
  fnPushToTalk: boolean;
  trainingCapture: boolean;
  [key: string]: unknown;
}
interface SpeechModel { model: string; cached: boolean }
interface PrepareProgress { model: string; percentage: number; message: string; done: boolean; error?: string }
interface HistoryItem { text: string; durationSeconds: number }

const progressList = document.getElementById("obProgress")!;
const stepHost = document.getElementById("obStep")!;
const backButton = document.getElementById("obBack") as HTMLButtonElement;
const skipButton = document.getElementById("obSkip") as HTMLButtonElement;
const nextButton = document.getElementById("obNext") as HTMLButtonElement;

let step: Step = "welcome";
let settings: Settings | null = null;
let permissions: PermissionStatus = { platform: "macos", microphone: "unknown", accessibility: "not-needed", inputMonitoring: "not-needed" };
let speech: SpeechModel[] = [];
let chosenModel = "parakeet-tdt-0.6b-v3";
const download = { model: "", percentage: 0, message: "", active: false, error: "" };
/** Teardown for whatever the current step started (streams, polls, listeners). */
let leaveStep: (() => void) | null = null;

// ── Small DOM helper ────────────────────────────────────────────────────
type Child = Node | string | null | undefined | false;
function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs: Record<string, string | boolean> = {}, children: Child[] = []): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value === false) continue;
    if (key === "class") node.className = String(value);
    else node.setAttribute(key, value === true ? "" : value);
  }
  for (const child of children) if (child) node.append(child);
  return node;
}
function svg(markup: string): SVGSVGElement {
  const holder = document.createElement("span");
  holder.innerHTML = markup;
  return holder.firstElementChild as SVGSVGElement;
}
const ICONS = {
  wave: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M4.5 10.5v3M8 7.5v9M11.5 4.5v15M15 8v8M18.5 10v4"/></svg>',
  mic: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/></svg>',
  cursor: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 4h2.5M12.5 4H15M12 4v16M9 20h2.5M12.5 20H15"/></svg>',
  keyboard: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="6" width="18" height="12" rx="2.5"/><path d="M7 10h.01M11 10h.01M15 10h.01M8 14h8"/></svg>',
  lock: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="5" y="10.5" width="14" height="10" rx="2.5"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/></svg>',
  apps: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="4" y="4" width="7" height="7" rx="2"/><rect x="13" y="4" width="7" height="7" rx="2"/><rect x="4" y="13" width="7" height="7" rx="2"/><rect x="13" y="13" width="7" height="7" rx="2"/></svg>',
  sparkle: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M12 3.5 13.8 9a2 2 0 0 0 1.2 1.2l5.5 1.8-5.5 1.8a2 2 0 0 0-1.2 1.2L12 20.5 10.2 15A2 2 0 0 0 9 13.8L3.5 12 9 10.2A2 2 0 0 0 10.2 9Z"/></svg>',
  stack: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3.5 8 4.25-8 4.25-8-4.25Z"/><path d="m4 12 8 4.25L20 12M4 16.25l8 4.25 8-4.25"/></svg>',
  bubble: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M5 5.5h14a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 17h-8l-4.5 3.5V17H5a1.5 1.5 0 0 1-1.5-1.5V7A1.5 1.5 0 0 1 5 5.5Z"/></svg>',
  heart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><path d="M12 19.5s-7.5-4.4-7.5-10A4.2 4.2 0 0 1 12 7a4.2 4.2 0 0 1 7.5 2.5c0 5.6-7.5 10-7.5 10Z"/></svg>',
  check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="m5.5 12.5 4.5 4.5 8.5-9.5"/></svg>',
};

function tile(icon: keyof typeof ICONS, tone: string, size: "lg" | "md" = "md"): HTMLElement {
  return h("span", { class: `ob-tile ob-tile--${tone} ob-tile--${size}`, "aria-hidden": "true" }, [svg(ICONS[icon])]);
}

function keycaps(shortcut: string): HTMLElement {
  const tokens = accelTokens(shortcut);
  return h("span", { class: "ob-keys", "aria-label": tokens.map(keyWord).join(" ") }, tokens.map((token) => h("kbd", {}, [keyGlyph(token)])));
}

function header(icon: keyof typeof ICONS, tone: string, title: string, subtitle: string): HTMLElement {
  return h("header", { class: "ob-head" }, [tile(icon, tone, "lg"), h("h1", { tabindex: "-1" }, [title]), h("p", {}, [subtitle])]);
}

async function readSettings(): Promise<Settings> {
  settings = await invoke<Settings>("get_settings");
  return settings;
}
// Read at save time and change only what this window owns, so another
// window's newer settings are never overwritten.
async function saveSettings(patch: Partial<Settings>): Promise<void> {
  const latest = await invoke<Settings>("get_settings");
  await invoke("save_settings", { settings: { ...latest, ...patch } });
  settings = { ...latest, ...patch };
}

// ── Steps ───────────────────────────────────────────────────────────────
function renderWelcome(): void {
  const points = h("ul", { class: "ob-points" }, [
    point("apps", "blue", "Works in every app", "Press a shortcut, speak, and the words land where you type."),
    point("lock", "green", "Stays on this computer", "Speech is recognised here. No account, no upload."),
    point("sparkle", "violet", "Cleans up as you go", "Fillers and false starts are tidied, and you can always undo."),
  ]);
  stepHost.replaceChildren(
    h("header", { class: "ob-head ob-head--hero" }, [
      h("span", { class: "ob-mark", "aria-hidden": "true" }, [svg(ICONS.wave)]),
      h("h1", { tabindex: "-1" }, ["Welcome to Fairspoken"]),
      h("p", {}, ["Speak anywhere you type. Fast, private, and on your computer."]),
    ]),
    points,
  );
  setFooter({ next: "Get started" });
}

function point(icon: keyof typeof ICONS, tone: string, title: string, body: string): HTMLElement {
  return h("li", { class: "ob-point" }, [tile(icon, tone), h("div", {}, [h("strong", {}, [title]), h("span", {}, [body])])]);
}

function permissionLabel(state: Permission): [string, string] {
  switch (state) {
    case "granted": return ["Allowed", "ok"];
    case "denied": return ["Not allowed", "warn"];
    case "not-determined": return ["Not asked yet", "idle"];
    case "not-needed": return ["Not needed", "idle"];
    default: return ["Not checked", "idle"];
  }
}

function permissionCard(kind: "microphone" | "accessibility" | "inputMonitoring", icon: keyof typeof ICONS, tone: string, title: string, body: string, optional: boolean): HTMLElement {
  const state = permissions[kind];
  const [label, labelTone] = permissionLabel(state);
  const status = h("span", { class: `ob-status ob-status--${labelTone}` }, [state === "granted" ? svg(ICONS.check) : null, label]);
  // macOS reports Accessibility only as on or off; its first ask is a prompt.
  const opensSettings = state === "denied" && kind !== "accessibility";
  const action = state === "granted" || state === "not-needed"
    ? null
    : h("button", { class: "ob-btn ob-btn--sm", type: "button" }, [opensSettings ? "Open Settings" : "Allow"]);
  action?.addEventListener("click", () => { void requestPermission(kind); });
  return h("li", { class: `ob-card ob-perm${state === "granted" ? " is-granted" : ""}` }, [
    tile(icon, tone),
    h("div", { class: "ob-card-text" }, [
      h("strong", {}, [title, optional ? h("span", { class: "ob-badge" }, ["Optional"]) : null]),
      h("span", {}, [body]),
    ]),
    h("div", { class: "ob-card-end" }, [status, action]),
  ]);
}

async function refreshPermissions(): Promise<void> {
  try {
    permissions = await invoke<PermissionStatus>("get_permission_status");
  } catch { /* keep the last answer */ }
  if (permissions.microphone === "unknown") permissions.microphone = await browserMicrophoneState();
}

// Where the platform can't say, the browser can: the permission API, or
// whether a microphone is labelled (labels appear only once access is given).
async function browserMicrophoneState(): Promise<Permission> {
  try {
    const status = await navigator.permissions?.query({ name: "microphone" as PermissionName });
    if (status?.state === "granted") return "granted";
    if (status?.state === "denied") return "denied";
  } catch { /* not supported */ }
  const devices = await navigator.mediaDevices?.enumerateDevices().catch(() => []) ?? [];
  return devices.some((device) => device.kind === "audioinput" && device.label) ? "granted" : "not-determined";
}

async function requestPermission(kind: "microphone" | "accessibility" | "inputMonitoring"): Promise<void> {
  if (kind === "microphone" && permissions.microphone !== "denied") {
    // Opening the microphone is what asks for it.
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
      stream.getTracks().forEach((track) => track.stop());
    } catch { /* answered no, or no device: the status says which */ }
  } else {
    try { await invoke("request_permission", { kind }); } catch { /* status refresh shows the result */ }
  }
  await refreshPermissions();
  if (step === "permissions") renderPermissions();
}

function renderPermissions(): void {
  const mac = permissions.platform === "macos";
  const cards = h("ul", { class: "ob-cards" }, [
    permissionCard("microphone", "mic", "red", "Microphone", "To hear you. Audio stays on this computer.", false),
    mac ? permissionCard("accessibility", "cursor", "blue", "Accessibility", "To type the text where your cursor is.", false) : null,
    mac ? permissionCard("inputMonitoring", "keyboard", "grey", "Input Monitoring", "Only for holding Fn to talk.", true) : null,
  ]);
  stepHost.replaceChildren(
    header("lock", "green", mac ? "Allow a few things" : "Allow the microphone", mac
      ? "Fairspoken needs your microphone. Accessibility lets it type for you."
      : "Fairspoken needs your microphone to hear you."),
    cards,
    h("p", { class: "ob-note" }, [mac ? "You can change these later in System Settings → Privacy & Security." : "You can change this later in your system's privacy settings."]),
  );
  setFooter({ next: permissions.microphone === "granted" ? "Continue" : "Continue without", back: true });
}

function enterPermissions(): void {
  renderPermissions();
  void refreshPermissions().then(() => { if (step === "permissions") renderPermissions(); });
  // People flip these in System Settings; follow along while the step is up.
  const poll = setInterval(() => {
    const before = JSON.stringify(permissions);
    void refreshPermissions().then(() => {
      if (step === "permissions" && JSON.stringify(permissions) !== before) renderPermissions();
    });
  }, 1500);
  leaveStep = () => clearInterval(poll);
}

// Microphone check: the device list and a live level, from the window's own
// stream (separate from dictation, closed when the step is left or the
// window hides). Each way it can fail says what to do about it.
function micProblem(error: unknown): string {
  const name = error instanceof DOMException ? error.name : "";
  if (name === "NotAllowedError" || name === "SecurityError") {
    return permissions.platform === "macos"
      ? "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone."
      : "Microphone access is off. Allow it in your system's privacy settings.";
  }
  if (name === "NotFoundError" || name === "OverconstrainedError") return "No microphone found. Plug one in, or pick another above.";
  if (name === "NotReadableError") return "That microphone is busy or unavailable. Close apps using it, or pick another.";
  return "The microphone couldn't start. Pick another, or try again.";
}

function enterMic(): void {
  const select = h("select", { class: "ob-select", id: "obMicSelect", "aria-label": "Microphone" });
  const bars = h("div", { class: "ob-wave", "aria-hidden": "true" }, Array.from({ length: 36 }, () => h("span")));
  const status = h("p", { class: "ob-mic-status", role: "status" }, ["Listening…"]);
  const card = h("div", { class: "ob-card ob-mic" }, [
    h("label", { class: "ob-field" }, [h("span", {}, ["Microphone"]), select]),
    bars,
    status,
  ]);
  stepHost.replaceChildren(header("mic", "red", "Check your microphone", "Say a few words. The bars should move as you speak."), card);
  setFooter({ next: "Continue", back: true, skip: "Skip" });

  let stream: MediaStream | null = null;
  let context: AudioContext | null = null;
  let frame = 0;
  let heard = 0;
  let session = 0;
  let silentSince = 0;
  const levels: number[] = Array(36).fill(0);
  const say = (text: string, tone?: "ok" | "warn") => {
    status.textContent = text;
    if (tone) status.dataset.tone = tone; else delete status.dataset.tone;
  };
  const stop = () => {
    session += 1;
    cancelAnimationFrame(frame);
    stream?.getTracks().forEach((track) => track.stop());
    void context?.close().catch(() => {});
    stream = null; context = null;
  };
  const start = async () => {
    stop();
    const mine = session;
    heard = 0;
    say("Listening…");
    try {
      const constraints: MediaTrackConstraints = { channelCount: 1 };
      if (select.value) constraints.deviceId = { exact: select.value };
      const opened = await navigator.mediaDevices.getUserMedia({ audio: constraints });
      if (mine !== session) { opened.getTracks().forEach((track) => track.stop()); return; }
      stream = opened;
      context = new AudioContext();
      const analyser = context.createAnalyser();
      analyser.fftSize = 512;
      context.createMediaStreamSource(opened).connect(analyser);
      const data = new Uint8Array(analyser.fftSize);
      let last = 0;
      silentSince = performance.now();
      const tick = (time: number) => {
        if (mine !== session) return;
        frame = requestAnimationFrame(tick);
        if (time - last < 50) return;
        last = time;
        analyser.getByteTimeDomainData(data);
        let sum = 0;
        for (const value of data) { const v = (value - 128) / 128; sum += v * v; }
        const rms = Math.sqrt(sum / data.length);
        // The pill's mapping: a gate, a full scale, a square-root response.
        const level = Math.min(1, Math.sqrt(Math.max(0, rms - 0.004) / 0.03));
        levels.shift(); levels.push(level);
        [...bars.children].forEach((bar, i) => { (bar as HTMLElement).style.transform = `scaleY(${Math.max(0.08, levels[i])})`; });
        if (level > 0.35) { heard += 1; silentSince = time; } else heard = Math.max(0, heard - 0.25);
        if (heard > 4) say("Sounds good.", "ok");
        else if (status.dataset.tone !== "ok" && time - silentSince > 5000) say("Nothing yet. Speak up, move closer, or pick another microphone.", "warn");
      };
      frame = requestAnimationFrame(tick);
      await loadDevices(select);
    } catch (error) {
      if (mine === session) say(micProblem(error), "warn");
    }
  };
  select.addEventListener("change", () => { void start(); });
  void loadDevices(select).then(start);
  leaveStep = () => {
    stop();
    const device = select.value;
    if (settings && device !== (settings.audioDevice ?? "")) void saveSettings({ audioDevice: device }).catch(() => {});
  };
}

async function loadDevices(select: HTMLSelectElement): Promise<void> {
  const current = select.value || settings?.audioDevice || "";
  const devices = await navigator.mediaDevices?.enumerateDevices().catch(() => []) ?? [];
  const inputs = devices.filter((device) => device.kind === "audioinput" && device.deviceId !== "default");
  select.replaceChildren(new Option("System default", ""), ...inputs.map((device, i) => new Option(device.label || `Microphone ${i + 1}`, device.deviceId)));
  select.value = [...select.options].some((option) => option.value === current) ? current : "";
}

// Model: three good starting points; the rest live in Models.
const STARTER_MODELS = ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2", "base"];

function ratingBar(label: string, value: number, measured: boolean): HTMLElement {
  return h("span", { class: "ob-rating", "aria-label": `${label} ${value} of 5${measured ? "" : ", estimated"}` }, [
    h("span", { class: "ob-rating-label", "aria-hidden": "true" }, [label]),
    h("span", { class: "ob-rating-steps", "aria-hidden": "true" }, Array.from({ length: 5 }, (_, i) => h("i", { class: i < value ? "on" : "" }))),
    measured ? null : h("span", { class: "ob-rating-est", "aria-hidden": "true" }, ["est."]),
  ]);
}

function modelState(id: string): "ready" | "downloading" | "failed" | "missing" {
  if (download.active && download.model === id) return "downloading";
  if (speech.find((model) => model.model === id)?.cached) return "ready";
  if (download.error && download.model === id) return "failed";
  return "missing";
}

function renderModel(): void {
  const focusedId = stepHost.contains(document.activeElement) ? document.activeElement?.id : "";
  const list = h("div", { class: "ob-cards ob-models", role: "radiogroup", "aria-label": "Speech model" });
  const ids = STARTER_MODELS;
  for (const id of ids) {
    const info = speechInfo(id);
    const state = modelState(id);
    const selected = chosenModel === id;
    const end = state === "downloading"
      ? h("span", { class: "ob-progress-ring", style: `--p:${download.percentage}`, "aria-label": `Downloading, ${Math.round(download.percentage)}%` }, [h("span", { "aria-hidden": "true" }, [`${Math.round(download.percentage)}%`])])
      : state === "ready" ? h("span", { class: "ob-status ob-status--ok" }, [svg(ICONS.check), "Downloaded"])
      : state === "failed" ? h("span", { class: "ob-status ob-status--warn" }, ["Failed"])
      : h("span", { class: "ob-size" }, [formatBytes(info.bytes)]);
    const option = h("button", {
      class: `ob-card ob-model${selected ? " is-selected" : ""}`, type: "button", role: "radio", id: `ob-model-${id}`,
      "aria-checked": String(selected), tabindex: selected ? "0" : "-1",
    }, [
      h("span", { class: "ob-radio", "aria-hidden": "true" }),
      h("span", { class: "ob-card-text" }, [
        h("strong", {}, [info.name, info.recommended ? h("span", { class: "ob-badge ob-badge--accent" }, ["Recommended"]) : null, info.language === "en" ? h("span", { class: "ob-badge" }, ["EN"]) : null]),
        h("span", {}, [info.language === "en" ? info.summary : `${info.summary} · ${info.languages}`]),
        h("span", { class: "ob-ratings" }, [ratingBar("Speed", info.speed, isMeasured(info)), ratingBar("Accuracy", info.accuracy, isMeasured(info))]),
      ]),
      h("span", { class: "ob-card-end" }, [end]),
    ]);
    option.addEventListener("click", () => { chosenModel = id; renderModel(); document.getElementById(`ob-model-${id}`)?.focus(); });
    list.append(option);
  }
  // Arrow keys move the choice, as in any radio group.
  list.addEventListener("keydown", (event) => {
    const delta = event.key === "ArrowDown" || event.key === "ArrowRight" ? 1 : event.key === "ArrowUp" || event.key === "ArrowLeft" ? -1 : 0;
    if (!delta) return;
    event.preventDefault();
    chosenModel = ids[(ids.indexOf(chosenModel) + delta + ids.length) % ids.length];
    renderModel();
    document.getElementById(`ob-model-${chosenModel}`)?.focus();
  });
  const failed = modelState(chosenModel) === "failed";
  stepHost.replaceChildren(
    header("stack", "indigo", "Choose a speech model", "It runs on this computer. You can switch any time in Models."),
    list,
    h("p", { class: `ob-note${failed ? " ob-note--warn" : ""}`, role: failed ? "alert" : false }, [failed
      ? `The download didn't finish: ${download.error}`
      : "Downloads carry on in the background while you finish setting up."]),
  );
  const state = modelState(chosenModel);
  setFooter({
    next: state === "ready" || state === "downloading" ? "Continue" : failed ? "Try again" : "Download and continue",
    back: true,
    skip: state === "ready" || state === "downloading" ? undefined : "Not now",
  });
  // A progress update re-renders the list; keep focus where it was.
  if (focusedId) document.getElementById(focusedId)?.focus({ preventScroll: true });
}

/** Saves the choice and starts its download. False when the download could not start. */
async function chooseModel(): Promise<boolean> {
  if (!settings) await readSettings();
  if (settings!.model !== chosenModel) await saveSettings({ model: chosenModel, transcriptionLocation: "local" });
  const state = modelState(chosenModel);
  if (state === "ready" || state === "downloading") return true;
  Object.assign(download, { model: chosenModel, percentage: 0, message: "Starting download…", active: true, error: "" });
  try {
    await invoke("begin_prepare_transcription_model", { request: { model: chosenModel } });
    return true;
  } catch (error) {
    Object.assign(download, { active: false, error: String(error) });
    renderModel();
    return false;
  }
}

// Try it: a chat with one message waiting for an answer. The real shortcut
// (handled by the pill) dictates as usual; its live text shows in the
// composer, and what was heard lands as your message with how fast you
// spoke. The button beside the composer records without inserting anywhere.
function enterTry(): void {
  const shortcut = settings?.recordingShortcut ?? "";
  const holdMode = settings?.recordingShortcutMode === "push-to-talk";
  const thread = h("div", { class: "ob-thread", role: "log", "aria-live": "polite" }, [
    bubble("them", "Hi! What will you use Fairspoken for? Answer out loud."),
  ]);
  const live = h("div", { class: "ob-compose-text", "data-placeholder": "Your words appear here as you speak" });
  const mic = h("button", { class: "ob-mic-btn", type: "button", "aria-label": "Hold to talk", title: "Hold to talk" }, [svg(ICONS.mic)]);
  const compose = h("div", { class: "ob-compose" }, [live, mic]);
  const hint = h("p", { class: "ob-try-hint" }, holdMode
    ? ["Hold", keycaps(shortcut), "while you speak, or hold the microphone button."]
    : ["Press", keycaps(shortcut), "to start and again to finish, or hold the microphone button."]);
  const chat = h("div", { class: "ob-card ob-chat" }, [thread, compose]);
  const status = h("p", { class: "ob-note", id: "obTryStatus" });
  stepHost.replaceChildren(header("bubble", "teal", "Try it", "Say a sentence. Watch it appear as you speak."), hint, chat, status);
  setFooter({ next: "Continue", back: true, skip: "Skip" });

  // Whether the chosen model can transcribe yet, and what to do if not.
  const showModel = () => {
    const state = modelState(settings?.model ?? chosenModel);
    const name = speechInfo(settings?.model ?? chosenModel).name;
    mic.disabled = state !== "ready";
    compose.classList.toggle("is-waiting", state !== "ready");
    status.classList.toggle("ob-note--warn", state === "failed" || state === "missing");
    status.textContent = state === "downloading" ? `${name} is downloading · ${Math.round(download.percentage)}%. You can try it when it's ready.`
      : state === "failed" ? `${name} didn't download. Go back to try again, or skip this step.`
      : state === "missing" ? `${name} isn't downloaded yet. Go back to download it, or skip this step.`
      : "";
  };
  showModel();

  let tries = 0;
  const result = (text: string, seconds: number) => {
    const clean = text.trim();
    live.textContent = "";
    compose.classList.remove("is-live");
    if (!clean) { status.textContent = "Nothing was heard. Try again a little louder."; return; }
    thread.append(bubble("me", clean));
    const words = clean.split(/\s+/).length;
    const wpm = seconds > 0 ? Math.round((words / seconds) * 60) : 0;
    tries += 1;
    const detail = wpm > 0 ? `${words} word${words === 1 ? "" : "s"} in ${seconds.toFixed(1)} s · ${wpm} words a minute` : `${words} word${words === 1 ? "" : "s"}`;
    setTimeout(() => {
      thread.append(h("div", { class: "ob-bubble ob-bubble--them ob-bubble--done" }, [
        svg(ICONS.check),
        h("span", {}, [h("strong", {}, [tries === 1 ? "That's it. It works." : "Got that too."]), h("span", {}, [detail])]),
      ]));
      thread.scrollTop = thread.scrollHeight;
    }, 320);
    thread.scrollTop = thread.scrollHeight;
  };

  // Hold-to-talk on the button: the side-effect-free capture the voice
  // accuracy test uses, so nothing is pasted or saved.
  let holding = false;
  let stopping = false;
  let started: Promise<unknown> | null = null;

  const unlisten: Promise<UnlistenFn>[] = [
    listen<{ text: string }>("transcript-preview", (event) => {
      live.textContent = event.payload.text;
      compose.classList.add("is-live");
    }),
    listen<{ item: HistoryItem }>("transcript-history-updated", (event) => {
      if (!holding) result(event.payload.item.text, event.payload.item.durationSeconds);
    }),
    listen<PrepareProgress>("model-prepare-progress", () => showModel()),
  ];

  const press = (event: Event) => {
    event.preventDefault();
    if (holding || stopping || mic.disabled) return;
    holding = true;
    mic.classList.add("is-on");
    compose.classList.add("is-live");
    status.textContent = "";
    started = invoke("start_recording").catch((error) => {
      status.textContent = String(error);
      holding = false;
      mic.classList.remove("is-on");
      compose.classList.remove("is-live");
      throw error;
    });
  };
  // pointerup and pointerleave both end a hold; only the first one stops.
  const release = () => {
    if (!holding || stopping) return;
    stopping = true;
    mic.classList.remove("is-on");
    void (started ?? Promise.resolve())
      .then(() => invoke<{ transcript: string; recordingSeconds: number }>("stop_voice_test_capture"))
      .then((capture) => result(capture.transcript, capture.recordingSeconds))
      .catch((error) => { if (holding) status.textContent = String(error); live.textContent = ""; compose.classList.remove("is-live"); })
      .finally(() => { holding = false; stopping = false; });
  };
  mic.addEventListener("pointerdown", press);
  mic.addEventListener("pointerup", release);
  mic.addEventListener("pointerleave", release);
  mic.addEventListener("keydown", (event) => { if ((event.key === " " || event.key === "Enter") && !event.repeat) press(event); });
  mic.addEventListener("keyup", (event) => { if (event.key === " " || event.key === "Enter") release(); });

  leaveStep = () => {
    release();
    for (const pending of unlisten) void pending.then((stop) => stop()).catch(() => {});
  };
}

function bubble(who: "me" | "them", text: string): HTMLElement {
  return h("div", { class: `ob-bubble ob-bubble--${who}` }, [text]);
}

function renderImprove(): void {
  const toggle = h("input", { type: "checkbox", role: "switch", class: "ob-switch", id: "obTraining" }) as HTMLInputElement;
  toggle.checked = Boolean(settings?.trainingCapture);
  toggle.addEventListener("change", () => {
    void saveSettings({ trainingCapture: toggle.checked }).catch(() => { toggle.checked = !toggle.checked; });
  });
  stepHost.replaceChildren(
    header("heart", "pink", "Help improve the models", "Optional, and off unless you turn it on."),
    h("div", { class: "ob-card ob-toggle-card" }, [
      h("label", { class: "ob-card-text", for: "obTraining" }, [
        h("strong", {}, ["Keep my dictations to improve models"]),
        h("span", {}, ["Saves each dictation's audio and text on this computer, for training your own models. Nothing is uploaded. Export or delete them any time in Settings."]),
      ]),
      toggle,
    ]),
    h("p", { class: "ob-note" }, ["Leave this off for patient notes or anything else sensitive."]),
  );
  setFooter({ next: "Continue", back: true });
}

// Done: a live checklist of what setup left in place, each with its fix.
function checkItem(ok: boolean | "busy", title: string, detail: string, fix?: { label: string; step: Step }): HTMLElement {
  const mark = ok === true ? h("span", { class: "ob-check ob-check--ok", "aria-hidden": "true" }, [svg(ICONS.check)])
    : ok === "busy" ? h("span", { class: "ob-check ob-check--busy", "aria-hidden": "true" })
    : h("span", { class: "ob-check ob-check--warn", "aria-hidden": "true" }, ["!"]);
  const button = fix ? h("button", { class: "ob-btn ob-btn--sm", type: "button" }, [fix.label]) : null;
  button?.addEventListener("click", () => go(fix!.step));
  return h("li", { class: "ob-check-row" }, [mark, h("div", { class: "ob-card-text" }, [h("strong", {}, [title]), h("span", {}, [detail])]), button]);
}

function renderDone(): void {
  const shortcut = settings?.recordingShortcut ?? "";
  const mac = permissions.platform === "macos";
  const micOk = permissions.microphone === "granted";
  const typeOk = permissions.accessibility === "granted";
  const model = settings?.model ?? chosenModel;
  const state = modelState(model);
  const name = speechInfo(model).name;
  const ready = micOk && (!mac || typeOk) && state === "ready";
  const list = h("ul", { class: "ob-card ob-checklist" }, [
    checkItem(micOk, "Microphone", micOk ? "Allowed" : "Not allowed yet", micOk ? undefined : { label: "Fix", step: "permissions" }),
    mac ? checkItem(typeOk, "Typing into apps", typeOk ? "Accessibility is allowed" : "Accessibility is needed to type where your cursor is", typeOk ? undefined : { label: "Fix", step: "permissions" }) : null,
    checkItem(state === "ready" ? true : state === "downloading" ? "busy" : false, name,
      state === "ready" ? "Downloaded and ready" : state === "downloading" ? `Downloading · ${Math.round(download.percentage)}%` : state === "failed" ? "The download failed" : "Not downloaded yet",
      state === "ready" || state === "downloading" ? undefined : { label: state === "failed" ? "Retry" : "Download", step: "model" }),
  ]);
  stepHost.replaceChildren(
    header(ready ? "check" : "wave", "green", ready ? "You're all set" : "Almost there", ready ? "Fairspoken is ready in every app." : "Everything else is ready. You can finish later in Settings."),
    h("div", { class: "ob-card ob-recap" }, [
      h("div", { class: "ob-recap-keys" }, [keycaps(shortcut)]),
      h("p", {}, [settings?.recordingShortcutMode === "push-to-talk" ? "Hold to dictate in any app, let go to insert." : "Press to dictate in any app, press again to insert."]),
    ]),
    list,
  );
  setFooter({ next: "Open Fairspoken", back: true });
}

// ── Navigation ──────────────────────────────────────────────────────────
function setFooter(options: { next: string; back?: boolean; skip?: string }): void {
  nextButton.textContent = options.next;
  backButton.hidden = !options.back;
  skipButton.hidden = !options.skip;
  if (options.skip) skipButton.textContent = options.skip;
}

function renderProgress(): void {
  const index = STEPS.indexOf(step);
  progressList.replaceChildren(...STEPS.map((name, i) => h("li", {
    class: i < index ? "is-done" : i === index ? "is-current" : "",
    "aria-current": i === index ? "step" : false,
    "aria-label": `${STEP_NAMES[name]}${i < index ? ", done" : ""}`,
  })));
}

function go(next: Step): void {
  leaveStep?.();
  leaveStep = null;
  step = next;
  document.documentElement.dataset.step = next;
  renderProgress();
  stepHost.classList.remove("is-entering");
  void stepHost.offsetWidth;
  stepHost.classList.add("is-entering");
  switch (next) {
    case "welcome": renderWelcome(); break;
    case "permissions": enterPermissions(); break;
    case "mic": enterMic(); break;
    case "model": renderModel(); break;
    case "try": enterTry(); break;
    case "improve": renderImprove(); break;
    case "done": renderDone(); break;
  }
  stepHost.querySelector<HTMLElement>("h1")?.focus({ preventScroll: true });
}

let finished = false;

async function advance(): Promise<void> {
  const index = STEPS.indexOf(step);
  if (step === "model") {
    nextButton.disabled = true;
    let ok = false;
    try { ok = await chooseModel(); } finally { nextButton.disabled = false; }
    if (!ok) return; // stay, with the error and Try again
  }
  if (step === "done") {
    nextButton.disabled = true;
    try {
      await invoke("complete_onboarding");
      finished = true;
    } finally {
      nextButton.disabled = false;
    }
    return;
  }
  go(STEPS[Math.min(STEPS.length - 1, index + 1)]);
}

// The window hides rather than closes. While hidden nothing keeps running
// (the microphone check's stream, a held recording); shown again, it resumes
// the step, or starts over once setup was finished.
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "hidden") {
    leaveStep?.();
    leaveStep = null;
    return;
  }
  if (finished) {
    finished = false;
    void Promise.all([readSettings().catch(() => null), refreshPermissions()]).then(() => go("welcome"));
  } else {
    void refreshPermissions().then(() => go(step));
  }
});

nextButton.addEventListener("click", () => { void advance(); });
skipButton.addEventListener("click", () => go(STEPS[Math.min(STEPS.length - 1, STEPS.indexOf(step) + 1)]));
backButton.addEventListener("click", () => go(STEPS[Math.max(0, STEPS.indexOf(step) - 1)]));
document.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && event.target === document.body) void advance();
});

void listen<PrepareProgress>("model-prepare-progress", (event) => {
  const progress = event.payload;
  Object.assign(download, { model: progress.model, percentage: progress.percentage, message: progress.message, active: !progress.done, error: progress.error ?? "" });
  if (progress.done && !progress.error) {
    const model = speech.find((entry) => entry.model === progress.model);
    if (model) model.cached = true;
  }
  if (step === "model") renderModel();
  if (step === "done") renderDone();
}).catch(() => {});

// Open on the step named in the URL (#mic, for a re-run from Settings or a
// screenshot), else the welcome.
async function start(): Promise<void> {
  await Promise.all([
    readSettings().catch(() => null),
    invoke<SpeechModel[]>("get_dictation_models").then((models) => { speech = models; }).catch(() => {}),
    refreshPermissions(),
  ]);
  if (settings?.model && SPEECH_MODELS.some((model) => model.id === settings!.model)) chosenModel = settings.model;
  if (!STARTER_MODELS.includes(chosenModel)) STARTER_MODELS.unshift(chosenModel);
  const wanted = location.hash.slice(1) as Step;
  go(STEPS.includes(wanted) ? wanted : "welcome");
}
void start();
