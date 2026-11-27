import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

import "./dashboardShell";
import "./homeStats";
import "./dictionary";
import "./trainingData";
import "./activity";
import "./modelDashboard";
import "./settingsModelSummaries";
import "./updates";
import { categories, currentCategory, PAGES, resolveCategory, selectSettingsCategory, settingsQuery } from "./settingsNavigation";
import "./sidebarStatus";
import { createSpeedTest } from "./speedTest";
import { createVoiceAccuracyTest } from "./voiceAccuracyTest";
import * as history from "./historyStore";
import { initThreadList, focusSearch as focusHistorySearch } from "./threadList";
import { renderDictation } from "./dictationView";
import "./homeView";
import { initPalette, isPaletteOpen, openPalette, PALETTE_SHORTCUT } from "./palette";
import { isMacOS } from "./shortcuts";
import { monogramEl } from "./icons";
// The window's look, last: it lays out the shell and restyles the feature sheets above.
import "./bark.css";

// The main window's shell, as on the Mac: the thread list (or the settings
// list) down the left, a breadcrumb top bar, and one screen at a time. Every
// way of getting somewhere (the sidebar, links, ⌘K, the pill's gear) ends up
// in `navigate`.

type Section = "home" | "models" | "training" | "settings" | "speedtest" | "voicetest";

const shell = document.getElementById("shell")!;
const screens = Array.from(document.querySelectorAll<HTMLElement>(".screen"));
const breadcrumb = document.getElementById("breadcrumb")!;
const micPicker = document.getElementById("micPicker")!;
const panelToggle = document.getElementById("panelToggle") as HTMLButtonElement;
const historyPane = document.getElementById("historyPane")!;
const settingsPane = document.getElementById("settingsPane")!;
const dictationScreen = document.getElementById("screen-dictation")!;
const content = document.getElementById("content")!;

document.documentElement.dataset.platform = isMacOS() ? "mac" : "other";

let section: Section = "home";
let selectedId: string | null = null;

const speedTestContainer = document.getElementById("speedTest");
const speedTest = speedTestContainer ? createSpeedTest({ container: speedTestContainer, onExit: () => navigate("home") }) : null;
const voiceTestContainer = document.getElementById("voiceTest");
const voiceTest = voiceTestContainer ? createVoiceAccuracyTest({ container: voiceTestContainer, onExit: () => navigate("home") }) : null;

export function selectedDictation(): string | null { return selectedId; }

// ── Sidebar ──

const SIDEBAR_KEY = "bark.sidebarHidden";
function setSidebar(visible: boolean): void {
  shell.dataset.sidebar = visible ? "visible" : "hidden";
  try { localStorage.setItem(SIDEBAR_KEY, visible ? "0" : "1"); } catch { /* session only */ }
  for (const button of document.querySelectorAll<HTMLElement>('[data-action="toggle-sidebar"]')) {
    const label = visible ? "Hide sidebar" : "Show sidebar";
    button.setAttribute("aria-label", label);
    button.title = `${label} (${isMacOS() ? "⌃⌘S" : "Ctrl+Shift+S"})`;
  }
}
try { setSidebar(localStorage.getItem(SIDEBAR_KEY) !== "1"); } catch { setSidebar(true); }

// ── Breadcrumb ──

function crumb(text: string, onClick?: () => void): HTMLElement {
  if (onClick) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "crumb crumb--link";
    button.textContent = text;
    button.addEventListener("click", onClick);
    return button;
  }
  const span = document.createElement("span");
  span.className = "crumb crumb--current";
  span.textContent = text;
  return span;
}

function separator(): HTMLElement {
  const span = document.createElement("span");
  span.className = "crumb-sep";
  span.setAttribute("aria-hidden", "true");
  span.textContent = "/";
  return span;
}

