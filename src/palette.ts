import { invoke } from "@tauri-apps/api/core";
import { emit } from "@tauri-apps/api/event";
import "./palette.css";
import { ageLabel, dictationTitle, matchRanges, monogramHue, monogramLetters, rank, type Fields } from "./paletteRank";
import { isMacOS, shortcutHint } from "./shortcuts";

// Ctrl+K (⌘K on a Mac) inside Bark: one field, results grouped under small
// labels (dictations by their words and app, then actions and Settings),
// shortcut hints on the right, and the keys along the foot. Keyboard first:
// ↑↓ move, Enter opens, Ctrl+C copies a dictation's text, Esc closes. A solid
// card over a dimmed window, the same as the Mac app's palette.
//
// The palette owns no screens: it moves the app by dispatching
// `bark-navigate` on `document` ({ detail: { route } }), which the shell
// handles. Routes: "home", "dictation/<id>", "models", "training",
// "settings/<page>[#<control id>]", "speedtest" and "voicetest".

type Group = "dictations" | "actions" | "settings";
const GROUP_TITLES: Record<Group, string> = { dictations: "Dictations", actions: "Actions", settings: "Settings" };

interface Entry {
  id: string;
  group: Group;
  title: string;
  /** A second line under the title (dictations). */
  subtitle?: string;
  /** A muted word on the right (the Settings page a setting is on). */
  aside?: string;
  /** An icon's SVG, or the app a dictation went into (for its monogram). */
  leading: { icon: string } | { app: string | null };
  shortcut?: string;
  /** Searched beside the title, counting for less. */
  keywords: string[];
  /** The history item Ctrl+C copies. */
  copyId?: string;
  run: () => void;
}

interface HistoryItem {
  id: string;
  createdAt: number;
  text: string;
  appName?: string | null;
  format?: { format?: string } | null;
}

const onMac = isMacOS();
const KEYS = {
  open: onMac ? "⌘K" : "Ctrl+K",
  enter: onMac ? "↵" : "Enter",
  esc: onMac ? "esc" : "Esc",
  copy: onMac ? "⌘C" : "Ctrl+C",
};

// ── Icons (16 px, drawn on a 24 grid, stroked in the text colour) ─────────

