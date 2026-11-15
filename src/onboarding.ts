import "./appearance";
import "./onboarding.css";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { accelTokens, keyGlyph, keyWord } from "./shortcuts";
import { SPEECH_MODELS, formatBytes, speechInfo } from "./modelCatalog";

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
    default: return ["Not checked", "idle"];
  }
}

function permissionCard(kind: "microphone" | "accessibility" | "inputMonitoring", icon: keyof typeof ICONS, tone: string, title: string, body: string, optional: boolean): HTMLElement {
  const state = permissions[kind];
  const [label, labelTone] = permissionLabel(state);
  const status = h("span", { class: `ob-status ob-status--${labelTone}` }, [state === "granted" ? svg(ICONS.check) : null, label]);
  const action = state === "granted"
    ? null
    : h("button", { class: "ob-btn ob-btn--sm", type: "button" }, [state === "denied" ? "Open Settings" : "Allow"]);
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
// stream (separate from dictation, closed when the step is left).
function enterMic(): void {
  const select = h("select", { class: "ob-select", id: "obMicSelect", "aria-label": "Microphone" });
  const bars = h("div", { class: "ob-wave", "aria-hidden": "true" }, Array.from({ length: 36 }, () => h("span")));
  const status = h("p", { class: "ob-mic-status", role: "status" }, ["Say something…"]);
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
  const levels: number[] = Array(36).fill(0);
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
        heard = level > 0.35 ? heard + 1 : Math.max(0, heard - 0.25);
        if (heard > 4) { status.textContent = "Sounds good."; status.dataset.tone = "ok"; }
      };
      frame = requestAnimationFrame(tick);
      await loadDevices(select);
    } catch {
      status.textContent = "No sound: allow the microphone, or pick another one.";
      status.dataset.tone = "warn";
    }
  };
  select.addEventListener("change", () => { heard = 0; status.textContent = "Say something…"; delete status.dataset.tone; void start(); });
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

function ratingBar(label: string, value: number): HTMLElement {
  return h("span", { class: "ob-rating", "aria-label": `${label} ${value} of 5` }, [
    h("span", { class: "ob-rating-label", "aria-hidden": "true" }, [label]),
    h("span", { class: "ob-rating-steps", "aria-hidden": "true" }, Array.from({ length: 5 }, (_, i) => h("i", { class: i < value ? "on" : "" }))),
  ]);
}

function renderModel(): void {
  const list = h("div", { class: "ob-cards ob-models", role: "radiogroup", "aria-label": "Speech model" });
  for (const id of STARTER_MODELS) {
    const info = speechInfo(id);
    const cached = speech.find((model) => model.model === id)?.cached ?? false;
    const selected = chosenModel === id;
    const downloading = download.active && download.model === id;
    const end = downloading
      ? h("span", { class: "ob-progress-ring", style: `--p:${download.percentage}` }, [h("span", {}, [`${Math.round(download.percentage)}%`])])
      : cached ? h("span", { class: "ob-status ob-status--ok" }, [svg(ICONS.check), "Downloaded"]) : h("span", { class: "ob-size" }, [formatBytes(info.bytes)]);
    const option = h("button", { class: `ob-card ob-model${selected ? " is-selected" : ""}`, type: "button", role: "radio", "aria-checked": String(selected) }, [
      h("span", { class: "ob-radio", "aria-hidden": "true" }),
      h("span", { class: "ob-card-text" }, [
        h("strong", {}, [info.name, info.recommended ? h("span", { class: "ob-badge ob-badge--accent" }, ["Recommended"]) : null, info.language === "en" ? h("span", { class: "ob-badge" }, ["EN"]) : null]),
        h("span", {}, [`${info.summary} · ${info.languages}`]),
        h("span", { class: "ob-ratings" }, [ratingBar("Speed", info.speed), ratingBar("Accuracy", info.accuracy)]),
      ]),
      h("span", { class: "ob-card-end" }, [end]),
    ]);
    option.addEventListener("click", () => { chosenModel = id; renderModel(); (list.querySelector(`[aria-checked="true"]`) as HTMLElement | null)?.focus(); });
    list.append(option);
  }
  stepHost.replaceChildren(
    header("stack", "indigo", "Choose a speech model", "It runs on this computer. You can switch any time in Models."),
    list,
    h("p", { class: "ob-note" }, [download.error ? download.error : "Downloads carry on in the background while you finish setting up. Ratings are estimates."]),
  );
  const cached = speech.find((model) => model.model === chosenModel)?.cached ?? false;
  setFooter({ next: cached || (download.active && download.model === chosenModel) ? "Continue" : "Download and continue", back: true });
}

async function chooseModel(): Promise<void> {
  if (!settings) await readSettings();
  if (settings!.model !== chosenModel) await saveSettings({ model: chosenModel, transcriptionLocation: "local" });
  const cached = speech.find((model) => model.model === chosenModel)?.cached ?? false;
  if (!cached && !(download.active && download.model === chosenModel)) {
    Object.assign(download, { model: chosenModel, percentage: 0, message: "Starting download…", active: true, error: "" });
    await invoke("begin_prepare_transcription_model", { request: { model: chosenModel } }).catch((error) => {
      Object.assign(download, { active: false, error: String(error) });
    });
  }
}

