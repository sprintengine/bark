import { invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { listen } from "@tauri-apps/api/event";
import "./modelDashboard.css";
import { createPublisherIcon } from "./publisherIcons";
import { POLISH_RATINGS, filterAndSort, formatBytes, measuredSpeed, speechInfo, type LibraryFilter, type LibraryRow, type ModelKind, type SortKey } from "./modelCatalog";

// The Models screen: one library table of every speech and polish model, with
// favourites, filters, sort and Hugging Face search. A row opens to show its
// details: the full description, its download link and its page.

type Settings = { model: string; transcriptionLocation: string; polishEnabled: boolean; polishProvider: "local" | "cloud"; polishModel: string; cloudAuthToken: string; modelLinks?: Record<string, string>; [key: string]: unknown };
type Model = { id: string; name: string; publisher: string; description: string; bytes: number; installed: boolean; selected: boolean; loaded: boolean; source: string; downloads: number | null; supported: boolean };
type Download = { model: string; stage: string; downloaded: number; total: number; message: string };
type Catalog = { polish: Model[]; download: Download | null; metadataError: string | null };
type SpeechModel = { model: string; cached: boolean };
type HistoryEntry = { durationSeconds: number; timings?: { speechModelMs: number } | null };
const root = document.querySelector<HTMLElement>("#screen-models")!;
const feedback = root.querySelector<HTMLElement>("#modelFeedback")!;
const rowsHost = root.querySelector<HTMLElement>("#modelRows")!;
let settings: Settings;
let catalog: Catalog;
let speech: SpeechModel[] = [];
let cloudAvailable = false;
let download: Download | null = null;
let speechDownload: string | null = null;
let measured: number | null = null;
let loading = false;
let reloadRequested = false;
// A Refresh pressed during an in-flight load still owes a Hugging Face refresh.
let refreshRequested = false;
const speechProgress = new Map<string, { percentage: number; message: string; done: boolean }>();
const progressCells = new Map<string, { status: HTMLElement; bar: HTMLElement }>();
const expanded = new Set<string>();
const filter: LibraryFilter = { query: "", kind: "all", language: "all", downloadedOnly: false, localOnly: false };
let sort: SortKey = "recommended";

// Favourites are a view preference of this window, not a setting.
const FAVORITES_KEY = "fairspoken.favoriteModels";
function loadFavorites(): Set<string> {
  try { return new Set(JSON.parse(localStorage.getItem(FAVORITES_KEY) ?? "[]") as string[]); } catch { return new Set(); }
}
const favorites = loadFavorites();
function toggleFavorite(id: string): void {
  if (favorites.has(id)) favorites.delete(id); else favorites.add(id);
  try { localStorage.setItem(FAVORITES_KEY, JSON.stringify([...favorites])); } catch { /* this session only */ }
  render();
}

function say(message: string, error = false): void { feedback.textContent = message; feedback.dataset.error = String(error); }
function button(label: string, action: () => Promise<unknown>, disabled = false, primary = false): HTMLButtonElement {
  const node = document.createElement("button"); node.type = "button"; node.className = primary ? "ds-button ds-button--outline model-action is-primary" : "ds-button ds-button--outline model-action";
  node.textContent = label; node.disabled = disabled;
  node.addEventListener("click", (event) => { event.stopPropagation(); node.disabled = true; void action().catch(e => say(String(e), true)).finally(() => { if (node.isConnected) node.disabled = disabled; }); });
  return node;
}
async function choose(patch: Partial<Settings>): Promise<void> {
  // Read at action time: don't overwrite newer settings from another screen.
  const latest = await invoke<Settings>("get_settings");
  await invoke("save_settings", { settings: { ...latest, ...patch } });
  await load();
}
function el<K extends keyof HTMLElementTagNameMap>(tag: K, className = "", text = ""): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag); if (className) node.className = className; if (text) node.textContent = text; return node;
}
const SVG = {
  star: '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m12 3.6 2.6 5.3 5.8.8-4.2 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8-4.2-4.1 5.8-.8Z" stroke="currentColor" stroke-width="1.7" stroke-linejoin="round"/></svg>',
  speech: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><path d="M5 10.5v3M8.5 7.5v9M12 4.5v15M15.5 8v8M19 10.5v3"/></svg>',
  polish: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M12 3.5 13.8 9a2 2 0 0 0 1.2 1.2l5.5 1.8-5.5 1.8a2 2 0 0 0-1.2 1.2L12 20.5 10.2 15A2 2 0 0 0 9 13.8L3.5 12 9 10.2A2 2 0 0 0 10.2 9Z"/></svg>',
  chevron: '<svg viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 2l3 3-3 3" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/></svg>',
};

type Row = LibraryRow & {
  summary: string;
  detail: string;
  publisher: string;
  languages: string;
  recommended: boolean;
  isNew: boolean;
  source?: string;
  polish?: Model;
};

function speechRows(): Row[] {
  return speech.map((m) => {
    const info = speechInfo(m.model);
    return {
      id: m.model, kind: "speech" as ModelKind, name: info.name, summary: info.summary, detail: "",
      publisher: info.publisher, languages: info.languages, language: info.language, bytes: info.bytes, speed: info.speed, accuracy: info.accuracy, rank: info.rank,
      installed: m.cached, inUse: settings.transcriptionLocation === "local" && settings.model === m.model, favorite: favorites.has(m.model),
      location: "local" as const, recommended: !!info.recommended, isNew: !!info.isNew,
      searchText: [info.name, info.publisher, m.model, info.languages, "speech dictation"].join(" "),
    };
  });
}