const svg = (body: string) =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${body}</svg>`;
const ICONS = {
  search: svg('<circle cx="10.5" cy="10.5" r="6.5"/><path d="m15.5 15.5 5 5"/>'),
  mic: svg('<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>'),
  copy: svg('<rect x="8.5" y="8.5" width="11" height="12" rx="2"/><path d="M15.5 8.5V5.5a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h2"/>'),
  layers: svg('<path d="m12 3.5 8.5 4.5-8.5 4.5L3.5 8Z"/><path d="m3.5 12 8.5 4.5 8.5-4.5M3.5 16l8.5 4.5 8.5-4.5"/>'),
  gauge: svg('<path d="M4.2 17.5a8.5 8.5 0 1 1 15.6 0"/><path d="m12 13 4-4.5"/><circle cx="12" cy="13.2" r="1.2"/>'),
  target: svg('<circle cx="12" cy="12" r="8.5"/><circle cx="12" cy="12" r="4.5"/><circle cx="12" cy="12" r="0.8"/>'),
  sync: svg('<path d="M19.5 12a7.5 7.5 0 0 1-12.8 5.3M4.5 12a7.5 7.5 0 0 1 12.8-5.3"/><path d="M17.5 3.5v3.3h-3.3M6.5 20.5v-3.3h3.3"/>'),
  guide: svg('<circle cx="12" cy="12" r="8.5"/><path d="m15.2 8.8-2 4.4-4.4 2 2-4.4Z"/>'),
  training: svg('<path d="M3.5 12h1.5M7.5 8v8M11 5v14M14.5 9v6"/><circle cx="18.5" cy="16.5" r="2.8"/>'),
  sliders: svg('<path d="M4 6.5h9M17 6.5h3M4 12h3M11 12h9M4 17.5h10M18 17.5h2"/><circle cx="15" cy="6.5" r="2"/><circle cx="9" cy="12" r="2"/><circle cx="16" cy="17.5" r="2"/>'),
  history: svg('<path d="M4.5 12a7.5 7.5 0 1 0 2.2-5.3L4.5 9"/><path d="M4.5 4.5V9H9M12 8v4.5l3 2"/>'),
  waveform: svg('<path d="M3.5 12h1M7 9v6M10.5 5v14M14 8v8M17.5 10.5v3M20.5 12h0"/>'),
  textformat: svg('<path d="M3.5 19 8 6l4.5 13M5 15h6"/><path d="M20.5 19v-4.5a2.5 2.5 0 0 0-5 0M15.5 16.5c0-1 1-1.5 2.5-1.5h2.5M20.5 17a2.2 2.2 0 0 1-2.5 2.2c-1.4 0-2.5-.7-2.5-1.8"/>'),
  book: svg('<path d="M5.5 19.5V5a1.5 1.5 0 0 1 1.5-1.5h11.5v14H7a1.5 1.5 0 0 0-1.5 1.5 1.5 1.5 0 0 0 1.5 1.5h11.5"/>'),
  server: svg('<rect x="4" y="4" width="16" height="6.5" rx="1.5"/><rect x="4" y="13.5" width="16" height="6.5" rx="1.5"/><path d="M7.5 7.25h.01M7.5 16.75h.01"/>'),
  info: svg('<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5M12 7.8h.01"/>'),
  dictation: svg('<path d="M5 5.5h14a1.5 1.5 0 0 1 1.5 1.5v8a1.5 1.5 0 0 1-1.5 1.5h-7l-4 3.5v-3.5H5A1.5 1.5 0 0 1 3.5 15V7A1.5 1.5 0 0 1 5 5.5Z"/>'),
};

// ── Settings: the pages, then their main settings ─────────────────────────

type Page = "general" | "history" | "transcription" | "app-styles" | "dictionary" | "server" | "updates" | "about";
const PAGES: Array<{ page: Page; title: string; icon: string; keywords: string[] }> = [
  { page: "general", title: "General", icon: ICONS.sliders, keywords: ["shortcut", "microphone"] },
  { page: "history", title: "History", icon: ICONS.history, keywords: ["dictations", "notes", "keep"] },
  { page: "transcription", title: "Transcription", icon: ICONS.waveform, keywords: ["model", "language", "polish"] },
  { page: "app-styles", title: "App styles", icon: ICONS.textformat, keywords: ["tone", "format"] },
  { page: "dictionary", title: "Dictionary", icon: ICONS.book, keywords: ["vocabulary", "words", "corrections"] },
  { page: "server", title: "Bark Server", icon: ICONS.server, keywords: ["host", "remote", "network"] },
  { page: "updates", title: "Updates", icon: ICONS.sync, keywords: ["version", "channel"] },
  { page: "about", title: "About", icon: ICONS.info, keywords: ["version", "privacy"] },
];

/** The settings this app has, in the Mac's words where both apps have them.
 * `anchor` is the control's id, for the shell to scroll to. */
const SETTINGS: Array<{ page: Page; title: string; anchor: string; keywords: string; macOnly?: boolean }> = [
  { page: "general", title: "Dictation shortcut", anchor: "recordingShortcutChip", keywords: "hotkey keyboard key record" },
  { page: "general", title: "Shortcut mode", anchor: "recordingModeSeg", keywords: "toggle push to talk hold press" },
  { page: "general", title: "Hold fn to dictate", anchor: "fnPushToTalk", keywords: "globe function key push to talk", macOnly: true },
  { page: "general", title: "Show copied messages", anchor: "transcriptStackShortcutChip", keywords: "shortcut hotkey keyboard stack shelf" },
  { page: "general", title: "Microphone", anchor: "audioDeviceSelect", keywords: "input device audio mic level" },
  { page: "general", title: "Input gain", anchor: "inputGain", keywords: "microphone volume level loud quiet" },
  { page: "general", title: "Noise suppression", anchor: "noiseSuppression", keywords: "microphone background noise filter" },
  { page: "general", title: "Echo cancellation", anchor: "echoCancellation", keywords: "microphone speakers echo" },
  { page: "general", title: "Longest recording", anchor: "maxRecordingSeconds", keywords: "stop recording after maximum length duration limit" },
  { page: "general", title: "Paste into the current app", anchor: "insertAtCursor", keywords: "insert cursor command v accessibility", macOnly: true },
  { page: "general", title: "Insert without pasting", anchor: "accessibilityInsert", keywords: "accessibility type clipboard", macOnly: true },
  { page: "general", title: "Start and stop sounds", anchor: "interactionSounds", keywords: "audio feedback chime sound" },
  { page: "general", title: "Keep the pill on top", anchor: "alwaysOnTop", keywords: "always on top float window" },
  { page: "general", title: "Appearance", anchor: "appearanceChoices", keywords: "theme dark light mode system" },
  { page: "general", title: "Save recordings to improve models", anchor: "trainingCapture", keywords: "training capture audio keep voice post-training" },
  { page: "general", title: "Keep recordings", anchor: "trainingRetentionDays", keywords: "training retention days delete" },
  { page: "history", title: "Delete notes", anchor: "noteRetentionMinutes", keywords: "keep retention older removed history dictations" },
  { page: "transcription", title: "Transcribe on", anchor: "locationSeg", keywords: "location local remote host network device this computer server" },
  { page: "transcription", title: "Speech model", anchor: "modelSelect", keywords: "model recognition download" },
  { page: "transcription", title: "Language", anchor: "langSelect", keywords: "spoken locale english" },
  { page: "transcription", title: "AI polish", anchor: "polishEnabled", keywords: "cleanup filler words grammar rewrite tidy" },
  { page: "transcription", title: "AI polish runs on", anchor: "polishProviderSelect", keywords: "cleanup local cloud polish model" },
  { page: "transcription", title: "Context awareness", anchor: "contextAwareness", keywords: "screen app context accessibility polish", macOnly: true },
  { page: "transcription", title: "Super mode", anchor: "superModeSelect", keywords: "accuracy second model ensemble" },
  { page: "transcription", title: "GPU acceleration", anchor: "useGpu", keywords: "graphics card speed" },
  { page: "app-styles", title: "Messaging", anchor: "polishToneMessaging", keywords: "style tone chat apps casual formal" },
  { page: "app-styles", title: "Email", anchor: "polishToneEmail", keywords: "style tone mail apps casual formal" },
  { page: "app-styles", title: "Documents", anchor: "polishToneDocs", keywords: "style tone docs apps casual formal" },
  { page: "app-styles", title: "Code editors", anchor: "polishToneCode", keywords: "style tone code apps verbatim" },
  { page: "app-styles", title: "Everything else", anchor: "polishToneOther", keywords: "style tone default other apps" },
  { page: "app-styles", title: "Detect format for unknown apps", anchor: "formatAiDetection", keywords: "style format classify automatic" },
  { page: "app-styles", title: "Add an app or site", anchor: "formatMappingKey", keywords: "style format website rule" },
  { page: "dictionary", title: "Your words", anchor: "vocabInput", keywords: "add a term word name vocabulary spelling" },
  { page: "dictionary", title: "Corrections", anchor: "addCorrection", keywords: "misheard replace heard" },
  { page: "dictionary", title: "Snippets", anchor: "addSnippet", keywords: "text expansion phrase" },
  { page: "dictionary", title: "Packs", anchor: "packRows", keywords: "vocabulary pack terms" },
  { page: "dictionary", title: "Learn from your corrections", anchor: "learnFromEdits", keywords: "edits automatic learned" },
  { page: "dictionary", title: "Apply dictionary", anchor: "postProcess", keywords: "vocabulary corrections apply" },
  { page: "server", title: "Server address", anchor: "remoteUrl", keywords: "host url address remote network" },
  { page: "server", title: "Server token", anchor: "remoteAuthToken", keywords: "host password auth key" },
  { page: "server", title: "Timeout", anchor: "remoteTimeoutSeconds", keywords: "host seconds wait network" },
  { page: "server", title: "Find hosts on your network", anchor: "tailnetScan", keywords: "host scan search tailnet discover" },
  { page: "server", title: "Machine name", anchor: "tailnetAddress", keywords: "host look up manual address" },
  { page: "updates", title: "Update channel", anchor: "updateChannelSeg", keywords: "nightly stable beta release" },
  { page: "updates", title: "Version", anchor: "appVersion", keywords: "about build number" },
];

// ── State ─────────────────────────────────────────────────────────────────

let overlay: HTMLDivElement | null = null;
let card: HTMLDivElement;
let input: HTMLInputElement;
let list: HTMLDivElement;
let isOpen = false;
let selected = 0;
let flat: Entry[] = [];
let history: HistoryItem[] = [];
let recordingShortcut = "";
let restoreFocus: HTMLElement | null = null;

function navigate(route: string): void {
  document.dispatchEvent(new CustomEvent("bark-navigate", { detail: { route } }));
}

function report(error: unknown): void {
  console.warn("palette:", error);
}

function copyItem(id: string): void {
  // The backend puts it on the clipboard and says "Copied" in the pill.
  void invoke("copy_transcript_history_item", { id }).catch(report);
}

const FORMAT_NAMES: Record<string, string> = { email: "Email", chat: "Chat", document: "Document", notes: "Notes", code: "Code" };

function dictationEntry(item: HistoryItem, now: number): Entry {
  const app = item.appName?.trim() || null;
  const meta: string[] = [];
  if (app) meta.push(app);
  // The style, unless it only repeats the app ("Notes · Notes").
  const style = FORMAT_NAMES[item.format?.format ?? ""];
  if (style && style !== app) meta.push(style);
  const age = ageLabel(item.createdAt, now);
  meta.push(age === "now" ? "just now" : `${age} ago`);
  return {
    id: `dictation-${item.id}`,
    group: "dictations",
    title: dictationTitle(item.text),
    subtitle: meta.join(" · "),
    leading: { app },
    keywords: [],
    copyId: item.id,
    run: () => navigate(`dictation/${item.id}`),
  };
}

function actions(): Entry[] {
  const out: Entry[] = [{
    id: "new-dictation", group: "actions", title: "New dictation", leading: { icon: ICONS.mic },
    shortcut: recordingShortcut ? shortcutHint(recordingShortcut) : undefined,
    keywords: ["dictate", "record", "start", "home"],
    run: () => {
      navigate("home");
      // Once the palette has gone, so focus is back in the window. The pill
      // owns dictation; it starts one unless one is already under way.
      setTimeout(() => void emit("pill-start-recording").catch(report), 150);
    },
  }];
  const last = history[0];
  if (last) {
    out.push({
      id: "copy-last", group: "actions", title: "Copy last dictation", leading: { icon: ICONS.copy },
      keywords: ["clipboard", last.appName ?? ""], copyId: last.id, run: () => copyItem(last.id),
    });
  }
  out.push(
    { id: "models", group: "actions", title: "Browse speech models", leading: { icon: ICONS.layers },
      keywords: ["models", "download", "library"], run: () => navigate("models") },
    { id: "speedtest", group: "actions", title: "Speed test", leading: { icon: ICONS.gauge },
      keywords: ["typing", "wpm", "words per minute", "fast"], run: () => navigate("speedtest") },
    { id: "voicetest", group: "actions", title: "Accuracy test", leading: { icon: ICONS.target },
      keywords: ["microphone", "read aloud", "voice", "errors"], run: () => navigate("voicetest") },
    { id: "training", group: "actions", title: "Post-training", leading: { icon: ICONS.training },
      keywords: ["training", "recordings", "voice", "improve", "model"], run: () => navigate("training") },
    { id: "check-updates", group: "actions", title: "Check for updates", leading: { icon: ICONS.sync },
      keywords: ["update", "new version", "upgrade", "install"],
      run: () => {
        navigate("settings/updates");
        void invoke("check_for_updates").catch(report);
      } },
    { id: "setup-guide", group: "actions", title: "Open setup guide", leading: { icon: ICONS.guide },
      keywords: ["onboarding", "welcome", "tutorial", "permissions"],
      run: () => void invoke("open_onboarding_window").catch(report) },
  );
  return out;
}

function settings(): Entry[] {
  const pages: Entry[] = PAGES.map((p) => ({
    id: `settings-${p.page}`, group: "settings", title: p.title, leading: { icon: p.icon },
    keywords: ["settings", "preferences", ...p.keywords], run: () => navigate(`settings/${p.page}`),
  }));
  const rows: Entry[] = SETTINGS.filter((s) => onMac || !s.macOnly).map((s) => {
    const page = PAGES.find((p) => p.page === s.page)!;
    return {
      id: `setting-${s.anchor}`, group: "settings", title: s.title, aside: page.title, leading: { icon: page.icon },
      keywords: s.keywords.split(" "), run: () => navigate(`settings/${s.page}#${s.anchor}`),
    };
  });
  // Pages first, so a page beats its own settings on a tie, and an empty
  // query shows pages only.
  return [...pages, ...rows];
}

