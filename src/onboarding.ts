import "./appearance";
import "./onboarding.css";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { shortcutHint } from "./shortcuts";
import { SPEECH_MODELS, formatBytes, isMeasured, speechInfo, starterChoices } from "./modelCatalog";
import dogTile from "./assets/brand/dog-tile.jpg";

// First-run setup in its own window: welcome, permissions, a microphone
// check, a speech model, a first dictation, the training-data choice, done.
// It opens until finished (onboarding.rs) and again from Settings → General.
// Every step can be passed; the app works with whatever was set. Drawn as
// the Mac setup guide is (apps/macos/Fairspoken/Sources/UI/Onboarding).

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

const progressHost = document.getElementById("obProgress")!;
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
/** The microphone check heard speech (null until it has run). */
let micHeard: boolean | null = null;
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
  const icon = holder.firstElementChild as SVGSVGElement;
  icon.setAttribute("aria-hidden", "true");
  return icon;
}
const STROKE = 'fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"';
const ICONS = {
  mic: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="2"><rect x="9" y="3" width="6" height="11" rx="3" fill="currentColor"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/></svg>`,
  cursor: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="2"><path d="M3 18 7 6l4 12M4.5 14h5"/><path d="M15 5h2.5M19.5 5H22M18.5 5v14M15 19h2.5M19.5 19H22"/></svg>`,
  keyboard: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="2"><rect x="2.5" y="6" width="19" height="12" rx="2.5"/><path d="M6.5 10h.01M10 10h.01M13.5 10h.01M17 10h.01M7.5 14h9"/></svg>`,
  lock: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="2"><rect x="5" y="10.5" width="14" height="10" rx="2.5" fill="currentColor"/><path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"/></svg>`,
  bolt: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="1.8"><path d="M13 2.5 5 13.5h6l-1 8 8-11h-6Z" fill="currentColor"/></svg>`,
  globe: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="1.6"><circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9c-2.5-2.6-3.7-5.6-3.7-9S9.5 5.6 12 3Z"/></svg>`,
  check: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="2.2"><path d="m5.5 12.5 4.5 4.5 8.5-9.5"/></svg>`,
  checkCircle: `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="currentColor"/><path d="m7.5 12.3 3 3 6-6.6" fill="none" stroke="var(--ob-on-mark)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  dashedCircle: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="2" stroke-dasharray="3.1 3.2"><circle cx="12" cy="12" r="9"/></svg>`,
  minusCircle: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="1.6"><circle cx="12" cy="12" r="9"/><path d="M8 12h8"/></svg>`,
  alertCircle: `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10" fill="currentColor"/><path d="M12 7v6M12 16.6v.1" fill="none" stroke="var(--ob-on-mark)" stroke-width="2.2" stroke-linecap="round"/></svg>`,
  warning: `<svg viewBox="0 0 24 24"><path d="M10.3 3.9 2.4 17.6A2 2 0 0 0 4.1 20.6h15.8a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z" fill="currentColor"/><path d="M12 9v5M12 17.1v.1" fill="none" stroke="var(--ob-on-mark)" stroke-width="2.2" stroke-linecap="round"/></svg>`,
  wave: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="2"><path d="M4.5 10.5v3M8 7.5v9M11.5 4.5v15M15 8v8M18.5 10v4"/></svg>`,
  download: `<svg viewBox="0 0 24 24" ${STROKE} stroke-width="1.8"><circle cx="12" cy="12" r="9"/><path d="M12 7.5v8M8.5 12.5 12 16l3.5-3.5"/></svg>`,
  stop: `<svg viewBox="0 0 24 24"><rect x="7.5" y="7.5" width="9" height="9" rx="1.8" fill="currentColor"/></svg>`,
};
type Icon = keyof typeof ICONS;

/** A soft tile: the symbol in its colour on a faint wash of it. */
function tile(icon: Icon, tone: "red" | "blue" | "gray"): HTMLElement {
  return h("span", { class: `ob-tile ob-tile--${tone}`, "aria-hidden": "true" }, [svg(ICONS[icon])]);
}

function badge(text: string, style: "neutral" | "info" | "outline" = "neutral", title?: string): HTMLElement {
  return h("span", { class: `ob-badge ob-badge--${style}`, title: title ?? false }, [text]);
}

/** The shortcut as people read it: "Ctrl+Shift+1", or "⌘⇧1" on a Mac. */
function shortcutText(): string {
  return shortcutHint(settings?.recordingShortcut ?? "");
}

/** A step's title and its one line of explanation. */
function header(title: string, subtitle: string | Child[]): HTMLElement {
  return h("header", { class: "ob-head" }, [
    h("h1", { tabindex: "-1" }, [title]),
    h("p", {}, typeof subtitle === "string" ? [subtitle] : subtitle),
  ]);
}

/** A grouped list: rows on one card, a hairline between them. */
function group(rows: Child[], attrs: Record<string, string | boolean> = {}): HTMLElement {
  return h("div", { ...attrs, class: `ob-group${attrs.class ? ` ${attrs.class}` : ""}` }, rows);
}

/** A row: the title (with badges), its description, and its control on the right. */
function row(title: Child[], detail: Child[] | string, end: Child[] = [], lead?: Child): HTMLElement {
  return h("div", { class: "ob-row" }, [
    lead,
    h("div", { class: "ob-row-text" }, [
      h("div", { class: "ob-row-title" }, title),
      detail.length ? h("div", { class: "ob-row-detail" }, typeof detail === "string" ? [detail] : detail) : null,
    ]),
    end.some(Boolean) ? h("div", { class: "ob-row-end" }, end) : null,
  ]);
}

function smallButton(label: string, onClick: () => void): HTMLButtonElement {
  const button = h("button", { class: "ob-btn ob-btn--outline", type: "button" }, [label]);
  button.addEventListener("click", onClick);
  return button;
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

const onThisComputer = () => (permissions.platform === "macos" ? "on this Mac" : "on this computer");

// ── Steps ───────────────────────────────────────────────────────────────
function renderWelcome(): void {
  const chip = (icon: Icon, text: string) => h("span", { class: "ob-chip" }, [svg(ICONS[icon]), text]);
  stepHost.replaceChildren(
    h("div", { class: "ob-welcome" }, [
      h("span", { class: "ob-mark", "aria-hidden": "true" }, [h("img", { src: dogTile, alt: "" })]),
      h("h1", { tabindex: "-1" }, ["Welcome to ", h("span", { class: "ob-wordmark" }, ["Bark"])]),
      h("p", {}, ["Speak in any app. Your words appear where you type,", h("br"), "transcribed privately on your own devices."]),
      h("div", { class: "ob-chips" }, [
        chip("lock", permissions.platform === "macos" ? "On this Mac" : "On this computer"),
        chip("bolt", "Text in a blink"),
        chip("globe", "25 languages"),
      ]),
      h("p", { class: "ob-welcome-note" }, ["Setup takes about two minutes."]),
    ]),
  );
  setFooter({ next: "Get started" });
}

function permissionCard(kind: "microphone" | "accessibility" | "inputMonitoring", icon: Icon, tone: "red" | "blue" | "gray", title: string, detail: string, required: boolean): HTMLElement {
  const state = permissions[kind];
  // macOS reports Accessibility only as on or off; its first ask is a prompt.
  const opensSettings = state === "denied" && kind !== "accessibility";
  const end = state === "granted" || state === "not-needed"
    ? h("span", { class: "ob-allowed" }, [svg(ICONS.checkCircle), state === "granted" ? "Allowed" : "Not needed"])
    : smallButton(opensSettings ? "Open Settings" : "Allow", () => { void requestPermission(kind); });
  return row([title, badge(required ? "Required" : "Optional", required ? "info" : "neutral")], detail, [end], tile(icon, tone));
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
  const remote = settings?.transcriptionLocation === "remote-host";
  stepHost.replaceChildren(
    header("Allow access", mac
      ? "Bark asks only for what dictation needs. You can change these in System Settings at any time."
      : "Bark asks only for what dictation needs. You can change this in your system's privacy settings at any time."),
    group([
      permissionCard("microphone", "mic", "red", "Microphone", remote
        ? "Hears you only while you dictate. Audio goes only to your network device."
        : `Hears you only while you dictate. Audio stays ${onThisComputer()}.`, true),
      mac ? permissionCard("accessibility", "cursor", "blue", "Accessibility", "Types your words into the app you're using. Without it, dictations are copied for you to paste.", false) : null,
      mac && settings?.fnPushToTalk ? permissionCard("inputMonitoring", "keyboard", "gray", "Input Monitoring", "Lets you hold fn to dictate.", false) : null,
    ]),
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
      ? "Microphone access is turned off for Bark. Turn it on in System Settings → Privacy & Security → Microphone."
      : "Microphone access is turned off for Bark. Allow it in your system's privacy settings.";
  }
  if (name === "NotFoundError" || name === "OverconstrainedError") return "No microphone found. Connect one, then try again.";
  if (name === "NotReadableError") return "The microphone wouldn't start: it's busy or unavailable. Choose another, or try again.";
  return "The microphone wouldn't start. Choose another, or try again.";
}

const MIC_BARS = 44;

function enterMic(): void {
  const select = h("select", { class: "ob-select", id: "obMicSelect", "aria-label": "Microphone" });
  const bars = h("div", { class: "ob-level", "aria-hidden": "true" }, Array.from({ length: MIC_BARS }, () => h("span")));
  const icon = h("span", { class: "ob-check-icon" });
  const message = h("span", { class: "ob-check-text" });
  const retry = h("button", { class: "ob-btn ob-btn--outline", type: "button", hidden: true }, ["Try again"]);
  const status = h("div", { class: "ob-check-line", role: "status" }, [icon, message, retry]);
  const card = group([
    row(["Microphone"], "Bark listens on this one only while you dictate.", [select]),
    h("div", { class: "ob-level-row" }, [bars]),
    status,
  ], { class: "ob-mic" });
  stepHost.replaceChildren(header("Test your microphone", "Say a few words. The bars should move as you speak."), card);
  setFooter({ next: "Continue", back: true });

  let stream: MediaStream | null = null;
  let context: AudioContext | null = null;
  let frame = 0;
  let heard = 0;
  let session = 0;
  let silentSince = 0;
  // Set when the step is left: a device list or a retry that resolves later
  // must not open the microphone again.
  let disposed = false;
  const levels: number[] = Array(MIC_BARS).fill(0);
  type Tone = "listening" | "ok" | "warn";
  const say = (text: string, tone: Tone) => {
    message.textContent = text;
    status.dataset.tone = tone;
    icon.replaceChildren(svg(ICONS[tone === "ok" ? "checkCircle" : tone === "warn" ? "warning" : "wave"]));
  };
  const draw = (active: boolean) => {
    [...bars.children].forEach((bar, i) => {
      const style = (bar as HTMLElement).style;
      style.height = `${Math.max(4, (active ? levels[i] : 0) * 64).toFixed(1)}px`;
      style.opacity = active ? (0.35 + 0.65 * i / (MIC_BARS - 1)).toFixed(3) : "0.25";
    });
  };
  // A failed start greys the meter and offers to try again.
  const failed = (text: string) => {
    say(text, "warn");
    card.classList.add("is-failed");
    levels.fill(0);
    draw(false);
    retry.hidden = false;
  };
  retry.addEventListener("click", () => { void start(); });
  const stop = () => {
    session += 1;
    cancelAnimationFrame(frame);
    stream?.getTracks().forEach((track) => track.stop());
    void context?.close().catch(() => {});
    stream = null; context = null;
  };
  const start = async () => {
    if (disposed) return;
    stop();
    const mine = session;
    heard = 0;
    card.classList.remove("is-failed", "is-hearing");
    retry.hidden = true;
    say("Listening…", "listening");
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
        draw(true);
        if (level > 0.35) { heard += 1; silentSince = time; } else heard = Math.max(0, heard - 0.25);
        if (heard > 4) {
          if (status.dataset.tone !== "ok") say("Sounds good. We can hear you.", "ok");
          card.classList.add("is-hearing");
          micHeard = true;
        } else if (status.dataset.tone !== "ok" && time - silentSince > 5000) {
          say("Nothing heard. Check the microphone isn't muted, or choose another.", "warn");
          if (micHeard !== true) micHeard = false;
        }
      };
      frame = requestAnimationFrame(tick);
      await loadDevices(select);
    } catch (error) {
      if (mine === session) failed(micProblem(error));
    }
  };
  draw(false);
  select.addEventListener("change", () => { void start(); });
  void loadDevices(select).then(start);
  leaveStep = () => {
    disposed = true;
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

// Model: three good starting points, the recommended one first; the rest
// live in Models. Only those this build can run are offered (starterModels).
const STARTER_MODELS = ["parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2", "base"];
const starters = () => starterChoices(STARTER_MODELS, speech.map((model) => model.model), chosenModel);

/** A 1…5 score as five short segments. */
function scoreBar(label: string, value: number, measured: boolean): HTMLElement {
  return h("span", { class: "ob-score", "aria-label": `${label} ${value} of 5${measured ? "" : ", estimated"}` }, [
    h("span", { class: "ob-score-label", "aria-hidden": "true" }, [measured ? label : `${label} (est.)`]),
    h("span", { class: "ob-score-steps", "aria-hidden": "true" }, Array.from({ length: 5 }, (_, i) => h("i", { class: i < value ? "on" : "" }))),
  ]);
}

function modelState(id: string): "ready" | "downloading" | "failed" | "missing" {
  if (download.active && download.model === id) return "downloading";
  if (speech.find((model) => model.model === id)?.cached) return "ready";
  if (download.error && download.model === id) return "failed";
  return "missing";
}

function modelCard(id: string): HTMLElement {
  const info = speechInfo(id);
  const state = modelState(id);
  const selected = chosenModel === id;
  const stateLabel = state === "downloading" ? h("span", { class: "ob-model-state" }, [`Downloading ${Math.round(download.percentage)}%`])
    : state === "ready" ? h("span", { class: "ob-model-state" }, [svg(ICONS.check), "Downloaded"])
    : state === "failed" ? h("span", { class: "ob-model-state ob-model-state--warn" }, ["Failed"])
    : h("span", { class: "ob-model-state" }, [formatBytes(info.bytes)]);
  const option = h("button", {
    class: `ob-row ob-model${selected ? " is-selected" : ""}`, type: "button", role: "radio", id: `ob-model-${id}`,
    "aria-checked": String(selected), tabindex: selected ? "0" : "-1",
  }, [
    h("span", { class: "ob-radio", "aria-hidden": "true" }),
    h("span", { class: "ob-row-text" }, [
      h("span", { class: "ob-row-title" }, [info.name, info.recommended ? badge("Recommended", "info") : null, info.language === "en" ? badge("EN", "outline", "English only") : null]),
      h("span", { class: "ob-row-detail" }, [info.language === "en" ? info.summary : `${info.summary}, in ${info.languages}`]),
    ]),
    h("span", { class: "ob-model-end" }, [scoreBar("Speed", info.speed, isMeasured(info)), scoreBar("Accuracy", info.accuracy, isMeasured(info)), stateLabel]),
  ]);
  option.addEventListener("click", () => { chosenModel = id; renderModel(); document.getElementById(`ob-model-${id}`)?.focus(); });
  return option;
}

/** The chosen model's download, or why it failed. */
function modelProgress(): HTMLElement | null {
  const info = speechInfo(chosenModel);
  const state = modelState(chosenModel);
  if (state === "downloading") {
    return h("div", { class: "ob-model-progress" }, [
      h("div", { class: "ob-bar", role: "progressbar", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(Math.round(download.percentage)) }, [
        h("span", { style: `width: ${Math.max(2, download.percentage)}%` }),
      ]),
      h("p", {}, [`Downloading ${info.name}: ${Math.round(download.percentage)}% of ${formatBytes(info.bytes)}. You can carry on; it finishes in the background.`]),
    ]);
  }
  if (state === "ready") return h("p", { class: "ob-model-progress ob-model-ready" }, [svg(ICONS.checkCircle), `${info.name} is ready.`]);
  if (state === "failed") {
    return h("div", { class: "ob-callout", role: "alert" }, [svg(ICONS.warning), h("div", {}, [
      h("strong", {}, [`${info.name} didn't download.`]),
      h("span", { class: "ob-selectable" }, [download.error]),
      h("span", {}, ["Check your connection and try again, or skip for now and download it later in Models."]),
    ])]);
  }
  return null;
}