function polishRows(): Row[] {
  return catalog.polish.map((m, index) => {
    const rating = POLISH_RATINGS[m.id] ?? { speed: 3, accuracy: 3, language: "multi" as const, languages: "Many languages", rank: 20 + index };
    const [summary] = m.description.split(" · ");
    return {
      id: m.id, kind: "polish" as ModelKind, name: m.name, summary, detail: m.description, publisher: m.publisher, languages: rating.languages,
      language: rating.language, bytes: m.bytes, speed: rating.speed, accuracy: rating.accuracy, rank: rating.rank,
      installed: m.installed, inUse: settings.polishEnabled && settings.polishProvider === "local" && m.selected && m.installed, favorite: favorites.has(m.id),
      location: "local" as const, recommended: !!rating.recommended, isNew: !!rating.isNew, source: m.source, polish: m,
      searchText: [m.name, m.publisher, m.id, m.description, "polish cleanup"].join(" "),
    };
  });
}

// Dictation or polish that runs elsewhere shows as a row too, so the table
// always says what is in use.
function remoteRows(): Row[] {
  const rows: Row[] = [];
  const remote = (id: string, kind: ModelKind, name: string, summary: string, location: "host" | "cloud"): Row => ({
    id, kind, name, summary, detail: summary, publisher: location === "cloud" ? "Fairspoken" : "Host", languages: "", language: "multi",
    bytes: 0, speed: 0, accuracy: 0, rank: -1, installed: true, inUse: true, favorite: favorites.has(id), location, recommended: false, isNew: false,
    searchText: `${name} ${summary}`,
  });
  if (settings.transcriptionLocation === "remote-host") rows.push(remote("remote-host", "speech", "Your host", "Dictation runs on your transcription host", "host"));
  if (settings.transcriptionLocation === "cloud") rows.push(remote("cloud-speech", "speech", "Fairspoken Cloud", "Hosted dictation", "cloud"));
  if (settings.polishEnabled && settings.polishProvider === "cloud") rows.push(remote("cloud-polish", "polish", "Fairspoken Cloud polish", "Hosted cleanup", "cloud"));
  return rows;
}

function steps(label: string, value: number, title = ""): HTMLElement {
  const node = el("span", "model-steps");
  node.setAttribute("role", "img");
  node.setAttribute("aria-label", value ? `${label}: ${value} of 5` : `${label}: not rated`);
  if (title) node.title = title;
  for (let i = 1; i <= 5; i += 1) node.append(el("i", i <= value ? "on" : ""));
  return node;
}

function badge(text: string, tone = ""): HTMLElement { return el("span", `model-badge${tone ? ` model-badge--${tone}` : ""}`, text); }

function cell(...children: (Node | string)[]): HTMLElement {
  const node = el("span", "model-cell"); node.setAttribute("role", "cell"); node.append(...children); return node;
}

function progressCell(id: string, percentage: number, message: string, cancel?: () => Promise<unknown>): HTMLElement {
  const wrap = el("span", "model-progress");
  const bar = el("span", "model-progress-bar"); const fill = el("span"); bar.append(fill);
  fill.style.width = `${Math.max(2, Math.min(100, percentage))}%`;
  const status = el("span", "model-progress-text", `${Math.round(percentage)}%`);
  status.title = message;
  wrap.append(bar, status);
  progressCells.set(id, { status, bar: fill });
  if (cancel) {
    const stop = el("button", "icon-btn model-progress-cancel"); stop.type = "button"; stop.setAttribute("aria-label", "Cancel download"); stop.title = "Cancel download";
    stop.innerHTML = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="m7 7 10 10M17 7 7 17"/></svg>';
    stop.addEventListener("click", (event) => { event.stopPropagation(); void cancel().catch(e => say(String(e), true)); });
    wrap.append(stop);
  }
  return wrap;
}

function action(row: Row): HTMLElement {
  if (row.location !== "local") return el("span", "model-inuse", "In use");
  if (row.kind === "speech") {
    const progress = speechProgress.get(row.id);
    if (speechDownload === row.id || (progress && !progress.done)) return progressCell(row.id, progress?.percentage ?? 0, progress?.message ?? "Starting download…");
    if (row.installed && row.inUse) return el("span", "model-inuse", "In use");
    if (row.installed) return button("Use", () => choose({ model: row.id, transcriptionLocation: "local" }));
    return button("Download", () => startSpeechDownload(row.id), speechDownload !== null);
  }
  const m = row.polish!;
  if (busyDownload() && download?.model === m.id) {
    const total = download.total || m.bytes;
    return progressCell(m.id, total ? (download.downloaded / total) * 100 : 0, download.message, async () => { await invoke("cancel_local_model_download"); say("Cancelling download…"); });
  }
  if (!m.supported) return el("span", "model-muted", "Unavailable");
  if (row.inUse) return el("span", "model-inuse", "In use");
  if (m.installed) return button("Use", () => choose({ polishProvider: "local", polishModel: m.id, polishEnabled: true }));
  return button("Download", () => startPolishDownload(m), busyDownload());
}