function renderBreadcrumb(): void {
  const parts: HTMLElement[] = [];
  const item = section === "home" ? history.dictation(selectedId) : null;
  if (item) {
    const name = history.appName(item);
    parts.push(monogramEl(name, item.isNote, "md"), crumb(name, () => navigate("home")), separator(), crumb(history.title(item)));
    parts[1].title = "Back to Home (esc)";
  } else if (section === "settings") {
    parts.push(crumb("Settings", () => selectSettingsCategory("general")), separator(),
      crumb(settingsQuery() ? "Search" : PAGES[currentCategory()].title));
  } else {
    const titles: Record<Section, string> = { home: "Home", models: "Models", training: "Post-training", settings: "Settings", speedtest: "Speed test", voicetest: "Accuracy test" };
    if (section === "speedtest" || section === "voicetest") parts.push(crumb("Home", () => navigate("home")), separator());
    parts.push(crumb(titles[section]));
  }
  breadcrumb.replaceChildren(...parts);
}

// ── Navigation ──

function showScreen(id: string): void {
  for (const screen of screens) screen.classList.toggle("active", screen.id === id);
}

/** Routes: home, dictation/<id>, models, training, settings[/<page>[#<id>]], speedtest, voicetest. */
export function navigate(route: string): void {
  const [path, anchor] = route.split("#");
  const [head, rest] = [path.split("/")[0], path.split("/").slice(1).join("/")];
  speedTest?.stop();
  voiceTest?.stop();
  const wasSettings = section === "settings";

  switch (head) {
    case "dictation":
      section = "home";
      selectedId = history.find(rest)?.id ?? null;
      break;
    case "notes":
    case "home":
      section = "home";
      selectedId = null;
      break;
    case "models":
    case "training":
    case "speedtest":
    case "voicetest":
      section = head;
      selectedId = null;
      break;
    case "dictionary":
    case "activity":
      section = "settings";
      selectSettingsCategory(head);
      break;
    case "settings":
      section = "settings";
      if (rest && resolveCategory(rest)) selectSettingsCategory(rest);
      break;
    default:
      return;
  }

  shell.dataset.section = section;
  historyPane.hidden = section === "settings";
  settingsPane.hidden = section !== "settings";
  for (const button of document.querySelectorAll<HTMLElement>("[data-nav]")) {
    const on = button.dataset.nav === section && (section !== "home" || selectedId === null);
    if (on) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current");
  }

  if (section === "home" && selectedId) {
    showScreen("screen-dictation");
    renderDictation(dictationScreen, selectedId);
  } else {
    showScreen(`screen-${section}`);
  }
  micPicker.hidden = !(section === "home" && !selectedId);
  panelToggle.hidden = !(section === "home" && selectedId);
  const saveStatus = document.getElementById("settingsSaveStatus");
  if (saveStatus) saveStatus.hidden = section !== "settings";
  if (section === "speedtest") speedTest?.start();
  if (section === "voicetest") voiceTest?.start();
  if (!(section === "home" && selectedId)) content.scrollTop = 0;

  renderBreadcrumb();
  document.dispatchEvent(new CustomEvent("home-screen-changed", { detail: { screen: section, dictation: selectedId } }));
  if (section === "settings" && !wasSettings) document.getElementById("settingsSearch")?.blur();
  if (anchor) {
    const target = document.getElementById(anchor);
    const row = target?.closest<HTMLElement>(".row") ?? target;
    if (row) {
      row.closest("details")?.setAttribute("open", "");
      requestAnimationFrame(() => {
        row.scrollIntoView({ block: "center" });
        row.classList.add("row--flash");
        setTimeout(() => row.classList.remove("row--flash"), 1200);
        target?.focus({ preventScroll: true });
      });
    }
  }
}

document.addEventListener("settings-category-changed", () => { if (section === "settings") renderBreadcrumb(); });
history.subscribe(() => {
  if (section === "home" && selectedId) {
    if (!history.dictation(selectedId)) navigate("home");
    else { renderDictation(dictationScreen, selectedId); renderBreadcrumb(); }
  }
});