// Try it: a chat with one message waiting for an answer. The real shortcut
// (handled by the pill) dictates as usual; its live text shows in the
// composer and the result arrives as the reply. The button beside the
// composer records without inserting anywhere.
function enterTry(): void {
  const shortcut = settings?.recordingShortcut ?? "";
  const holdMode = settings?.recordingShortcutMode === "push-to-talk";
  const thread = h("div", { class: "ob-thread", role: "log", "aria-live": "polite" }, [
    bubble("them", "Hi! What will you use Fairspoken for? Answer out loud."),
  ]);
  const live = h("div", { class: "ob-compose-text", "data-placeholder": "Your words appear here as you speak" });
  const mic = h("button", { class: "ob-mic-btn", type: "button", "aria-label": "Hold to talk" }, [svg(ICONS.mic)]);
  const compose = h("div", { class: "ob-compose" }, [live, mic]);
  const hint = h("p", { class: "ob-try-hint" }, holdMode
    ? ["Hold", keycaps(shortcut), "while you speak, or hold the microphone button."]
    : ["Press", keycaps(shortcut), "to start and again to finish, or hold the microphone button."]);
  const chat = h("div", { class: "ob-card ob-chat" }, [thread, compose]);
  const status = h("p", { class: "ob-note", id: "obTryStatus" });
  stepHost.replaceChildren(header("bubble", "teal", "Try it", "Say a sentence. Watch it appear as you speak."), hint, chat, status);
  setFooter({ next: "Continue", back: true, skip: "Skip" });

  const modelReady = () => !download.active || download.model !== settings?.model;
  const showDownload = () => {
    const waiting = !modelReady();
    mic.disabled = waiting;
    compose.classList.toggle("is-waiting", waiting);
    status.textContent = waiting ? `${speechInfo(download.model).name} is downloading · ${Math.round(download.percentage)}%. You can try it when it's ready.` : "";
  };
  showDownload();

  let answered = false;
  const answer = (text: string, seconds: number) => {
    const clean = text.trim();
    live.textContent = "";
    compose.classList.remove("is-live");
    if (!clean) return;
    thread.append(bubble("me", clean));
    const words = clean.split(/\s+/).length;
    const wpm = seconds > 0 ? Math.round((words / seconds) * 60) : 0;
    const reply = answered
      ? "Lovely. Keep going as long as you like."
      : wpm > 0
        ? `Got it: ${words} word${words === 1 ? "" : "s"} in ${seconds.toFixed(1)} seconds. That's about ${wpm} words a minute${wpm >= 80 ? `, ${Math.round(wpm / 40)}× a typical typing speed` : ""}.`
        : "Got it. That's all there is to it.";
    answered = true;
    setTimeout(() => { thread.append(bubble("them", reply)); thread.scrollTop = thread.scrollHeight; }, 380);
    thread.scrollTop = thread.scrollHeight;
  };

  const unlisten: Promise<UnlistenFn>[] = [
    listen<{ text: string }>("transcript-preview", (event) => {
      live.textContent = event.payload.text;
      compose.classList.add("is-live");
    }),
    listen<{ item: HistoryItem }>("transcript-history-updated", (event) => {
      if (!holding) answer(event.payload.item.text, event.payload.item.durationSeconds);
    }),
    listen<PrepareProgress>("model-prepare-progress", () => showDownload()),
  ];

  // Hold-to-talk on the button: the side-effect-free capture the voice
  // accuracy test uses, so nothing is pasted or saved.
  let holding = false;
  let started: Promise<unknown> | null = null;
  const press = (event: Event) => {
    event.preventDefault();
    if (holding || mic.disabled) return;
    holding = true;
    mic.classList.add("is-on");
    compose.classList.add("is-live");
    started = invoke("start_recording").catch((error) => { status.textContent = String(error); holding = false; mic.classList.remove("is-on"); });
  };
  const release = () => {
    if (!holding) return;
    mic.classList.remove("is-on");
    void (started ?? Promise.resolve()).then(() => invoke<{ transcript: string; recordingSeconds: number }>("stop_voice_test_capture"))
      .then((capture) => answer(capture.transcript, capture.recordingSeconds))
      .catch((error) => { status.textContent = String(error); live.textContent = ""; compose.classList.remove("is-live"); })
      .finally(() => { holding = false; });
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

function renderDone(): void {
  const shortcut = settings?.recordingShortcut ?? "";
  stepHost.replaceChildren(
    header("check", "green", "You're all set", "Fairspoken is ready in every app."),
    h("div", { class: "ob-card ob-recap" }, [
      h("div", { class: "ob-recap-keys" }, [keycaps(shortcut)]),
      h("p", {}, [settings?.recordingShortcutMode === "push-to-talk" ? "Hold to dictate, let go to insert." : "Press to start, press again to insert."]),
    ]),
    h("ul", { class: "ob-points ob-points--compact" }, [
      point("wave", "green", "The pill shows when it's listening", "It sits at the bottom of your screen. Click it to start or stop."),
      point("stack", "indigo", "Change models any time", "Models has speech and polish models, with search."),
    ]),
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

async function advance(): Promise<void> {
  const index = STEPS.indexOf(step);
  if (step === "model") {
    nextButton.disabled = true;
    try { await chooseModel(); } finally { nextButton.disabled = false; }
  }
  if (step === "done") {
    nextButton.disabled = true;
    try { await invoke("complete_onboarding"); } catch { nextButton.disabled = false; }
    return;
  }
  go(STEPS[Math.min(STEPS.length - 1, index + 1)]);
}

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