function details(row: Row): HTMLElement {
  const panel = el("div", "model-detail"); panel.setAttribute("role", "row"); panel.id = `model-detail-${row.id}`;
  const body = el("div", "model-detail-body"); body.setAttribute("role", "cell");
  if (row.detail && row.detail !== row.summary) body.append(el("p", "model-detail-text", row.detail));
  const facts = el("dl", "model-facts");
  const fact = (k: string, v: string) => { const d = el("div"); d.append(el("dt", "", k), el("dd", "", v)); facts.append(d); };
  fact("Publisher", row.publisher);
  if (row.languages) fact("Languages", row.languages);
  if (row.bytes) fact(row.kind === "speech" ? "Download, about" : "Download", formatBytes(row.bytes));
  if (row.kind === "speech" && row.inUse && measured) fact("Measured here", `${measured.toFixed(0)}× real time`);
  if (row.polish?.downloads != null) fact("Hugging Face downloads", row.polish.downloads.toLocaleString());
  body.append(facts);
  if (row.location === "local") {
    const supported = row.polish ? row.polish.supported : true;
    const start = row.kind === "speech" ? () => startSpeechDownload(row.id) : () => startPolishDownload(row.polish!);
    if (row.installed || (row.kind === "speech" ? speechDownload !== null : busyDownload())) linkDrafts.delete(row.id);
    if (supported) body.append(...linkSection(row.id, row.name, start));
    const buttons = el("div", "models-actions");
    if (!row.installed && supported && !linkDrafts.has(row.id) && (row.kind === "speech" ? speechDownload === null : !busyDownload())) buttons.append(linkButton(row.id));
    if (row.source?.startsWith("https://huggingface.co/")) buttons.append(button("Model page ↗", () => openUrl(row.source!)));
    if (row.polish?.installed) buttons.append(button("Remove", async () => { await invoke("remove_local_model", { model: row.id }); await load(); }, busyDownload()));
    if (buttons.childElementCount) body.append(buttons);
  }
  panel.append(body);
  return panel;
}

function rowElement(row: Row): HTMLElement[] {
  const node = el("div", `model-row${row.inUse ? " is-in-use" : ""}${expanded.has(row.id) ? " is-open" : ""}`);
  node.setAttribute("role", "row"); node.id = `model-${row.id}`; node.dataset.kind = row.kind;

  const star = el("button", `model-star${row.favorite ? " is-on" : ""}`); star.type = "button"; star.id = `model-star-${row.id}`;
  star.setAttribute("aria-pressed", String(row.favorite)); star.setAttribute("aria-label", `Favourite ${row.name}`); star.title = row.favorite ? "Remove from favourites" : "Add to favourites";
  star.innerHTML = SVG.star;
  star.addEventListener("click", (event) => { event.stopPropagation(); toggleFavorite(row.id); document.getElementById(`model-${row.id}`)?.querySelector<HTMLElement>(".model-star")?.focus(); });

  const open = el("button", "model-name-btn"); open.type = "button"; open.id = `model-open-${row.id}`;
  open.setAttribute("aria-expanded", String(expanded.has(row.id))); open.setAttribute("aria-controls", `model-detail-${row.id}`);
  const chevron = el("span", "model-chevron"); chevron.innerHTML = SVG.chevron;
  const titleLine = el("span", "model-name");
  titleLine.append(el("span", "model-name-text", row.name));
  if (row.recommended) titleLine.append(badge("Recommended", "good"));
  if (row.language === "en") titleLine.append(badge("EN"));
  if (row.isNew) titleLine.append(badge("New", "new"));
  const text = el("span", "model-name-stack"); text.append(titleLine, el("span", "model-name-summary", row.summary));
  open.append(chevron, createPublisherIcon(row.publisher, { size: "sm" }), text);
  open.addEventListener("click", (event) => { event.stopPropagation(); toggle(row.id); });

  const kind = el("span", `model-kind model-kind--${row.kind}`); kind.innerHTML = row.kind === "speech" ? SVG.speech : SVG.polish;
  kind.title = row.kind === "speech" ? "Speech to text" : "Cleanup and polish";
  kind.setAttribute("aria-label", kind.title); kind.setAttribute("role", "img");

  const measuredTitle = row.kind === "speech" && row.inUse && measured ? `Measured on this computer: ${measured.toFixed(0)}× real time` : "";
  const where = row.location === "local" ? "This device" : row.location === "host" ? "Your host" : "Cloud";
  node.append(
    cell(star),
    cell(open),
    cell(kind),
    cell(row.speed ? steps("Speed", row.speed, measuredTitle) : el("span", "model-muted", "—")),
    cell(row.accuracy ? steps("Accuracy", row.accuracy) : el("span", "model-muted", "—")),
    Object.assign(cell(row.bytes ? formatBytes(row.bytes) : "—"), { className: "model-cell col-size num" }),
    Object.assign(cell(where), { className: `model-cell model-where model-where--${row.location}` }),
    Object.assign(cell(action(row)), { className: "model-cell model-action-cell" }),
  );
  node.addEventListener("click", () => toggle(row.id));
  return expanded.has(row.id) ? [node, details(row)] : [node];
}

function toggle(id: string): void {
  if (expanded.has(id)) expanded.delete(id); else expanded.add(id);
  render();
  document.getElementById(`model-${id}`)?.querySelector<HTMLElement>(".model-name-btn")?.focus({ preventScroll: true });
}