function renderModel(): void {
  const focusedId = stepHost.contains(document.activeElement) ? document.activeElement?.id : "";
  const ids = starters();
  const recommended = ids.filter((id) => speechInfo(id).recommended);
  const others = ids.filter((id) => !speechInfo(id).recommended);
  const list = h("div", { class: "ob-models", role: "radiogroup", "aria-label": "Speech model" }, [
    recommended.length ? group(recommended.map(modelCard)) : null,
    modelProgress(),
    others.length ? h("div", { class: "ob-section" }, [
      h("div", { class: "ob-section-head" }, [
        h("h2", {}, [recommended.length ? "Other models" : "Models"]),
        h("span", {}, [`All ${SPEECH_MODELS.length} are in Models`]),
      ]),
      group(others.map(modelCard)),
    ]) : null,
  ]);
  // Arrow keys move the choice, as in any radio group.
  list.addEventListener("keydown", (event) => {
    const delta = event.key === "ArrowDown" || event.key === "ArrowRight" ? 1 : event.key === "ArrowUp" || event.key === "ArrowLeft" ? -1 : 0;
    if (!delta) return;
    event.preventDefault();
    const order = [...recommended, ...others];
    chosenModel = order[(order.indexOf(chosenModel) + delta + order.length) % order.length];
    renderModel();
    document.getElementById(`ob-model-${chosenModel}`)?.focus();
  });
  stepHost.replaceChildren(
    header("Choose a speech model", `It runs ${onThisComputer()}, so nothing you say is uploaded. The recommended model suits most people; you can change it any time in Models.`),
    list,
    h("p", { class: "ob-footnote" }, ["Speed and accuracy compare the models on a short English test; est. marks an estimate."]),
  );
  const state = modelState(chosenModel);
  const failed = state === "failed";
  setFooter({
    next: state === "ready" || state === "downloading" ? "Continue" : failed ? "Try again" : "Download and continue",
    back: true,
    skip: state === "ready" || state === "downloading" ? undefined : "Skip for now",
  });
  // A progress update re-renders the list; keep focus where it was.
  if (focusedId) document.getElementById(focusedId)?.focus({ preventScroll: true });
}