function sections(query: string): Array<{ group: Group; entries: Entry[] }> {
  const q = query.trim();
  const empty = q === "";
  const out: Array<{ group: Group; entries: Entry[] }> = [];
  const now = Date.now();
  const dictations = rank(history, q, (item): Fields => ({ title: item.text, other: [item.appName ?? ""] }), { limit: empty ? 4 : 6 })
    .map((item) => dictationEntry(item, now));
  if (dictations.length) out.push({ group: "dictations", entries: dictations });
  for (const [group, all] of [["actions", actions()], ["settings", settings()]] as const) {
    const ranked = rank(all, q, (e): Fields => ({ title: e.title, other: [...e.keywords, e.subtitle ?? ""] }),
      { limit: empty && group !== "actions" ? 3 : undefined, allowScattered: true });
    if (ranked.length) out.push({ group, entries: ranked });
  }
  return out;
}

// ── DOM ───────────────────────────────────────────────────────────────────

function el<K extends keyof HTMLElementTagNameMap>(tag: K, className?: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function keycap(label: string): HTMLElement {
  return el("kbd", "palette-key", label);
}

function monogram(app: string | null): HTMLElement {
  if (!app) {
    const icon = el("span", "palette-icon");
    icon.innerHTML = ICONS.dictation;
    return icon;
  }
  const tile = el("span", "palette-monogram", monogramLetters(app));
  tile.style.setProperty("--palette-mono", `var(--bark-mono-${monogramHue(app)})`);
  return tile;
}

/** The title with the words searched for underlined (dictations only). */
function titleNode(entry: Entry, query: string): HTMLElement {
  const title = el("span", "palette-title");
  if (entry.group !== "dictations" || !query.trim()) {
    title.textContent = entry.title;
    return title;
  }
  let at = 0;
  for (const [start, end] of matchRanges(query, entry.title)) {
    if (start > at) title.append(entry.title.slice(at, start));
    title.append(el("u", undefined, entry.title.slice(start, end)));
    at = end;
  }
  if (at < entry.title.length) title.append(entry.title.slice(at));
  return title;
}

function row(entry: Entry, index: number, query: string): HTMLElement {
  const node = el("div", "palette-row");
  node.id = `palette-option-${index}`;
  node.setAttribute("role", "option");
  node.dataset.index = String(index);
  if (entry.subtitle) node.classList.add("palette-row--two-line");

  const leading = el("span", "palette-leading");
  if ("icon" in entry.leading) {
    const icon = el("span", "palette-icon");
    icon.innerHTML = entry.leading.icon;
    leading.append(icon);
  } else {
    leading.append(monogram(entry.leading.app));
  }

  const text = el("span", "palette-text");
  text.append(titleNode(entry, query));
  if (entry.subtitle) text.append(el("span", "palette-subtitle", entry.subtitle));

  node.append(leading, text);
  if (entry.aside) node.append(el("span", "palette-aside", entry.aside));
  const trailing = el("span", "palette-trailing");
  if (entry.group === "dictations") trailing.append(Object.assign(keycap(KEYS.enter), { className: "palette-key palette-enter-key" }));
  else if (entry.shortcut) trailing.append(keycap(entry.shortcut));
  if (trailing.childNodes.length) node.append(trailing);

  node.addEventListener("mousemove", () => { if (selected !== index) select(index, false); });
  node.addEventListener("mousedown", (event) => event.preventDefault());
  node.addEventListener("click", () => run(entry));
  return node;
}

function render(): void {
  const query = input.value;
  const groups = sections(query);
  flat = groups.flatMap((g) => g.entries);
  if (selected >= flat.length) selected = 0;
  const fragment = document.createDocumentFragment();
  if (flat.length === 0) {
    const empty = el("p", "palette-empty", `Nothing matches “${query.trim()}”`);
    empty.setAttribute("role", "status");
    fragment.append(empty);
  }
  let index = 0;
  for (const { group, entries } of groups) {
    const section = el("div", "palette-section");
    section.setAttribute("role", "group");
    const heading = el("div", "palette-heading", GROUP_TITLES[group]);
    heading.id = `palette-heading-${group}`;
    heading.setAttribute("role", "presentation");
    section.setAttribute("aria-labelledby", heading.id);
    section.append(heading);
    for (const entry of entries) section.append(row(entry, index++, query));
    fragment.append(section);
  }
  list.replaceChildren(fragment);
  select(selected, false);
}

function select(index: number, scroll: boolean): void {
  selected = index;
  for (const node of list.querySelectorAll<HTMLElement>(".palette-row")) {
    const on = Number(node.dataset.index) === index;
    node.classList.toggle("is-selected", on);
    node.setAttribute("aria-selected", String(on));
    if (on && scroll) node.scrollIntoView({ block: "nearest" });
  }
  if (flat[index]) input.setAttribute("aria-activedescendant", `palette-option-${index}`);
  else input.removeAttribute("aria-activedescendant");
}

function move(step: number): void {
  if (!flat.length) return;
  select((selected + step + flat.length) % flat.length, true);
}

function run(entry: Entry): void {
  closePalette();
  entry.run();
}

function build(): void {
  overlay = el("div", "palette-overlay");
  overlay.hidden = true;
  overlay.addEventListener("mousedown", (event) => {
    if (event.target === overlay) {
      event.preventDefault();
      closePalette();
    }
  });

  card = el("div", "palette-card");
  card.setAttribute("role", "dialog");
  card.setAttribute("aria-modal", "true");
  card.setAttribute("aria-label", "Search and commands");

  const field = el("div", "palette-field");
  const glass = el("span", "palette-search-icon");
  glass.innerHTML = ICONS.search;
  input = el("input", "palette-input");
  input.type = "text";
  input.placeholder = "Search dictations, actions and settings";
  input.autocomplete = "off";
  input.spellcheck = false;
  input.setAttribute("role", "combobox");
  input.setAttribute("aria-expanded", "true");
  input.setAttribute("aria-autocomplete", "list");
  input.setAttribute("aria-controls", "palette-list");
  input.setAttribute("aria-label", "Search dictations, actions and settings");
  input.addEventListener("input", () => {
    selected = 0;
    render();
    list.scrollTop = 0;
  });
  input.addEventListener("keydown", onKey);
  field.append(glass, input, keycap(KEYS.esc));

  list = el("div", "palette-list");
  list.id = "palette-list";
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-label", "Results");

  const footer = el("div", "palette-footer");
  footer.setAttribute("aria-hidden", "true");
  for (const [key, label] of [["↑↓", "move"], [KEYS.enter, "open"], [KEYS.copy, "copy text"]]) {
    const hint = el("span", "palette-hint");
    hint.append(keycap(key), label);
    footer.append(hint);
  }

  card.append(field, el("div", "palette-rule"), list, el("div", "palette-rule"), footer);
  overlay.append(card);
  document.body.append(overlay);
}

function onKey(event: KeyboardEvent): void {
  const mod = onMac ? event.metaKey : event.ctrlKey;
  switch (event.key) {
    case "ArrowDown":
      event.preventDefault();
      move(1);
      return;
    case "ArrowUp":
      event.preventDefault();
      move(-1);
      return;
    case "Enter":
      event.preventDefault();
      if (!event.isComposing && flat[selected]) run(flat[selected]);
      return;
    case "Escape":
      event.preventDefault();
      event.stopPropagation();
      closePalette();
      return;
    case "Tab":
      // The field is the palette's only stop: focus stays in it.
      event.preventDefault();
      return;
  }
  // Ctrl+C copies the selected dictation, unless text in the field is selected.
  if (mod && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "c" && input.selectionStart === input.selectionEnd) {
    const copyId = flat[selected]?.copyId;
    if (!copyId) return;
    event.preventDefault();
    closePalette();
    copyItem(copyId);
  }
}

async function refresh(): Promise<void> {
  const [items, saved] = await Promise.all([
    invoke<HistoryItem[]>("get_transcript_history").catch((error) => { report(error); return history; }),
    invoke<{ recordingShortcut?: string } | null>("get_settings").catch(() => null),
  ]);
  history = Array.isArray(items) ? [...items].sort((a, b) => b.createdAt - a.createdAt) : [];
  if (saved?.recordingShortcut !== undefined) recordingShortcut = saved.recordingShortcut;
  if (isOpen) render();
}

function isPaletteShortcut(event: KeyboardEvent): boolean {
  if (!(onMac ? event.metaKey : event.ctrlKey) || event.altKey || event.shiftKey) return false;
  const key = event.key.toLowerCase();
  // By the letter printed on the key; by position only on layouts without Latin letters.
  return key === "k" || (!/^[a-z]$/.test(key) && event.code === "KeyK");
}

/** Open the palette (the sidebar's search button calls this). */
export function openPalette(query = ""): void {
  if (!overlay) build();
  if (isOpen) {
    input.focus();
    return;
  }
  isOpen = true;
  const active = document.activeElement;
  restoreFocus = active instanceof HTMLElement && active !== document.body ? active : null;
  input.value = query;
  selected = 0;
  overlay!.hidden = false;
  render();
  list.scrollTop = 0;
  input.focus();
  input.select();
  void refresh();
}

export function closePalette(): void {
  if (!overlay || !isOpen) return;
  isOpen = false;
  overlay.hidden = true;
  const target = restoreFocus;
  restoreFocus = null;
  if (target?.isConnected) target.focus({ preventScroll: true });
}

export function isPaletteOpen(): boolean {
  return isOpen;
}

let initialised = false;

/** Install the palette: Ctrl+K (⌘K on a Mac) opens and closes it. */
export function initPalette(): void {
  if (initialised) return;
  initialised = true;
  window.addEventListener("keydown", (event) => {
    if (!isPaletteShortcut(event) || event.repeat) return;
    event.preventDefault();
    event.stopPropagation();
    if (isOpen) closePalette();
    else openPalette();
  }, true);
  // Focus stays inside while it is open.
  document.addEventListener("focusin", (event) => {
    if (isOpen && !card.contains(event.target as Node)) input.focus();
  });
  void refresh();
}

/** How the palette's shortcut reads on this platform ("Ctrl+K", "⌘K"), for the sidebar's keycap. */
export const PALETTE_SHORTCUT = KEYS.open;