function renderSummary(): void {
  const speechName = settings.transcriptionLocation === "remote-host" ? "your host" : settings.transcriptionLocation === "cloud" ? "Fairspoken Cloud" : speechInfo(settings.model).name;
  const dictation = root.querySelector("#dictationProvider")!;
  dictation.replaceChildren(el("span", "model-summary-k", "Dictation"), el("strong", "", speechName));
  const polishName = !settings.polishEnabled ? "Off" : settings.polishProvider === "cloud" ? "Fairspoken Cloud" : catalog.polish.find(m => m.id === settings.polishModel)?.name ?? settings.polishModel;
  root.querySelector("#polishProvider")!.replaceChildren(el("span", "model-summary-k", "Polish"), el("strong", "", polishName));
  const providerActions = root.querySelector("#polishProviderActions")!;
  providerActions.replaceChildren();
  if (settings.polishEnabled) providerActions.append(button("Turn polish off", () => choose({ polishEnabled: false })));
  if (cloudAvailable) providerActions.append(button("Use cloud polish", () => choose({ polishProvider: "cloud", polishEnabled: true }), !settings.cloudAuthToken || (settings.polishEnabled && settings.polishProvider === "cloud")));
}

function render(): void {
  if (!settings || !catalog) return;
  const focusedId = root.contains(document.activeElement) ? (document.activeElement as HTMLElement).id : "";
  progressCells.clear();
  renderSummary();
  const rows = filterAndSort([...remoteRows(), ...speechRows(), ...polishRows()], filter, sort);
  rowsHost.replaceChildren(...rows.flatMap(rowElement));
  if (!rows.length) {
    const empty = el("div", "model-empty"); empty.setAttribute("role", "row");
    const text = el("span", "", "No models match. "); text.setAttribute("role", "cell");
    const reset = el("button", "link-btn", "Clear filters"); reset.type = "button";
    reset.addEventListener("click", resetFilters);
    text.append(reset); empty.append(text); rowsHost.append(empty);
  }
  if (focusedId) document.getElementById(focusedId)?.focus({ preventScroll: true });
}

function resetFilters(): void {
  Object.assign(filter, { query: "", kind: "all", language: "all", downloadedOnly: false, localOnly: false });
  searchInput.value = ""; scheduleSearch(); syncFilterControls(); render();
}

const kindFilter = root.querySelector<HTMLElement>("#modelKindFilter")!;
const languageFilter = root.querySelector<HTMLSelectElement>("#modelLanguageFilter")!;
const downloadedFilter = root.querySelector<HTMLButtonElement>("#modelDownloadedFilter")!;
const localFilter = root.querySelector<HTMLButtonElement>("#modelLocalFilter")!;
const sortHead = root.querySelector<HTMLElement>("#modelSort")!;
function syncFilterControls(): void {
  for (const option of kindFilter.querySelectorAll<HTMLButtonElement>("button")) option.setAttribute("aria-pressed", String(option.dataset.value === filter.kind));
  languageFilter.value = filter.language;
  downloadedFilter.setAttribute("aria-pressed", String(filter.downloadedOnly));
  localFilter.setAttribute("aria-pressed", String(filter.localOnly));
  // Column headers sort; the active one says which way. Choosing it again
  // returns to the recommended order.
  for (const header of sortHead.querySelectorAll<HTMLButtonElement>(".model-sort-btn")) {
    const active = header.dataset.sort === sort;
    header.classList.toggle("is-active", active);
    header.closest("[role='columnheader']")?.setAttribute("aria-sort", active ? (sort === "name" || sort === "size" ? "ascending" : "descending") : "none");
    header.title = active ? "Back to recommended order" : `Sort by ${header.textContent?.toLowerCase()}`;
  }
}
kindFilter.addEventListener("click", (event) => {
  const value = (event.target as HTMLElement).closest<HTMLButtonElement>("button")?.dataset.value;
  if (value === "all" || value === "speech" || value === "polish") { filter.kind = value; syncFilterControls(); render(); }
});
languageFilter.addEventListener("change", () => { filter.language = languageFilter.value as LibraryFilter["language"]; render(); });
downloadedFilter.addEventListener("click", () => { filter.downloadedOnly = !filter.downloadedOnly; syncFilterControls(); render(); });
localFilter.addEventListener("click", () => { filter.localOnly = !filter.localOnly; syncFilterControls(); render(); });
sortHead.addEventListener("click", (event) => {
  const key = (event.target as HTMLElement).closest<HTMLButtonElement>(".model-sort-btn")?.dataset.sort as SortKey | undefined;
  if (!key) return;
  sort = sort === key ? "recommended" : key;
  syncFilterControls(); render();
});
syncFilterControls();