/** Saves the choice and starts its download. False when the download could not start. */
async function chooseModel(): Promise<boolean> {
  if (!settings) await readSettings();
  // Choosing a model here means dictating with it on this computer, even
  // when it is already the configured one and dictation ran on a host.
  if (settings!.model !== chosenModel || settings!.transcriptionLocation !== "local") {
    await saveSettings({ model: chosenModel, transcriptionLocation: "local" });
  }
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

// Try it: a message thread waiting for an answer. The real shortcut (handled
// by the pill) dictates as usual; its live text shows in the message box, and
// what was heard lands as your message with how fast you spoke. The button
// beside the message box records without inserting anywhere.
function enterTry(): void {
  const holdMode = settings?.recordingShortcutMode === "push-to-talk";
  const keys = shortcutText();
  const thread = h("div", { class: "ob-thread", role: "log", "aria-live": "polite" }, [
    h("div", { class: "ob-bubble ob-bubble--them" }, ["Try a sentence like “Book a follow-up in ten days and send the letter to Dr Byrne.”"]),
  ]);
  const level = h("span", { class: "ob-compose-level", "aria-hidden": "true" }, Array.from({ length: 12 }, () => h("span")));
  const live = h("span", { class: "ob-compose-text", "data-placeholder": "Your words appear here as you speak" });
  const field = h("div", { class: "ob-compose-field" }, [level, live]);
  const mic = h("button", { class: "ob-mic-btn", type: "button", "aria-label": "Hold to talk", title: "Hold to talk" }, [svg(ICONS.mic), svg(ICONS.stop)]);
  const compose = h("div", { class: "ob-compose" }, [field, mic]);
  const chat = h("div", { class: "ob-chat" }, [thread, compose]);
  const status = h("p", { class: "ob-try-status", id: "obTryStatus" });
  stepHost.replaceChildren(
    header("Try it", keys
      ? [`${holdMode ? "Hold" : "Press"} `, h("span", { class: "ob-keys-inline" }, [keys]), ` and say something, or hold the microphone button.`]
      : "Hold the microphone button and say something."),
    chat,
    status,
  );
  setFooter({ next: "Continue", back: true });

  // Whether the chosen model can transcribe yet, and what to do if not.
  const showModel = () => {
    const state = modelState(settings?.model ?? chosenModel);
    const name = speechInfo(settings?.model ?? chosenModel).name;
    mic.disabled = state !== "ready";
    compose.classList.toggle("is-waiting", state !== "ready");
    status.classList.toggle("is-warn", state === "failed" || state === "missing");
    status.replaceChildren(...(state === "ready" ? [] : [
      svg(ICONS[state === "downloading" ? "download" : "warning"]),
      state === "downloading" ? `${name} is still downloading (${Math.round(download.percentage)}%). Dictation starts working when it's done.`
        : state === "failed" ? `${name} didn't download. Go back to try again, or skip this step.`
        : `${name} isn't downloaded yet. Go back to download it, or skip this step.`,
    ]));
  };
  showModel();

  // A level that moves while the button is held (the window's own stream is
  // not open here, so it follows the live words arriving).
  let pulse = 0;
  const animate = () => {
    pulse = requestAnimationFrame(animate);
    const t = performance.now() / 1000;
    [...level.children].forEach((bar, i) => {
      (bar as HTMLElement).style.transform = `scaleY(${(0.35 + 0.65 * Math.abs(Math.sin(t * 5 + i * 0.9))).toFixed(3)})`;
    });
  };
  const setLive = (on: boolean) => {
    compose.classList.toggle("is-live", on);
    cancelAnimationFrame(pulse);
    if (on && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) animate();
  };

  const say = (text: string) => { status.classList.add("is-warn"); status.replaceChildren(svg(ICONS.warning), text); };
  const result = (text: string, seconds: number) => {
    const clean = text.trim();
    live.textContent = "";
    setLive(false);
    if (!clean) { say("Nothing was heard. Try again a little louder, or go back to test the microphone."); return; }
    const words = clean.split(/\s+/).length;
    const wpm = seconds > 0 ? Math.round((words / seconds) * 60) : 0;
    const stats = [`${words} word${words === 1 ? "" : "s"}`, seconds > 0 ? `${seconds.toFixed(1)} s` : "", wpm > 0 ? `${wpm} words a minute` : ""].filter(Boolean).join(" · ");
    thread.append(h("div", { class: "ob-mine" }, [h("div", { class: "ob-bubble ob-bubble--me" }, [clean]), h("span", { class: "ob-stats" }, [stats])]));
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
      setLive(true);
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
    setLive(true);
    showModel();
    started = invoke("start_recording").catch((error) => {
      say(String(error));
      holding = false;
      mic.classList.remove("is-on");
      setLive(false);
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
      .catch((error) => { if (holding) say(String(error)); live.textContent = ""; setLive(false); })
      .finally(() => { holding = false; stopping = false; });
  };
  mic.addEventListener("pointerdown", press);
  mic.addEventListener("pointerup", release);
  mic.addEventListener("pointerleave", release);
  mic.addEventListener("keydown", (event) => { if ((event.key === " " || event.key === "Enter") && !event.repeat) press(event); });
  mic.addEventListener("keyup", (event) => { if (event.key === " " || event.key === "Enter") release(); });

  leaveStep = () => {
    release();
    cancelAnimationFrame(pulse);
    for (const pending of unlisten) void pending.then((stop) => stop()).catch(() => {});
  };
}

function renderImprove(): void {
  const toggle = h("input", { type: "checkbox", role: "switch", class: "ob-switch", id: "obTraining", "aria-label": "Keep my dictations to improve models" }) as HTMLInputElement;
  toggle.checked = Boolean(settings?.trainingCapture);
  toggle.addEventListener("change", () => {
    void saveSettings({ trainingCapture: toggle.checked }).catch(() => { toggle.checked = !toggle.checked; });
  });
  stepHost.replaceChildren(
    header("Help improve the models", "Optional, and off unless you turn it on."),
    group([
      row([h("label", { for: "obTraining" }, ["Keep my dictations to improve models"])],
        `Saves each dictation's audio and text ${onThisComputer()}, for training your own models. Nothing is uploaded. Export or delete them any time in Settings.`, [toggle]),
    ]),
    h("p", { class: "ob-footnote" }, ["Leave this off for patient notes or anything else sensitive."]),
  );
  setFooter({ next: "Continue", back: true });
}

// Done: a live checklist of what setup left in place, each with its fix.
type CheckState = "done" | "pending" | "problem" | "busy";
function checkItem(state: CheckState, required: boolean, title: string, detail: string, fix?: { label: string; step: Step }): HTMLElement {
  const icon = state === "done" ? ICONS.checkCircle : state === "problem" ? ICONS.alertCircle : required ? ICONS.dashedCircle : ICONS.minusCircle;
  const tone = state === "busy" ? "pending" : state;
  const mark = h("span", { class: `ob-check-mark ob-check-mark--${tone}${required ? "" : " is-optional"}` }, [svg(icon)]);
  // Downloading: a spinner where the fix would be.
  const end = state === "busy" ? h("span", { class: "ob-spinner", "aria-hidden": "true" })
    : fix ? smallButton(fix.label, () => go(fix.step)) : null;
  return row([title, required ? null : badge("Optional")], detail, [end], h("span", { class: "ob-check-lead", "aria-hidden": "true" }, [mark]));
}

function renderDone(): void {
  const mac = permissions.platform === "macos";
  const micOk = permissions.microphone === "granted";
  const typeOk = permissions.accessibility === "granted";
  const model = settings?.model ?? chosenModel;
  const state = modelState(model);
  const name = speechInfo(model).name;
  // Only what dictation can't work without; typing into apps is optional.
  const ready = micOk && state === "ready";
  const keys = shortcutText();
  const hold = settings?.recordingShortcutMode === "push-to-talk";
  const list = group([
    checkItem(micOk ? "done" : permissions.microphone === "denied" ? "problem" : "pending", true, "Microphone allowed",
      micOk ? "Heard only while you dictate" : permissions.microphone === "denied" ? "Turned off in your privacy settings" : "Not allowed yet",
      micOk ? undefined : { label: "Fix", step: "permissions" }),
    checkItem(state === "ready" ? "done" : state === "downloading" ? "busy" : state === "failed" ? "problem" : "pending", true, "Speech model ready",
      state === "ready" ? `${name} ${onThisComputer()}` : state === "downloading" ? `Downloading, ${Math.round(download.percentage)}%` : state === "failed" ? download.error || "The download failed" : "Not downloaded",
      state === "ready" || state === "downloading" ? undefined : { label: "Fix", step: "model" }),
    mac ? checkItem(typeOk ? "done" : "pending", false, "Types into apps", typeOk ? "Your words go where you type" : "Dictations are copied for you to paste",
      typeOk ? undefined : { label: "Allow", step: "permissions" }) : null,
    micHeard === null ? null : checkItem(micHeard ? "done" : "pending", false, "Microphone tested", micHeard ? "We heard you" : "Nothing heard",
      micHeard ? undefined : { label: "Test", step: "mic" }),
  ]);
  stepHost.replaceChildren(
    header(ready ? "You're all set" : "Almost there", ready
      ? (keys ? [`${hold ? "Hold" : "Press"} `, h("span", { class: "ob-keys-inline" }, [keys]), " in any app to dictate."] : "Bark is ready in every app.")
      : "Bark can't dictate until the items marked below are done. You can finish later in Settings."),
    list,
  );
  setFooter({ next: ready ? "Start dictating" : "Done", back: true });
}

// ── Navigation ──────────────────────────────────────────────────────────
function setFooter(options: { next: string; back?: boolean; skip?: string }): void {
  nextButton.textContent = options.next;
  backButton.hidden = !options.back;
  skipButton.hidden = !options.skip;
  if (options.skip) skipButton.textContent = options.skip;
}

// "Step 2 of 6 · Microphone" over a segmented line; the welcome shows none.
function renderProgress(): void {
  const steps: Step[] = STEPS.filter((name) => name !== "welcome");
  const index = steps.indexOf(step);
  if (index < 0) {
    progressHost.replaceChildren();
    return;
  }
  const caption = `Step ${index + 1} of ${steps.length} · ${STEP_NAMES[step]}`;
  progressHost.replaceChildren(
    h("div", { class: "ob-segments", "aria-hidden": "true" }, steps.map((_, i) => h("span", { class: i < index ? "is-done" : i === index ? "is-current" : "" }))),
    h("p", { "aria-label": `Step ${index + 1} of ${steps.length}, ${STEP_NAMES[step]}` }, [caption]),
  );
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
  document.documentElement.dataset.platform = permissions.platform;
  if (settings?.model && SPEECH_MODELS.some((model) => model.id === settings!.model)) chosenModel = settings.model;
  if (!starters().includes(chosenModel)) chosenModel = starters()[0] ?? chosenModel;
  const wanted = location.hash.slice(1) as Step;
  go(STEPS.includes(wanted) ? wanted : "welcome");
}
void start();