// One listener for every link-like control, including ones drawn later.
document.addEventListener("click", (event) => {
  const target = (event.target as HTMLElement).closest<HTMLElement>("[data-route], [data-open], [data-settings-target], [data-nav], [data-action]");
  if (!target || (target as HTMLButtonElement).disabled) return;
  if (target.dataset.nav) {
    navigate(target.dataset.nav);
  } else if (target.dataset.route) {
    const route = target.dataset.route === "settings" && target.dataset.settingsTarget
      ? `settings/${target.dataset.settingsTarget}` : target.dataset.route;
    navigate(route);
  } else if (target.dataset.settingsTarget) {
    navigate(`settings/${target.dataset.settingsTarget}`);
  } else if (target.dataset.open === "speedtest" || target.dataset.open === "voicetest") {
    navigate(target.dataset.open);
  } else if (target.dataset.open === "onboarding") {
    void invoke("open_onboarding_window").catch(() => {});
  } else if (target.dataset.action === "toggle-sidebar") {
    setSidebar(shell.dataset.sidebar === "hidden");
  } else if (target.dataset.action === "back") {
    navigate("home");
  } else {
    return;
  }
  event.preventDefault();
});

// Tooltips: the system's own, as `.help` gives on the Mac.
for (const el of document.querySelectorAll<HTMLElement>("[data-tip]")) {
  if (!el.title) el.title = el.dataset.tip!;
}

// ── Keyboard ──

const mod = (event: KeyboardEvent) => (isMacOS() ? event.metaKey : event.ctrlKey) && !event.altKey;
document.addEventListener("keydown", (event) => {
  if (isPaletteOpen()) return;
  if (mod(event) && !event.shiftKey && /^[1-4]$/.test(event.key)) {
    event.preventDefault();
    navigate((["home", "models", "training", "settings"] as const)[Number(event.key) - 1]);
  } else if (mod(event) && event.shiftKey && event.key.toLowerCase() === "s") {
    event.preventDefault();
    setSidebar(shell.dataset.sidebar === "hidden");
  } else if (mod(event) && !event.shiftKey && event.key.toLowerCase() === "f") {
    event.preventDefault();
    setSidebar(true);
    if (section === "settings") document.getElementById("settingsSearch")?.focus();
    else focusHistorySearch();
  } else if (event.key === "Escape" && !event.defaultPrevented) {
    const field = (event.target as HTMLElement).closest("input, textarea, select");
    if (field && field.id !== "settingsSearch") return;
    if (document.querySelector(".shortcut[data-capturing], .shortcut.capturing")) return;
    if (section === "settings" && !settingsQuery()) navigate("home");
    else if (section === "home" && selectedId) navigate("home");
    else if (section === "speedtest" || section === "voicetest") navigate("home");
  }
});

// ⌘K / Ctrl+K: search and commands.
initPalette();
document.addEventListener("bark-navigate", (event) => {
  const route = (event as CustomEvent<{ route: string }>).detail?.route;
  if (typeof route === "string") navigate(route);
});
const paletteKey = document.getElementById("paletteKey");
if (paletteKey) {
  paletteKey.textContent = PALETTE_SHORTCUT.replace("+", " ");
  paletteKey.addEventListener("click", () => openPalette());
}
const settingsSearchKey = document.getElementById("settingsSearchKey");
if (settingsSearchKey) settingsSearchKey.textContent = isMacOS() ? "⌘F" : "Ctrl F";

// The pill's gear and the tray open this window on a screen.
void listen<string>("home-navigate", (event) => {
  if (typeof event.payload === "string") navigate(event.payload);
}).catch(() => { /* best-effort; the window still opens on Home */ });

// "Bark 0.1.0 · Stable" at the foot of the settings list, and on About.
type VersionStatus = { currentVersion?: string; channel?: string; buildChannel?: string };
function showVersion(status: VersionStatus | null | undefined): void {
  if (!status?.currentVersion) return;
  const channel = status.channel === "nightly" ? "Nightly" : "Stable";
  document.getElementById("sidebarVersion")!.textContent = `Bark ${status.currentVersion} · ${channel}`;
  document.getElementById("aboutVersion")!.textContent = `Version ${status.currentVersion} · ${channel} channel`;
}
void listen<VersionStatus>("update-status", (event) => showVersion(event.payload)).catch(() => {});
void invoke<VersionStatus>("get_update_status").then(showVersion).catch(() => {});

initThreadList({ navigate, selected: () => (section === "home" ? selectedId : null) });
void history.refresh();

// Kept for links that still name a category directly.
export { categories };

// Deep links for looking at a screen: home.html#settings/general.
const initial = decodeURIComponent(location.hash.slice(1));
if (initial) {
  void history.refresh().then(() => navigate(initial));
}
navigate("home");