async function startSpeechDownload(model: string): Promise<void> {
  speechDownload = model; speechProgress.set(model, { percentage: 0, message: "Starting download…", done: false }); render();
  try { await invoke("begin_prepare_transcription_model", { request: { model } }); }
  catch (e) { speechDownload = null; speechProgress.delete(model); render(); throw e; }
}
async function startPolishDownload(m: Model): Promise<void> {
  download = { model: m.id, stage: "runtime", downloaded: 0, total: 0, message: "Starting download…" }; render();
  try { await invoke("download_local_model", { model: m.id }); say(`${m.name} downloaded. Choose Use to enable it.`); }
  finally { await load(); }
}
function busyDownload(): boolean { return !!download && ["runtime", "model"].includes(download.stage); }
function progressUpdate(value: Download): void {
  download = value;
  const current = progressCells.get(value.model);
  if (current && value.total) {
    const pct = (value.downloaded / value.total) * 100;
    current.bar.style.width = `${Math.max(2, pct)}%`;
    current.status.textContent = `${Math.round(pct)}%`;
    current.status.title = `${value.message} · ${formatBytes(value.downloaded)} / ${formatBytes(value.total)}`;
  }
}
async function load(refresh = false): Promise<void> {
  if (loading) { reloadRequested = true; refreshRequested = refreshRequested || refresh; return; }
  loading = true;
  try {
    const values = await Promise.all([
      invoke<Settings>("get_settings"),
      invoke<Catalog>("get_local_model_catalog", { refresh }),
      invoke<SpeechModel[]>("get_dictation_models"),
      invoke<boolean>("get_cloud_available").catch(() => false),
      invoke<HistoryEntry[]>("get_transcript_history").catch(() => [] as HistoryEntry[]),
    ]);
    const previous = catalog;
    let history: HistoryEntry[];
    [settings, catalog, speech, cloudAvailable, history] = values;
    measured = measuredSpeed(history ?? []);
    if (!refresh && previous) {
      for (const model of catalog.polish) model.downloads = previous.polish.find(m => m.id === model.id)?.downloads ?? model.downloads;
    }
    download = catalog.download; render();
    if (refresh) say(catalog.metadataError ?? "Model information refreshed from Hugging Face.", !!catalog.metadataError);
  } finally {
    loading = false;
    if (reloadRequested) {
      const refreshNext = refreshRequested;
      reloadRequested = refreshRequested = false;
      void load(refreshNext).catch(e => say(String(e), true));
    }
  }
}
root.querySelector<HTMLButtonElement>("#refreshModels")!.addEventListener("click", event => {
  const button = event.currentTarget as HTMLButtonElement; button.disabled = true;
  void load(true).catch(e => say(String(e), true)).finally(() => { button.disabled = false; });
});
void listen<Download>("local-model-download", event => {
  const wasBusy = busyDownload(); progressUpdate(event.payload);
  if (catalog && wasBusy !== busyDownload()) render();
  if (["error", "cancelled"].includes(event.payload.stage)) say(event.payload.message, event.payload.stage === "error");
}).catch(e => say(String(e), true));
void listen<{ model: string; percentage: number; message: string; done: boolean; error?: string }>("model-prepare-progress", event => {
  const e = event.payload; speechProgress.set(e.model, e); if (!e.done) speechDownload = e.model;
  const current = progressCells.get(e.model);
  if (current && !e.done) { current.bar.style.width = `${Math.max(2, e.percentage)}%`; current.status.textContent = `${Math.round(e.percentage)}%`; current.status.title = e.message; }
  else if (!current && !e.done && settings) render();
  if (e.done) { speechDownload = null; if (e.error) say(e.error, true); void load().catch(e => say(String(e), true)); }
}).catch(e => say(String(e), true));
void listen<Settings>("settings-updated", event => { settings = event.payload; void load().catch(e => say(String(e), true)); }).catch(e => say(String(e), true));
// Refresh memory state only while the Models screen is on screen in a visible
// window; the poll stops when either goes away. Don't rebuild focused controls.
let memoryPoll: ReturnType<typeof setInterval> | undefined;
function syncMemoryPoll(): void {
  const visible = root.classList.contains("active") && document.visibilityState === "visible";
  if (visible && memoryPoll === undefined) {
    memoryPoll = setInterval(() => {
      if (!catalog || root.contains(document.activeElement) || busyDownload()) return;
      void load().catch(() => {});
    }, 5000);
  } else if (!visible && memoryPoll !== undefined) {
    clearInterval(memoryPoll);
    memoryPoll = undefined;
  }
}
document.addEventListener("home-screen-changed", syncMemoryPoll);
document.addEventListener("visibilitychange", syncMemoryPoll);
syncMemoryPoll();
void load().catch(e => say(String(e), true));


// Download links (model_link.rs): a model with one downloads from that link,
// typically a .zip on the organisation's own server, instead of its usual
// download. Open editors and what is typed in them survive re-renders.
const linkDrafts = new Map<string, string>();
const linkErrors = new Map<string, string>();
const savedLink = (model: string): string | undefined => settings.modelLinks?.[model];
// Host and path only: a query string may carry an access token.
function linkLabel(link: string): string {
  try {
    const url = new URL(link);
    if (url.protocol === "http:" || url.protocol === "https:") return `${url.host}${url.pathname}`;
    if (url.protocol === "file:") return `${url.host ? `//${url.host}` : ""}${decodeURIComponent(url.pathname)}`;
  } catch { /* a path */ }
  return link.split(/[?#]/)[0];
}
function openLinkEditor(model: string): void {
  linkDrafts.set(model, savedLink(model) ?? ""); linkErrors.delete(model); render();
  document.getElementById(`model-link-input-${model}`)?.focus();
}
// The saved link (with a way back to the standard download) and, when open,
// the link field. `start` begins the model's download once a link is saved.
function linkSection(model: string, name: string, start: () => Promise<void>): HTMLElement[] {
  const parts: HTMLElement[] = [];
  const saved = savedLink(model);
  if (saved) {
    const line = document.createElement("div"); line.className = "model-link-saved";
    const text = document.createElement("span"); text.textContent = "Downloads from ";
    const where = document.createElement("span"); where.className = "model-link-url"; where.textContent = linkLabel(saved); where.title = linkLabel(saved);
    text.append(where);
    const reset = button("Use the standard download", async () => {
      settings = await invoke<Settings>("set_model_link", { model, link: null });
      linkDrafts.delete(model); linkErrors.delete(model); render();
      say(`${name} will use the standard download.`);
    });
    reset.className = "ds-button ds-button--ghost ds-button--inline"; reset.id = `model-link-reset-${model}`;
    line.append(text, reset); parts.push(line);
  }
  if (!linkDrafts.has(model)) return parts;
  const form = document.createElement("form"); form.className = "model-link-editor"; form.noValidate = true;
  const field = document.createElement("div"); field.className = "model-link-field";
  const input = document.createElement("input");
  input.className = "ds-input ds-input--well model-link-input"; input.id = `model-link-input-${model}`; input.type = "text";
  input.placeholder = "https://… or a path to a .zip"; input.maxLength = 2048; input.autocomplete = "off"; input.spellcheck = false;
  input.setAttribute("autocapitalize", "off"); input.setAttribute("aria-label", `Download link for ${name}`);
  input.value = linkDrafts.get(model) ?? "";
  const submit = document.createElement("button"); submit.type = "submit"; submit.className = "ds-button ds-button--primary"; submit.textContent = "Download"; submit.id = `model-link-submit-${model}`;
  const cancel = document.createElement("button"); cancel.type = "button"; cancel.className = "ds-button ds-button--ghost"; cancel.textContent = "Cancel";
  const help = document.createElement("p"); help.className = "ds-field-help"; help.id = `model-link-help-${model}`;
  help.textContent = "A link to a .zip of this model, for example from your organisation's server.";
  const error = document.createElement("p"); error.className = "ds-field-error"; error.id = `model-link-error-${model}`; error.setAttribute("role", "alert");
  const showError = (message: string) => {
    error.textContent = message; error.hidden = !message; help.hidden = !!message;
    input.setAttribute("aria-invalid", String(!!message));
    input.setAttribute("aria-describedby", message ? error.id : help.id);
  };
  showError(linkErrors.get(model) ?? "");
  const close = () => { linkDrafts.delete(model); linkErrors.delete(model); render(); };
  input.addEventListener("input", () => { linkDrafts.set(model, input.value); if (!error.hidden) { linkErrors.delete(model); showError(""); } });
  input.addEventListener("keydown", event => { if (event.key === "Escape") { event.preventDefault(); close(); document.getElementById(`model-link-open-${model}`)?.focus(); } });
  cancel.addEventListener("click", close);
  form.addEventListener("submit", event => {
    event.preventDefault();
    const link = input.value.trim();
    if (!link) { showError("Enter a link to a .zip of the model."); input.focus(); return; }
    submit.disabled = cancel.disabled = input.disabled = true;
    void (async () => {
      try { settings = await invoke<Settings>("set_model_link", { model, link }); }
      catch (e) {
        linkErrors.set(model, String(e)); linkDrafts.set(model, input.value); render();
        document.getElementById(`model-link-input-${model}`)?.focus(); return;
      }
      linkDrafts.delete(model); linkErrors.delete(model);
      try { await start(); } catch (e) { say(String(e), true); }
    })();
  });
  field.append(input, submit, cancel); form.append(field, help, error); parts.push(form);
  return parts;
}
function linkButton(model: string): HTMLButtonElement {
  const node = button("Download from link…", async () => openLinkEditor(model));
  node.id = `model-link-open-${model}`;
  return node;
}

type HubModel = { id: string; author?: string; name?: string; downloads: number; likes: number; pipelineTag: string | null; libraryName: string | null; languages: string[]; license: string | null; description?: string | null; gated: boolean; source: string };
type SearchHit = { key: string; title: string; publisher: string; detail: string; family?: string; model?: string; polishId?: string; repo?: string };
const searchInput = root.querySelector<HTMLInputElement>("#modelSearch")!;
const searchBox = root.querySelector<HTMLElement>("#modelSearchBox")!;
const searchClear = root.querySelector<HTMLButtonElement>("#modelSearchClear")!;
const searchStatus = root.querySelector<HTMLElement>("#modelSearchStatus")!;
const searchListbox = root.querySelector<HTMLElement>("#modelSearchListbox")!;
const searchResults = root.querySelector<HTMLElement>("#modelSearchResults")!;
let searchRevision = 0;
let searchTimer: ReturnType<typeof setTimeout> | undefined;
let searchHits: SearchHit[] = [];
let activeHit = 0;
let popoverOpen = false;
function supportedVariant(id: string): { family: string; model?: string } | null {
  const parakeet = /^(?:nvidia\/parakeet-tdt-0\.6b-(v[23])|istupakov\/parakeet-tdt-0\.6b-(v[23])-onnx)$/.exec(id);
  if (parakeet) {
    const model = `parakeet-tdt-0.6b-${parakeet[1] ?? parakeet[2]}`;
    if (speech.some(m => m.model === model)) return { family: "parakeet", model };
  }
  if (id === "moondream/parakeet-ultra" && speech.some(m => m.model === "parakeet-ultra")) return { family: "parakeet", model: "parakeet-ultra" };
  const whisper = /^openai\/whisper-(tiny|base|small|medium|large-v2|large-v3|large-v3-turbo)$/.exec(id);
  if (whisper && speech.some(m => m.model === whisper[1])) return { family: "whisper", model: whisper[1] };
  if (id === "ggerganov/whisper.cpp" && speech.some(m => !m.model.startsWith("parakeet"))) return { family: "whisper" };
  return null;
}
function polishFor(id: string): Model | undefined {
  return catalog?.polish.find(m => m.supported && m.source === `https://huggingface.co/${id}`);
}
function compatibleHit(model: HubModel): SearchHit | null {
  if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(model.id)) return null;
  const match = supportedVariant(model.id);
  const polish = polishFor(model.id);
  if (!match && !polish) return null;
  const publisher = model.author || model.id.split("/")[0];
  const title = model.name || model.id.split("/")[1];
  const detail = [model.libraryName, model.languages.slice(0, 3).join(", "), `${(model.downloads ?? 0).toLocaleString()} downloads`, model.license, model.gated ? "Access approval required" : null].filter(Boolean).join(" · ");
  return { key: `hub-${model.id}`, title: `${publisher}/${title}`, publisher, detail, family: match?.family, model: match?.model, polishId: polish?.id, repo: model.id };
}
// What the query keeps in the table, for the popover's first group.
function localHits(query: string): SearchHit[] {
  if (!settings || !catalog) return [];
  const rows = filterAndSort([...speechRows(), ...polishRows()], { ...filter, query }, sort);
  return rows.slice(0, 4).map((row) => ({ key: `local-${row.id}`, title: row.name, publisher: row.publisher, detail: row.summary, model: row.kind === "speech" ? row.id : undefined, polishId: row.kind === "polish" ? row.id : undefined }));
}
// Show a model's row: clear what would hide it, open it, and move to it.
function jumpTo(hit: SearchHit): void {
  closePopover();
  const id = hit.model ?? hit.polishId ?? (hit.family === "whisper" ? speech.find(m => !m.model.startsWith("parakeet"))?.model : undefined);
  if (!id) return;
  Object.assign(filter, { query: "", kind: "all", language: "all", downloadedOnly: false, localOnly: false });
  syncFilterControls();
  expanded.add(id);
  render();
  const target = document.getElementById(`model-${id}`);
  target?.scrollIntoView({ block: "center", behavior: "smooth" });
  target?.querySelector<HTMLElement>(".model-name-btn")?.focus({ preventScroll: true });
}
function placePopover(): void {
  const box = searchBox.getBoundingClientRect();
  searchListbox.style.setProperty("--ds-popover-top", `${box.bottom + 6}px`);
  searchListbox.style.setProperty("--ds-popover-left", `${box.left}px`);
  searchListbox.style.setProperty("--ds-popover-trigger-width", `${box.width}px`);
}
function closePopover(): void {
  popoverOpen = false;
  searchListbox.hidden = true;
  searchInput.setAttribute("aria-expanded", "false");
  searchInput.removeAttribute("aria-activedescendant");
}
function optionButton(hit: SearchHit, index: number): HTMLButtonElement {
  const option = document.createElement("button");
  option.type = "button";
  option.className = "ds-menu-option ds-menu-option--stacked model-search-option";
  option.id = `model-search-option-${index}`;
  option.setAttribute("role", "option");
  option.tabIndex = -1;
  option.setAttribute("aria-selected", String(index === activeHit));
  const text = document.createElement("span"); text.className = "ds-menu-option-text";
  const name = document.createElement("span"); name.className = "ds-menu-option-name"; name.textContent = hit.title;
  const supporting = document.createElement("span"); supporting.className = "ds-menu-option-supporting"; supporting.textContent = hit.detail;
  text.append(name, supporting);
  option.append(createPublisherIcon(hit.publisher, { size: "sm" }), text);
  option.addEventListener("pointerenter", () => { if (activeHit !== index) { activeHit = index; paintActive(); } });
  option.addEventListener("mousedown", event => event.preventDefault());
  option.addEventListener("click", () => jumpTo(hit));
  return option;
}
function paintActive(): void {
  const options = [...searchListbox.querySelectorAll<HTMLElement>("[role='option']")];
  options.forEach((option, index) => option.setAttribute("aria-selected", String(index === activeHit)));
  const current = options[activeHit];
  if (current) {
    searchInput.setAttribute("aria-activedescendant", current.id);
    current.scrollIntoView({ block: "nearest" });
  } else searchInput.removeAttribute("aria-activedescendant");
}
function renderPopover(local: SearchHit[], hub: SearchHit[], note: string | null): void {
  searchHits = [...local, ...hub];
  activeHit = Math.min(activeHit, Math.max(0, searchHits.length - 1));
  searchListbox.replaceChildren();
  const addGroup = (label: string, rows: SearchHit[], start: number) => {
    if (!rows.length) return;
    const group = document.createElement("div"); group.className = "model-search-group"; group.setAttribute("role", "group"); group.setAttribute("aria-label", label);
    const heading = document.createElement("div"); heading.className = "model-search-group-heading"; heading.textContent = label; heading.setAttribute("aria-hidden", "true");
    group.append(heading, ...rows.map((hit, i) => optionButton(hit, start + i)));
    searchListbox.append(group);
  };
  addGroup("In your library", local, 0);
  addGroup("Hugging Face", hub, local.length);
  if (note && !searchHits.length) {
    const empty = document.createElement("div"); empty.className = "model-search-empty"; empty.textContent = note;
    searchListbox.append(empty);
  }
  if (searchHits.length) {
    const footer = document.createElement("div"); footer.className = "model-search-footer";
    footer.innerHTML = `<span><span class="ds-kbd-chord"><kbd class="ds-kbd-chord-key">↑</kbd><kbd class="ds-kbd-chord-key">↓</kbd></span> to select</span><span><span class="ds-kbd-chord"><kbd class="ds-kbd-chord-key">↵</kbd></span> to choose</span>`;
    searchListbox.append(footer);
  }
  popoverOpen = true;
  searchListbox.hidden = false;
  searchInput.setAttribute("aria-expanded", "true");
  placePopover();
  paintActive();
}
const hubSection = root.querySelector<HTMLElement>("#hubSection")!;
function renderHubList(hits: SearchHit[]): void {
  searchResults.replaceChildren();
  hubSection.hidden = hits.length === 0;
  for (const hit of hits) {
    const item = document.createElement("div"); item.className = "ds-list-row model-hub-row model-search-hit";
    const content = document.createElement("div"); content.className = "ds-list-row-content";
    const title = document.createElement("div"); title.className = "ds-list-row-title"; title.textContent = hit.title;
    const detail = document.createElement("span"); detail.className = "ds-list-row-supporting"; detail.textContent = hit.detail;
    content.append(title, detail);
    const actions = document.createElement("div"); actions.className = "models-actions";
    actions.append(button("Show in library", async () => jumpTo(hit)));
    if (hit.repo) actions.append(button("Model page ↗", () => openUrl(`https://huggingface.co/${hit.repo}`)));
    item.append(createPublisherIcon(hit.publisher), content, actions);
    searchResults.append(item);
  }
}
async function searchHub(query: string, revision: number, local: SearchHit[]): Promise<void> {
  searchStatus.textContent = "Searching Hugging Face…"; searchResults.setAttribute("aria-busy", "true");
  if (document.activeElement === searchInput) renderPopover(local, [], "Searching Hugging Face…");
  try {
    const result = await invoke<{ models: HubModel[]; cached: boolean }>("search_hugging_face_models", { query });
    if (revision !== searchRevision) return;
    const hub = result.models.map(compatibleHit).filter((hit): hit is SearchHit => !!hit);
    const count = hub.length;
    searchStatus.textContent = count ? `${count} compatible on Hugging Face${result.cached ? " · cached" : ""}` : "No compatible models on Hugging Face for that search.";
    renderHubList(hub);
    if (document.activeElement === searchInput) renderPopover(localHits(query), hub, count ? null : "No compatible models for that search.");
  } catch (error) {
    if (revision !== searchRevision) return;
    searchStatus.textContent = `Search unavailable: ${String(error)}. Edit your search to try again.`;
    searchResults.replaceChildren();
    if (document.activeElement === searchInput) renderPopover(localHits(query), [], searchStatus.textContent);
  } finally {
    if (revision === searchRevision) searchResults.setAttribute("aria-busy", "false");
  }
}
function scheduleSearch(): void {
  const revision = ++searchRevision; clearTimeout(searchTimer);
  const query = searchInput.value.trim();
  searchClear.hidden = !query;
  filter.query = query; render();
  searchResults.replaceChildren(); hubSection.hidden = true; searchResults.setAttribute("aria-busy", "false");
  if (!query) {
    closePopover();
    searchStatus.textContent = "";
    return;
  }
  const local = localHits(query);
  searchStatus.textContent = "Waiting to search…";
  if (document.activeElement === searchInput) renderPopover(local, [], local.length ? null : "Waiting to search…");
  searchTimer = setTimeout(() => { void searchHub(query, revision, localHits(query)); }, 350);
}
searchInput.addEventListener("input", scheduleSearch);
searchInput.addEventListener("focus", () => {
  const query = searchInput.value.trim();
  if (query && !popoverOpen) renderPopover(localHits(query), [], null);
});
searchClear.addEventListener("mousedown", event => event.preventDefault());
searchClear.addEventListener("click", () => { searchInput.value = ""; searchInput.focus(); scheduleSearch(); });
searchInput.addEventListener("keydown", event => {
  if (event.key === "Escape") {
    event.preventDefault();
    if (popoverOpen) closePopover();
    else { searchInput.value = ""; scheduleSearch(); }
    return;
  }
  if (event.key === "ArrowDown" || event.key === "ArrowUp") {
    if (!popoverOpen || !searchHits.length) return;
    event.preventDefault();
    activeHit = (activeHit + (event.key === "ArrowDown" ? 1 : searchHits.length - 1)) % searchHits.length;
    paintActive();
    return;
  }
  if (event.key === "Enter") {
    event.preventDefault();
    const hit = searchHits[activeHit];
    if (popoverOpen && hit) jumpTo(hit);
    else { clearTimeout(searchTimer); void searchHub(searchInput.value.trim(), ++searchRevision, localHits(searchInput.value.trim())); }
  }
});
document.addEventListener("pointerdown", event => {
  if (popoverOpen && !searchBox.contains(event.target as Node) && !searchListbox.contains(event.target as Node)) closePopover();
});
window.addEventListener("resize", () => { if (popoverOpen) placePopover(); });
